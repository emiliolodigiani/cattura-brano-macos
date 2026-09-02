//
//  DemucsSeparator.swift
//  cattura brano
//
//  Separazione degli stem tramite demucs (CLI esterna, installata con pipx)
//  e post-elaborazione delle tracce aggiuntive: click e drumless.
//
//  Se demucs non è installato l'opzione drumless resta nascosta e il click
//  ripiega sul rilevamento dei battiti sul mix completo.
//

import AVFoundation

/// Invoca la CLI di demucs per separare batteria e resto del brano.
nonisolated enum DemucsSeparator {

    struct Stems {
        /// Lo stem della sola batteria (ottimo per il beat tracking).
        let drums: URL
        /// Il brano senza batteria.
        let noDrums: URL
    }

    /// Percorso dell'eseguibile demucs, se installato.
    static var executableURL: URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let candidates = [
            home.appendingPathComponent(".local/bin/demucs"),
            URL(fileURLWithPath: "/opt/homebrew/bin/demucs"),
            URL(fileURLWithPath: "/usr/local/bin/demucs"),
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    static var isAvailable: Bool { executableURL != nil }

    /// Modello scelto nelle Impostazioni (⌘,): "htdemucs" (veloce) oppure
    /// "htdemucs_ft" (fine-tuned, qualità migliore, ~4× più lento).
    static var model: String {
        UserDefaults.standard.string(forKey: "demucsModel") ?? "htdemucs"
    }

    /// Passate di analisi (--shifts): più passate mediano il risultato e
    /// riducono gli artefatti, moltiplicando i tempi.
    static var shifts: Int {
        let stored = UserDefaults.standard.integer(forKey: "demucsShifts")
        return stored > 0 ? stored : 1
    }

    /// Esegue demucs in modalità due stem (batteria / resto) su `source`,
    /// scrivendo dentro `workDir` (creata e poi eliminata dal chiamante).
    static func separate(source: URL, workDir: URL) throws -> Stems {
        guard let executable = executableURL else {
            throw RecorderError.separationFailed("demucs non è installato")
        }
        let model = Self.model

        let process = Process()
        process.executableURL = executable
        process.arguments = [
            "--two-stems", "drums",
            "-n", model,
            "--shifts", String(shifts),
            "--float32",
            "-o", workDir.path,
            source.path,
        ]
        // L'output va scaricato man mano: le barre di avanzamento di demucs
        // superano la capienza della pipe (64 KB) e, senza un lettore attivo,
        // il processo si blocca in scrittura e non termina mai.
        let errorOutput = drainingErrorPipe(for: process)
        process.standardOutput = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            throw RecorderError.separationFailed(String(errorOutput.text().suffix(300)))
        }

        let trackName = source.deletingPathExtension().lastPathComponent
        let stemFolder = workDir.appendingPathComponent("\(model)/\(trackName)")
        let stems = Stems(
            drums: stemFolder.appendingPathComponent("drums.wav"),
            noDrums: stemFolder.appendingPathComponent("no_drums.wav")
        )
        guard FileManager.default.fileExists(atPath: stems.noDrums.path),
              FileManager.default.fileExists(atPath: stems.drums.path) else {
            throw RecorderError.separationFailed("demucs non ha prodotto gli stem attesi")
        }
        return stems
    }
}

/// Raccoglie lo standard error di un processo man mano che arriva, senza
/// far riempire la pipe. Thread-safe.
nonisolated final class ProcessErrorBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func append(_ chunk: Data) {
        lock.lock()
        data.append(chunk)
        lock.unlock()
    }

    func text() -> String {
        lock.lock()
        defer { lock.unlock() }
        return String(data: data, encoding: .utf8) ?? ""
    }
}

/// Collega a `process` una pipe di standard error svuotata in continuo e
/// restituisce il buffer da cui leggere il testo raccolto.
nonisolated func drainingErrorPipe(for process: Process) -> ProcessErrorBuffer {
    let buffer = ProcessErrorBuffer()
    let pipe = Pipe()
    pipe.fileHandleForReading.readabilityHandler = { handle in
        let chunk = handle.availableData
        if chunk.isEmpty {
            handle.readabilityHandler = nil
        } else {
            buffer.append(chunk)
        }
    }
    process.standardError = pipe
    return buffer
}

