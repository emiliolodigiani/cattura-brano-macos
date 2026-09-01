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

    private var format: RecordingFormat {
        let stored = RecordingFormat(rawValue: formatRaw) ?? .alac
        // Se il formato salvato è l'MP3 ma LAME non è integrato, ripiega su ALAC.
        return RecordingFormat.selectable.contains(stored) ? stored : .alac
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Cattura brano")
                .font(.largeTitle.bold())

            interfaceSection
            saveSettingsSection

            Divider()

            meterSection
            transportSection
            statusSection

            Spacer(minLength: 0)
        }
        .padding(24)
        .frame(minWidth: 480, minHeight: 560)
    }

    // MARK: Interfaccia audio

    private var interfaceSection: some View {
        @Bindable var recorder = recorder
        return VStack(alignment: .leading, spacing: 6) {
            Label("Interfaccia di ingresso", systemImage: "waveform.badge.mic")
                .font(.headline)

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
                .labelsHidden()
                .disabled(recorder.isRecording)

                Button {
                    recorder.refreshDevices()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("Aggiorna l'elenco dei dispositivi")
                .disabled(recorder.isRecording)
            }
        }
    }

    // MARK: Impostazioni di salvataggio (nome file, formato, cartella)

    private var saveSettingsSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Nome del file")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    TextField("Nome del brano", text: $filename)
                        .textFieldStyle(.roundedBorder)
                        .help("Puoi modificare il nome anche durante la registrazione.")
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("Formato")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Picker("Formato", selection: $formatRaw) {
                        ForEach(RecordingFormat.selectable) { format in
                            Text(format.displayName).tag(format.rawValue)
                        }
                    }
                    .labelsHidden()
                    .disabled(recorder.isRecording)
                }

                Toggle(isOn: $trimSilence) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Rimuovi il silenzio iniziale e finale")
                        Text("Il file salvato parte dal primo suono e termina all'ultimo.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .disabled(recorder.isRecording)

                VStack(alignment: .leading, spacing: 4) {
                    Text("Cartella")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    HStack {
                        Text(folderStore.url.path)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)

                        Spacer()

                        Button("Scegli…") {
                            folderStore.choose()
                        }
                        .disabled(recorder.isRecording)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(4)
        } label: {
            Label("Salvataggio", systemImage: "square.and.arrow.down")
                .font(.headline)
        }
    }

    // MARK: Misuratore di livello e tempo

    private var meterSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label("Livello", systemImage: "speaker.wave.2")
                    .font(.headline)
                Spacer()
                Text(timeString(recorder.elapsed))
                    .font(.system(.title3, design: .monospaced))
                    .foregroundStyle(recorder.isRecording ? .red : .secondary)
            }

            LevelMeter(levels: recorder.levels)
        }
    }

    // MARK: Comandi

    private var transportSection: some View {
        HStack {
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
    }

    // MARK: Stato / esiti

    private var statusSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            if recorder.isSaving {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Elaborazione e salvataggio in corso…")
                        .foregroundStyle(.secondary)
                }
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
                    trimSilence: trimSilence
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

/// Misuratore di picco per canale con scala in decibel (dBFS).
///
/// Non esiste un componente nativo SwiftUI/AppKit per i VU meter audio,
/// quindi le barre sono disegnate a mano: da `floorDB` (silenzio) a 0 dBFS.
private struct LevelMeter: View {
    /// Picchi lineari (0…1), uno per canale. Vuoto quando non si registra.
    let levels: [Float]

    /// Limite inferiore della scala: sotto questa soglia la barra è vuota.
    private static let floorDB: Float = -60

    var body: some View {
        VStack(spacing: 5) {
            ForEach(Array(displayLevels.enumerated()), id: \.offset) { index, level in
                let db = Self.decibels(level)
                HStack(spacing: 8) {
                    Text(channelLabel(index))
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                        .frame(width: 14, alignment: .leading)

                    GeometryReader { geometry in
                        ZStack(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 4)
                                .fill(Color(nsColor: .quaternaryLabelColor))

                            RoundedRectangle(cornerRadius: 4)
                                .fill(barColor(db))
                                .frame(width: geometry.size.width * CGFloat(normalized(db)))
                                .animation(.linear(duration: 0.05), value: level)
                        }
                    }
                    .frame(height: 9)

                    Text(dbLabel(db))
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .frame(width: 62, alignment: .trailing)
                }
            }
        }
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
    private func normalized(_ db: Float) -> Float {
        guard db.isFinite else { return 0 }
        return min(max((db - Self.floorDB) / -Self.floorDB, 0), 1)
    }

    private func dbLabel(_ db: Float) -> String {
        guard db.isFinite, db >= Self.floorDB else { return "–∞ dB" }
        return String(format: "%.1f dB", db)
    }

    private func barColor(_ db: Float) -> Color {
        switch db {
        case ..<(-12): .green
        case ..<(-3): .yellow
        default: .red
        }
    }
}

#Preview {
    ContentView()
}
