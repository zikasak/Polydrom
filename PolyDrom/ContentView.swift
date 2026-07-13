//
//  ContentView.swift
//  PolyDrom
//
//  Created by zikasak on 07/07/2026.
//

import AppKit
import SwiftUI

struct ContentView: View {
    @ObservedObject var viewModel: AppViewModel
    @State private var detailPath: [LibraryRoute] = []
    @State private var isFullPlayerPresented = false

    var body: some View {
        libraryContent
            .disabled(isFullPlayerPresented)
            .frame(minWidth: 980, minHeight: 680)
            .overlay {
                ZStack {
                    if isFullPlayerPresented {
                        FullPlayerView(viewModel: viewModel) {
                            isFullPlayerPresented = false
                        }
                        .transition(
                            .move(edge: .bottom)
                                .combined(with: .opacity)
                                .combined(with: .scale(scale: 0.98, anchor: .bottom))
                        )
                        .zIndex(1)
                    }
                }
                .animation(.snappy(duration: 0.42, extraBounce: 0.06), value: isFullPlayerPresented)
            }
            .overlayPreferenceValue(AirPlayRoutePickerAnchorPreferenceKey.self) { anchors in
                GeometryReader { proxy in
                    let location: AirPlayRoutePickerLocation = isFullPlayerPresented
                        ? .fullPlayer
                        : .compactPlayer
                    let anchor = anchors[location] ?? anchors[.compactPlayer]
                    let frame = anchor.map { proxy[$0] } ?? .zero
                    let isPositioned = anchor != nil

                    // Keep the one native picker mounted even while SwiftUI briefly
                    // drops layout preferences during navigation or transitions.
                    AirPlayRoutePicker(controller: viewModel.audioPlayer.airPlayRoutePickerController)
                        .frame(width: frame.width, height: frame.height)
                        .position(x: frame.midX, y: frame.midY)
                        .opacity(isPositioned ? 1 : 0)
                        .allowsHitTesting(isPositioned)
                        .help("Choose AirPlay speaker")
                }
            }
            .task {
                await viewModel.connectToLatestServer()
            }
    }

    private var libraryContent: some View {
        NavigationSplitView {
            SidebarView(viewModel: viewModel) {
                detailPath = []
            }
        } detail: {
            NavigationStack(path: $detailPath) {
                withPlayerBar {
                    LibraryDetailView(viewModel: viewModel)
                }
                .navigationDestination(for: LibraryRoute.self) { route in
                    switch route {
                    case .album(let album):
                        withPlayerBar {
                            AlbumDetailView(viewModel: viewModel, album: album)
                        }
                    case .artist(let artist):
                        withPlayerBar {
                            ArtistDetailView(viewModel: viewModel, artist: artist)
                        }
                    case .playlist(let playlist):
                        withPlayerBar {
                            PlaylistDetailView(viewModel: viewModel, playlist: playlist)
                        }
                    }
                }
            }
            .environment(\.openLibraryRoute) { route in
                detailPath.append(route)
            }
            .navigationTitle("PolyDrom")
        }
    }

    private func withPlayerBar<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if viewModel.isConnected || viewModel.audioPlayer.currentSong != nil {
                    PlayerBarView(viewModel: viewModel) {
                        NSApp.keyWindow?.makeFirstResponder(nil)
                        isFullPlayerPresented = true
                    }
                }
            }
    }
}

private struct OpenLibraryRouteKey: EnvironmentKey {
    static let defaultValue: (LibraryRoute) -> Void = { _ in }
}

extension EnvironmentValues {
    var openLibraryRoute: (LibraryRoute) -> Void {
        get { self[OpenLibraryRouteKey.self] }
        set { self[OpenLibraryRouteKey.self] = newValue }
    }
}
