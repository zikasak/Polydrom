//
//  AudioPlayer.swift
//  PolyDrom
//
//  Created by zikasak on 07/07/2026.
//

import AVFoundation
import Combine
import Foundation
import OSLog

enum PlaybackRoute: Equatable {
    case local
    case sonos(String)
}

enum SonosPlaybackCommand {
    case play
    case pause
    case stop
    case seek(Double)
    case volume(Double)
}

@MainActor
final class AudioPlayer: ObservableObject {
    @Published var currentSong: NavidromeSong?
    @Published var isPlaying = false
    @Published var statusMessage = "Nothing playing"
    @Published var currentTime: Double = 0
    @Published var duration: Double = 0
    @Published var volume: Double = 1
    @Published private(set) var route: PlaybackRoute = .local

    let player: AVPlayer
    let airPlayRoutePickerController: AirPlayRoutePickerController
    var onSongFinished: (() -> Void)?
    var onSongFailed: ((NavidromeSong) -> Void)?
    var onPlaybackStateChanged: (() -> Void)?
    var onPlaybackEvent: ((AudioPlaybackEvent) -> Void)?
    var onVolumeChanged: ((Double) -> Void)?
    var onSonosCommand: ((SonosPlaybackCommand) -> Void)?

    var hasPlayableItem: Bool {
        player.currentItem != nil || (route != .local && currentSong != nil)
    }

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
    private var pendingSeekTarget: Double?
    private var canPlayPreviousInNowPlaying = false
    private var canPlayNextInNowPlaying = false
    private var localVolume: Double = 1
    private var isHandoffInProgress = false

    init() {
        let player = AVPlayer()
        self.player = player
        self.airPlayRoutePickerController = AirPlayRoutePickerController(player: player)
        player.allowsExternalPlayback = true
        player.volume = Float(volume)
        observeTimeControlStatus()
    }

    isolated deinit {
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

    func play(
        song: NavidromeSong,
        url: URL,
        startingAt startTime: Double = 0,
        autoplay: Bool = true,
        reportStart: Bool = true
    ) {
        route = .local
        AppLog.playback.info(
            "Starting playback for song \(song.id, privacy: .private(mask: .hash))"
        )
        let targetTime = normalizedPlaybackTime(startTime, duration: Double(song.duration ?? 0))
        playbackGeneration += 1
        let generation = playbackGeneration
        removeTimeObserver()
        removeStallCheckTimer()
        pendingSeekTarget = targetTime > 0 ? targetTime : nil
        resetStallTracking(at: targetTime)
        let item = AVPlayerItem(url: url)
        observeSongFinished(for: item)
        observePlaybackFailure(for: item, generation: generation)
        player.replaceCurrentItem(with: item)
        observePlaybackTime(for: playbackGeneration)
        observePlaybackStalls()
        startStallCheckTimer()
        currentSong = song
        isPlaying = autoplay
        hasFinishedCurrentSong = false
        currentTime = targetTime
        duration = Double(song.duration ?? 0)
        statusMessage = autoplay ? "Playing through the selected audio route." : "Paused"

        if targetTime > 0 {
            let target = CMTime(seconds: targetTime, preferredTimescale: 600)
            player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self,
                          self.playbackGeneration == generation,
                          self.currentSong?.id == song.id else { return }
                    self.currentTime = targetTime
                    self.lastObservedPlaybackTime = targetTime
                    self.lastPlaybackProgressAt = Date()
                    if autoplay {
                        self.player.play()
                    }
                    self.updateNowPlayingInfo()
                    self.notifyPlaybackStateChanged(event: .progressed)
                }
            }
        } else if autoplay {
            player.play()
        }

