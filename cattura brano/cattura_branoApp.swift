//
//  cattura_branoApp.swift
//  cattura brano
//
//  Created by Emilio Alfredo Lodigiani on 01/09/2026.
//

import SwiftUI

@main
struct cattura_branoApp: App {
    var body: some Scene {
        WindowGroup("Cattura Brano") {
            ContentView()
        }

        Settings {
            SettingsView()
        }
    }
}
