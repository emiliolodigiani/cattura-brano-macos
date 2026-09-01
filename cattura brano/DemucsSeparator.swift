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
        let errorPipe = Pipe()
        process.standardOutput = Pipe()
        process.standardError = errorPipe
        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let output = String(
                data: errorPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8
            ) ?? ""
            throw RecorderError.separationFailed(String(output.suffix(300)))
        }

        let trackName = source.deletingPathExtension().lastPathComponent
        let stemFolder = workDir.appendingPathComponent("\(model)/\(trackName)")
        let stems = Stems(
            drums: stemFolder.appendingPathComponent("drums.wav"),
            noDrums: stemFolder.appendingPathComponent("no_drums.wav")
        )
        guard FileManager.default.fileExists(atPath: stems.noDrums.path) else {
            throw RecorderError.separationFailed("demucs non ha prodotto gli stem attesi")
        }
        return stems
    }
}

/// Genera le tracce aggiuntive dopo il salvataggio: "(click)", "(drumless)"
/// e "(drumless click)", a seconda delle opzioni attive.
nonisolated enum AudioPostProcessor {

    /// - Parameters:
    ///   - processedWAV: WAV temporaneo con la regione già rifilata e
    ///     normalizzata (senza click); viene eliminato al termine.
    ///   - baseName: nome del file principale già salvato (senza estensione).
    /// - Returns: gli URL dei file creati.
    static func run(
        processedWAV: URL,
        folder: URL,
        baseName: String,
        format: RecordingFormat,
        addClick: Bool,
        separateDrums: Bool
    ) throws -> [URL] {
        defer { try? FileManager.default.removeItem(at: processedWAV) }

        // Separazione stem: serve per la traccia drumless e, quando
        // disponibile, anche per un beat tracking più preciso del click.
        var stems: DemucsSeparator.Stems?
        var workDir: URL?
        if DemucsSeparator.isAvailable, separateDrums || addClick {
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
        return outputs
    }
}
