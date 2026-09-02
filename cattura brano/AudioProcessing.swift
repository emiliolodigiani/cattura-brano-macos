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
    case separationFailed(String)

    var errorDescription: String? {
        switch self {
        case .deviceSelectionFailed(let status):
            "Impossibile selezionare l'interfaccia audio (codice \(status))."
        case .invalidFormat:
            "L'interfaccia selezionata non fornisce audio (formato non valido). Potrebbe essere in uso esclusivo da un'altra app: chiudi le app che la usano, scollegala e ricollegala, o riavvia il Mac."
        case .emptyRecording:
            "La registrazione non contiene audio da salvare."
        case .separationFailed(let details):
            "Separazione degli stem non riuscita. \(details)"
        }
    }
}

/// Esito dell'esportazione principale.
nonisolated struct ExportResult {
    let savedURL: URL
    /// WAV temporaneo della regione elaborata (rifilata e normalizzata, senza
    /// click), da passare al post-processore per le tracce aggiuntive;
    /// `nil` se non richiesto.
    let processedCopyURL: URL?
}

/// Riceve i buffer dal tap del motore audio (thread audio in tempo reale) e li
/// scrive su un file temporaneo. Calcola anche il picco per il misuratore di livello.
///
/// Con `url` a `nil` non scrive nulla e fa solo da misuratore: è la modalità
/// usata per monitorare il livello d'ingresso prima della registrazione.
///
/// È `nonisolated`/`@unchecked Sendable` perché viene invocata dal thread audio,
/// non dal main actor.
nonisolated final class TapWriter: @unchecked Sendable {
    private var file: AVAudioFile?
    private let lock = NSLock()
    private var peaks: [Float]
    /// Ultimo picco valido, restituito quando tra due letture non sono arrivati
    /// buffer nuovi (il tap consegna a cadenza diversa da quella del misuratore).
    private var heldPeaks: [Float]
    private var hasFreshPeaks = false

    init(url: URL?, format: AVAudioFormat) throws {
        peaks = [Float](repeating: 0, count: Int(format.channelCount))
        heldPeaks = peaks
        file = try url.map {
            try AVAudioFile(
                forWriting: $0,
                settings: format.settings,
                commonFormat: .pcmFormatFloat32,
                interleaved: false
            )
        }
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
        hasFreshPeaks = true
        lock.unlock()
    }

    /// Restituisce i picchi per canale accumulati dall'ultima lettura e li azzera.
    /// Se non è arrivato nessun buffer nuovo, ripropone l'ultimo valore valido
    /// invece di uno zero spurio (che farebbe lampeggiare il misuratore).
    func consumePeaks() -> [Float] {
        lock.lock()
        defer { lock.unlock() }
        if hasFreshPeaks {
            heldPeaks = peaks
            peaks = [Float](repeating: 0, count: peaks.count)
            hasFreshPeaks = false
        }
        return heldPeaks
    }

    /// Chiude il file, assicurando lo scaricamento su disco.
    func close() {
        file = nil
    }
}

