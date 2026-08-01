//
//  FullPlayerView.swift
//  PolyDrom
//
//  Created by Codex on 10/07/2026.
//

import AVKit
import SwiftUI

struct FullPlayerView: View {
    @ObservedObject var viewModel: AppCoordinator
    @ObservedObject private var audioPlayer: AudioPlayer
    @State private var detailPanel: PlayerDetailPanel?
    let openRoute: (LibraryRoute) -> Void
    let onClose: () -> Void

    init(
        viewModel: AppCoordinator,
        openRoute: @escaping (LibraryRoute) -> Void = { _ in },
        onClose: @escaping () -> Void
    ) {
        self.viewModel = viewModel
        self.audioPlayer = viewModel.audioPlayer
        self.openRoute = openRoute
        self.onClose = onClose
    }

    var body: some View {
        GeometryReader { proxy in
            let usesCompactSpacing = proxy.size.height < 760
            let artworkSize = max(
                220,
                min(430, proxy.size.height - 400, proxy.size.width * 0.42)
            )
            let artworkResource = audioPlayer.currentSong.flatMap {
                viewModel.coverArtResource(for: $0, size: 900)
            }

            ZStack {
                playerBackground(resource: artworkResource)

                HStack(spacing: 0) {
                    mainPlayer(
                        artworkResource: artworkResource,
                        artworkSize: artworkSize,
                        usesCompactSpacing: usesCompactSpacing
                    )
                        .frame(maxWidth: .infinity, maxHeight: .infinity)

                    if let detailPanel {
                        Divider()
                        detailView(for: detailPanel)
                            .frame(width: min(360, max(300, proxy.size.width * 0.32)))
                            .transition(.move(edge: .trailing).combined(with: .opacity))
                    }
                }
            }
            .animation(.snappy(duration: 0.28), value: detailPanel)
        }
        .frame(minWidth: 760, minHeight: 620)
    }

    private func playerBackground(resource: CoverArtResource?) -> some View {
        PlayerArtworkBackground(resource: resource)
            .ignoresSafeArea()
            .accessibilityHidden(true)
    }

    private func mainPlayer(
        artworkResource: CoverArtResource?,
        artworkSize: CGFloat,
        usesCompactSpacing: Bool
    ) -> some View {
        VStack(spacing: usesCompactSpacing ? 14 : 20) {
            HStack {
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .bold))
                        .frame(width: 30, height: 30)
                        .background(.regularMaterial, in: Circle())
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)
                .help("Close full player")

                Text("NOW PLAYING")
                    .font(.caption.weight(.semibold))
                    .tracking(1.8)
                    .foregroundStyle(.secondary)

                Spacer()

