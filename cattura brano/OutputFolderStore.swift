//
//  OutputFolderStore.swift
//  cattura brano
//
//  Gestisce la cartella di destinazione delle registrazioni, ricordando la
//  scelta tra un avvio e l'altro tramite un bookmark (l'app non è sandboxed,
//  quindi non servono bookmark con ambito di sicurezza).
//

import AppKit
import Foundation
import Observation

@MainActor
@Observable
final class OutputFolderStore {

    private(set) var url: URL

    private let bookmarkKey = "outputFolderBookmark"

    init() {
        let fallback = (try? FileManager.default.url(
            for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        )) ?? FileManager.default.temporaryDirectory

        if let data = UserDefaults.standard.data(forKey: bookmarkKey) {
            var isStale = false
            if let resolved = try? URL(
                resolvingBookmarkData: data,
                bookmarkDataIsStale: &isStale
            ), FileManager.default.isWritableFile(atPath: resolved.path) {
                url = resolved
                if isStale { saveBookmark(resolved) }
                return
            }
            // Bookmark non risolvibile o cartella non scrivibile (anche quelli
            // con ambito di sicurezza dell'era sandbox): va scartato.
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
        saveBookmark(chosen)
    }

    private func saveBookmark(_ url: URL) {
        if let data = try? url.bookmarkData(
            options: [],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        ) {
            UserDefaults.standard.set(data, forKey: bookmarkKey)
        }
    }
}
