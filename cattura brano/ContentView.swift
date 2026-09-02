//
//  ContentView.swift
//  cattura brano
//
//  Created by Emilio Alfredo Lodigiani on 01/09/2026.
//

import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @State private var recorder = AudioRecorder()
    @State private var folderStore = OutputFolderStore()
    @State private var demucsInstaller = DemucsInstaller()
    @State private var demucsAvailable = DemucsSeparator.isAvailable

    @State private var filename = ""
    @AppStorage("recordingFormat") private var formatRaw = RecordingFormat.alac.rawValue
    @AppStorage("trimSilence") private var trimSilence = true
    @AppStorage("appendBPM") private var appendBPM = true
    @AppStorage("addClick") private var addClick = false
    @AppStorage("separateDrums") private var separateDrums = false
    @AppStorage("drumsTrack") private var drumsTrack = false
    @AppStorage("normalizeLevel") private var normalizeLevel = false

    private var format: RecordingFormat {
        let stored = RecordingFormat(rawValue: formatRaw) ?? .alac
        // Se il formato salvato è l'MP3 ma LAME non è integrato, ripiega su ALAC.
        return RecordingFormat.selectable.contains(stored) ? stored : .alac
    }

    var body: some View {
        @Bindable var recorder = recorder
        return Form {
                Section("Ingresso") {
                    HStack {
                        Picker("Interfaccia", selection: $recorder.selectedDeviceID) {
                            if recorder.devices.isEmpty {
                                Text("Nessun dispositivo").tag(Optional<UInt32>.none)
                            }
                            ForEach(recorder.devices) { device in
                                Text("\(device.name) · \(device.inputChannels) can.")
                                    .tag(Optional(device.id))
                            }
                        }

                        Button {
                            recorder.refreshDevices()
                        } label: {
                            Image(systemName: "arrow.clockwise")
                        }
                        .buttonStyle(.borderless)
                        .help("Aggiorna l'elenco dei dispositivi")
                    }
                    .disabled(recorder.isRecording)
                }

                Section("Salvataggio") {
                    TextField("Nome del brano", text: $filename, prompt: Text("Registrazione"))
                        .help("Puoi modificare il nome anche durante la registrazione.")

                    Picker("Formato", selection: $formatRaw) {
                        ForEach(RecordingFormat.selectable) { format in
                            Text(format.displayName).tag(format.rawValue)
                        }
                    }
                    .disabled(recorder.isRecording)

                    LabeledContent("Cartella") {
                        HStack(spacing: 8) {
                            Text(folderStore.url.path)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .foregroundStyle(.secondary)

                            Button("Scegli…") {
                                folderStore.choose()
                            }
                            .disabled(recorder.isRecording)
                        }
                    }
                }

                Section("Opzioni") {
                    Toggle(isOn: $trimSilence) {
                        Text("Rimuovi il silenzio iniziale e finale")
                        Text("Il file salvato parte dal primo suono e termina all'ultimo.")
                    }

                    Toggle(isOn: $normalizeLevel) {
                        Text("Normalizza il volume")
                        Text("Riporta il picco della traccia a −1 dB.")
                    }

                    if BeatDetector.isAvailable {
                        Toggle(isOn: $appendBPM) {
                            Text("Aggiungi i BPM al nome del file")
                            Text("Solo quando il tempo è rilevabile con sicurezza.")
                        }

                        Toggle(isOn: $addClick) {
                            Text("Genera la traccia con il click")
                            Text("Salva una copia \"(click)\" con un tick sulle battute; la traccia principale resta pulita.")
                        }
                    }

                    if demucsAvailable {
                        Toggle(isOn: $separateDrums) {
                            Text("Genera la traccia senza batteria")
                            Text("Separa gli stem con demucs e salva una copia \"(drumless)\"; con il click attivo anche \"(drumless click)\".")
                        }

                        Toggle(isOn: $drumsTrack) {
                            Text("Genera la traccia batteria")
                            Text("Salva una copia \"(batteria)\": batteria in primo piano, resto del brano di sottofondo. Il volume del sottofondo si regola nelle Impostazioni (con \"Nessuno\" resta la sola batteria).")
                        }
                    } else {
                        demucsInstallRow
                    }
                }
        }
        .formStyle(.grouped)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            recordingBar
                .padding(.horizontal, 14)
                .padding(.bottom, 14)
        }
        .frame(minWidth: 500, minHeight: 600)
        .onChange(of: recorder.selectedDeviceID) {
            recorder.noteDeviceChanged()
        }
    }

    // MARK: Installazione guidata di demucs

    /// Mostrato al posto dell'opzione drumless quando demucs non è installato.
    private var demucsInstallRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            LabeledContent {
                if demucsInstaller.isRunning {
                    ProgressView().controlSize(.small)
                } else {
                    Button("Installa…") {
                        Task {
                            await demucsInstaller.install()
                            demucsAvailable = DemucsSeparator.isAvailable
                        }
                    }
                }
            } label: {
                Text("Traccia senza batteria e click di precisione")
                Text("Richiedono demucs, il motore di separazione degli stem (~600 MB, una volta sola).")
            }

            switch demucsInstaller.status {
            case .running(let step):
                Text(step)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .needsHomebrew:
                VStack(alignment: .leading, spacing: 4) {
                    Text("Serve prima Homebrew: incolla questo comando nel Terminale, completa l'installazione e premi di nuovo Installa.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    HStack(spacing: 8) {
                        Text(DemucsInstaller.homebrewCommand)
                            .font(.caption.monospaced())
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                        Button("Copia") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(
                                DemucsInstaller.homebrewCommand, forType: .string
                            )
                        }
                        .controlSize(.small)
                    }
                }
            case .failed(let message):
                Label(message, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            case .idle, .done:
                EmptyView()
            }
        }
    }

    // MARK: Barra di registrazione (livello, tempo, comando)

    @ViewBuilder
    private var recordingBar: some View {
        // Scheda flottante staccata dai bordi: vetro "liquid glass" su
        // macOS 26, materiale traslucido classico sulle versioni precedenti
        // (dove l'API glassEffect non esiste).
        if #available(macOS 26.0, *) {
            recordingBarContent
                .glassEffect(.regular, in: .rect(cornerRadius: 18))
        } else {
            recordingBarContent
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
                .overlay(
                    RoundedRectangle(cornerRadius: 18)
                        .strokeBorder(.separator, lineWidth: 1)
                )
        }
    }

    private var recordingBarContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Label("Livello", systemImage: "waveform")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)

                Spacer()

                Text(timeString(recorder.elapsed))
                    .font(.system(.title3, design: .monospaced).weight(.medium))
                    .foregroundStyle(recorder.isRecording ? .red : .secondary)
            }

            LevelMeter(levels: recorder.levels)

            statusSection

            HStack(spacing: 10) {
                Button(action: toggleRecording) {
                    Label(
                        recorder.isRecording ? "Stop" : "Registra",
                        systemImage: recorder.isRecording ? "stop.fill" : "record.circle"
                    )
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)
                .tint(recorder.isRecording ? .gray : .red)
                .controlSize(.large)
                .disabled(recorder.selectedDeviceID == nil || recorder.isSaving)

                Button(action: chooseFileToProcess) {
                    Label("Elabora file…", systemImage: "square.and.arrow.down.on.square")
                        .padding(.vertical, 6)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .help("Applica le stesse elaborazioni a un file audio esistente")
                .disabled(recorder.isRecording || recorder.isSaving || recorder.isPostProcessing)
            }
        }
        .padding(20)
    }

    // MARK: Stato / esiti

    @ViewBuilder
    private var statusSection: some View {
        if recorder.isSaving {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Elaborazione e salvataggio in corso…")
                    .foregroundStyle(.secondary)
            }
            .font(.callout)
        }

        if recorder.isPostProcessing {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Generazione delle tracce aggiuntive… (può richiedere qualche minuto)")
                    .foregroundStyle(.secondary)
            }
            .font(.callout)
        }

        if let url = recorder.lastSavedURL {
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                Text("Salvato: \(url.lastPathComponent)")
                Button("Mostra nel Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting(
                        [url] + recorder.extraFiles
                    )
                }
                .buttonStyle(.link)
            }
            .font(.callout)
        }

        ForEach(recorder.extraFiles, id: \.self) { file in
            HStack(spacing: 8) {
                Image(systemName: "sparkles").foregroundStyle(.blue)
                Text(file.lastPathComponent)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .font(.callout)
        }

        if let message = recorder.errorMessage {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text(message)
            }
            .font(.callout)
            .foregroundStyle(.secondary)
        }
    }

    // MARK: Azioni

    private func toggleRecording() {
        if recorder.isRecording {
            let folder = folderStore.url
            Task {
                await recorder.stopRecording(
                    filename: filename,
                    format: format,
                    outputFolder: folder,
                    trimSilence: trimSilence,
                    appendBPM: appendBPM,
                    addClick: addClick,
                    separateDrums: separateDrums,
                    drumsTrack: drumsTrack,
                    normalize: normalizeLevel
                )
            }
        } else {
            Task { await recorder.startRecording() }
        }
    }

    /// Sceglie un file audio esistente e lo elabora con le opzioni correnti.
    private func chooseFileToProcess() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.audio]
        panel.prompt = "Elabora"
        panel.message = "Scegli il file audio da elaborare con le opzioni correnti"

        guard panel.runModal() == .OK, let url = panel.url else { return }
        let folder = folderStore.url
        Task {
            await recorder.processExistingFile(
                url,
                filename: filename,
                format: format,
                outputFolder: folder,
                trimSilence: trimSilence,
                appendBPM: appendBPM,
                addClick: addClick,
                separateDrums: separateDrums,
                drumsTrack: drumsTrack,
                normalize: normalizeLevel
            )
        }
    }

    private func timeString(_ interval: TimeInterval) -> String {
        let total = Int(interval)
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}