        updateNowPlayingInfo()
        notifyPlaybackStateChanged(event: reportStart ? (autoplay ? .started : .prepared) : .progressed)
    }

    func beginSonosPlayback(
        song: NavidromeSong,
        groupID: String,
        at seconds: Double,
        isPlaying: Bool,
        groupVolume: Double,
        reportStart: Bool
    ) {
        playbackGeneration += 1
        removeTimeObserver()
        removeSongFinishedObserver()
        removePlaybackFailureObserver()
        removePlaybackStalledObserver()
        removeStallCheckTimer()
        player.pause()
        player.replaceCurrentItem(with: nil)
        isHandoffInProgress = false
        route = .sonos(groupID)
        currentSong = song
        currentTime = normalizedPlaybackTime(seconds, duration: Double(song.duration ?? 0))
        duration = Double(song.duration ?? 0)
        self.isPlaying = isPlaying
        volume = min(max(groupVolume, 0), 1)
        hasFinishedCurrentSong = false
        statusMessage = isPlaying ? "Playing on Sonos" : "Paused on Sonos"
        updateNowPlayingInfo()
        notifyPlaybackStateChanged(event: reportStart ? .started : .progressed)
    }

    func selectSonosRoute(groupID: String, groupVolume: Double) {
        guard currentSong == nil else { return }
        route = .sonos(groupID)
        volume = min(max(groupVolume, 0), 1)
        statusMessage = "Sonos selected"
    }

    func pauseForSonosHandoff() {
        guard route == .local else { return }
        isHandoffInProgress = true
        player.pause()
    }

    func resumeAfterFailedSonosHandoff() {
        isHandoffInProgress = false
        guard route == .local, isPlaying else { return }
        player.play()
    }

    func updateSonosPlayback(
        song: NavidromeSong,
        at seconds: Double,
        duration: Double,
        isPlaying: Bool,
        event: AudioPlaybackEvent.Trigger = .progressed
    ) {
        guard route != .local else { return }
        currentSong = song
        currentTime = normalizedPlaybackTime(seconds, duration: duration)
        self.duration = duration > 0 ? duration : Double(song.duration ?? 0)
        self.isPlaying = isPlaying
        statusMessage = isPlaying ? "Playing on Sonos" : "Paused on Sonos"
        updateNowPlayingInfo()
        notifyPlaybackStateChanged(event: event)
    }

    func endSonosTrack(finished: Bool) {
        guard route != .local, currentSong != nil else { return }
        if finished { currentTime = duration }
        isPlaying = false
        updateNowPlayingInfo()
        notifyPlaybackStateChanged(event: finished ? .finished : .stopped)
    }

    func leaveSonosRoute(song: NavidromeSong?, url: URL?, at seconds: Double, autoplay: Bool) {
        route = .local
        volume = localVolume
        player.volume = Float(localVolume)
        if let song, let url {
            play(song: song, url: url, startingAt: seconds, autoplay: autoplay, reportStart: false)
        } else {
            clearPlayback()
        }
    }

    func setSonosVolume(_ nextVolume: Double) {
        guard route != .local else { return }
        volume = min(max(nextVolume, 0), 1)
    }

    func restore(song: NavidromeSong, at seconds: Double) {
        route = .local
        let targetTime = normalizedPlaybackTime(seconds, duration: Double(song.duration ?? 0))
        currentSong = song
        isPlaying = false
        hasFinishedCurrentSong = false
        pendingSeekTarget = nil
        currentTime = targetTime
        duration = Double(song.duration ?? 0)
        resetStallTracking(at: targetTime)
        statusMessage = "Ready to resume"
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
        if route != .local {
            guard currentSong != nil else { return }
            onSonosCommand?(.play)
            return
        }
        guard currentSong != nil, player.currentItem != nil else { return }

        AppLog.playback.debug("Resuming current song")
        resetStallTracking(at: currentTime)
        startStallCheckTimer()
        isPlaying = true
        player.play()
        statusMessage = "Playing through the selected audio route."
        updateNowPlayingInfo()
        notifyPlaybackStateChanged(event: .resumed)
    }

    func pauseCurrentSong() {
        if route != .local {
            guard currentSong != nil else { return }
            onSonosCommand?(.pause)
            return
        }
        guard currentSong != nil else { return }

        AppLog.playback.debug("Pausing current song at \(self.currentTime, privacy: .public) seconds")
        player.pause()
        removeStallCheckTimer()
        isPlaying = false
        statusMessage = "Paused"
        updateNowPlayingInfo()
        notifyPlaybackStateChanged(event: .paused)
    }

    func stop() {
        if route != .local {
            onSonosCommand?(.stop)
            return
        }
        clearPlayback()
    }

    func clearPlayback() {
        AppLog.playback.info("Stopping playback")
        playbackGeneration += 1
        removeTimeObserver()
        removeSongFinishedObserver()
        removePlaybackFailureObserver()
        removePlaybackStalledObserver()
        removeStallCheckTimer()
        player.pause()
        isPlaying = false
        if let event = playbackEvent(trigger: .stopped) {
            onPlaybackEvent?(event)
        }
        player.replaceCurrentItem(with: nil)
        pendingSeekTarget = nil
        currentSong = nil
        hasFinishedCurrentSong = false
        currentTime = 0
        duration = 0
        statusMessage = "Nothing playing"
        updateNowPlayingInfo()
        notifyPlaybackStateChanged()
    }

    func seek(to seconds: Double) {
        guard currentSong != nil else { return }
        let clampedSeconds = min(max(seconds, 0), max(duration, 0))
        if route != .local {
            onSonosCommand?(.seek(clampedSeconds))
            return
        }
        AppLog.playback.debug("Seeking to \(clampedSeconds, privacy: .public) seconds")
        currentTime = clampedSeconds
        lastObservedPlaybackTime = clampedSeconds
        lastPlaybackProgressAt = Date()
        didAttemptStallRecovery = false
        pendingSeekTarget = nil
        player.seek(to: CMTime(seconds: clampedSeconds, preferredTimescale: 600))
        updateNowPlayingInfo()
        notifyPlaybackStateChanged(event: .seeked)
    }

    func setVolume(_ nextVolume: Double) {
        let clampedVolume = min(max(nextVolume, 0), 1)
        volume = clampedVolume
        if route != .local {
            onSonosCommand?(.volume(clampedVolume))
            return
        }
        localVolume = clampedVolume
        player.volume = Float(clampedVolume)
        onVolumeChanged?(clampedVolume)
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
        guard route == .local, generation == playbackGeneration, currentSong != nil else { return }

        if let pendingSeekTarget {
            guard seconds.isFinite, abs(seconds - pendingSeekTarget) <= 1 else { return }
            self.pendingSeekTarget = nil
        }

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
            return
        }

        updateNowPlayingInfo()
        notifyPlaybackStateChanged(event: .progressed)
    }

    private func checkForPlaybackStall() {
        guard route == .local, isPlaying, currentSong != nil, !hasFinishedCurrentSong else { return }
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
            skipCurrentSongAfterStall()
        } else if stalledFor >= 8, !didAttemptStallRecovery {
            AppLog.playback.warning("Playback stalled for 8 seconds; attempting recovery")
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

    private func observePlaybackFailure(for item: AVPlayerItem, generation: Int) {
        removePlaybackFailureObserver()
        songFailedObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemFailedToPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self, weak item] notification in
            let error = notification.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error
            Task { @MainActor [weak self, weak item] in
                guard let self, self.isCurrentPlayback(item, generation: generation) else { return }
                self.failCurrentSong(error: error ?? item?.error)
            }
        }

        itemStatusObservation = item.observe(\.status, options: [.new]) { [weak self, weak item] observedItem, _ in
            guard observedItem.status == .failed else { return }
            Task { @MainActor [weak self, weak item] in
                guard let self, self.isCurrentPlayback(item, generation: generation) else { return }
                self.failCurrentSong(error: item?.error)
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
        guard route == .local, !isHandoffInProgress, currentSong != nil, !hasFinishedCurrentSong else { return }

        switch player.timeControlStatus {
        case .paused:
            guard isPlaying else { return }
            removeStallCheckTimer()
            isPlaying = false
            statusMessage = "Paused"
            updateNowPlayingInfo()
            notifyPlaybackStateChanged(event: .paused)
        case .waitingToPlayAtSpecifiedRate, .playing:
            guard !isPlaying else { return }
            resetStallTracking(at: currentTime)
            startStallCheckTimer()
            isPlaying = true
            statusMessage = "Playing through the selected audio route."
            updateNowPlayingInfo()
            notifyPlaybackStateChanged(event: .resumed)
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
        guard route == .local, isPlaying, currentSong != nil, !hasFinishedCurrentSong else { return }
        AppLog.playback.warning("AVPlayer reported a playback stall; attempting recovery")
        didAttemptStallRecovery = true
        lastPlaybackProgressAt = Date()
        statusMessage = "Recovering playback..."
        player.play()
        updateNowPlayingInfo()
    }

    private func finishCurrentSong() {
        guard route == .local, !hasFinishedCurrentSong else { return }
        AppLog.playback.info("Playback finished")
        hasFinishedCurrentSong = true
        removeStallCheckTimer()
        currentTime = duration
        isPlaying = false
        statusMessage = "Finished"
        updateNowPlayingInfo()
        notifyPlaybackStateChanged(event: .finished)
        onSongFinished?()
    }

    func skipCurrentSongAfterStall() {
        guard route == .local, !hasFinishedCurrentSong, currentSong != nil else { return }
        AppLog.playback.warning("Playback stalled for 18 seconds; advancing to the next track")
        hasFinishedCurrentSong = true
        removeStallCheckTimer()
        player.pause()
        isPlaying = false
        statusMessage = "Skipping stalled track"
        updateNowPlayingInfo()
        notifyPlaybackStateChanged(event: .failed)
        onSongFinished?()
    }

    private func failCurrentSong(error: Error?) {
        guard route == .local, !hasFinishedCurrentSong, let failedSong = currentSong else { return }
        if let error {
            let nsError = error as NSError
            AppLog.playback.error(
                "Playback failed (domain: \(nsError.domain, privacy: .public), code: \(nsError.code, privacy: .public))"
            )
        } else {
            AppLog.playback.error("Playback failed with no error details")
        }
        hasFinishedCurrentSong = true
        removeStallCheckTimer()
        isPlaying = false
        statusMessage = "Playback failed: \(error?.localizedDescription ?? "Unknown error")"
        updateNowPlayingInfo()
        notifyPlaybackStateChanged(event: .failed)
        onSongFailed?(failedSong)
    }

    private func isCurrentPlayback(_ item: AVPlayerItem?, generation: Int) -> Bool {
        guard let item else { return false }
        return playbackGeneration == generation && player.currentItem === item
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

    private func normalizedPlaybackTime(_ seconds: Double, duration: Double) -> Double {
        let nonnegativeSeconds = seconds.isFinite ? max(seconds, 0) : 0
        guard duration.isFinite, duration > 0 else { return nonnegativeSeconds }
        return min(nonnegativeSeconds, duration)
    }

    private func notifyPlaybackStateChanged(event trigger: AudioPlaybackEvent.Trigger? = nil) {
        onPlaybackStateChanged?()
        guard let trigger, let event = playbackEvent(trigger: trigger) else { return }
        onPlaybackEvent?(event)
    }

    private func playbackEvent(trigger: AudioPlaybackEvent.Trigger) -> AudioPlaybackEvent? {
        guard let currentSong else { return nil }
        let normalizedPosition = currentTime.isFinite ? max(currentTime, 0) : 0
        let normalizedDuration = duration.isFinite ? max(duration, 0) : 0
        return AudioPlaybackEvent(
            snapshot: AudioPlaybackSnapshot(
                song: currentSong,
                position: normalizedPosition,
                duration: normalizedDuration,
                isPlaying: isPlaying
            ),
            trigger: trigger,
            occurredAt: Date()
        )
    }
}
