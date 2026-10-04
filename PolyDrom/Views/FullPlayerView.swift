//
//  FullPlayerView.swift
//  PolyDrom
//
//  Created by Codex on 10/07/2026.
//

import AVKit
import Combine
import SwiftUI

struct FullPlayerView: View {
    @ObservedObject var viewModel: AppCoordinator
    private let audioPlayer: AudioPlayer
    @State private var currentSong: NavidromeSong?
    @State private var isPlaying: Bool
    @State private var statusMessage: String
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
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
        _currentSong = State(initialValue: viewModel.audioPlayer.currentSong)
        _isPlaying = State(initialValue: viewModel.audioPlayer.isPlaying)
        _statusMessage = State(initialValue: viewModel.audioPlayer.statusMessage)
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
            let artworkResource = currentSong.flatMap {
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
                        PlayerDetailPanelView(panel: detailPanel, viewModel: viewModel)
                            .frame(width: min(360, max(300, proxy.size.width * 0.32)))
                            .transition(.move(edge: .trailing).combined(with: .opacity))
                    }
                }
            }
            .animation(reduceMotion ? nil : .snappy(duration: 0.28), value: detailPanel)
        }
        .frame(minWidth: 760, minHeight: 620)
        .onReceive(audioPlayer.$currentSong.removeDuplicates()) { currentSong = $0 }
        .onReceive(audioPlayer.$isPlaying.removeDuplicates()) { isPlaying = $0 }
        .onReceive(audioPlayer.$statusMessage.removeDuplicates()) { statusMessage = $0 }
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

                HStack(spacing: 8) {
                    detailButton(.queue)
                    detailButton(.lyrics)
                }
                .fixedSize()
                // Animate the pair's position, not each button's geometry independently.
                .geometryGroup()
            }

            Spacer(minLength: 0)

            CoverArtView(
                resource: artworkResource,
                size: artworkSize
            )
            .shadow(color: .black.opacity(0.28), radius: 28, y: 16)
            .contextMenu {
                if let album = currentSong.flatMap(viewModel.albumForNavigation) {
                    AlbumContextMenu(viewModel: viewModel, album: album) {
                        openRoute(.album(album))
                    }
                }
            }

            VStack(spacing: 5) {
                NowPlayingTitle(
                    viewModel: viewModel,
                    song: currentSong,
                    font: .system(size: 28, weight: .bold, design: .rounded),
                    openRoute: openRoute
                )

                NowPlayingMetadataLine(
                    viewModel: viewModel,
                    song: currentSong,
                    statusMessage: statusMessage,
                    font: .title3,
                    spacing: 6,
                    openRoute: openRoute
                )
            }
            .frame(maxWidth: 560)

            progressControls
                .frame(maxWidth: 600)

            PlayerTransportControls(
                viewModel: viewModel,
                currentSong: currentSong,
                isPlaying: isPlaying,
                style: .full
            )

            outputControls

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 36)
        .padding(.vertical, usesCompactSpacing ? 16 : 24)
    }

    private var progressControls: some View {
        FullPlayerProgressControls(audioPlayer: audioPlayer)
    }

    private var outputControls: some View {
        HStack(spacing: 12) {
            PlayerVolumeControl(audioPlayer: audioPlayer, spacing: 12, iconWidth: 20, sliderWidth: 180)

            Divider()
                .frame(height: 24)
                .padding(.horizontal, 4)

            AirPlayRoutePickerAnchor(location: .fullPlayer)
                .frame(width: 32, height: 30)

            SonosOutputPicker(viewModel: viewModel)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: Capsule())
    }

    private func detailButton(_ panel: PlayerDetailPanel) -> some View {
        Button {
            detailPanel = detailPanel == panel ? nil : panel
            if panel == .lyrics, let song = currentSong {
                Task { await viewModel.loadLyrics(for: song) }
            }
        } label: {
            Label(panel.title, systemImage: panel.systemImage)
        }
        .buttonStyle(.bordered)
        .tint(detailPanel == panel ? .accentColor : nil)
        // Keep selection colors out of the panel's spring animation.
        .animation(nil, value: detailPanel)
        .help(panel.title)
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
        return await CoverArtCache.shared.imageRetrying(for: resource)
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

struct PlayerQueueView: View {
    @ObservedObject var viewModel: AppCoordinator
    // Mirrors only the player state the queue shows. Observing the player itself
    // would rebuild every visible queue row on each playback-time tick.
    @State private var hasCurrentSong: Bool
    @State private var isPlaying: Bool

    init(viewModel: AppCoordinator) {
        self.viewModel = viewModel
        _hasCurrentSong = State(initialValue: viewModel.audioPlayer.currentSong != nil)
        _isPlaying = State(initialValue: viewModel.audioPlayer.isPlaying)
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
                                let isCurrent = hasCurrentSong
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
                                            Image(systemName: isPlaying ? "speaker.wave.2.fill" : "pause.fill")
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
                    .tracksLibraryScrollActivity()
                }
            }
        }
        .background(.ultraThinMaterial)
        .onReceive(viewModel.audioPlayer.$currentSong.map { $0 != nil }.removeDuplicates()) { value in
            hasCurrentSong = value
        }
        .onReceive(viewModel.audioPlayer.$isPlaying.removeDuplicates()) { value in
            isPlaying = value
        }
    }

    private func scrollToCurrentEntry(with proxy: ScrollViewProxy, animated: Bool) {
        guard hasCurrentSong,
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
    private let audioPlayer: AudioPlayer
    @State private var songID: String?
    @State private var highlightedLine: Int?

    init(viewModel: AppCoordinator) {
        self.viewModel = viewModel
        self.audioPlayer = viewModel.audioPlayer
        _songID = State(initialValue: viewModel.audioPlayer.currentSong?.id)
        _highlightedLine = State(initialValue: viewModel.lyricsTimeline.lineIndex(at: viewModel.audioPlayer.currentTime))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            panelHeader("Lyrics", subtitle: viewModel.currentLyrics?.displayLanguage)

            if viewModel.isLoadingLyrics {
                ProgressView("Loading lyrics...")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let lyrics = viewModel.currentLyrics, !lyrics.lines.isEmpty {
                lyricsScrollView(lyrics)
                    .id(viewModel.lyricsRevision)
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
        .onReceive(audioPlayer.$currentSong.map { $0?.id }.removeDuplicates()) { songID = $0 }
        .onReceive(audioPlayer.$currentTime) { updateHighlightedLine(at: $0) }
        .onChange(of: viewModel.lyricsRevision, initial: true) { _, _ in
            updateHighlightedLine(at: audioPlayer.currentTime)
        }
        .task(id: songID) {
            guard let song = audioPlayer.currentSong else { return }
            await viewModel.loadLyrics(for: song)
        }
    }

    private func updateHighlightedLine(at time: Double) {
        let index = viewModel.lyricsTimeline.lineIndex(at: time)
        if highlightedLine != index { highlightedLine = index }
    }

    private func lyricsScrollView(_ lyrics: SongLyrics) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    ForEach(lyrics.lines.indices, id: \.self) { index in
                        lyricRow(
                            lyrics.lineSegments[index],
                            isHighlighted: index == highlightedLine,
                            playbackTime: viewModel.lyricsTimeline.playbackTime(at: index)
                        )
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

    @ViewBuilder
    private func lyricRow(
        _ segments: [SongLyricsSegment],
        isHighlighted: Bool,
        playbackTime: Double?
    ) -> some View {
        if let playbackTime {
            Button {
                audioPlayer.seek(to: playbackTime)
            } label: {
                lyricText(segments, isHighlighted: isHighlighted)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Jump to this lyric")
            .accessibilityHint("Jumps playback to this lyric in the song")
        } else {
            lyricText(segments, isHighlighted: isHighlighted)
        }
    }

    private func lyricText(_ segments: [SongLyricsSegment], isHighlighted: Bool) -> some View {
        let font = Font.title3.weight(isHighlighted ? .semibold : .regular)
        var text = AttributedString(segments.isEmpty ? " " : "")
        for segment in segments {
            var run = AttributedString(segment.text)
            if segment.isBackground {
                run.font = font.italic()
                run.foregroundColor = isHighlighted ? .secondary : .secondary.opacity(0.6)
            }
            text.append(run)
        }

        return Text(text)
            .font(font)
            .foregroundStyle(isHighlighted ? .primary : .secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
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
