//
//  DemucsInstaller.swift
//  cattura brano
//
//  Installazione guidata di demucs per le nuove installazioni dell'app:
//  ottiene pipx (via Homebrew, se serve), installa demucs con le sue
//  dipendenze e scarica subito il modello di separazione.
//

import AVFoundation
import Foundation
import Observation

@MainActor
@Observable
final class DemucsInstaller {

    enum Status: Equatable {
        case idle
        case running(String)
        /// Homebrew assente: serve un passaggio manuale nel Terminale.
        case needsHomebrew
        case failed(String)
        case done
    }

    /// Comando ufficiale di installazione di Homebrew (da incollare nel
    /// Terminale: chiede la password di amministratore, non automatizzabile).
    static let homebrewCommand =
        #"/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)""#

    private(set) var status: Status = .idle

    var isRunning: Bool {
        if case .running = status { return true }
        return false
    }

    private struct InstallError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private static func firstExecutable(_ paths: [String]) -> URL? {
        paths.map { URL(fileURLWithPath: $0) }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    private static var brewURL: URL? {
        firstExecutable(["/opt/homebrew/bin/brew", "/usr/local/bin/brew"])
    }

    private static var pipxURL: URL? {
        firstExecutable(["/opt/homebrew/bin/pipx", "/usr/local/bin/pipx"])
    }

    func install() async {
        do {
            var pipx = Self.pipxURL
            if pipx == nil {
                guard let brew = Self.brewURL else {
                    status = .needsHomebrew
                    return
                }
                status = .running("Installazione di pipx…")
                try await run(brew, ["install", "pipx"])
                pipx = Self.pipxURL
            }
            guard let pipx else {
                throw InstallError(message: "pipx non trovato dopo l'installazione.")
            }

            status = .running("Installazione di demucs (può richiedere qualche minuto)…")
            try await run(pipx, ["install", "demucs"])
            // numpy è richiesto da demucs ma non dichiarato dal pacchetto.
            status = .running("Installazione delle dipendenze…")
            try await run(pipx, ["inject", "demucs", "numpy"])

            status = .running("Scaricamento del modello di separazione…")
            try await warmUpModel()

            if DemucsSeparator.isAvailable {
                status = .done
            } else {
                throw InstallError(message: "demucs risulta ancora mancante dopo l'installazione.")
            }
        } catch {
            status = .failed(error.localizedDescription)
        }
    }

    /// Esegue demucs su un secondo di silenzio per far scaricare il modello
    /// adesso, invece che alla prima registrazione vera.
    private func warmUpModel() async throws {
        let temp = FileManager.default.temporaryDirectory
        let silence = temp.appendingPathComponent("demucs-warmup-\(UUID().uuidString).wav")
        let workDir = temp.appendingPathComponent("demucs-warmup-out-\(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(at: silence)
            try? FileManager.default.removeItem(at: workDir)
        }

        guard let format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 44100)
        else { throw InstallError(message: "Impossibile preparare il file di prova.") }
        buffer.frameLength = 44100
        do {
            let file = try AVAudioFile(forWriting: silence, settings: format.settings)
            try file.write(from: buffer)
        }
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)

        _ = try await Task.detached(priority: .userInitiated) {
            try DemucsSeparator.separate(source: silence, workDir: workDir)
        }.value
    }

    private func run(_ executable: URL, _ arguments: [String]) async throws {
        try await Task.detached(priority: .userInitiated) {
            let process = Process()
            process.executableURL = executable
            process.arguments = arguments
            // Pipe svuotata in continuo: l'output abbondante di brew/pip
            // riempirebbe la pipe e bloccherebbe il processo per sempre.
            let errorOutput = drainingErrorPipe(for: process)
            process.standardOutput = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                throw InstallError(
                    message: "Installazione non riuscita. \(String(errorOutput.text().suffix(300)))"
                )
            }
        }.value
    }
}
