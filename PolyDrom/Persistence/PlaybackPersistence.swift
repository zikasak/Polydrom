//
//  PlaybackPersistence.swift
//  PolyDrom
//

import Foundation
import OSLog

struct PersistedPlaybackState: Codable, Equatable, Sendable {
    let serverKey: String?
    let queue: [PlaybackQueueEntry]
    let currentQueueEntryID: UUID?
    let currentSong: NavidromeSong?
    let position: Double
    let isPlaying: Bool
}

struct PlaybackPersistence {
    static let userDefaultsKey = "persistedPlaybackState"
    private static let selectedVolumeKey = "selectedVolume"

    private let userDefaults: UserDefaults
    private let fileURL: URL?

    init(userDefaults: UserDefaults, fileURL: URL? = nil) {
        self.userDefaults = userDefaults
        self.fileURL = fileURL ?? Self.defaultFileURL()
    }

    func load() -> PersistedPlaybackState? {
        if let fileURL, FileManager.default.fileExists(atPath: fileURL.path) {
            do {
                let state = try decode(Data(contentsOf: fileURL))
                // Also clean up a legacy value if a previous migration was interrupted.
                userDefaults.removeObject(forKey: Self.userDefaultsKey)
                return state
            } catch {
                AppLog.persistence.error(
                    "Could not read persisted playback file: \(error.localizedDescription, privacy: .private)"
                )
                removeFile()
            }
        }

        guard let data = userDefaults.data(forKey: Self.userDefaultsKey) else { return nil }

        do {
            let state = try decode(data)
            do {
                try write(data)
                userDefaults.removeObject(forKey: Self.userDefaultsKey)
            } catch {
                AppLog.persistence.error(
                    "Could not migrate persisted playback state to disk: \(error.localizedDescription, privacy: .private)"
                )
            }
            return state
        } catch {
            AppLog.persistence.error(
                "Could not decode persisted playback state: \(error.localizedDescription, privacy: .private)"
            )
            clear()
            return nil
        }
    }

    func save(_ state: PersistedPlaybackState) {
        do {
            try write(JSONEncoder().encode(state))
            // Remove the pre-file-storage value after the new copy is safely on disk.
            userDefaults.removeObject(forKey: Self.userDefaultsKey)
        } catch {
            AppLog.persistence.error(
                "Could not save persisted playback state: \(error.localizedDescription, privacy: .private)"
            )
        }
    }

    func clear() {
        removeFile()
        userDefaults.removeObject(forKey: Self.userDefaultsKey)
    }

    func loadSelectedVolume() -> Double? {
        (userDefaults.object(forKey: Self.selectedVolumeKey) as? NSNumber)?.doubleValue
    }

    func saveSelectedVolume(_ volume: Double) {
        userDefaults.set(volume, forKey: Self.selectedVolumeKey)
    }

    private func decode(_ data: Data) throws -> PersistedPlaybackState {
        try JSONDecoder().decode(PersistedPlaybackState.self, from: data)
    }

    private func write(_ data: Data) throws {
        guard let fileURL else { throw PlaybackPersistenceError.fileURLUnavailable }
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: fileURL, options: .atomic)
    }

    private func removeFile() {
        guard let fileURL, FileManager.default.fileExists(atPath: fileURL.path) else { return }

        do {
            try FileManager.default.removeItem(at: fileURL)
        } catch {
            AppLog.persistence.error(
                "Could not remove persisted playback file: \(error.localizedDescription, privacy: .private)"
            )
        }
    }

    private static func defaultFileURL() -> URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("PolyDrom", isDirectory: true)
            .appendingPathComponent("playback-state.json")
    }
}

private enum PlaybackPersistenceError: LocalizedError {
    case fileURLUnavailable

    var errorDescription: String? {
        switch self {
        case .fileURLUnavailable:
            "The playback persistence file location is unavailable."
        }
    }
}

extension AppCoordinator {
    func isCurrentSession(_ generation: UInt, serverKey: String) -> Bool {
        sessionGeneration == generation && self.serverKey == serverKey
    }

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
            self?.persistPlaybackState()
        }
        audioPlayer.onPlaybackEvent = { [weak self] event in
            self?.playbackReporter.handle(event)
        }
        audioPlayer.onVolumeChanged = { [weak self] volume in
            self?.playbackPersistence.saveSelectedVolume(volume)
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

    func restorePersistedPlaybackIfNeeded(for generation: UInt) async {
        guard !didRestorePlayback,
              let state = pendingPlaybackRestore,
              let song = state.currentSong,
              let client,
              let activeServerKey = serverKey,
              state.serverKey == nil || state.serverKey == activeServerKey,
              isCurrentSession(generation, serverKey: activeServerKey) else {
            return
        }

        do {
            let url = try client.streamURL(for: song)
            await warmCachedSongCovers([song])
            guard isCurrentSession(generation, serverKey: activeServerKey) else { return }

            pendingPlaybackRestore = nil
            didRestorePlayback = true
            audioPlayer.play(
                song: song,
                url: url,
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
              let activeServerKey = serverKey else {
            return
        }

        let generation = sessionGeneration
        Task { @MainActor [weak self] in
            do {
                let availableSong = try await client.songMetadata(for: song.id)
                guard let self,
                      self.isCurrentSession(generation, serverKey: activeServerKey),
                      self.currentPlaybackQueueEntryID == failedEntryID,
                      self.audioPlayer.currentSong?.id == song.id,
                      availableSong == nil else {
                    return
                }

                self.removeUnavailablePlaybackEntry(
                    failedEntryID,
                    song: song
                )
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
                await self?.play(nextEntry, shouldHydrateSong: false)
            }
        } else {
            statusMessage = "Removed unavailable song from queue."
        }
    }

    func persistPlaybackState() {
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
        playbackPersistence.save(state)

        if !didRestorePlayback, pendingPlaybackRestore != nil {
            pendingPlaybackRestore = state
        }
    }

    func clearPlaybackState() {
        playbackQueue = []
        currentPlaybackQueueEntryID = nil
        pendingPlaybackRestore = nil
        didRestorePlayback = false
        audioPlayer.stop()
        playbackPersistence.clear()
        updateNowPlayingQueueState()
    }
}
