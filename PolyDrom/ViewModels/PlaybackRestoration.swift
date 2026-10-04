import Foundation
import OSLog

extension AppCoordinator {
    func configureAudioPlayer() {
        if let selectedVolume = playbackPersistence.loadSelectedVolume() {
            audioPlayer.setVolume(selectedVolume)
        }
        audioPlayer.onSongFinished = { [weak self] in
            self?.playNextTrackAfterCurrentSongFinished()
        }
        audioPlayer.onSongFailed = { [weak self] song in
            self?.handlePlaybackFailure(for: song)
        }
        audioPlayer.onPlaybackStateChanged = { [weak self] in
            self?.persistPlaybackState(deferringProgress: true)
        }
        audioPlayer.onPlaybackEvent = { [weak self] event in
            self?.playbackReporter.handle(event)
        }
        audioPlayer.onVolumeChanged = { [weak self] volume in
            self?.playbackPersistence.saveSelectedVolume(volume)
        }
        audioPlayer.onSonosCommand = { [weak self] command in
            self?.handleSonosCommand(command)
        }
        audioPlayer.configureRemotePlaybackCommands(
            onPreviousTrack: { [weak self] in
                self?.playPreviousTrack()
            },
            onNextTrack: { [weak self] in
                self?.playNextTrack()
            }
        )
    }

    func restorePersistedPlaybackState() {
        guard let state = playbackPersistence.load() else { return }

        var queue = state.queue
        var currentQueueEntryID = state.currentQueueEntryID
        var currentSong = state.currentSong

        if let currentQueueEntryID,
           let index = queue.firstIndex(where: { $0.id == currentQueueEntryID }) {
            if let currentSong {
                queue[index].song = currentSong
            } else {
                currentSong = queue[index].song
            }
        } else if let currentSong,
                  let index = queue.firstIndex(where: { $0.song.id == currentSong.id }) {
            currentQueueEntryID = queue[index].id
            queue[index].song = currentSong
        } else if let currentSong {
            let entryID = currentQueueEntryID ?? UUID()
            queue.append(PlaybackQueueEntry(id: entryID, song: currentSong))
            currentQueueEntryID = entryID
        }

        guard !queue.isEmpty || currentSong != nil else {
            playbackPersistence.clear()
            return
        }

        let normalizedState = PersistedPlaybackState(
            serverKey: state.serverKey,
            queue: queue,
            currentQueueEntryID: currentQueueEntryID,
            currentSong: currentSong,
            position: max(state.position.isFinite ? state.position : 0, 0),
            isPlaying: false
        )
        playbackQueue = queue
        currentPlaybackQueueEntryID = currentQueueEntryID
        pendingPlaybackRestore = normalizedState

        if let currentSong {
            audioPlayer.restore(song: currentSong, at: normalizedState.position)
        }
        updateNowPlayingQueueState()
    }

    func restorePersistedPlaybackIfNeeded(for session: SessionIdentity) async {
        guard !didRestorePlayback,
              let state = pendingPlaybackRestore,
              let song = state.currentSong,
              let client,
              state.serverKey == nil || state.serverKey == session.serverKey,
              isCurrentSession(session) else {
            return
        }

        do {
            let streams = try client.playbackStreamURLs(for: song)
            await warmCachedSongCovers([song])
            guard isCurrentSession(session) else { return }

            pendingPlaybackRestore = nil
            didRestorePlayback = true
            audioPlayer.play(
                song: song,
                url: streams.url,
                fallbackURL: streams.fallbackURL,
                startingAt: state.position,
                autoplay: false
            )
            updateNowPlayingQueueState()
            updateNowPlayingArtwork(for: song)
            statusMessage = "Restored \(song.title)"
        } catch {
            AppLog.playback.error(
                "Could not restore playback: \(error.localizedDescription, privacy: .private)"
            )
        }
    }

    func handlePlaybackFailure(for song: NavidromeSong) {
        guard let failedEntryID = currentPlaybackQueueEntryID,
              let client,
              let session = currentSession else {
            return
        }

        Task { @MainActor [weak self] in
            do {
                let availableSong = try await client.songMetadata(for: song.id)
                guard let self,
                      self.isCurrentSession(session),
                      self.currentPlaybackQueueEntryID == failedEntryID,
                      self.audioPlayer.currentSong?.id == song.id,
                      availableSong == nil else {
                    return
                }

                self.removeUnavailablePlaybackEntry(failedEntryID, song: song)
            } catch {
                AppLog.playback.error(
                    "Could not verify failed playback: \(error.localizedDescription, privacy: .private)"
                )
            }
        }
    }

    private func removeUnavailablePlaybackEntry(_ entryID: UUID, song: NavidromeSong) {
        guard currentPlaybackQueueEntryID == entryID,
              audioPlayer.currentSong?.id == song.id,
              let index = playbackQueue.firstIndex(where: { $0.id == entryID }) else {
            return
        }

        let nextEntry = playbackQueue.indices.contains(index + 1) ? playbackQueue[index + 1] : nil
        playbackQueue.remove(at: index)
        currentPlaybackQueueEntryID = nil
        pendingPlaybackRestore = nil
        didRestorePlayback = true
        audioPlayer.stop()
        updateNowPlayingQueueState()
        persistPlaybackState()

        if let nextEntry {
            statusMessage = "Skipped unavailable song."
            Task { @MainActor [weak self] in
                await self?.startPlayback(of: nextEntry)
            }
        } else {
            statusMessage = "Removed unavailable song from queue."
        }
    }

    /// `deferringProgress` lets a save that only moves the playback position be
    /// written later in the background instead of right away.
    func persistPlaybackState(deferringProgress: Bool = false) {
        guard !playbackQueue.isEmpty || audioPlayer.currentSong != nil else {
            playbackPersistence.clear()
            return
        }

        let savedServerKey = activeServer?.serverKey ?? pendingPlaybackRestore?.serverKey
        let currentSong = audioPlayer.currentSong
        let isWaitingForRestore = !didRestorePlayback
            && pendingPlaybackRestore != nil
            && !audioPlayer.hasPlayableItem
        let isPlaying = isWaitingForRestore
            ? (pendingPlaybackRestore?.isPlaying ?? audioPlayer.isPlaying)
            : audioPlayer.isPlaying
        let position = audioPlayer.currentTime.isFinite ? max(audioPlayer.currentTime, 0) : 0
        let state = PersistedPlaybackState(
            serverKey: savedServerKey,
            queue: playbackQueue,
            currentQueueEntryID: currentPlaybackQueueEntryID,
            currentSong: currentSong,
            position: position,
            isPlaying: isPlaying
        )
        if deferringProgress {
            playbackPersistence.saveProgress(state)
        } else {
            playbackPersistence.save(state)
        }

        if !didRestorePlayback, pendingPlaybackRestore != nil {
            pendingPlaybackRestore = state
        }
    }

    func clearPlaybackState() {
        resetSonosForServerChange()
        playbackQueue = []
        currentPlaybackQueueEntryID = nil
        pendingPlaybackRestore = nil
        didRestorePlayback = false
        audioPlayer.stop()
        playbackPersistence.clear()
        updateNowPlayingQueueState()
    }
}
