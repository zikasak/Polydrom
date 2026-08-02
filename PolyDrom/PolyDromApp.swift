//
//  PolyDromApp.swift
//  PolyDrom
//
//  Created by zikasak on 07/07/2026.
//

import AppKit
import SwiftUI

@main
@MainActor
struct PolyDromApp: App {
    @StateObject private var viewModel = AppCoordinator()
    private let updater = AppUpdater()

    var body: some Scene {
        WindowGroup {
            ContentView(viewModel: viewModel)
                .background(MacOSWindowConfigurator())
        }
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") {
                    updater.checkForUpdates()
                }
            }
        }

        Settings {
            SettingsView(viewModel: viewModel)
        }
    }
}

private struct MacOSWindowConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        NSView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            guard let window = nsView.window else { return }

            window.collectionBehavior.remove(.fullScreenPrimary)
            window.collectionBehavior.remove(.fullScreenAuxiliary)
            window.collectionBehavior.insert(.fullScreenNone)
            window.standardWindowButton(.zoomButton)?.isEnabled = false
        }
    }
}