/// Misuratore di picco per canale con righello graduato in decibel (dBFS).
///
/// Non esiste un componente nativo SwiftUI/AppKit per i VU meter audio,
/// quindi barre e scala sono disegnate a mano: da `floorDB` (silenzio) a 0 dBFS.
private struct LevelMeter: View {
    /// Picchi lineari (0…1), uno per canale. Vuoto quando non si registra.
    let levels: [Float]

    /// Limite inferiore della scala: sotto questa soglia la barra è vuota.
    private static let floorDB: Float = -60
    /// Segmenti "LED" per barra: 20 da 3 dB ciascuno (−60…0 dBFS).
    private static let segmentCount = 20
    private static let segmentStep: Float = 3
    /// Tacche con etichetta numerica del righello.
    private static let majorTicks: [Float] = [-60, -48, -36, -24, -12, -6, 0]
    /// Tacche intermedie, più corte e senza etichetta.
    private static let minorTicks: [Float] = [-54, -42, -30, -18, -9, -3]
    /// Larghezza dell'etichetta di canale + spaziatura: rientro del righello.
    private static let channelLabelWidth: CGFloat = 14
    private static let barSpacing: CGFloat = 8

    var body: some View {
        VStack(spacing: 5) {
            ForEach(Array(displayLevels.enumerated()), id: \.offset) { index, level in
                let db = Self.decibels(level)
                HStack(spacing: Self.barSpacing) {
                    Text(channelLabel(index))
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                        .frame(width: Self.channelLabelWidth, alignment: .leading)

                    HStack(spacing: 2) {
                        ForEach(0..<Self.segmentCount, id: \.self) { index in
                            RoundedRectangle(cornerRadius: 1.5)
                                .fill(segmentColor(index, currentDB: db))
                        }
                    }
                    .frame(height: 9)
                }
            }

            scale
                .padding(.leading, Self.channelLabelWidth + Self.barSpacing)
        }
    }

