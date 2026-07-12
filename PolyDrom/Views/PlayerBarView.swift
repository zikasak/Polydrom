//
//  PlayerBarView.swift
//  PolyDrom
//
//  Created by zikasak on 07/07/2026.
//

import SwiftUI

struct PlayerBarView: View {
    @ObservedObject var viewModel: AppViewModel
    @ObservedObject private var audioPlayer: AudioPlayer
    let onOpenFullPlayer: (PlayerDetailPanel?) -> Void

    init(viewModel: AppViewModel, onOpenFullPlayer: @escaping (PlayerDetailPanel?) -> Void) {
        self.viewModel = viewModel
        self.audioPlayer = viewModel.audioPlayer
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
                            .font(.system(size: 17, weight: .semibold))
                            .frame(width: 40, height: 40)
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
                        Label("Next", systemImage: "forward.fill")
                            .labelStyle(.iconOnly)
                            .font(.body)
                    }
                    .buttonStyle(.plain)
                    .disabled(!viewModel.canPlayNextTrack())
                    .help("Next")

                    Button {
                        audioPlayer.stop()
                    } label: {
                        Label("Stop", systemImage: "stop.fill")
                            .labelStyle(.iconOnly)
                            .font(.body)
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
                        .font(.body)
                    }
                    .buttonStyle(.plain)
                    .disabled(audioPlayer.currentSong == nil)
                    .help(currentSongIsFavorite ? "Remove from favorites" : "Add to favorites")
                }

                AirPlayRoutePickerAnchor(location: .compactPlayer)
                    .frame(width: 32, height: 40)

                CoverArtView(resource: audioPlayer.currentSong.flatMap { viewModel.coverArtResource(for: $0, size: 96) }, size: 44)
                    .contentShape(Rectangle())
                    .onTapGesture(perform: openFullPlayer)

                VStack(alignment: .leading, spacing: 6) {
                    Text(audioPlayer.currentSong?.title ?? "Nothing playing")
                        .font(.headline)
                        .lineLimit(1)

                    Text(audioPlayer.currentSong?.subtitle ?? audioPlayer.statusMessage)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)

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
                .contentShape(Rectangle())
                .onTapGesture(perform: openFullPlayer)

                if viewModel.isBusy {
                    ProgressView()
                        .controlSize(.small)
                }

                HStack(spacing: 8) {
                    detailButton(.lyrics)
                    detailButton(.queue)
                }
            }
            .padding(12)
        }
        .background {
            Button {
                openFullPlayer()
            } label: {
                Rectangle()
                    .fill(.bar)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Open full player")
            .help("Open full player")
        }
    }

    private func openFullPlayer() {
        onOpenFullPlayer(nil)
    }

    private func detailButton(_ panel: PlayerDetailPanel) -> some View {
        Button {
            onOpenFullPlayer(panel)
        } label: {
            Label("Open \(panel.title)", systemImage: panel.systemImage)
                .labelStyle(.iconOnly)
                .font(.body)
                .frame(width: 30, height: 30)
        }
        .buttonStyle(.plain)
        .disabled(panel == .lyrics && audioPlayer.currentSong == nil)
        .help("Open \(panel.title.lowercased())")
    }

    private var progressUpperBound: Double {
        max(audioPlayer.duration, 1)
    }

    private var currentSongIsFavorite: Bool {
        audioPlayer.currentSong.map(viewModel.isFavorite) ?? false
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
