//
//  AudioPlayer.swift
//  PolyDrom
//
//  Created by zikasak on 07/07/2026.
//

import AVFoundation
import Combine
import Foundation

@MainActor
final class AudioPlayer: ObservableObject {
    @Published var currentSong: NavidromeSong?
    @Published var isPlaying = false
    @Published var statusMessage = "Nothing playing"
    @Published var currentTime: Double = 0
    @Published var duration: Double = 0
    @Published var volume: Double = 1

    let player: AVPlayer
    let airPlayRoutePickerController: AirPlayRoutePickerController
    var onSongFinished: (() -> Void)?

    private let nowPlayingController = NowPlayingController()
    private var timeObserver: Any?
    private var songFinishedObserver: Any?
    private var songFailedObserver: Any?
    private var playbackStalledObserver: Any?
    private var itemStatusObservation: NSKeyValueObservation?
    private var timeControlStatusObservation: NSKeyValueObservation?
    private var stallCheckTimer: Timer?
    private var hasFinishedCurrentSong = false
    private var playbackGeneration = 0
    private var lastObservedPlaybackTime: Double = 0
    private var lastPlaybackProgressAt = Date()
    private var didAttemptStallRecovery = false
    private var canPlayPreviousInNowPlaying = false
    private var canPlayNextInNowPlaying = false

    init() {
        let player = AVPlayer()
        self.player = player
        self.airPlayRoutePickerController = AirPlayRoutePickerController(player: player)
        player.allowsExternalPlayback = true
        player.volume = Float(volume)
        observeTimeControlStatus()
    }

    deinit {
        if let timeObserver {
            player.removeTimeObserver(timeObserver)
        }
        if let songFinishedObserver {
            NotificationCenter.default.removeObserver(songFinishedObserver)
        }
        if let songFailedObserver {
            NotificationCenter.default.removeObserver(songFailedObserver)
        }
        if let playbackStalledObserver {
            NotificationCenter.default.removeObserver(playbackStalledObserver)
        }
        itemStatusObservation?.invalidate()
        timeControlStatusObservation?.invalidate()
        stallCheckTimer?.invalidate()
    }

    func play(song: NavidromeSong, url: URL) {
        playbackGeneration += 1
        removeTimeObserver()
        removeStallCheckTimer()
        resetStallTracking()
        let item = AVPlayerItem(url: url)
        observeSongFinished(for: item)
        observePlaybackFailure(for: item)
        player.replaceCurrentItem(with: item)
        observePlaybackTime(for: playbackGeneration)
        observePlaybackStalls()
        startStallCheckTimer()
        player.play()
        currentSong = song
        isPlaying = true
        hasFinishedCurrentSong = false
        currentTime = 0
        duration = Double(song.duration ?? 0)
        statusMessage = "Playing through the selected audio route."
        updateNowPlayingInfo()
    }

    func togglePlayPause() {
        if isPlaying {
            pauseCurrentSong()
        } else {
            playCurrentSong()
        }
    }

    func playCurrentSong() {
        guard currentSong != nil else { return }

        resetStallTracking(at: currentTime)
        startStallCheckTimer()
        isPlaying = true
        player.play()
        statusMessage = "Playing through the selected audio route."
        updateNowPlayingInfo()
    }

    func pauseCurrentSong() {
        guard currentSong != nil else { return }

        player.pause()
        removeStallCheckTimer()
        isPlaying = false
        statusMessage = "Paused"
        updateNowPlayingInfo()
    }

    func stop() {
        playbackGeneration += 1
        removeTimeObserver()
        removeSongFinishedObserver()
        removePlaybackFailureObserver()
        removePlaybackStalledObserver()
        removeStallCheckTimer()
        player.pause()
        player.replaceCurrentItem(with: nil)
        currentSong = nil
        isPlaying = false
        hasFinishedCurrentSong = false
        currentTime = 0
        duration = 0
        statusMessage = "Nothing playing"
        updateNowPlayingInfo()
    }

    func seek(to seconds: Double) {
        guard currentSong != nil else { return }
        let clampedSeconds = min(max(seconds, 0), max(duration, 0))
        currentTime = clampedSeconds
        lastObservedPlaybackTime = clampedSeconds
        lastPlaybackProgressAt = Date()
        didAttemptStallRecovery = false
        player.seek(to: CMTime(seconds: clampedSeconds, preferredTimescale: 600))
        updateNowPlayingInfo()
    }

