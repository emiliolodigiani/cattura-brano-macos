//
//  AudioRecorder.swift
//  cattura brano
//
//  Coordina selezione interfaccia, registrazione, misuratore di livello ed
//  esportazione con trim del silenzio.
//

import AVFoundation
import CoreAudio
import Observation
import SwiftUI

@MainActor
@Observable
final class AudioRecorder {

    // MARK: Stato osservabile

    var devices: [AudioInputDevice] = []
    var selectedDeviceID: AudioDeviceID?
    private(set) var isRecording = false
    private(set) var isSaving = false
    private(set) var elapsed: TimeInterval = 0
    /// Picchi lineari (0…1) per canale, aggiornati durante la registrazione.
    private(set) var levels: [Float] = []
    private(set) var lastSavedURL: URL?
    var errorMessage: String?

    /// Soglia di silenzio lineare (≈ -50 dBFS) usata per il trim.
    private let silenceThreshold: Float = 0.00316

    // MARK: Stato interno

    private let engine = AVAudioEngine()
    private var writer: TapWriter?
    private var tempURL: URL?
    private var startDate: Date?
    private var meterTask: Task<Void, Never>?

    var selectedDevice: AudioInputDevice? {
        devices.first { $0.id == selectedDeviceID }
    }

    init() {
        refreshDevices()
    }

    // MARK: Dispositivi

    func refreshDevices() {
        devices = AudioDeviceEnumerator.inputDevices()
        if selectedDeviceID == nil || !devices.contains(where: { $0.id == selectedDeviceID }) {
            selectedDeviceID = AudioDeviceEnumerator.defaultInputDevice() ?? devices.first?.id
        }
    }

    // MARK: Registrazione

    func startRecording() async {
        guard !isRecording else { return }
        errorMessage = nil
        lastSavedURL = nil

        guard await requestMicrophoneAccess() else {
            errorMessage = "Permesso al microfono negato. Abilitalo in Impostazioni di Sistema › Privacy e sicurezza › Microfono."
            return
        }

        do {
            let input = engine.inputNode

            // Instrada il motore verso l'interfaccia selezionata.
            if let device = selectedDevice, let audioUnit = input.audioUnit {
                var deviceID = device.id
                let status = AudioUnitSetProperty(
                    audioUnit,
                    kAudioOutputUnitProperty_CurrentDevice,
                    kAudioUnitScope_Global,
                    0,
                    &deviceID,
                    UInt32(MemoryLayout<AudioDeviceID>.size)
                )
                guard status == noErr else { throw RecorderError.deviceSelectionFailed(status) }
            }

            let format = input.outputFormat(forBus: 0)
            guard format.channelCount > 0, format.sampleRate > 0 else {
                throw RecorderError.invalidFormat
            }

            let tempURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("cattura-\(UUID().uuidString).caf")
            let writer = try TapWriter(url: tempURL, format: format)

            input.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, _ in
                writer.append(buffer)
            }

            engine.prepare()
            try engine.start()

            self.writer = writer
            self.tempURL = tempURL
            self.startDate = Date()
            self.elapsed = 0
            self.isRecording = true
            startMeter()
        } catch {
            cleanupEngine()
            errorMessage = "Impossibile avviare la registrazione: \(error.localizedDescription)"
        }
    }

    /// Ferma la registrazione, applica il trim del silenzio (se attivo) e salva il file.
    func stopRecording(
        filename: String, format: RecordingFormat, outputFolder: URL, trimSilence: Bool
    ) async {
        guard isRecording else { return }

        isRecording = false
        stopMeter()
        levels = []

        engine.inputNode.removeTap(onBus: 0)
        engine.stop()

        guard let writer, let tempURL else { return }
        writer.close()
        self.writer = nil
        self.tempURL = nil

        let name = sanitizedFilename(filename)
        let threshold = silenceThreshold

        isSaving = true
        do {
            let savedURL = try await Task.detached(priority: .userInitiated) {
                try AudioProcessor.trimAndExport(
                    source: tempURL,
                    folder: outputFolder,
                    name: name,
                    format: format,
                    silenceThreshold: trimSilence ? threshold : nil
                )
            }.value
            lastSavedURL = savedURL
        } catch {
            errorMessage = "Impossibile salvare il file: \(error.localizedDescription)"
        }

        try? FileManager.default.removeItem(at: tempURL)
        isSaving = false
    }

    // MARK: Utilità

    private func requestMicrophoneAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return true
        case .notDetermined:
            return await AVCaptureDevice.requestAccess(for: .audio)
        default:
            return false
        }
    }

    private func sanitizedFilename(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleaned = trimmed.components(separatedBy: CharacterSet(charactersIn: "/\\:?%*|\"<>"))
            .joined(separator: "-")
        return cleaned.isEmpty ? "Registrazione" : cleaned
    }

    private func startMeter() {
        meterTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 50_000_000)
                guard let self, self.isRecording else { break }
                if let writer = self.writer {
                    self.levels = writer.consumePeaks()
                }
                if let startDate = self.startDate {
                    self.elapsed = Date().timeIntervalSince(startDate)
                }
            }
        }
    }

    private func stopMeter() {
        meterTask?.cancel()
        meterTask = nil
    }

    private func cleanupEngine() {
        stopMeter()
        if engine.isRunning { engine.stop() }
        engine.inputNode.removeTap(onBus: 0)
        writer?.close()
        writer = nil
        if let tempURL { try? FileManager.default.removeItem(at: tempURL) }
        tempURL = nil
        isRecording = false
    }
}
