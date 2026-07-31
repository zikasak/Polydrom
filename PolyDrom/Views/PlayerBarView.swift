//
//  PlayerBarView.swift
//  PolyDrom
//
//  Created by zikasak on 07/07/2026.
//

import SwiftUI

struct PlayerBarView: View {
    @ObservedObject var viewModel: AppCoordinator
    @ObservedObject private var audioPlayer: AudioPlayer
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
        self.openRoute = openRoute
        self.onOpenFullPlayer = onOpenFullPlayer
    }

    var body: some View {
        VStack(spacing: 0) {
            Divider()

            HStack(spacing: 12) {
                HStack(spacing: 16) {
                    Button {
                        viewModel.playPreviousTrack()
                    } label: {
                        Label("Previous", systemImage: "backward.fill")
                            .labelStyle(.iconOnly)
                            .font(.body)
                            .padding(8)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .padding(-8)
                    .disabled(!viewModel.canPlayPreviousTrack())
                    .help("Previous")

                    Button {
                        audioPlayer.togglePlayPause()
                    } label: {
                        Label(
                            audioPlayer.isPlaying ? "Pause" : "Play",
                            systemImage: audioPlayer.isPlaying ? "pause.fill" : "play.fill"
                        )
                            .labelStyle(.iconOnly)
                            .font(.system(size: 17, weight: .semibold))
                            .frame(width: 40, height: 40)
                            .foregroundStyle(Color(nsColor: .windowBackgroundColor))
                            .background {
                                Circle()
                                    .fill(Color(nsColor: .labelColor))
                            }
                            .padding(8)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .padding(-8)
                    .disabled(audioPlayer.currentSong == nil)
                    .help(audioPlayer.isPlaying ? "Pause" : "Play")

                    Button {
                        viewModel.playNextTrack()
                    } label: {
                        Label("Next", systemImage: "forward.fill")
                            .labelStyle(.iconOnly)
                            .font(.body)
                            .padding(8)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .padding(-8)
                    .disabled(!viewModel.canPlayNextTrack())
                    .help("Next")

                    Button {
                        audioPlayer.stop()
                    } label: {
                        Label("Stop", systemImage: "stop.fill")
                            .labelStyle(.iconOnly)
                            .font(.body)
                            .padding(8)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .padding(-8)
                    .disabled(audioPlayer.currentSong == nil)
                    .help("Stop")

                    Button {
                        if let song = audioPlayer.currentSong {
                            viewModel.toggleFavorite(song)
                        }
                    } label: {
                        Label(
                            currentSongIsFavorite ? "Unfavorite" : "Favorite",
                            systemImage: currentSongIsFavorite ? "heart.fill" : "heart"
                        )
                        .labelStyle(.iconOnly)
                        .font(.body)
                        .padding(8)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .padding(-8)
                    .disabled(audioPlayer.currentSong == nil || !viewModel.isOnline)
                    .help(currentSongIsFavorite ? "Remove from favorites" : "Add to favorites")
                }

                AirPlayRoutePickerAnchor(location: .compactPlayer)
                    .frame(width: 32, height: 40)

                Button(action: openFullPlayer) {
                    CoverArtView(resource: audioPlayer.currentSong.flatMap { viewModel.coverArtResource(for: $0, size: 96) }, size: 44)
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
                    if let album = currentAlbum {
                        PlayerAlbumContextMenu(
                            viewModel: viewModel,
                            album: album,
                            openRoute: openRoute
                        )
                    }
                }

                VStack(alignment: .leading, spacing: 6) {
                    title

                    metadataLine

                    HStack(spacing: 8) {
                        Text(timeText(audioPlayer.currentTime))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 42, alignment: .trailing)

                        Slider(
                            value: Binding(
                                get: { audioPlayer.currentTime },
                                set: { audioPlayer.seek(to: $0) }
                            ),
                            in: 0...progressUpperBound
                        )
                        .frame(minWidth: 180, idealWidth: 360, maxWidth: 520)
                        .disabled(audioPlayer.currentSong == nil || audioPlayer.duration <= 0)

                        Text(timeText(audioPlayer.duration))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 42, alignment: .leading)

                        HStack(spacing: 6) {
                            Image(systemName: volumeSystemImage)
                                .foregroundStyle(.secondary)
                                .frame(width: 18)

                            Slider(
                                value: Binding(
                                    get: { audioPlayer.volume },
                                    set: { audioPlayer.setVolume($0) }
                                ),
                                in: 0...1
                            )
                            .frame(width: 110)
                            .help("Volume")
                        }
                        .padding(.leading, 8)
                    }
                }
                .layoutPriority(1)

                if viewModel.isBusy {
                    ProgressView()
                        .controlSize(.small)
                }

                HStack(spacing: 8) {
                    detailButton(.lyrics)
                    detailButton(.queue)

                    Button(action: openFullPlayer) {
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
    }

    private func openFullPlayer() {
        onOpenFullPlayer()
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
        .disabled(panel == .lyrics && audioPlayer.currentSong == nil)
        .help("Open \(panel.title.lowercased())")
        .popover(isPresented: detailPanelBinding(for: panel), arrowEdge: .bottom) {
            detailView(for: panel)
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

    @ViewBuilder
    private func detailView(for panel: PlayerDetailPanel) -> some View {
        switch panel {
        case .queue:
            PlayerQueueView(viewModel: viewModel)
        case .lyrics:
            PlayerLyricsView(viewModel: viewModel)
        }
    }

    private var progressUpperBound: Double {
        max(audioPlayer.duration, 1)
    }

    private var currentSongIsFavorite: Bool {
        audioPlayer.currentSong.map(viewModel.isFavorite) ?? false
    }

    @ViewBuilder
    private var title: some View {
        if let song = audioPlayer.currentSong, let album = currentAlbum {
            Button {
                openRoute(.album(album))
            } label: {
                Text(song.title)
                    .font(.headline)
                    .lineLimit(1)
            }
            .buttonStyle(.plain)
            .help("Open album")
            .contextMenu {
                PlayerSongContextMenu(viewModel: viewModel, song: song)
            }
        } else {
            Text(audioPlayer.currentSong?.title ?? "Nothing playing")
                .font(.headline)
                .lineLimit(1)
                .contextMenu {
                    if let song = audioPlayer.currentSong {
                        PlayerSongContextMenu(viewModel: viewModel, song: song)
                    }
                }
        }
    }

    @ViewBuilder
    private var metadataLine: some View {
        if audioPlayer.currentSong == nil {
            Text(audioPlayer.statusMessage)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        } else {
            HStack(spacing: 5) {
                if let artist = currentArtist {
                    Button {
                        openRoute(.artist(artist))
                    } label: {
                        Text(artist.name)
                    }
                    .buttonStyle(.plain)
                    .help("Open artist")
                        .contextMenu {
                            PlayerArtistContextMenu(
                                viewModel: viewModel,
                                artist: artist,
                                openRoute: openRoute
                            )
                        }
                }

                if currentArtist != nil, currentAlbum != nil {
                    Text("-")
                }

                if let album = currentAlbum {
                    Button {
                        openRoute(.album(album))
                    } label: {
                        Text(album.name)
                    }
                    .buttonStyle(.plain)
                    .help("Open album")
                        .contextMenu {
                            PlayerAlbumContextMenu(
                                viewModel: viewModel,
                                album: album,
                                openRoute: openRoute
                            )
                        }
                }
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
    }

    private var currentAlbum: NavidromeAlbum? {
        audioPlayer.currentSong.flatMap(viewModel.albumForNavigation)
    }

    private var currentArtist: NavidromeArtist? {
        audioPlayer.currentSong.flatMap(viewModel.artistForNavigation)
    }

    private var volumeSystemImage: String {
        switch audioPlayer.volume {
        case 0:
            "speaker.slash.fill"
        case ..<0.4:
            "speaker.wave.1.fill"
        case ..<0.75:
            "speaker.wave.2.fill"
        default:
            "speaker.wave.3.fill"
        }
    }

    private func timeText(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds > 0 else { return "0:00" }
        let totalSeconds = Int(seconds.rounded(.down))
        return "\(totalSeconds / 60):\(String(format: "%02d", totalSeconds % 60))"
    }
}

struct PlayerSongContextMenu: View {
    @ObservedObject var viewModel: AppCoordinator
    let song: NavidromeSong

    var body: some View {
        Button {
            viewModel.playNext([song])
        } label: {
            Label("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward")
        }

        Button {
            viewModel.addToQueue([song])
        } label: {
            Label("Add to Queue", systemImage: "text.badge.plus")
        }

        Divider()

        Button {
            viewModel.toggleFavorite(song)
        } label: {
            Label(
                viewModel.isFavorite(song) ? "Remove from Favorites" : "Add to Favorites",
                systemImage: viewModel.isFavorite(song) ? "heart.slash" : "heart"
            )
        }
        .disabled(!viewModel.isOnline)

        AddToPlaylistMenu(viewModel: viewModel, songs: [song])
    }
}

struct PlayerAlbumContextMenu: View {
    @ObservedObject var viewModel: AppCoordinator
    let album: NavidromeAlbum
    let openRoute: (LibraryRoute) -> Void

    var body: some View {
        Button {
            viewModel.play(album)
        } label: {
            Label("Play", systemImage: "play.fill")
        }
        .disabled(!viewModel.isOnline)

        Button {
            viewModel.playNext(album)
        } label: {
            Label("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward")
        }

        Button {
            viewModel.addToQueue(album)
        } label: {
            Label("Add to Queue", systemImage: "text.badge.plus")
        }

        Button {
            viewModel.toggleFavorite(album)
        } label: {
            Label(
                viewModel.isFavorite(album) ? "Remove from Favorites" : "Add to Favorites",
                systemImage: viewModel.isFavorite(album) ? "heart.slash" : "heart"
            )
        }
        .disabled(!viewModel.isOnline)

        Divider()

        Button {
            openRoute(.album(album))
        } label: {
            Label("Open Album", systemImage: "rectangle.stack")
        }

        OpenInSpotifyLink(album: album)
    }
}

struct PlayerArtistContextMenu: View {
    @ObservedObject var viewModel: AppCoordinator
    let artist: NavidromeArtist
    let openRoute: (LibraryRoute) -> Void

    var body: some View {
        Button {
            viewModel.play(artist)
        } label: {
            Label("Play", systemImage: "play.fill")
        }
        .disabled(!viewModel.isOnline)

        Button {
            viewModel.playNext(artist)
        } label: {
            Label("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward")
        }

        Button {
            viewModel.addToQueue(artist)
        } label: {
            Label("Add to Queue", systemImage: "text.badge.plus")
        }

        Button {
            viewModel.toggleFavorite(artist)
        } label: {
            Label(
                viewModel.isFavorite(artist) ? "Remove from Favorites" : "Add to Favorites",
                systemImage: viewModel.isFavorite(artist) ? "heart.slash" : "heart"
            )
        }
        .disabled(!viewModel.isOnline)

        Divider()

        Button {
            openRoute(.artist(artist))
        } label: {
            Label("Open Artist", systemImage: "music.mic")
        }

        OpenInSpotifyLink(artist: artist)
    }
}
