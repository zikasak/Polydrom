//
//  FullPlayerView.swift
//  PolyDrom
//
//  Created by Codex on 10/07/2026.
//

import AVKit
import SwiftUI

struct FullPlayerView: View {
    @ObservedObject var viewModel: AppViewModel
    @ObservedObject private var audioPlayer: AudioPlayer
    @State private var detailPanel: PlayerDetailPanel?
    let onClose: () -> Void

    init(
        viewModel: AppViewModel,
        initialDetailPanel: PlayerDetailPanel? = nil,
        onClose: @escaping () -> Void
    ) {
        self.viewModel = viewModel
        self.audioPlayer = viewModel.audioPlayer
        self._detailPanel = State(initialValue: initialDetailPanel)
        self.onClose = onClose
    }

    var body: some View {
        GeometryReader { proxy in
            let usesCompactSpacing = proxy.size.height < 760
            let artworkSize = max(
                220,
                min(430, proxy.size.height - 400, proxy.size.width * 0.42)
            )

            ZStack {
                playerBackground

                HStack(spacing: 0) {
                    mainPlayer(artworkSize: artworkSize, usesCompactSpacing: usesCompactSpacing)
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

    private var playerBackground: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)

            LinearGradient(
                colors: [
                    Color.accentColor.opacity(0.20),
                    .clear,
                    .clear
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
        .ignoresSafeArea()
    }

    private func mainPlayer(artworkSize: CGFloat, usesCompactSpacing: Bool) -> some View {
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
                resource: audioPlayer.currentSong.flatMap { viewModel.coverArtResource(for: $0, size: 900) },
                size: artworkSize
            )
            .shadow(color: .black.opacity(0.28), radius: 28, y: 16)

            VStack(spacing: 5) {
                Text(audioPlayer.currentSong?.title ?? "Nothing playing")
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                    .lineLimit(1)

                Text(audioPlayer.currentSong?.subtitle ?? audioPlayer.statusMessage)
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
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

    private func timeText(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds > 0 else { return "0:00" }
        let totalSeconds = Int(seconds.rounded(.down))
        return "\(totalSeconds / 60):\(String(format: "%02d", totalSeconds % 60))"
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

private struct PlayerQueueView: View {
    @ObservedObject var viewModel: AppViewModel
    @ObservedObject private var audioPlayer: AudioPlayer
    @State private var isScrolling = false

    init(viewModel: AppViewModel) {
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
                ScrollView {
                    LazyVStack(spacing: 4) {
                        ForEach(Array(viewModel.playbackQueue.enumerated()), id: \.offset) { _, song in
                            Button {
                                viewModel.play(song, in: viewModel.playbackQueue)
                            } label: {
                                HStack(spacing: 10) {
                                    CoverArtView(resource: viewModel.coverArtResource(for: song, size: 96), size: 42)

                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(song.title)
                                            .fontWeight(audioPlayer.currentSong?.id == song.id ? .semibold : .regular)
                                            .lineLimit(1)
                                        Text(song.artist ?? song.album ?? "Unknown artist")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                    }

                                    Spacer()

                                    if audioPlayer.currentSong?.id == song.id {
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
                                    audioPlayer.currentSong?.id == song.id ? Color.accentColor.opacity(0.13) : .clear,
                                    in: RoundedRectangle(cornerRadius: 8)
                                )
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.bottom, 12)
                }
                .onScrollPhaseChange { _, newPhase in
                    isScrolling = newPhase.isScrolling
                }
                .environment(\.libraryGridIsScrolling, isScrolling)
            }
        }
        .background(.ultraThinMaterial)
    }
}

private struct PlayerLyricsView: View {
    @ObservedObject var viewModel: AppViewModel
    @ObservedObject private var audioPlayer: AudioPlayer

    init(viewModel: AppViewModel) {
        self.viewModel = viewModel
        self.audioPlayer = viewModel.audioPlayer
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            panelHeader("Lyrics", subtitle: viewModel.currentLyrics?.language?.uppercased())

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
