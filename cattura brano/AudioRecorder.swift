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
    /// `true` mentre demucs/click stanno generando le tracce aggiuntive.
    private(set) var isPostProcessing = false
    /// Tracce aggiuntive generate dopo il salvataggio (click, drumless…).
    private(set) var extraFiles: [URL] = []
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
    /// Tap di solo monitoraggio, attivo quando non si registra.
    private var monitor: TapWriter?
    private var tempURL: URL?
    private var startDate: Date?
    private var meterTask: Task<Void, Never>?

    var selectedDevice: AudioInputDevice? {
        devices.first { $0.id == selectedDeviceID }
    }

    init() {
        refreshDevices()
        Task { await startMonitoring() }
    }

    // MARK: Dispositivi

    func refreshDevices() {
        devices = AudioDeviceEnumerator.inputDevices()
        if selectedDeviceID == nil || !devices.contains(where: { $0.id == selectedDeviceID }) {
            selectedDeviceID = AudioDeviceEnumerator.defaultInputDevice() ?? devices.first?.id
        }
    }

    // MARK: Monitoraggio del livello (senza registrare)

    /// Avvia il motore audio con un tap di sola misura, così il misuratore
    /// mostra il livello d'ingresso anche prima di registrare.
    func startMonitoring() async {
        guard !isRecording, monitor == nil else { return }
        // Senza permesso non mostriamo errori: il messaggio arriva solo
        // quando l'utente prova davvero a registrare.
        guard await requestMicrophoneAccess() else { return }
        // La risposta al permesso può arrivare molto dopo (finestra di sistema
        // al primo avvio): nel frattempo l'utente può aver premuto Registra.
        // Senza questo ricontrollo si installerebbe un secondo tap sul bus già
        // occupato, e AVAudioEngine abbatte l'app con una NSException.
        guard !isRecording, monitor == nil else { return }

        do {
            try configureEngineInput()
            let input = engine.inputNode
            let format = input.outputFormat(forBus: 0)
            guard format.channelCount > 0, format.sampleRate > 0 else { return }

            let monitor = try TapWriter(url: nil, format: format)
            input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
                monitor.append(buffer)
            }
            engine.prepare()
            try engine.start()

            self.monitor = monitor
            startMeter()
        } catch {
            // Il monitoraggio è accessorio: se fallisce, il misuratore resta
            // fermo e l'eventuale errore emerge alla registrazione.
            stopMonitoring()
        }
    }

    private func stopMonitoring() {
        // Nessuna guardia su `monitor`: se l'avvio del monitoraggio fallisce
        // dopo installTap, il tap resta installato con `monitor` ancora nil,
        // e va comunque rimosso (removeTap è innocuo se non c'è alcun tap).
        engine.inputNode.removeTap(onBus: 0)
        if engine.isRunning { engine.stop() }
        monitor = nil
        stopMeter()
        levels = []
    }

    /// Da chiamare quando cambia l'interfaccia selezionata: riavvia il
    /// monitoraggio sul nuovo dispositivo.
    func noteDeviceChanged() {
        guard !isRecording else { return }
        stopMonitoring()
        Task { await startMonitoring() }
    }

    // MARK: Registrazione

    func startRecording() async {
        guard !isRecording else { return }
        errorMessage = nil
        lastSavedURL = nil
        extraFiles = []

        guard await requestMicrophoneAccess() else {
            errorMessage = "Permesso al microfono negato. Abilitalo in Impostazioni di Sistema › Privacy e sicurezza › Microfono."
            return
        }

        stopMonitoring()

        do {
            let input = engine.inputNode
            try configureEngineInput()

            let format = input.outputFormat(forBus: 0)
            guard format.channelCount > 0, format.sampleRate > 0 else {
                throw RecorderError.invalidFormat
            }

            let tempURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("cattura-\(UUID().uuidString).caf")
            let writer = try TapWriter(url: tempURL, format: format)

            input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
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
            await startMonitoring()
        }
    }

    /// Ferma la registrazione, applica le elaborazioni scelte e salva il file.
    func stopRecording(
        filename: String,
        format: RecordingFormat,
        outputFolder: URL,
        trimSilence: Bool,
        appendBPM: Bool,
        addClick: Bool,
        separateDrums: Bool,
        normalize: Bool
    ) async {
        guard isRecording else { return }

        isRecording = false
        stopMeter()
        levels = []
        startDate = nil

        engine.inputNode.removeTap(onBus: 0)
        engine.stop()

        // Qualunque sia l'esito del salvataggio, il monitoraggio riparte.
        defer { Task { await startMonitoring() } }

        guard let writer, let tempURL else { return }
        writer.close()
        self.writer = nil
        self.tempURL = nil

        await exportAndPostProcess(
            source: tempURL,
            deleteSource: true,
            name: sanitizedFilename(filename),
            format: format,
            outputFolder: outputFolder,
            trimSilence: trimSilence,
            appendBPM: appendBPM,
            addClick: addClick,
            separateDrums: separateDrums,
            normalize: normalize
        )
    }

    /// Elabora un file audio esistente con la stessa pipeline delle
    /// registrazioni (trim, normalizzazione, BPM, click, drumless).
    /// Il nome del file salvato è `filename`; se vuoto, quello del sorgente.
    func processExistingFile(
        _ source: URL,
        filename: String,
        format: RecordingFormat,
        outputFolder: URL,
        trimSilence: Bool,
        appendBPM: Bool,
        addClick: Bool,
        separateDrums: Bool,
        normalize: Bool
    ) async {
        guard !isRecording, !isSaving, !isPostProcessing else { return }
        errorMessage = nil
        lastSavedURL = nil
        extraFiles = []
        let typed = filename.trimmingCharacters(in: .whitespacesAndNewlines)
        let baseName = typed.isEmpty ? source.deletingPathExtension().lastPathComponent : typed
        await exportAndPostProcess(
            source: source,
            deleteSource: false,
            name: sanitizedFilename(baseName),
            format: format,
            outputFolder: outputFolder,
            trimSilence: trimSilence,
            appendBPM: appendBPM,
            addClick: addClick,
            separateDrums: separateDrums,
            normalize: normalize
        )
    }

    /// Esporta `source` con le opzioni scelte e genera le tracce aggiuntive.
    private func exportAndPostProcess(
        source: URL,
        deleteSource: Bool,
        name: String,
        format: RecordingFormat,
        outputFolder: URL,
        trimSilence: Bool,
        appendBPM: Bool,
        addClick: Bool,
        separateDrums: Bool,
        normalize: Bool
    ) async {
        let threshold = silenceThreshold
        let wantsExtras = addClick || separateDrums

        isSaving = true
        var exportResult: ExportResult?
        do {
            let result = try await Task.detached(priority: .userInitiated) {
                try AudioProcessor.trimAndExport(
                    source: source,
                    folder: outputFolder,
                    name: name,
                    format: format,
                    silenceThreshold: trimSilence ? threshold : nil,
                    appendBPM: appendBPM,
                    normalize: normalize,
                    prepareProcessedCopy: wantsExtras
                )
            }.value
            lastSavedURL = result.savedURL
            exportResult = result
        } catch {
            errorMessage = "Impossibile salvare il file: \(error.localizedDescription)"
        }

        if deleteSource { try? FileManager.default.removeItem(at: source) }
        isSaving = false

        if let exportResult, let processedCopy = exportResult.processedCopyURL {
            await runPostProcessing(
                processedWAV: processedCopy,
                savedURL: exportResult.savedURL,
                folder: outputFolder,
                format: format,
                addClick: addClick,
                separateDrums: separateDrums
            )
        }
    }

    /// Genera le tracce aggiuntive (click/drumless) dopo il salvataggio.
    private func runPostProcessing(
        processedWAV: URL,
        savedURL: URL,
        folder: URL,
        format: RecordingFormat,
        addClick: Bool,
        separateDrums: Bool
    ) async {
        isPostProcessing = true
        let baseName = savedURL.deletingPathExtension().lastPathComponent
        do {
            let outputs = try await Task.detached(priority: .userInitiated) {
                try AudioPostProcessor.run(
                    processedWAV: processedWAV,
                    folder: folder,
                    baseName: baseName,
                    format: format,
                    addClick: addClick,
                    separateDrums: separateDrums
                )
            }.value
            extraFiles = outputs
            if addClick, outputs.isEmpty {
                errorMessage = "Nessun battito rilevabile: traccia con click non generata."
            }
        } catch {
            errorMessage = error.localizedDescription
        }
        isPostProcessing = false
    }

    // MARK: Utilità

    /// Instrada il nodo d'ingresso del motore verso l'interfaccia selezionata.
    private func configureEngineInput() throws {
        guard let device = selectedDevice, let audioUnit = engine.inputNode.audioUnit else { return }
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
        stopMeter()
        meterTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 50_000_000)
                guard let self else { break }
                // Il misuratore legge dal tap attivo: registrazione o monitoraggio.
                guard let source = self.writer ?? self.monitor else { break }
                let peaks = source.consumePeaks()
                if self.levels.count != peaks.count {
                    self.levels = peaks
                } else {
                    // Balistica da peak meter: attacco immediato, rilascio
                    // graduale (≈80 dB/s con tick da 50 ms), per una lettura
                    // stabile senza sfarfallio.
                    self.levels = zip(self.levels, peaks).map { max($1, $0 * 0.631) }
                }
                if self.isRecording, let startDate = self.startDate {
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
        monitor = nil
        if let tempURL { try? FileManager.default.removeItem(at: tempURL) }
        tempURL = nil
        isRecording = false
    }
}