    func setVolume(_ nextVolume: Double) {
        let clampedVolume = min(max(nextVolume, 0), 1)
        volume = clampedVolume
        player.volume = Float(clampedVolume)
    }

    func setNowPlayingQueueState(canPlayPrevious: Bool, canPlayNext: Bool) {
        canPlayPreviousInNowPlaying = canPlayPrevious
        canPlayNextInNowPlaying = canPlayNext
        updateNowPlayingInfo()
    }

    func setNowPlayingArtworkData(_ data: Data?, for songID: String) {
        nowPlayingController.setArtworkData(data, for: songID)
        updateNowPlayingInfo()
    }

    func configureRemotePlaybackCommands(
        onPreviousTrack: @escaping () -> Void,
        onNextTrack: @escaping () -> Void
    ) {
        nowPlayingController.onPlay = { [weak self] in
            self?.playCurrentSong()
        }
        nowPlayingController.onPause = { [weak self] in
            self?.pauseCurrentSong()
        }
        nowPlayingController.onTogglePlayPause = { [weak self] in
            self?.togglePlayPause()
        }
        nowPlayingController.onStop = { [weak self] in
            self?.stop()
        }
        nowPlayingController.onPreviousTrack = onPreviousTrack
        nowPlayingController.onNextTrack = onNextTrack
        nowPlayingController.onSeek = { [weak self] seconds in
            self?.seek(to: seconds)
        }
    }

    private func updatePlaybackTime(_ seconds: Double, generation: Int) {
        guard generation == playbackGeneration, currentSong != nil else { return }

        if seconds.isFinite {
            currentTime = seconds
            if seconds > lastObservedPlaybackTime + 0.1 || seconds < lastObservedPlaybackTime - 1 {
                lastObservedPlaybackTime = seconds
                lastPlaybackProgressAt = Date()
                didAttemptStallRecovery = false
            }
        }

        if let itemDuration = player.currentItem?.duration.seconds,
           itemDuration.isFinite,
           itemDuration > 0 {
            duration = itemDuration
        }

        if shouldFinishCurrentSong(at: seconds) {
            finishCurrentSong()
        }

        updateNowPlayingInfo()
    }

    private func checkForPlaybackStall() {
        guard isPlaying, currentSong != nil, !hasFinishedCurrentSong else { return }
        guard player.timeControlStatus != .paused else {
            synchronizePlaybackStateWithPlayer()
            return
        }

        if shouldFinishCurrentSong(at: currentTime) {
            finishCurrentSong()
            return
        }

        let stalledFor = Date().timeIntervalSince(lastPlaybackProgressAt)
        if stalledFor >= 18 {
            statusMessage = "Skipping stalled track"
            finishCurrentSong()
        } else if stalledFor >= 8, !didAttemptStallRecovery {
            didAttemptStallRecovery = true
            statusMessage = "Recovering playback..."
            player.play()
        }
    }

