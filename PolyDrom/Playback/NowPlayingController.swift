//
//  NowPlayingController.swift
//  PolyDrom
//
//  Created by Codex on 09/07/2026.
//

import AppKit
import Foundation
import MediaPlayer

@MainActor
final class NowPlayingController {
    var onPlay: (() -> Void)?
    var onPause: (() -> Void)?
    var onTogglePlayPause: (() -> Void)?
    var onStop: (() -> Void)?
    var onPreviousTrack: (() -> Void)?
    var onNextTrack: (() -> Void)?
    var onSeek: ((Double) -> Void)?

    private var currentSongID: String?
    private var artworkData: Data?
    private var commandTargets: [(MPRemoteCommand, Any)] = []

    init() {
        configureRemoteCommands()
    }

    deinit {
        for (command, target) in commandTargets {
            command.removeTarget(target)
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }

    func update(
        song: NavidromeSong?,
        isPlaying: Bool,
        elapsedTime: Double,
        duration: Double,
        canPlayPrevious: Bool,
        canPlayNext: Bool
    ) {
        updateRemoteCommandAvailability(
            hasCurrentSong: song != nil,
            canPlayPrevious: canPlayPrevious,
            canPlayNext: canPlayNext
        )

        guard let song else {
            currentSongID = nil
            artworkData = nil
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            return
        }

        if currentSongID != song.id {
            currentSongID = song.id
            artworkData = nil
        }

        var nowPlayingInfo: [String: Any] = [
            MPMediaItemPropertyTitle: song.title,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: max(elapsedTime, 0),
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: 1.0
        ]

        if let artist = song.artist, !artist.isEmpty {
            nowPlayingInfo[MPMediaItemPropertyArtist] = artist
        }

        if let album = song.album, !album.isEmpty {
            nowPlayingInfo[MPMediaItemPropertyAlbumTitle] = album
        }

        let knownDuration = duration > 0 ? duration : Double(song.duration ?? 0)
        if knownDuration > 0 {
            nowPlayingInfo[MPMediaItemPropertyPlaybackDuration] = knownDuration
        }

        if let artworkData, let image = NSImage(data: artworkData) {
            nowPlayingInfo[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: image.size) { _ in
                image
            }
        }

        MPNowPlayingInfoCenter.default().nowPlayingInfo = nowPlayingInfo
    }

    func setArtworkData(_ data: Data?, for songID: String) {
        guard currentSongID == songID else { return }
        artworkData = data
    }

    private func configureRemoteCommands() {
        let commandCenter = MPRemoteCommandCenter.shared()

        addTarget(to: commandCenter.playCommand) { [weak self] in
            self?.onPlay?()
        }

        addTarget(to: commandCenter.pauseCommand) { [weak self] in
            self?.onPause?()
        }

        addTarget(to: commandCenter.togglePlayPauseCommand) { [weak self] in
            self?.onTogglePlayPause?()
        }

        addTarget(to: commandCenter.stopCommand) { [weak self] in
            self?.onStop?()
        }

        addTarget(to: commandCenter.previousTrackCommand) { [weak self] in
            self?.onPreviousTrack?()
        }

        addTarget(to: commandCenter.nextTrackCommand) { [weak self] in
            self?.onNextTrack?()
        }

        commandCenter.changePlaybackPositionCommand.isEnabled = false
        let seekTarget = commandCenter.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else {
                return .commandFailed
            }

            Task { @MainActor [weak self] in
                self?.onSeek?(event.positionTime)
            }
            return .success
        }
        commandTargets.append((commandCenter.changePlaybackPositionCommand, seekTarget))

        updateRemoteCommandAvailability(hasCurrentSong: false, canPlayPrevious: false, canPlayNext: false)
    }

    private func addTarget(to command: MPRemoteCommand, action: @escaping @MainActor () -> Void) {
        let target = command.addTarget { _ in
            Task { @MainActor in
                action()
            }
            return .success
        }
        commandTargets.append((command, target))
    }

    private func updateRemoteCommandAvailability(
        hasCurrentSong: Bool,
        canPlayPrevious: Bool,
        canPlayNext: Bool
    ) {
        let commandCenter = MPRemoteCommandCenter.shared()
        commandCenter.playCommand.isEnabled = hasCurrentSong
        commandCenter.pauseCommand.isEnabled = hasCurrentSong
        commandCenter.togglePlayPauseCommand.isEnabled = hasCurrentSong
        commandCenter.stopCommand.isEnabled = hasCurrentSong
        commandCenter.changePlaybackPositionCommand.isEnabled = hasCurrentSong
        commandCenter.previousTrackCommand.isEnabled = canPlayPrevious
        commandCenter.nextTrackCommand.isEnabled = canPlayNext
    }
}