/// Legge una registrazione temporanea, rimuove il silenzio iniziale e finale e
/// la esporta nel formato scelto.
nonisolated enum AudioProcessor {

    /// Picco di destinazione della normalizzazione: −1 dBFS.
    private static let normalizationPeak: Float = 0.891

    /// Rileva i confini non silenziosi ed esporta la regione utile.
    /// - Parameters:
    ///   - silenceThreshold: ampiezza lineare (0…1) sotto cui un campione è
    ///     silenzio; `nil` disattiva il trim e salva l'intera registrazione.
    ///   - appendBPM: se `true` stima i BPM e li aggiunge al nome del file
    ///     (solo quando rilevabili con confidenza sufficiente).
    ///   - normalize: se `true` riporta il picco della traccia a −1 dBFS.
    ///   - prepareProcessedCopy: se `true` scrive anche un WAV temporaneo
    ///     della regione elaborata per le tracce aggiuntive (click/drumless).
    ///   - padding: secondi di margine da mantenere prima/dopo l'audio.
    static func trimAndExport(
        source: URL,
        folder: URL,
        name: String,
        format: RecordingFormat,
        silenceThreshold: Float?,
        appendBPM: Bool = false,
        normalize: Bool = false,
        prepareProcessedCopy: Bool = false,
        padding: Double = 0.1
    ) throws -> ExportResult {
        let readFile = try AVAudioFile(forReading: source)
        let processingFormat = readFile.processingFormat
        let sampleRate = processingFormat.sampleRate
        let channels = processingFormat.channelCount
        let totalFrames = readFile.length

        let chunkSize: AVAudioFrameCount = 65_536
        guard let buffer = AVAudioPCMBuffer(pcmFormat: processingFormat, frameCapacity: chunkSize) else {
            throw RecorderError.invalidFormat
        }

        // Passo 1 — analisi: confini non silenziosi (per il trim) e picco
        // globale (per la normalizzazione), in un'unica lettura.
        var firstNonSilent: AVAudioFramePosition = -1
        var lastNonSilent: AVAudioFramePosition = -1
        var globalPeak: Float = 0

        if silenceThreshold != nil || normalize {
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
                        if amplitude > globalPeak { globalPeak = amplitude }
                        if let silenceThreshold, amplitude > silenceThreshold {
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

        // Guadagno di normalizzazione: riporta il picco a −1 dBFS.
        var gain: Float = 1
        if normalize, globalPeak > 0 {
            gain = Self.normalizationPeak / globalPeak
        }

        // Stima dei BPM sulla stessa regione che verrà esportata.
        var finalName = name
        if appendBPM {
            let analysis = BeatDetector.analyze(
                readFile: readFile, startFrame: startFrame, endFrame: endFrame
            )
            if let bpm = analysis.bpm {
                finalName += " - \(Int(bpm.rounded())) BPM"
            }
        }

        // Passo 2 — scrivi la regione utile nel formato richiesto.
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let outputURL = uniqueURL(folder: folder, name: finalName, fileExtension: format.fileExtension)

        if format.usesLAME {
            try exportMP3(
                readFile: readFile,
                buffer: buffer,
                startFrame: startFrame,
                framesToWrite: framesToWrite,
                chunkSize: chunkSize,
                gain: gain,
                clickBeats: [],
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
                framesToWrite: framesToWrite, chunkSize: chunkSize, gain: gain
            ) { chunk in
                try outputFile.write(from: chunk)
            }
        }

        // Copia elaborata per il post-processore (click/drumless): stessa
        // regione e stesso guadagno, in WAV float senza perdita.
        var processedCopyURL: URL?
        if prepareProcessedCopy {
            let copyURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("cattura-elaborata-\(UUID().uuidString).wav")
            let copyFile = try AVAudioFile(
                forWriting: copyURL,
                settings: [
                    AVFormatIDKey: kAudioFormatLinearPCM,
                    AVSampleRateKey: sampleRate,
                    AVNumberOfChannelsKey: Int(channels),
                    AVLinearPCMBitDepthKey: 32,
                    AVLinearPCMIsFloatKey: true,
                    AVLinearPCMIsBigEndianKey: false,
                    AVLinearPCMIsNonInterleaved: false,
                ],
                commonFormat: .pcmFormatFloat32,
                interleaved: false
            )
            try readRegion(
                readFile: readFile, buffer: buffer, startFrame: startFrame,
                framesToWrite: framesToWrite, chunkSize: chunkSize, gain: gain
            ) { chunk in
                try copyFile.write(from: chunk)
            }
            processedCopyURL = copyURL
        }

        return ExportResult(savedURL: outputURL, processedCopyURL: processedCopyURL)
    }

    /// Esporta un file già elaborato (nessun trim né guadagno) nel formato
    /// scelto, mixando eventualmente il click sulle battute indicate.
    /// - Parameter clickBeatsSeconds: posizioni delle battute in secondi
    ///   (indipendenti dalla frequenza di campionamento della sorgente).
    static func exportProcessed(
        source: URL,
        folder: URL,
        name: String,
        format: RecordingFormat,
        clickBeatsSeconds: [Double]
    ) throws -> URL {
        let readFile = try AVAudioFile(forReading: source)
        let processingFormat = readFile.processingFormat
        let sampleRate = processingFormat.sampleRate
        let channels = processingFormat.channelCount
        let chunkSize: AVAudioFrameCount = 65_536
        guard let buffer = AVAudioPCMBuffer(pcmFormat: processingFormat, frameCapacity: chunkSize)
        else { throw RecorderError.invalidFormat }

        let clickBeats = clickBeatsSeconds.map { AVAudioFramePosition($0 * sampleRate) }

        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let outputURL = uniqueURL(folder: folder, name: name, fileExtension: format.fileExtension)

        if format.usesLAME {
            try exportMP3(
                readFile: readFile,
                buffer: buffer,
                startFrame: 0,
                framesToWrite: readFile.length,
                chunkSize: chunkSize,
                gain: 1,
                clickBeats: clickBeats,
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
                readFile: readFile, buffer: buffer, startFrame: 0,
                framesToWrite: readFile.length, chunkSize: chunkSize,
                clickBeats: clickBeats, sampleRate: sampleRate
            ) { chunk in
                try outputFile.write(from: chunk)
            }
        }

        return outputURL
    }

    /// Legge la regione [startFrame, startFrame+framesToWrite) a blocchi,
    /// applica guadagno ed eventuale click e invoca `handle` per ciascun blocco.
    private static func readRegion(
        readFile: AVAudioFile,
        buffer: AVAudioPCMBuffer,
        startFrame: AVAudioFramePosition,
        framesToWrite: AVAudioFramePosition,
        chunkSize: AVAudioFrameCount,
        gain: Float = 1,
        clickBeats: [AVAudioFramePosition] = [],
        sampleRate: Double = 0,
        handle: (AVAudioPCMBuffer) throws -> Void
    ) throws {
        readFile.framePosition = startFrame
        var position = startFrame
        var remaining = framesToWrite
        while remaining > 0 {
            let toRead = AVAudioFrameCount(min(AVAudioFramePosition(chunkSize), remaining))
            try readFile.read(into: buffer, frameCount: toRead)
            let framesRead = buffer.frameLength
            if framesRead == 0 { break }
            if gain != 1, let channelData = buffer.floatChannelData {
                for channel in 0..<Int(buffer.format.channelCount) {
                    let samples = channelData[channel]
                    for frame in 0..<Int(framesRead) { samples[frame] *= gain }
                }
            }
            if !clickBeats.isEmpty {
                mixClick(
                    into: buffer, chunkStart: position, beats: clickBeats, sampleRate: sampleRate
                )
            }
            try handle(buffer)
            position += AVAudioFramePosition(framesRead)
            remaining -= AVAudioFramePosition(framesRead)
            if framesRead < toRead { break }
        }
    }

    // MARK: Click sulle battute

    /// Parametri del tick: 1 kHz, 30 ms, decadimento esponenziale.
    private static let clickFrequency = 1000.0
    private static let clickDuration = 0.03
    private static let clickDecay = 0.006
    private static let clickAmplitude: Float = 0.6

    /// Somma un tick a ogni battuta che ricade (anche parzialmente) nel blocco.
    /// Il click viene aggiunto dopo la normalizzazione, così il suo volume è
    /// sempre lo stesso; la somma è limitata a ±1 per evitare distorsioni.
    private static func mixClick(
        into buffer: AVAudioPCMBuffer,
        chunkStart: AVAudioFramePosition,
        beats: [AVAudioFramePosition],
        sampleRate: Double
    ) {
        guard sampleRate > 0, let channelData = buffer.floatChannelData else { return }
        let frames = Int(buffer.frameLength)
        let chunkEnd = chunkStart + AVAudioFramePosition(frames)
        let clickFrames = AVAudioFramePosition(clickDuration * sampleRate)
        let channels = Int(buffer.format.channelCount)

        for beat in beats {
            let clickEnd = beat + clickFrames
            guard beat < chunkEnd, clickEnd > chunkStart else { continue }
            for frame in max(beat, chunkStart)..<min(clickEnd, chunkEnd) {
                let time = Double(frame - beat) / sampleRate
                let tick = Float(sin(2 * .pi * clickFrequency * time) * exp(-time / clickDecay))
                    * clickAmplitude
                let index = Int(frame - chunkStart)
                for channel in 0..<channels {
                    let mixed = channelData[channel][index] + tick
                    channelData[channel][index] = min(max(mixed, -1), 1)
                }
            }
        }
    }

    /// Esporta la regione in MP3 tramite LAME (disponibile solo con `LAME_ENABLED`).
    private static func exportMP3(
        readFile: AVAudioFile,
        buffer: AVAudioPCMBuffer,
        startFrame: AVAudioFramePosition,
        framesToWrite: AVAudioFramePosition,
        chunkSize: AVAudioFrameCount,
        gain: Float,
        clickBeats: [AVAudioFramePosition],
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
            framesToWrite: framesToWrite, chunkSize: chunkSize, gain: gain,
            clickBeats: clickBeats, sampleRate: sampleRate
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