    /// Righello con le tacche dei decibel, allineato sotto le barre.
    private var scale: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            ZStack(alignment: .topLeading) {
                ForEach(Self.minorTicks, id: \.self) { db in
                    Rectangle()
                        .fill(Color(nsColor: .tertiaryLabelColor))
                        .frame(width: 1, height: 3)
                        .position(x: tickX(db, width), y: 1.5)
                }
                ForEach(Self.majorTicks, id: \.self) { db in
                    Rectangle()
                        .fill(Color(nsColor: .secondaryLabelColor))
                        .frame(width: 1, height: 5)
                        .position(x: tickX(db, width), y: 2.5)

                    Text(String(format: "%.0f", db))
                        .font(.system(size: 8).monospaced())
                        .foregroundStyle(.secondary)
                        .position(x: min(max(tickX(db, width), 10), width - 4), y: 12)
                }
            }
        }
        .frame(height: 17)
    }

    private func tickX(_ db: Float, _ width: CGFloat) -> CGFloat {
        CGFloat(Self.normalized(db)) * width
    }

    /// A riposo mostra comunque due barre vuote per mantenere stabile il layout.
    private var displayLevels: [Float] {
        levels.isEmpty ? [0, 0] : levels
    }

    private func channelLabel(_ index: Int) -> String {
        if displayLevels.count == 1 { return "M" }
        switch index {
        case 0: return "L"
        case 1: return "R"
        default: return "\(index + 1)"
        }
    }

    private static func decibels(_ level: Float) -> Float {
        level > 0 ? 20 * log10(level) : -.infinity
    }

    /// Posizione 0…1 sulla scala della barra.
    private static func normalized(_ db: Float) -> Float {
        guard db.isFinite else { return 0 }
        return min(max((db - floorDB) / -floorDB, 0), 1)
    }

    /// Colore di un segmento: dipende dalla POSIZIONE del segmento sulla scala
    /// (verde sotto −12, giallo fino a −3, rosso oltre), acceso se il livello
    /// lo raggiunge, altrimenti spento (stessa tinta, molto attenuata).
    private func segmentColor(_ index: Int, currentDB: Float) -> Color {
        let segmentDB = Self.floorDB + Float(index) * Self.segmentStep
        let base: Color = switch segmentDB {
        case ..<(-12): .green
        case ..<(-3): .yellow
        default: .red
        }
        let lit = currentDB.isFinite && currentDB >= segmentDB
        return lit ? base : base.opacity(0.15)
    }
}

#Preview {
    ContentView()
}
