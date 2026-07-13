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
            .frame(minWidth: 1120, minHeight: 720)
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
            .navigationSplitViewColumnWidth(min: 190, ideal: 220, max: 280)
        } detail: {
            NavigationStack(path: $detailPath) {
                withPlayerBar {
                    LibraryDetailView(
                        viewModel: viewModel,
                        openRoute: openLibraryRoute
                    )
                }
                .navigationDestination(for: LibraryRoute.self) { route in
                    switch route {
                    case .album(let album):
                        withPlayerBar {
                            AlbumDetailView(
                                viewModel: viewModel,
                                album: album,
                                openRoute: openLibraryRoute
                            )
                        }
                    case .artist(let artist):
                        withPlayerBar {
                            ArtistDetailView(
                                viewModel: viewModel,
                                artist: artist,
                                openAlbum: { album in
                                    openLibraryRoute(.album(album))
                                }
                            )
                        }
                    case .playlist(let playlist):
                        withPlayerBar {
                            PlaylistDetailView(
                                viewModel: viewModel,
                                playlist: playlist,
                                openRoute: openLibraryRoute
                            )
                        }
                    }
                }
            }
            .environment(\.openLibraryRoute, openLibraryRoute)
            .navigationTitle("PolyDrom")
        }
    }

    private func openLibraryRoute(_ route: LibraryRoute) {
        guard detailPath.last?.identifiesSameDestination(as: route) != true else { return }

        // A macOS context menu is still being dismissed when its button action
        // runs, so update the path after its presentation transaction completes.
        DispatchQueue.main.async {
            detailPath.append(route)
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

private extension LibraryRoute {
    func identifiesSameDestination(as other: LibraryRoute) -> Bool {
        switch (self, other) {
        case (.album(let lhs), .album(let rhs)):
            return lhs.id == rhs.id
        case (.artist(let lhs), .artist(let rhs)):
            return lhs.id == rhs.id
        case (.playlist(let lhs), .playlist(let rhs)):
            return lhs.id == rhs.id
        default:
            return false
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
