//
//  cattura_branoApp.swift
//  cattura brano
//
//  Created by Emilio Alfredo Lodigiani on 01/09/2026.
//

import AppKit
import SwiftUI

@main
struct cattura_branoApp: App {
    var body: some Scene {
        WindowGroup("Cattura Brano") {
            ContentView()
        }
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("Informazioni su Cattura Brano") {
                    NSApplication.shared.orderFrontStandardAboutPanel(options: [
                        .credits: NSAttributedString(
                            string: "Ideato e sviluppato da Emilio Lodigiani",
                            attributes: [
                                .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
                                .foregroundColor: NSColor.secondaryLabelColor,
                            ]
                        )
                    ])
                }
            }
        }

        Settings {
            SettingsView()
        }
    }
}