                detailButton(.queue)
                detailButton(.lyrics)
            }

            Spacer(minLength: 0)

            CoverArtView(
                resource: artworkResource,
                size: artworkSize
            )
            .shadow(color: .black.opacity(0.28), radius: 28, y: 16)
            .contextMenu {
                if let album = currentAlbum {
                    PlayerAlbumContextMenu(
                        viewModel: viewModel,
                        album: album,
                        openRoute: openRoute
                    )
                }
            }

            VStack(spacing: 5) {
                title

                metadataLine
            }
            .frame(maxWidth: 560)

            progressControls
                .frame(maxWidth: 600)

            transportControls

            outputControls

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 36)
        .padding(.vertical, usesCompactSpacing ? 16 : 24)
    }

    private var progressControls: some View {
        VStack(spacing: 4) {
            Slider(
                value: Binding(
                    get: { audioPlayer.currentTime },
                    set: { audioPlayer.seek(to: $0) }
                ),
                in: 0...max(audioPlayer.duration, 1)
            )
            .disabled(audioPlayer.currentSong == nil || audioPlayer.duration <= 0)

            HStack {
                Text(timeText(audioPlayer.currentTime))
                Spacer()
                Text("-\(timeText(max(audioPlayer.duration - audioPlayer.currentTime, 0)))")
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
        }
    }

    private var transportControls: some View {
        HStack(spacing: 34) {
            Button {
                viewModel.playPreviousTrack()
            } label: {
                Image(systemName: "backward.fill")
                    .font(.title2)
            }
            .buttonStyle(.plain)
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
                    .font(.system(size: 26, weight: .semibold))
                    .frame(width: 62, height: 62)
                    .foregroundStyle(Color(nsColor: .windowBackgroundColor))
                    .background {
                        Circle()
                            .fill(Color(nsColor: .labelColor))
                    }
            }
            .buttonStyle(.plain)
            .disabled(audioPlayer.currentSong == nil)
            .help(audioPlayer.isPlaying ? "Pause" : "Play")

            Button {
                viewModel.playNextTrack()
            } label: {
                Image(systemName: "forward.fill")
                    .font(.title2)
            }
            .buttonStyle(.plain)
            .disabled(!viewModel.canPlayNextTrack())
            .help("Next")

            Button {
                audioPlayer.stop()
            } label: {
                Label("Stop", systemImage: "stop.fill")
                    .labelStyle(.iconOnly)
                    .font(.title2)
            }
            .buttonStyle(.plain)
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
                .font(.title2)
            }
            .buttonStyle(.plain)
            .disabled(audioPlayer.currentSong == nil || !viewModel.isOnline)
            .help(currentSongIsFavorite ? "Remove from favorites" : "Add to favorites")
        }
    }

    private var outputControls: some View {
        HStack(spacing: 12) {
            Image(systemName: volumeSystemImage)
                .foregroundStyle(.secondary)
                .frame(width: 20)

            Slider(
                value: Binding(
                    get: { audioPlayer.volume },
                    set: { audioPlayer.setVolume($0) }
                ),
                in: 0...1
            )
            .frame(width: 180)
            .help("Volume")

            Divider()
                .frame(height: 24)
                .padding(.horizontal, 4)

            AirPlayRoutePickerAnchor(location: .fullPlayer)
                .frame(width: 32, height: 30)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: Capsule())
    }

    private func detailButton(_ panel: PlayerDetailPanel) -> some View {
        Button {
            detailPanel = detailPanel == panel ? nil : panel
            if panel == .lyrics, let song = audioPlayer.currentSong {
                Task { await viewModel.loadLyrics(for: song) }
            }
        } label: {
            Label(panel.title, systemImage: panel.systemImage)
        }
        .buttonStyle(.bordered)
        .tint(detailPanel == panel ? .accentColor : nil)
        .help(panel.title)
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

    private var volumeSystemImage: String {
        switch audioPlayer.volume {
        case 0: "speaker.slash.fill"
        case ..<0.4: "speaker.wave.1.fill"
        case ..<0.75: "speaker.wave.2.fill"
        default: "speaker.wave.3.fill"
        }
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
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                    .lineLimit(1)
            }
            .buttonStyle(.plain)
            .help("Open album")
            .contextMenu {
                PlayerSongContextMenu(viewModel: viewModel, song: song)
            }
        } else {
            Text(audioPlayer.currentSong?.title ?? "Nothing playing")
                .font(.system(size: 28, weight: .bold, design: .rounded))
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
                .font(.title3)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        } else {
            HStack(spacing: 6) {
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
            .font(.title3)
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

    private func timeText(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds > 0 else { return "0:00" }
        let totalSeconds = Int(seconds.rounded(.down))
        return "\(totalSeconds / 60):\(String(format: "%02d", totalSeconds % 60))"
    }
}

private struct PlayerArtworkBackground: View {
    private struct Artwork {
        let cacheKey: String
        let image: CGImage
    }

    let resource: CoverArtResource?

    @Environment(\.colorScheme) private var colorScheme
    @State private var outgoingArtwork: Artwork?
    @State private var displayedArtwork: Artwork?
    @State private var transitionProgress = 1.0

    var body: some View {
        GeometryReader { proxy in
            let imageSize = max(proxy.size.width, proxy.size.height)

            ZStack {
                Color(nsColor: .windowBackgroundColor)

                if let outgoingArtwork {
                    artworkLayer(outgoingArtwork.image, size: imageSize)
                        .opacity(1 - transitionProgress)
                }

                if let displayedArtwork {
                    artworkLayer(displayedArtwork.image, size: imageSize)
                        .opacity(transitionProgress)
                }

                Rectangle()
                    .fill(.ultraThinMaterial)

                LinearGradient(
                    colors: [
                        Color(nsColor: .windowBackgroundColor).opacity(
                            colorScheme == .dark ? 0.16 : 0.34
                        ),
                        Color(nsColor: .windowBackgroundColor).opacity(
                            colorScheme == .dark ? 0.52 : 0.68
                        )
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            }
        }
        .task(id: resource?.cacheKey) {
            guard let resource else {
                await transition(to: nil)
                return
            }

            if displayedArtwork?.cacheKey == resource.cacheKey { return }

            let image = await loadImage(for: resource)
            guard !Task.isCancelled else { return }

            await transition(
                to: image.map { Artwork(cacheKey: resource.cacheKey, image: $0) }
            )
        }
    }

    private func artworkLayer(_ image: CGImage, size: CGFloat) -> some View {
        Image(decorative: image, scale: 1)
            .resizable()
            .scaledToFill()
            .frame(width: size, height: size)
            .clipped()
            .scaleEffect(1.16)
            .blur(radius: 64, opaque: true)
            .saturation(1.25)
            .opacity(colorScheme == .dark ? 0.72 : 0.52)
    }

    private func loadImage(for resource: CoverArtResource) async -> CGImage? {
        if let cachedImage = CoverArtCache.shared.cachedImage(for: resource) {
            return cachedImage
        }

        for attempt in 0..<3 {
            do {
                return try await CoverArtCache.shared.image(for: resource)
            } catch {
                guard !Task.isCancelled, attempt < 2 else { return nil }

                do {
                    try await Task.sleep(for: .milliseconds(attempt == 0 ? 400 : 900))
                } catch {
                    return nil
                }
            }
        }

        return nil
    }

    @MainActor
    private func transition(to artwork: Artwork?) async {
        guard displayedArtwork?.cacheKey != artwork?.cacheKey else { return }

        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            outgoingArtwork = displayedArtwork
            displayedArtwork = artwork
            transitionProgress = 0
        }

        await Task.yield()

        withAnimation(.easeInOut(duration: 0.8)) {
            transitionProgress = 1
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

struct PlayerQueueView: View {
    @ObservedObject var viewModel: AppCoordinator
    @ObservedObject private var audioPlayer: AudioPlayer
    @State private var isScrolling = false

    init(viewModel: AppCoordinator) {
        self.viewModel = viewModel
        self.audioPlayer = viewModel.audioPlayer
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            panelHeader("Playing Queue", subtitle: "\(viewModel.playbackQueue.count) songs")

            if viewModel.playbackQueue.isEmpty {
                ContentUnavailableView("Queue is empty", systemImage: "music.note.list")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 4) {
                            ForEach(viewModel.playbackQueue) { entry in
                                let song = entry.song
                                let isCurrent = audioPlayer.currentSong != nil
                                    && viewModel.currentPlaybackQueueEntryID == entry.id
                                Button {
                                    viewModel.play(entry)
                                } label: {
                                    HStack(spacing: 10) {
                                        CoverArtView(resource: viewModel.coverArtResource(for: song, size: 96), size: 42)

                                        VStack(alignment: .leading, spacing: 3) {
                                            Text(song.title)
                                                .fontWeight(isCurrent ? .semibold : .regular)
                                                .lineLimit(1)
                                            Text(song.artist ?? song.album ?? "Unknown artist")
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                                .lineLimit(1)
                                        }

                                        Spacer()

                                        if isCurrent {
                                            Image(systemName: audioPlayer.isPlaying ? "speaker.wave.2.fill" : "pause.fill")
                                                .foregroundStyle(.tint)
                                        } else {
                                            Text(song.durationText)
                                                .font(.caption.monospacedDigit())
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                    .padding(8)
                                    .background(
                                        isCurrent ? Color.accentColor.opacity(0.13) : .clear,
                                        in: RoundedRectangle(cornerRadius: 8)
                                    )
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .disabled(!viewModel.isOnline)
                                .id(entry.id)
                            }
                        }
                        .padding(.horizontal, 12)
                        .padding(.bottom, 12)
                    }
                    .onAppear {
                        scrollToCurrentEntry(with: proxy, animated: false)
                    }
                    .onChange(of: viewModel.currentPlaybackQueueEntryID) { _, _ in
                        scrollToCurrentEntry(with: proxy, animated: true)
                    }
                    .onScrollPhaseChange { _, newPhase in
                        isScrolling = newPhase.isScrolling
                    }
                    .environment(\.libraryGridIsScrolling, isScrolling)
                }
            }
        }
        .background(.ultraThinMaterial)
    }

    private func scrollToCurrentEntry(with proxy: ScrollViewProxy, animated: Bool) {
        guard audioPlayer.currentSong != nil,
              let currentEntryID = viewModel.currentPlaybackQueueEntryID,
              viewModel.playbackQueue.contains(where: { $0.id == currentEntryID }) else {
            return
        }

        let scroll = {
            proxy.scrollTo(currentEntryID, anchor: .center)
        }
        if animated {
            withAnimation(.easeOut(duration: 0.3), scroll)
        } else {
            scroll()
        }
    }
}

struct PlayerLyricsView: View {
    @ObservedObject var viewModel: AppCoordinator
    @ObservedObject private var audioPlayer: AudioPlayer

    init(viewModel: AppCoordinator) {
        self.viewModel = viewModel
        self.audioPlayer = viewModel.audioPlayer
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            panelHeader("Lyrics", subtitle: viewModel.currentLyrics?.displayLanguage)

            if viewModel.isLoadingLyrics {
                ProgressView("Loading lyrics...")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let lyrics = viewModel.currentLyrics, !lyrics.lines.isEmpty {
                lyricsScrollView(lyrics)
            } else {
                ContentUnavailableView(
                    "Lyrics unavailable",
                    systemImage: "quote.bubble",
                    description: Text(viewModel.lyricsMessage)
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(.ultraThinMaterial)
        .task(id: audioPlayer.currentSong?.id) {
            guard let song = audioPlayer.currentSong else { return }
            await viewModel.loadLyrics(for: song)
        }
    }

    private func lyricsScrollView(_ lyrics: SongLyrics) -> some View {
        let highlightedLine = currentLineIndex(in: lyrics)

        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    ForEach(Array(lyrics.lines.enumerated()), id: \.offset) { index, line in
                        Text(line.value.isEmpty ? " " : line.value)
                            .font(.title3.weight(index == highlightedLine ? .semibold : .regular))
                            .foregroundStyle(index == highlightedLine ? .primary : .secondary)
                            .id(index)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 22)
                .padding(.bottom, 28)
            }
            .onAppear {
                guard let highlightedLine else { return }
                proxy.scrollTo(highlightedLine, anchor: .center)
            }
            .onChange(of: highlightedLine) { _, index in
                guard let index else { return }
                withAnimation(.easeOut(duration: 0.3)) {
                    proxy.scrollTo(index, anchor: .center)
                }
            }
        }
    }

    private func currentLineIndex(in lyrics: SongLyrics) -> Int? {
        guard lyrics.synced else { return nil }
        let currentMilliseconds = Int(audioPlayer.currentTime * 1_000) + (lyrics.offset ?? 0)
        return lyrics.lines.lastIndex { ($0.start ?? Int.max) <= currentMilliseconds }
    }
}

private func panelHeader(_ title: String, subtitle: String?) -> some View {
    HStack {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.title2.bold())
            if let subtitle, !subtitle.isEmpty {
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        Spacer()
    }
    .padding(20)
}
