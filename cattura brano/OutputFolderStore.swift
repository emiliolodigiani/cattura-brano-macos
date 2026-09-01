//
//  OutputFolderStore.swift
//  cattura brano
//
//  Gestisce la cartella di destinazione delle registrazioni, con bookmark
//  con ambito di sicurezza per ricordare la scelta tra un avvio e l'altro.
//

import AppKit
import Foundation
import Observation

@MainActor
@Observable
final class OutputFolderStore {

    private(set) var url: URL

    private let bookmarkKey = "outputFolderBookmark"
    private var isSecurityScoped = false

    init() {
        let fallback = (try? FileManager.default.url(
            for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        )) ?? FileManager.default.temporaryDirectory

        if let data = UserDefaults.standard.data(forKey: bookmarkKey) {
            var isStale = false
            if let resolved = try? URL(
                resolvingBookmarkData: data,
                options: [.withSecurityScope],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            ), Self.isWritableFolder(resolved) {
                url = resolved
                isSecurityScoped = true
                if isStale { saveBookmark(resolved) }
                return
            }
            // Bookmark non risolvibile o senza permesso di scrittura (es. creato
            // da una versione dell'app con accesso in sola lettura): va scartato,
            // l'utente dovrà scegliere di nuovo la cartella.
            UserDefaults.standard.removeObject(forKey: bookmarkKey)
        }
        url = fallback
    }

    /// Mostra un pannello per scegliere la cartella di destinazione.
    func choose() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Scegli"
        panel.message = "Scegli la cartella dove salvare le registrazioni"

        guard panel.runModal() == .OK, let chosen = panel.url else { return }
        url = chosen
        isSecurityScoped = true
        saveBookmark(chosen)
    }

    /// Avvia l'accesso con ambito di sicurezza (se necessario) prima di scrivere.
    func beginAccess() -> Bool {
        guard isSecurityScoped else { return false }
        return url.startAccessingSecurityScopedResource()
    }

    /// Termina l'accesso avviato da `beginAccess()`.
    func endAccess() {
        if isSecurityScoped { url.stopAccessingSecurityScopedResource() }
    }

    /// Verifica che la cartella del bookmark sia davvero scrivibile con
    /// l'accesso con ambito di sicurezza attivo.
    private static func isWritableFolder(_ url: URL) -> Bool {
        let started = url.startAccessingSecurityScopedResource()
        defer { if started { url.stopAccessingSecurityScopedResource() } }
        return FileManager.default.isWritableFile(atPath: url.path)
    }

    private func saveBookmark(_ url: URL) {
        if let data = try? url.bookmarkData(
            options: [.withSecurityScope],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        ) {
            UserDefaults.standard.set(data, forKey: bookmarkKey)
        }
    }
}
