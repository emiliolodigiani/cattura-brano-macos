//
//  ContentView.swift
//  cattura brano
//
//  Created by Emilio Alfredo Lodigiani on 01/09/2026.
//

import SwiftUI

struct ContentView: View {
    @State private var recorder = AudioRecorder()
    @State private var folderStore = OutputFolderStore()

    @State private var filename = ""
    @AppStorage("recordingFormat") private var formatRaw = RecordingFormat.alac.rawValue
    @AppStorage("trimSilence") private var trimSilence = true
    @AppStorage("appendBPM") private var appendBPM = true
    @AppStorage("addClick") private var addClick = false
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
                            Text("Aggiungi un click sulle battute")
                            Text("Un tick a ogni battito rilevato, mixato nella traccia salvata.")
                        }
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

    // MARK: Barra di registrazione (livello, tempo, comando)

    private var recordingBar: some View {
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
        }
        .padding(20)
        // Scheda flottante in vetro, staccata dai bordi: il contenuto del
        // modulo scorre visibilmente dietro e intorno, come nei pannelli
        // di sistema di macOS 26.
        .glassEffect(.regular, in: .rect(cornerRadius: 18))
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

        if let url = recorder.lastSavedURL {
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                Text("Salvato: \(url.lastPathComponent)")
                Button("Mostra nel Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }
                .buttonStyle(.link)
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
            let didScope = folderStore.beginAccess()
            let folder = folderStore.url
            Task {
                await recorder.stopRecording(
                    filename: filename,
                    format: format,
                    outputFolder: folder,
                    trimSilence: trimSilence,
                    appendBPM: appendBPM,
                    addClick: addClick,
                    normalize: normalizeLevel
                )
                if didScope { folderStore.endAccess() }
            }
        } else {
            Task { await recorder.startRecording() }
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
