//
//  GenerationQueue.swift
//  cattura brano
//
//  Turni per la generazione delle tracce aggiuntive quando più brani si
//  accavallano: uno alla volta, in ordine di arrivo, oppure tutti insieme,
//  secondo le Impostazioni (⌘,).
//

import Foundation

@MainActor
final class GenerationQueue {

    /// `true` se i brani generano tutti insieme, `false` se uno alla volta.
    /// Riletto a ogni decisione: un cambio nelle Impostazioni vale dal primo
    /// brano che arriva o che finisce.
    private let runsInParallel: () -> Bool
    /// Brani che occupano la macchina, anche durante l'interruzione (finché
    /// demucs non è uscito).
    private var running: [ProcessingJob] = []
    /// Brani in attesa, in ordine di arrivo: ognuno riparte quando la sua
    /// continuazione viene ripresa.
    private var waiters: [(job: ProcessingJob, continuation: CheckedContinuation<Void, Never>)] = []

    init(runsInParallel: @escaping () -> Bool = {
        UserDefaults.standard.bool(forKey: "parallelGeneration")
    }) {
        self.runsInParallel = runsInParallel
    }

    /// Sospende `job` finché non è il suo turno. Al ritorno la fase è
    /// `.generating`, oppure `.interrupted` se nel frattempo il brano è stato
    /// tolto dalla coda con `dequeue(_:)`.
    func waitForTurn(_ job: ProcessingJob) async {
        // Chi è già in coda passa prima (conta se le Impostazioni sono appena
        // passate alle elaborazioni in parallelo).
        admitWaiters()
        guard !runsInParallel(), !running.isEmpty else {
            start(job)
            return
        }
        job.phase = .queued
        await withCheckedContinuation { waiters.append((job, $0)) }
    }

    /// Da chiamare quando la generazione di `job` si è fermata (conclusa,
    /// interrotta o fallita): libera il posto per il prossimo in coda.
    func finish(_ job: ProcessingJob) {
        running.removeAll { $0 === job }
        admitWaiters()
    }

    /// Toglie `job` dalla coda prima che parta, senza toccare gli altri.
    func dequeue(_ job: ProcessingJob) {
        guard let index = waiters.firstIndex(where: { $0.job === job }) else { return }
        let waiter = waiters.remove(at: index)
        job.phase = .interrupted
        waiter.continuation.resume()
    }

    /// La fase cambia qui, prima di riprendere la continuazione, così un
    /// brano in arrivo nel frattempo trova già il posto occupato.
    private func start(_ job: ProcessingJob) {
        job.phase = .generating
        running.append(job)
    }

    private func admitWaiters() {
        while !waiters.isEmpty, runsInParallel() || running.isEmpty {
            let waiter = waiters.removeFirst()
            start(waiter.job)
            waiter.continuation.resume()
        }
    }
}