    private func observePlaybackTime(for generation: Int) {
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.5, preferredTimescale: 600),
            queue: .main
        ) { [weak self] time in
            let seconds = time.seconds
            Task { [weak self] in
                await self?.updatePlaybackTime(seconds, generation: generation)
            }
        }
    }

    private func observeSongFinished(for item: AVPlayerItem) {
        removeSongFinishedObserver()
        songFinishedObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] _ in
            Task { [weak self] in
                await self?.finishCurrentSong()
            }
        }
    }

    private func observePlaybackFailure(for item: AVPlayerItem) {
        removePlaybackFailureObserver()
        songFailedObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemFailedToPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] notification in
            let error = notification.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error
            Task { [weak self] in
                await self?.failCurrentSong(error: error ?? item.error)
            }
        }

        itemStatusObservation = item.observe(\.status, options: [.new]) { [weak self, weak item] observedItem, _ in
            guard observedItem.status == .failed else { return }
            Task { @MainActor [weak self, weak item] in
                self?.failCurrentSong(error: item?.error)
            }
        }
    }

    private func observePlaybackStalls() {
        removePlaybackStalledObserver()
        playbackStalledObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemPlaybackStalled,
            object: player.currentItem,
            queue: .main
        ) { [weak self] _ in
            Task { [weak self] in
                await self?.recoverFromPlaybackStall()
            }
        }
    }

    private func observeTimeControlStatus() {
        timeControlStatusObservation = player.observe(\.timeControlStatus, options: [.new]) { [weak self] _, _ in
            Task { @MainActor [weak self] in
                self?.synchronizePlaybackStateWithPlayer()
            }
        }
    }

    private func synchronizePlaybackStateWithPlayer() {
        guard currentSong != nil, !hasFinishedCurrentSong else { return }

        switch player.timeControlStatus {
        case .paused:
            guard isPlaying else { return }
            removeStallCheckTimer()
            isPlaying = false
            statusMessage = "Paused"
            updateNowPlayingInfo()
        case .waitingToPlayAtSpecifiedRate, .playing:
            guard !isPlaying else { return }
            resetStallTracking(at: currentTime)
            startStallCheckTimer()
            isPlaying = true
            statusMessage = "Playing through the selected audio route."
            updateNowPlayingInfo()
        @unknown default:
            break
        }
    }

    private func removeSongFinishedObserver() {
        if let songFinishedObserver {
            NotificationCenter.default.removeObserver(songFinishedObserver)
            self.songFinishedObserver = nil
        }
    }

    private func removePlaybackFailureObserver() {
        if let songFailedObserver {
            NotificationCenter.default.removeObserver(songFailedObserver)
            self.songFailedObserver = nil
        }
        itemStatusObservation?.invalidate()
        itemStatusObservation = nil
    }

    private func removePlaybackStalledObserver() {
        if let playbackStalledObserver {
            NotificationCenter.default.removeObserver(playbackStalledObserver)
            self.playbackStalledObserver = nil
        }
    }

    private func removeTimeObserver() {
        if let timeObserver {
            player.removeTimeObserver(timeObserver)
            self.timeObserver = nil
        }
    }

    private func startStallCheckTimer() {
        removeStallCheckTimer()
        stallCheckTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { [weak self] in
                await self?.checkForPlaybackStall()
            }
        }
    }

    private func removeStallCheckTimer() {
        stallCheckTimer?.invalidate()
        stallCheckTimer = nil
    }

    private func resetStallTracking(at playbackTime: Double = 0) {
        lastObservedPlaybackTime = playbackTime
        lastPlaybackProgressAt = Date()
        didAttemptStallRecovery = false
    }

    private func recoverFromPlaybackStall() {
        guard isPlaying, currentSong != nil, !hasFinishedCurrentSong else { return }
        didAttemptStallRecovery = true
        lastPlaybackProgressAt = Date()
        statusMessage = "Recovering playback..."
        player.play()
        updateNowPlayingInfo()
    }

    private func finishCurrentSong() {
        guard !hasFinishedCurrentSong else { return }
        hasFinishedCurrentSong = true
        removeStallCheckTimer()
        currentTime = duration
        isPlaying = false
        statusMessage = "Finished"
        updateNowPlayingInfo()
        onSongFinished?()
    }

    private func failCurrentSong(error: Error?) {
        guard !hasFinishedCurrentSong else { return }
        hasFinishedCurrentSong = true
        removeStallCheckTimer()
        isPlaying = false
        statusMessage = "Playback failed: \(error?.localizedDescription ?? "Unknown error")"
        updateNowPlayingInfo()
    }

    private func shouldFinishCurrentSong(at seconds: Double) -> Bool {
        guard isPlaying, !hasFinishedCurrentSong, seconds.isFinite else { return false }
        let knownDuration = duration > 0 ? duration : Double(currentSong?.duration ?? 0)
        guard knownDuration > 0 else { return false }
        return seconds >= max(knownDuration - 0.75, 0)
    }

    private func updateNowPlayingInfo() {
        nowPlayingController.update(
            song: currentSong,
            isPlaying: isPlaying,
            elapsedTime: currentTime,
            duration: duration,
            canPlayPrevious: canPlayPreviousInNowPlaying,
            canPlayNext: canPlayNextInNowPlaying
        )
    }
}
