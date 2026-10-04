//
//  PlayerBarView.swift
//  PolyDrom
//
//  Created by zikasak on 07/07/2026.
//

import Combine
import SwiftUI

struct PlayerBarView: View {
    @ObservedObject var viewModel: AppCoordinator
    /// Not observed: the player publishes its time twice a second, and only the
    /// progress controls need that. The rest of the bar mirrors the few player
    /// values it shows so it is not rebuilt (and does not compete with scrolling)
    /// on every tick.
    private let audioPlayer: AudioPlayer
    @State private var currentSong: NavidromeSong?
    @State private var isPlaying: Bool
    @State private var statusMessage: String
    @State private var presentedDetailPanel: PlayerDetailPanel?
    @State private var isCoverArtHovered = false
    let openRoute: (LibraryRoute) -> Void
    let onOpenFullPlayer: () -> Void

    init(
        viewModel: AppCoordinator,
        openRoute: @escaping (LibraryRoute) -> Void = { _ in },
        onOpenFullPlayer: @escaping () -> Void
    ) {
        self.viewModel = viewModel
        self.audioPlayer = viewModel.audioPlayer
        _currentSong = State(initialValue: viewModel.audioPlayer.currentSong)
        _isPlaying = State(initialValue: viewModel.audioPlayer.isPlaying)
        _statusMessage = State(initialValue: viewModel.audioPlayer.statusMessage)
        self.openRoute = openRoute
        self.onOpenFullPlayer = onOpenFullPlayer
    }

    var body: some View {
        VStack(spacing: 0) {
            Divider()

            HStack(spacing: 12) {
                PlayerTransportControls(
                    viewModel: viewModel,
                    currentSong: currentSong,
                    isPlaying: isPlaying,
                    style: .compact
                )

                AirPlayRoutePickerAnchor(location: .compactPlayer)
                    .frame(width: 32, height: 40)

                SonosOutputPicker(viewModel: viewModel)

                Button(action: onOpenFullPlayer) {
                    CoverArtView(resource: currentSong.flatMap { viewModel.coverArtResource(for: $0, size: 96) }, size: 44)
                        .overlay {
                            Image(systemName: "arrow.up.left.and.arrow.down.right")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.white)
                                .padding(6)
                                .background(.black.opacity(0.55), in: Circle())
                                .opacity(isCoverArtHovered ? 1 : 0)
                        }
                }
                .buttonStyle(.plain)
                .onHover { isCoverArtHovered = $0 }
                .animation(.easeOut(duration: 0.15), value: isCoverArtHovered)
                .help("Open full player")
                .contextMenu {
                    if let album = currentSong.flatMap(viewModel.albumForNavigation) {
                        AlbumContextMenu(viewModel: viewModel, album: album) {
                            openRoute(.album(album))
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 6) {
                    NowPlayingTitle(viewModel: viewModel, song: currentSong, font: .headline, openRoute: openRoute)

                    NowPlayingMetadataLine(
                        viewModel: viewModel,
                        song: currentSong,
                        statusMessage: statusMessage,
                        font: .subheadline,
                        spacing: 5,
                        openRoute: openRoute
                    )

                    PlayerBarProgressControls(audioPlayer: audioPlayer)
                }
                .layoutPriority(1)

                if viewModel.isBusy {
                    ProgressView()
                        .controlSize(.small)
                }

                HStack(spacing: 8) {
                    detailButton(.lyrics)
                    detailButton(.queue)

                    Button(action: onOpenFullPlayer) {
                        Label("Open full player", systemImage: "arrow.up.left.and.arrow.down.right")
                            .labelStyle(.iconOnly)
                            .font(.body)
                            .frame(width: 30, height: 30)
                    }
                    .buttonStyle(.plain)
                    .help("Open full player")
                }
            }
            .padding(12)
        }
        .background(.bar)
        .onReceive(audioPlayer.$currentSong.removeDuplicates()) { currentSong = $0 }
        .onReceive(audioPlayer.$isPlaying.removeDuplicates()) { isPlaying = $0 }
        .onReceive(audioPlayer.$statusMessage.removeDuplicates()) { statusMessage = $0 }
    }

    private func detailButton(_ panel: PlayerDetailPanel) -> some View {
        Button {
            presentedDetailPanel = panel
        } label: {
            Label("Open \(panel.title)", systemImage: panel.systemImage)
                .labelStyle(.iconOnly)
                .font(.body)
                .frame(width: 30, height: 30)
        }
        .buttonStyle(.plain)
        .disabled(panel == .lyrics && currentSong == nil)
        .help("Open \(panel.title.lowercased())")
        .popover(isPresented: detailPanelBinding(for: panel), arrowEdge: .bottom) {
            PlayerDetailPanelView(panel: panel, viewModel: viewModel)
                .frame(width: 360, height: 500)
        }
    }

    private func detailPanelBinding(for panel: PlayerDetailPanel) -> Binding<Bool> {
        Binding(
            get: { presentedDetailPanel == panel },
            set: { isPresented in
                if !isPresented, presentedDetailPanel == panel {
                    presentedDetailPanel = nil
                }
            }
        )
    }
}

/// The only part of the player bar that follows playback time.
private struct PlayerBarProgressControls: View {
    @ObservedObject var audioPlayer: AudioPlayer

    var body: some View {
        HStack(spacing: 8) {
            Text(PlaybackTime.text(audioPlayer.currentTime))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 42, alignment: .trailing)

            PlayerSeekSlider(audioPlayer: audioPlayer)
                .frame(minWidth: 180, idealWidth: 360, maxWidth: 520)

            Text(PlaybackTime.text(audioPlayer.duration))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 42, alignment: .leading)

            PlayerVolumeControl(audioPlayer: audioPlayer, spacing: 6, iconWidth: 18, sliderWidth: 110)
                .padding(.leading, 8)
        }
    }
}
