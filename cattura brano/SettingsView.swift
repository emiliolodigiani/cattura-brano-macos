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
    @AppStorage("silenceThresholdDB") private var silenceThresholdDB = -50
    @AppStorage("silencePaddingTenths") private var silencePaddingTenths = 5

    var body: some View {
        Form {
            Section("Registrazione") {
                Picker(selection: $silenceThresholdDB) {
                    Text("−70 dB · bassissima, conserva anche i suoni più deboli").tag(-70)
                    Text("−60 dB · bassa").tag(-60)
                    Text("−50 dB · standard").tag(-50)
                    Text("−40 dB · alta").tag(-40)
                    Text("−30 dB · altissima, taglia anche fruscii e respiri").tag(-30)
                } label: {
                    Text("Soglia di silenzio")
                    Text("Sotto questa soglia, l'audio a inizio e fine registrazione è considerato silenzio e viene rimosso (quando \"Rimuovi il silenzio\" è attivo). Se il taglio mangia parlato o code deboli, scegli una soglia più bassa.")
                }

                Picker(selection: $silencePaddingTenths) {
                    Text("Nessuno · attacco secco").tag(0)
                    Text("0,1 s").tag(1)
                    Text("0,2 s").tag(2)
                    Text("0,3 s").tag(3)
                    Text("0,5 s · standard").tag(5)
                    Text("1 s").tag(10)
                    Text("2 s").tag(20)
                } label: {
                    Text("Margine di silenzio")
                    Text("Silenzio lasciato prima e dopo il brano quando il taglio è attivo, così non inizia né finisce di colpo. Se la registrazione non ne contiene abbastanza, il margine viene aggiunto.")
                }
            }

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
                    Text("2 · alta").tag(2)
                    Text("3 · molto alta").tag(3)
                    Text("4 · altissima").tag(4)
                    Text("5 · estrema").tag(5)
                } label: {
                    Text("Passate di analisi")
                    Text("Più passate mediano il risultato e riducono gli artefatti; ogni passata in più allunga i tempi in proporzione. Il guadagno cala oltre 2–3.")
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
