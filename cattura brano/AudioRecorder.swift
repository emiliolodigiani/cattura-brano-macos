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
    /// Brani in lavorazione o appena conclusi, dal più vecchio al più recente.
    /// Quelli conclusi restano in elenco fino alla registrazione successiva.
    private(set) var jobs: [ProcessingJob] = []
    private(set) var elapsed: TimeInterval = 0
    /// Picchi lineari (0…1) per canale, aggiornati durante la registrazione.
    private(set) var levels: [Float] = []
    /// Errori di ingresso e registrazione; quelli di un brano in lavorazione
    /// stanno nel suo `ProcessingJob`.
    var errorMessage: String?

    /// `true` mentre un brano sta scrivendo il proprio file principale.
    var isSaving: Bool {
        jobs.contains { $0.phase == .saving }
    }

    /// Soglia di silenzio lineare usata per il trim, dalle Impostazioni (⌘,).
    /// Il valore è salvato in dBFS (default −50 ≈ 0.00316 lineare).
    private var silenceThreshold: Float {
        let db = UserDefaults.standard.object(forKey: "silenceThresholdDB") as? Int ?? -50
        return pow(10, Float(db) / 20)
    }

    /// Secondi di silenzio garantiti prima e dopo il brano dal trim,
    /// dalle Impostazioni (salvati in decimi di secondo, default 0,5 s).
    private var silencePadding: Double {
        let tenths = UserDefaults.standard.object(forKey: "silencePaddingTenths") as? Int ?? 5
        return Double(tenths) / 10
    }

    // MARK: Stato interno

    private let engine = AVAudioEngine()
    private var writer: TapWriter?
    /// Tap di solo monitoraggio, attivo quando non si registra.
    private var monitor: TapWriter?
    private var tempURL: URL?
    private var startDate: Date?
    private var meterTask: Task<Void, Never>?
    /// Turni per le tracce aggiuntive quando più brani si accavallano.
    private let generationQueue = GenerationQueue()

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
            let format = try validatedInputFormat(of: input)

            let monitor = try TapWriter(url: nil, format: format)
            try withObjCExceptionGuard {
                input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
                    monitor.append(buffer)
                }
                engine.prepare()
                try engine.start()
            }

            self.monitor = monitor
            startMeter()
        } catch {
            // Il monitoraggio è accessorio, ma un ingresso inutilizzabile va
            // segnalato: spiega perché la barra del livello resta ferma
            // (senza sovrascrivere un errore di registrazione già mostrato).
            stopMonitoring()
            if errorMessage == nil {
                errorMessage = "Ingresso non attivo: \(error.localizedDescription)"
            }
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
        errorMessage = nil
        stopMonitoring()
        Task { await startMonitoring() }
    }

    // MARK: Registrazione

    func startRecording() async {
        guard !isRecording else { return }
        errorMessage = nil
        clearFinishedJobs()

        guard await requestMicrophoneAccess() else {
            errorMessage = "Permesso al microfono negato. Abilitalo in Impostazioni di Sistema › Privacy e sicurezza › Microfono."
            return
        }

        stopMonitoring()

        do {
            let input = engine.inputNode
            try configureEngineInput()

            let format = try validatedInputFormat(of: input)

            let tempURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("cattura-\(UUID().uuidString).caf")
            let writer = try TapWriter(url: tempURL, format: format)

            try withObjCExceptionGuard {
                input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
                    writer.append(buffer)
                }

                engine.prepare()
                try engine.start()
            }

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
        drumsTrack: Bool,
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
            drumsTrack: drumsTrack,
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
        drumsTrack: Bool,
        normalize: Bool
    ) async {
        guard !isRecording, !isSaving else { return }
        errorMessage = nil
        clearFinishedJobs()
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
            drumsTrack: drumsTrack,
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
        drumsTrack: Bool,
        normalize: Bool
    ) async {
        let threshold = silenceThreshold
        let padding = silencePadding
        let wantsExtras = addClick || separateDrums || drumsTrack

        let job = ProcessingJob(name: name)
        jobs.append(job)
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
                    prepareProcessedCopy: wantsExtras,
                    padding: padding
                )
            }.value
            job.savedURL = result.savedURL
            exportResult = result
        } catch {
            job.message = "Impossibile salvare il file: \(error.localizedDescription)"
        }

        if deleteSource { try? FileManager.default.removeItem(at: source) }

        guard let exportResult else {
            job.phase = .failed
            return
        }
        guard let processedCopy = exportResult.processedCopyURL else {
            job.phase = .done
            return
        }
        await runPostProcessing(
            job: job,
            processedWAV: processedCopy,
            savedURL: exportResult.savedURL,
            folder: outputFolder,
            format: format,
            addClick: addClick,
            separateDrums: separateDrums,
            drumsTrack: drumsTrack
        )
    }

    /// Genera le tracce aggiuntive (click/drumless) dopo il salvataggio,
    /// aspettando il proprio turno se le elaborazioni vanno una alla volta.
    private func runPostProcessing(
        job: ProcessingJob,
        processedWAV: URL,
        savedURL: URL,
        folder: URL,
        format: RecordingFormat,
        addClick: Bool,
        separateDrums: Bool,
        drumsTrack: Bool
    ) async {
        await generationQueue.waitForTurn(job)
        guard job.phase == .generating else {
            // Interrotto prima di partire: mentre era in coda oppure
            // nell'istante tra il via libera e la ripartenza (fase già
            // `.cancelling`, task non ancora creato). Il WAV temporaneo, che
            // altrimenti elimina AudioPostProcessor, va rimosso qui.
            try? FileManager.default.removeItem(at: processedWAV)
            job.phase = .interrupted
            generationQueue.finish(job)
            return
        }

        let baseName = savedURL.deletingPathExtension().lastPathComponent
        let task = Task.detached(priority: .userInitiated) {
            try await AudioPostProcessor.run(
                processedWAV: processedWAV,
                folder: folder,
                baseName: baseName,
                format: format,
                addClick: addClick,
                separateDrums: separateDrums,
                drumsTrack: drumsTrack,
                onOutput: { url in
                    Task { @MainActor in job.noteExtraFile(url) }
                }
            )
        }
        job.task = task
        do {
            let outputs = try await task.value
            job.extraFiles = outputs
            if addClick, outputs.isEmpty {
                job.message = "Nessun battito rilevabile: traccia con click non generata."
            }
            job.phase = .done
        } catch {
            // Dopo la richiesta di interruzione qualunque errore è una
            // conseguenza dello stop (demucs terminato, scrittura troncata):
            // non va mostrato come guasto.
            if job.phase == .cancelling {
                job.phase = .interrupted
            } else {
                job.message = error.localizedDescription
                job.phase = .failed
            }
        }
        job.task = nil
        generationQueue.finish(job)
    }

    /// Interrompe le tracce aggiuntive di `job`, senza toccare gli altri
    /// brani: se è in coda ne esce subito; se sta generando, demucs viene
    /// terminato e il file in scrittura eliminato, mentre le tracce già
    /// pronte restano salvate. Il salvataggio principale non è coinvolto.
    func cancel(_ job: ProcessingJob) {
        switch job.phase {
        case .queued:
            generationQueue.dequeue(job)
        case .generating:
            job.phase = .cancelling
            job.task?.cancel()
        case .saving, .cancelling, .done, .interrupted, .failed:
            break
        }
    }

    /// All'inizio di un nuovo brano l'elenco si sfoltisce: restano solo i
    /// brani che hanno ancora lavoro da fare.
    private func clearFinishedJobs() {
        jobs.removeAll { !$0.isActive }
    }

    // MARK: Utilità

    /// Formato con cui installare il tap sul nodo d'ingresso: quello REALE
    /// dell'hardware (`inputFormat`), mai quello del bus di uscita
    /// (`outputFormat`), che dopo un cambio di interfaccia può restare in
    /// cache col formato del dispositivo precedente (es. 44,1 kHz quando il
    /// microfono integrato lavora a 48 kHz) e far fallire installTap con
    /// "Failed to create tap due to format mismatch". Un formato hardware
    /// a 0 Hz/0 canali indica un dispositivo inutilizzabile (rotto o in uso
    /// esclusivo altrove): meglio un errore chiaro che una NSException.
    private func validatedInputFormat(of input: AVAudioInputNode) throws -> AVAudioFormat {
        let hardware = input.inputFormat(forBus: 0)
        guard hardware.sampleRate > 0, hardware.channelCount > 0 else {
            throw RecorderError.invalidFormat
        }
        return hardware
    }

    /// Esegue `body` intercettando sia gli errori Swift sia le NSException
    /// Objective-C di AVAudioEngine. Un'eccezione lasciata correre fin dentro
    /// AppKit viene "ingoiata" dal ciclo eventi e corrompe lo stato della
    /// concorrenza Swift, con crash al click successivo: qui diventa invece
    /// un errore normale, gestito dal chiamante.
    private func withObjCExceptionGuard(_ body: () throws -> Void) throws {
        var swiftError: Error?
        let objcError = CBCatchObjCException {
            do { try body() } catch { swiftError = error }
        }
        if let swiftError { throw swiftError }
        if let objcError { throw objcError }
    }

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
        // Scarta i formati che il motore tiene in cache dal dispositivo
        // precedente: senza reset, inputFormat/outputFormat possono riferirsi
        // alla vecchia interfaccia e il tap fallirebbe per formato discordante.
        engine.reset()
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
        // `joiningLines` rifila anche gli spazi: un nome su più righe non
        // arriva mai al file system con un a capo dentro.
        let trimmed = raw.joiningLines
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

extension String {
    /// Il testo riunito su una sola riga: ogni riga rifilata dagli spazi, le
    /// vuote scartate, le altre unite da " - " (un titolo incollato su due
    /// righe diventa "RIGA1 - RIGA2"). Su una riga sola equivale a un trim.
    nonisolated var joiningLines: String {
        components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " - ")
    }
}
