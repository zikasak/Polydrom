//
//  PolyDromApp.swift
//  PolyDrom
//
//  Created by zikasak on 07/07/2026.
//

import SwiftUI

@main
struct PolyDromApp: App {
    @StateObject private var viewModel = AppViewModel()

    var body: some Scene {
        WindowGroup {
            ContentView(viewModel: viewModel)
        }
        .windowStyle(.hiddenTitleBar)
    }
}
