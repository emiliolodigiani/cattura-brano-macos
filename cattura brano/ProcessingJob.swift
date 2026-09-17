//
//  ProcessingJob.swift
//  cattura brano
//
//  Un brano in lavorazione, dal salvataggio del file principale alla
//  generazione delle tracce aggiuntive. Ogni brano ha il proprio stato, così
//  più elaborazioni accavallate si seguono e si interrompono una per una.
//

import Foundation
import Observation

@MainActor
@Observable
final class ProcessingJob: Identifiable {

    enum Phase {
        /// Trim, normalizzazione e scrittura del file principale.
        case saving
        /// File principale salvato; le tracce aggiuntive aspettano che
        /// finisca la generazione di un altro brano.
        case queued
        /// demucs/click stanno generando le tracce aggiuntive.
        case generating
        /// Da quando l'utente chiede di interrompere la generazione a quando
        /// questa si è davvero fermata.
        case cancelling
        case done
        /// Generazione interrotta dall'utente (le tracce già pronte restano
        /// salvate).
        case interrupted
        case failed
    }

    let id = UUID()
    /// Nome scelto per il brano, mostrato finché il file non è salvato.
    let name: String
    var phase = Phase.saving
    var savedURL: URL?
    /// Tracce aggiuntive generate dopo il salvataggio (click, drumless…),
    /// elencate man mano che sono pronte.
    var extraFiles: [URL] = []
    /// Errore o avviso che riguarda questo brano.
    var message: String?
    /// Generazione delle tracce aggiuntive in corso, annullabile.
    var task: Task<[URL], any Error>?

    init(name: String) {
        self.name = name
    }

    /// `true` finché il brano ha ancora lavoro da fare.
    var isActive: Bool {
        switch phase {
        case .saving, .queued, .generating, .cancelling: true
        case .done, .interrupted, .failed: false
        }
    }

    /// `true` mentre la generazione occupa la macchina (anche durante
    /// l'interruzione, finché demucs non è uscito).
    var isGenerating: Bool {
        phase == .generating || phase == .cancelling
    }

    /// Aggiunge all'elenco una traccia aggiuntiva appena completata.
    func noteExtraFile(_ url: URL) {
        if !extraFiles.contains(url) { extraFiles.append(url) }
    }
}
