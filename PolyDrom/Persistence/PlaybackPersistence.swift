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

/// Orders playback state writes and holds back the ones that only move the
/// playback position, so a newer state is never overwritten by an older one.
private final class PlaybackStateWriteQueue: @unchecked Sendable {
    private let queue = DispatchQueue(label: "uk.zikasak.PolyDrom.playback-persistence", qos: .utility)
    private let lock = NSLock()
    private var lastState: PersistedPlaybackState?
    private var pendingProgress: PersistedPlaybackState?
    private var isProgressWriteScheduled = false

    /// Runs `write` after any write already in progress, replacing a progress
    /// update that is still waiting.
    func writeNow(_ state: PersistedPlaybackState?, _ write: () -> Void) {
        lock.withLock {
            lastState = state
            pendingProgress = nil
        }
        queue.sync(execute: write)
    }

    /// Writes `state` in the background once `delay` has passed, coalescing
    /// the updates that arrive in the meantime. Returns false when `state`
    /// changes more than the position since the last write, leaving it to the
    /// caller to write it immediately.
    func writeProgress(
        _ state: PersistedPlaybackState,
        after delay: TimeInterval,
        _ write: @escaping @Sendable (PersistedPlaybackState) -> Void
    ) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        guard let lastState, state.differsOnlyInPosition(from: lastState) else { return false }
        self.lastState = state
        pendingProgress = state
        guard !isProgressWriteScheduled else { return true }

        isProgressWriteScheduled = true
        queue.asyncAfter(deadline: .now() + delay) { [self] in
            let pendingState = lock.withLock {
                self.isProgressWriteScheduled = false
                defer { self.pendingProgress = nil }
                return self.pendingProgress
            }
            if let pendingState {
                write(pendingState)
            }
        }
        return true
    }
}

private extension PersistedPlaybackState {
    func differsOnlyInPosition(from other: PersistedPlaybackState) -> Bool {
        serverKey == other.serverKey
            && currentQueueEntryID == other.currentQueueEntryID
            && isPlaying == other.isPlaying
            && currentSong == other.currentSong
            && queue == other.queue
    }
}

// `UserDefaults` is thread-safe but is not declared `Sendable`.
struct PlaybackPersistence: @unchecked Sendable {
    static let userDefaultsKey = "persistedPlaybackState"
    private static let selectedVolumeKey = "selectedVolume"

    private let userDefaults: UserDefaults
    private let fileURL: URL?
    private static let progressSaveInterval: TimeInterval = 5
    private let writes = PlaybackStateWriteQueue()

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
        writes.writeNow(state) { encodeAndWrite(state) }
    }

    /// Saves a state that usually differs from the previous one only by playback
    /// position. Those updates arrive twice a second while a song plays, and
    /// encoding a long queue for each of them on the main thread stalls the UI,
    /// so they are written in the background at most once per interval.
    func saveProgress(_ state: PersistedPlaybackState) {
        let isDeferred = writes.writeProgress(state, after: Self.progressSaveInterval) { [self] pendingState in
            encodeAndWrite(pendingState)
        }
        if !isDeferred {
            save(state)
        }
    }

    func clear() {
        writes.writeNow(nil) {
            removeFile()
            userDefaults.removeObject(forKey: Self.userDefaultsKey)
        }
    }

    func loadSelectedVolume() -> Double? {
        (userDefaults.object(forKey: Self.selectedVolumeKey) as? NSNumber)?.doubleValue
    }

    func saveSelectedVolume(_ volume: Double) {
        userDefaults.set(volume, forKey: Self.selectedVolumeKey)
    }

    private func encodeAndWrite(_ state: PersistedPlaybackState) {
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
        AppDirectories.applicationSupport?.appendingPathComponent("playback-state.json")
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
