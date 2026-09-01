//
//  SettingsView.swift
//  cattura brano
//
//  Impostazioni dell'app (⌘,): parametri di qualità della separazione stem.
//

import SwiftUI

struct SettingsView: View {
    @AppStorage("demucsModel") private var demucsModel = "htdemucs"
    @AppStorage("demucsShifts") private var demucsShifts = 1

    var body: some View {
        Form {
            Section("Separazione stem (demucs)") {
                Picker(selection: $demucsModel) {
                    Text("Standard · veloce").tag("htdemucs")
                    Text("Fine-tuned · qualità migliore, ~4× più lento").tag("htdemucs_ft")
                } label: {
                    Text("Modello")
                    Text("Il fine-tuned preserva meglio voce e timbri; alla prima separazione scarica ~300 MB.")
                }

                Picker(selection: $demucsShifts) {
                    Text("1 · standard").tag(1)
                    Text("2 · migliore").tag(2)
                    Text("5 · massima").tag(5)
                } label: {
                    Text("Passate di analisi")
                    Text("Più passate mediano il risultato e riducono gli artefatti, moltiplicando i tempi di elaborazione.")
                }
            }

            if !DemucsSeparator.isAvailable {
                Section {
                    Text("demucs non è installato: queste impostazioni avranno effetto dopo l'installazione dalla finestra principale.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 520)
        .fixedSize(horizontal: false, vertical: true)
    }
}

#Preview {
    SettingsView()
}