/// Genera le tracce aggiuntive dopo il salvataggio: "(click)", "(drumless)"
/// e "(drumless click)", a seconda delle opzioni attive.
nonisolated enum AudioPostProcessor {

    /// - Parameters:
    ///   - processedWAV: WAV temporaneo con la regione già rifilata e
    ///     normalizzata (senza click); viene eliminato al termine.
    ///   - baseName: nome del file principale già salvato (senza estensione).
    /// - Returns: gli URL dei file creati.
    /// Volume lineare del resto del brano sotto la batteria nella traccia
    /// "(batteria)", dalle Impostazioni (in dB, default −12; ≤ −100 = niente
    /// sottofondo, solo batteria).
    private static var drumsBackgroundGain: Float {
        let db = UserDefaults.standard.object(forKey: "drumsBackgroundDB") as? Int ?? -12
        return db <= -100 ? 0 : pow(10, Float(db) / 20)
    }

    static func run(
        processedWAV: URL,
        folder: URL,
        baseName: String,
        format: RecordingFormat,
        addClick: Bool,
        separateDrums: Bool,
        drumsTrack: Bool
    ) throws -> [URL] {
        defer { try? FileManager.default.removeItem(at: processedWAV) }

        // Separazione stem: serve per le tracce drumless e batteria e, quando
        // disponibile, anche per un beat tracking più preciso del click.
        var stems: DemucsSeparator.Stems?
        var workDir: URL?
        if DemucsSeparator.isAvailable, separateDrums || drumsTrack || addClick {
            let dir = FileManager.default.temporaryDirectory
                .appendingPathComponent("demucs-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            workDir = dir
            stems = try DemucsSeparator.separate(source: processedWAV, workDir: dir)
        }
        defer { if let workDir { try? FileManager.default.removeItem(at: workDir) } }

        // Battiti per il click: dallo stem di batteria se c'è, altrimenti dal
        // mix. Espressi in secondi perché gli stem di demucs sono a 44.1 kHz
        // mentre la registrazione è alla frequenza dell'interfaccia.
        var beatsSeconds: [Double] = []
        if addClick {
            let beatSource = stems?.drums ?? processedWAV
            let file = try AVAudioFile(forReading: beatSource)
            let analysis = BeatDetector.analyze(
                readFile: file, startFrame: 0, endFrame: file.length
            )
            let rate = file.processingFormat.sampleRate
            beatsSeconds = analysis.beats.map { Double($0) / rate }
        }

        var outputs: [URL] = []
        if addClick, !beatsSeconds.isEmpty {
            outputs.append(try AudioProcessor.exportProcessed(
                source: processedWAV, folder: folder, name: "\(baseName) (click)",
                format: format, clickBeatsSeconds: beatsSeconds
            ))
        }
        if separateDrums, let stems {
            outputs.append(try AudioProcessor.exportProcessed(
                source: stems.noDrums, folder: folder, name: "\(baseName) (drumless)",
                format: format, clickBeatsSeconds: []
            ))
            if addClick, !beatsSeconds.isEmpty {
                outputs.append(try AudioProcessor.exportProcessed(
                    source: stems.noDrums, folder: folder, name: "\(baseName) (drumless click)",
                    format: format, clickBeatsSeconds: beatsSeconds
                ))
            }
        }
        if drumsTrack, let stems {
            let gain = drumsBackgroundGain
            if gain > 0 {
                // Batteria in primo piano, resto del brano di sottofondo.
                let mixURL = try AudioProcessor.mixFiles(
                    main: stems.drums, background: stems.noDrums, backgroundGain: gain
                )
                defer { try? FileManager.default.removeItem(at: mixURL) }
                outputs.append(try AudioProcessor.exportProcessed(
                    source: mixURL, folder: folder, name: "\(baseName) (batteria)",
                    format: format, clickBeatsSeconds: []
                ))
            } else {
                outputs.append(try AudioProcessor.exportProcessed(
                    source: stems.drums, folder: folder, name: "\(baseName) (solo batteria)",
                    format: format, clickBeatsSeconds: []
                ))
            }
        }
        return outputs
    }
}
