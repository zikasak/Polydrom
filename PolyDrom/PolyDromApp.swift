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
    @NSApplicationDelegateAdaptor(PolyDromApplicationDelegate.self) private var applicationDelegate
    @StateObject private var viewModel = AppCoordinator()
    private let updater = AppUpdater()

    var body: some Scene {
        WindowGroup { [viewModel] in
            ContentView(viewModel: viewModel)
                .background(MacOSWindowConfigurator())
                .onAppear {
                    let model = viewModel
                    applicationDelegate.prepareForTermination = { [weak model] in
                        await model?.stopSonosForTermination()
                        await model?.playbackReporter.finishForApplicationTermination()
                    }
                }
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

@MainActor
final class PolyDromApplicationDelegate: NSObject, NSApplicationDelegate {
    var prepareForTermination: (@MainActor @Sendable () async -> Void)?

    private var terminationTask: Task<Void, Never>?
    private var timeoutTask: Task<Void, Never>?
    private var isWaitingForTermination = false
    private let terminationTimeout: Duration = .seconds(6)

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let prepareForTermination else { return .terminateNow }
        guard !isWaitingForTermination else { return .terminateLater }

        isWaitingForTermination = true
        terminationTask = Task { @MainActor [weak self, weak sender] in
            await prepareForTermination()
            guard let self, let sender else { return }
            completeTermination(for: sender)
        }
        timeoutTask = Task { @MainActor [weak self, weak sender] in
            guard let self else { return }
            try? await Task.sleep(for: terminationTimeout)
            guard !Task.isCancelled, let sender else { return }
            completeTermination(for: sender)
        }
        return .terminateLater
    }

    private func completeTermination(for application: NSApplication) {
        guard isWaitingForTermination else { return }
        isWaitingForTermination = false
        terminationTask?.cancel()
        timeoutTask?.cancel()
        terminationTask = nil
        timeoutTask = nil
        application.reply(toApplicationShouldTerminate: true)
    }
}

private struct MacOSWindowConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        WindowConfigurationView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

private final class WindowConfigurationView: NSView {
    private weak var configuredWindow: NSWindow?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()

        guard let window, window !== configuredWindow else { return }
        WindowConfiguration.apply(to: window)
        configuredWindow = window
    }
}

enum WindowConfiguration {
    @MainActor
    static func apply(to window: NSWindow) {
        window.collectionBehavior.remove(.fullScreenPrimary)
        window.collectionBehavior.remove(.fullScreenAuxiliary)
        window.collectionBehavior.insert(.fullScreenNone)
        window.standardWindowButton(.zoomButton)?.isEnabled = false

        // Keep interactive resizing at the native one-point granularity and let
        // AppKit reuse unchanged content instead of redrawing the whole window.
        window.contentResizeIncrements = NSSize(width: 1, height: 1)
        window.preservesContentDuringLiveResize = true
    }
}
