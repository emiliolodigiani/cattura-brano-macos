//
//  AudioProcessing.swift
//  cattura brano
//
//  Scrittura del flusso in registrazione e trim del silenzio in esportazione.
//

import AVFoundation

nonisolated enum RecorderError: LocalizedError {
    case deviceSelectionFailed(OSStatus)
    case invalidFormat
    case emptyRecording

    var errorDescription: String? {
        switch self {
        case .deviceSelectionFailed(let status):
            "Impossibile selezionare l'interfaccia audio (codice \(status))."
        case .invalidFormat:
            "Formato audio dell'interfaccia non valido."
        case .emptyRecording:
            "La registrazione non contiene audio da salvare."
        }
    }
}

/// Riceve i buffer dal tap del motore audio (thread audio in tempo reale) e li
/// scrive su un file temporaneo. Calcola anche il picco per il misuratore di livello.
///
/// È `nonisolated`/`@unchecked Sendable` perché viene invocata dal thread audio,
/// non dal main actor.
nonisolated final class TapWriter: @unchecked Sendable {
    private var file: AVAudioFile?
    private let lock = NSLock()
    private var peaks: [Float]

    init(url: URL, format: AVAudioFormat) throws {
        peaks = [Float](repeating: 0, count: Int(format.channelCount))
        file = try AVAudioFile(
            forWriting: url,
            settings: format.settings,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
    }

    /// Aggiunge un buffer al file e aggiorna il picco corrente di ogni canale.
    func append(_ buffer: AVAudioPCMBuffer) {
        try? file?.write(from: buffer)

        guard let channelData = buffer.floatChannelData else { return }
        let frames = Int(buffer.frameLength)
        let channels = min(Int(buffer.format.channelCount), peaks.count)
        var localPeaks = [Float](repeating: 0, count: channels)
        // Sotto-campioniamo (passo 8) per non gravare sul thread audio.
        for channel in 0..<channels {
            let samples = channelData[channel]
            var frame = 0
            while frame < frames {
                let value = abs(samples[frame])
                if value > localPeaks[channel] { localPeaks[channel] = value }
                frame += 8
            }
        }

        lock.lock()
        for channel in 0..<channels where localPeaks[channel] > peaks[channel] {
            peaks[channel] = localPeaks[channel]
        }
        lock.unlock()
    }

    /// Restituisce i picchi per canale accumulati dall'ultima lettura e li azzera.
    func consumePeaks() -> [Float] {
        lock.lock()
        defer {
            peaks = [Float](repeating: 0, count: peaks.count)
            lock.unlock()
        }
        return peaks
    }

    /// Chiude il file, assicurando lo scaricamento su disco.
    func close() {
        file = nil
    }
}

/// Legge una registrazione temporanea, rimuove il silenzio iniziale e finale e
/// la esporta nel formato scelto.
nonisolated enum AudioProcessor {

    /// Rileva i confini non silenziosi ed esporta la regione utile.
    /// - Parameters:
    ///   - silenceThreshold: ampiezza lineare (0…1) sotto cui un campione è
    ///     silenzio; `nil` disattiva il trim e salva l'intera registrazione.
    ///   - padding: secondi di margine da mantenere prima/dopo l'audio.
    /// - Returns: l'URL del file salvato.
    static func trimAndExport(
        source: URL,
        folder: URL,
        name: String,
        format: RecordingFormat,
        silenceThreshold: Float?,
        padding: Double = 0.1
    ) throws -> URL {
        let readFile = try AVAudioFile(forReading: source)
        let processingFormat = readFile.processingFormat
        let sampleRate = processingFormat.sampleRate
        let channels = processingFormat.channelCount
        let totalFrames = readFile.length

        let chunkSize: AVAudioFrameCount = 65_536
        guard let buffer = AVAudioPCMBuffer(pcmFormat: processingFormat, frameCapacity: chunkSize) else {
            throw RecorderError.invalidFormat
        }

        // Passo 1 — individua il primo e l'ultimo campione sopra la soglia
        // (solo se il trim del silenzio è attivo).
        var firstNonSilent: AVAudioFramePosition = -1
        var lastNonSilent: AVAudioFramePosition = -1

        if let silenceThreshold {
            var position: AVAudioFramePosition = 0
            readFile.framePosition = 0
            while true {
                try readFile.read(into: buffer, frameCount: chunkSize)
                let framesRead = Int(buffer.frameLength)
                if framesRead == 0 { break }

                if let channelData = buffer.floatChannelData {
                    for frame in 0..<framesRead {
                        var amplitude: Float = 0
                        for channel in 0..<Int(channels) {
                            let value = abs(channelData[channel][frame])
                            if value > amplitude { amplitude = value }
                        }
                        if amplitude > silenceThreshold {
                            let globalFrame = position + AVAudioFramePosition(frame)
                            if firstNonSilent < 0 { firstNonSilent = globalFrame }
                            lastNonSilent = globalFrame
                        }
                    }
                }

                position += AVAudioFramePosition(framesRead)
                if buffer.frameLength < chunkSize { break }
            }
        }

        // Determina la regione da esportare.
        let startFrame: AVAudioFramePosition
        let endFrame: AVAudioFramePosition
        if firstNonSilent < 0 {
            // Trim disattivato o tutto silenzio: conserva l'intera registrazione.
            startFrame = 0
            endFrame = totalFrames
        } else {
            let pad = AVAudioFramePosition(padding * sampleRate)
            startFrame = max(0, firstNonSilent - pad)
            endFrame = min(totalFrames, lastNonSilent + pad + 1)
        }

        let framesToWrite = endFrame - startFrame
        guard framesToWrite > 0 else { throw RecorderError.emptyRecording }

        // Passo 2 — scrivi la regione utile nel formato richiesto.
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let outputURL = uniqueURL(folder: folder, name: name, fileExtension: format.fileExtension)

        if format.usesLAME {
            try exportMP3(
                readFile: readFile,
                buffer: buffer,
                startFrame: startFrame,
                framesToWrite: framesToWrite,
                chunkSize: chunkSize,
                sampleRate: sampleRate,
                channels: channels,
                bitrateKbps: format.bitrateKbps,
                outputURL: outputURL
            )
        } else {
            let outputFile = try AVAudioFile(
                forWriting: outputURL,
                settings: format.settings(sampleRate: sampleRate, channels: channels),
                commonFormat: .pcmFormatFloat32,
                interleaved: false
            )
            try readRegion(
                readFile: readFile, buffer: buffer, startFrame: startFrame,
                framesToWrite: framesToWrite, chunkSize: chunkSize
            ) { chunk in
                try outputFile.write(from: chunk)
            }
        }

        return outputURL
    }

    /// Legge la regione [startFrame, startFrame+framesToWrite) a blocchi,
    /// invocando `handle` per ciascun blocco letto.
    private static func readRegion(
        readFile: AVAudioFile,
        buffer: AVAudioPCMBuffer,
        startFrame: AVAudioFramePosition,
        framesToWrite: AVAudioFramePosition,
        chunkSize: AVAudioFrameCount,
        handle: (AVAudioPCMBuffer) throws -> Void
    ) throws {
        readFile.framePosition = startFrame
        var remaining = framesToWrite
        while remaining > 0 {
            let toRead = AVAudioFrameCount(min(AVAudioFramePosition(chunkSize), remaining))
            try readFile.read(into: buffer, frameCount: toRead)
            let framesRead = buffer.frameLength
            if framesRead == 0 { break }
            try handle(buffer)
            remaining -= AVAudioFramePosition(framesRead)
            if framesRead < toRead { break }
        }
    }

    /// Esporta la regione in MP3 tramite LAME (disponibile solo con `LAME_ENABLED`).
    private static func exportMP3(
        readFile: AVAudioFile,
        buffer: AVAudioPCMBuffer,
        startFrame: AVAudioFramePosition,
        framesToWrite: AVAudioFramePosition,
        chunkSize: AVAudioFrameCount,
        sampleRate: Double,
        channels: AVAudioChannelCount,
        bitrateKbps: Int,
        outputURL: URL
    ) throws {
        #if LAME_ENABLED
        let encoder = try MP3Encoder(
            url: outputURL, sampleRate: sampleRate, channels: channels, bitrateKbps: bitrateKbps
        )
        try readRegion(
            readFile: readFile, buffer: buffer, startFrame: startFrame,
            framesToWrite: framesToWrite, chunkSize: chunkSize
        ) { chunk in
            try encoder.encode(chunk)
        }
        try encoder.finalize()
        #else
        throw RecorderError.invalidFormat
        #endif
    }

    /// Un URL disponibile nella cartella: aggiunge " 2", " 3", … se il nome esiste.
    private static func uniqueURL(folder: URL, name: String, fileExtension: String) -> URL {
        let base = folder.appendingPathComponent(name).appendingPathExtension(fileExtension)
        if !FileManager.default.fileExists(atPath: base.path) { return base }
        var index = 2
        while true {
            let candidate = folder
                .appendingPathComponent("\(name) \(index)")
                .appendingPathExtension(fileExtension)
            if !FileManager.default.fileExists(atPath: candidate.path) { return candidate }
            index += 1
        }
    }
}
