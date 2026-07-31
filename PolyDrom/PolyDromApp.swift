//
//  PolyDromApp.swift
//  PolyDrom
//
//  Created by zikasak on 07/07/2026.
//

import AppKit
import SwiftUI

@main
struct PolyDromApp: App {
    @StateObject private var viewModel = AppCoordinator()

    var body: some Scene {
        WindowGroup {
            ContentView(viewModel: viewModel)
                .background(MacOSWindowConfigurator())
        }
        .windowStyle(.hiddenTitleBar)
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
