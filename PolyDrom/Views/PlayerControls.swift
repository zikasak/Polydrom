//
//  PlayerControls.swift
//  PolyDrom
//

import SwiftUI

/// Previous, play or pause, next, stop, and favorite for the current song.
struct PlayerTransportControls: View {
    struct Style {
        let spacing: CGFloat
        let iconFont: Font
        let playIconFont: Font
        let playButtonSize: CGFloat
        /// Extends each button's click target past its glyph without moving it.
        let hitPadding: CGFloat

        static let compact = Style(
            spacing: 16,
            iconFont: .body,
            playIconFont: .system(size: 17, weight: .semibold),
            playButtonSize: 40,
            hitPadding: 8
        )
        static let full = Style(
            spacing: 34,
            iconFont: .title2,
            playIconFont: .system(size: 26, weight: .semibold),
            playButtonSize: 62,
            hitPadding: 0
        )
    }

    @ObservedObject var viewModel: AppCoordinator
    let currentSong: NavidromeSong?
    let isPlaying: Bool
    let style: Style

    var body: some View {
        let isFavorite = currentSong.map(viewModel.isFavorite) ?? false

        HStack(spacing: style.spacing) {
            iconButton("Previous", systemImage: "backward.fill") {
                viewModel.playPreviousTrack()
            }
            .disabled(!viewModel.canPlayPreviousTrack())

            Button {
                viewModel.audioPlayer.togglePlayPause()
            } label: {
                Label(isPlaying ? "Pause" : "Play", systemImage: isPlaying ? "pause.fill" : "play.fill")
                    .labelStyle(.iconOnly)
                    .font(style.playIconFont)
                    .frame(width: style.playButtonSize, height: style.playButtonSize)
                    .foregroundStyle(Color(nsColor: .windowBackgroundColor))
                    .background {
                        Circle()
                            .fill(Color(nsColor: .labelColor))
                    }
                    .modifier(HitArea(padding: style.hitPadding))
            }
            .buttonStyle(.plain)
            .padding(-style.hitPadding)
            .disabled(currentSong == nil)
            .help(isPlaying ? "Pause" : "Play")

            iconButton("Next", systemImage: "forward.fill") {
                viewModel.playNextTrack()
            }
            .disabled(!viewModel.canPlayNextTrack())

            iconButton("Stop", systemImage: "stop.fill") {
                viewModel.audioPlayer.stop()
            }
            .disabled(currentSong == nil)

            Button {
                if let currentSong {
                    viewModel.toggleFavorite(currentSong)
                }
            } label: {
                FavoriteLabel(isFavorite: isFavorite)
                    .labelStyle(.iconOnly)
                    .font(style.iconFont)
                    .modifier(HitArea(padding: style.hitPadding))
            }
            .buttonStyle(.plain)
            .padding(-style.hitPadding)
            .disabled(currentSong == nil || !viewModel.isOnline)
            .help(isFavorite ? "Remove from favorites" : "Add to favorites")
        }
    }

    private func iconButton(_ title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .labelStyle(.iconOnly)
                .font(style.iconFont)
                .modifier(HitArea(padding: style.hitPadding))
        }
        .buttonStyle(.plain)
        .padding(-style.hitPadding)
        .help(title)
    }

    private struct HitArea: ViewModifier {
        let padding: CGFloat

        func body(content: Content) -> some View {
            content
                .padding(padding)
                .contentShape(Rectangle())
        }
    }
}

struct PlayerSeekSlider: View {
    @ObservedObject var audioPlayer: AudioPlayer

    var body: some View {
        Slider(
            value: Binding(
                get: { audioPlayer.currentTime },
                set: { audioPlayer.seek(to: $0) }
            ),
            in: 0...max(audioPlayer.duration, 1)
        )
        .disabled(audioPlayer.currentSong == nil || audioPlayer.duration <= 0)
    }
}

struct PlayerVolumeControl: View {
    @ObservedObject var audioPlayer: AudioPlayer
    let spacing: CGFloat
    let iconWidth: CGFloat
    let sliderWidth: CGFloat

    var body: some View {
        HStack(spacing: spacing) {
            Image(systemName: systemImage)
                .foregroundStyle(.secondary)
                .frame(width: iconWidth)

            Slider(
                value: Binding(
                    get: { audioPlayer.volume },
                    set: { audioPlayer.setVolume($0) }
                ),
                in: 0...1
            )
            .frame(width: sliderWidth)
            .help("Volume")
        }
    }

    private var systemImage: String {
        switch audioPlayer.volume {
        case 0: "speaker.slash.fill"
        case ..<0.4: "speaker.wave.1.fill"
        case ..<0.75: "speaker.wave.2.fill"
        default: "speaker.wave.3.fill"
        }
    }
}

/// The current song's title, which opens its album.
struct NowPlayingTitle: View {
    @ObservedObject var viewModel: AppCoordinator
    let song: NavidromeSong?
    let font: Font
    let openRoute: (LibraryRoute) -> Void

    var body: some View {
        if let song, let album = viewModel.albumForNavigation(from: song) {
            Button {
                openRoute(.album(album))
            } label: {
                Text(song.title)
                    .font(font)
                    .lineLimit(1)
            }
            .buttonStyle(.plain)
            .help("Open album")
            .contextMenu {
                PlayerSongContextMenu(viewModel: viewModel, song: song)
            }
        } else {
            Text(song?.title ?? "Nothing playing")
                .font(font)
                .lineLimit(1)
                .contextMenu {
                    if let song {
                        PlayerSongContextMenu(viewModel: viewModel, song: song)
                    }
                }
        }
    }
}

/// The current song's artist and album, or the player's status when nothing is loaded.
struct NowPlayingMetadataLine: View {
    @ObservedObject var viewModel: AppCoordinator
    let song: NavidromeSong?
    let statusMessage: String
    let font: Font
    let spacing: CGFloat
    let openRoute: (LibraryRoute) -> Void

    var body: some View {
        if let song {
            let artist = viewModel.artistForNavigation(from: song)
            let album = viewModel.albumForNavigation(from: song)

            HStack(spacing: spacing) {
                if let artist {
                    Button(artist.name) {
                        openRoute(.artist(artist))
                    }
                    .buttonStyle(.plain)
                    .help("Open artist")
                    .contextMenu {
                        ArtistContextMenu(viewModel: viewModel, artist: artist) {
                            openRoute(.artist(artist))
                        }
                    }
                }

                if artist != nil, album != nil {
                    Text("-")
                }

                if let album {
                    Button(album.name) {
                        openRoute(.album(album))
                    }
                    .buttonStyle(.plain)
                    .help("Open album")
                    .contextMenu {
                        AlbumContextMenu(viewModel: viewModel, album: album) {
                            openRoute(.album(album))
                        }
                    }
                }
            }
            .font(font)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        } else {
            Text(statusMessage)
                .font(font)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }
}

enum PlayerDetailPanel: Equatable {
    case queue
    case lyrics

    var title: String {
        switch self {
        case .queue: "Queue"
        case .lyrics: "Lyrics"
        }
    }

    var systemImage: String {
        switch self {
        case .queue: "text.line.last.and.arrowtriangle.forward"
        case .lyrics: "quote.bubble"
        }
    }
}

struct PlayerDetailPanelView: View {
    let panel: PlayerDetailPanel
    let viewModel: AppCoordinator

    var body: some View {
        switch panel {
        case .queue:
            PlayerQueueView(viewModel: viewModel)
        case .lyrics:
            PlayerLyricsView(viewModel: viewModel)
        }
    }
}
