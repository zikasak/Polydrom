import Foundation
import OSLog

struct SonosActiveSession {
    let group: SonosGroup
    var syncedCount: Int
    var entryIDs: [UUID]
    var ownsQueue: Bool
    var expectedQueueVersion: String?
    var lastTrack: Int
    var startedAt: Date
}

@MainActor
extension AppCoordinator {
    func refreshSonosGroups() async {
        guard !sonosIsDiscovering else { return }
        sonosIsDiscovering = true
        sonosMessage = nil
        defer { sonosIsDiscovering = false }
        do {
            sonosGroups = try await sonosUPnP.discoverGroups()
            if sonosGroups.isEmpty { sonosMessage = SonosError.discoveryUnavailable.localizedDescription }
        } catch {
            sonosGroups = []
            sonosMessage = error.localizedDescription
        }
    }

    func selectSonosGroup(_ group: SonosGroup) {
        sonosGeneration += 1
        let generation = sonosGeneration
        let previous = sonosActivationTask
        let cleanup = sonosCleanupTask
        sonosActivationTask?.cancel()
        sonosActivationTask = Task { [weak self] in
            await previous?.value
            await cleanup?.value
            await self?.activateSonosGroup(group, generation: generation)
        }
    }

    private func activateSonosGroup(_ group: SonosGroup, generation: Int) async {
        guard isOnline, let client, let serverKey else {
            sonosMessage = "Connect to Navidrome before selecting Sonos."
            return
        }
        let serverGeneration = sessionGeneration
        sonosSyncTask?.cancel()
        await sonosSyncTask?.value
        sonosQueueWriteTask?.cancel()
        await sonosQueueWriteTask?.value
        sonosPollTask?.cancel()
        await sonosPollTask?.value
        if let old = sonosSession { await stopAndClearOwnedQueue(old) }
        guard generation == sonosGeneration, isCurrentSession(serverGeneration, serverKey: serverKey) else { return }

        do {
            let volume = try await sonosUPnP.groupVolume(on: group.coordinator)
            guard generation == sonosGeneration else { return }
            var queue = playbackQueue
            if let song = audioPlayer.currentSong {
                let index: Int
                if let entryID = currentPlaybackQueueEntryID,
                   let existing = queue.firstIndex(where: { $0.id == entryID }) {
                    index = existing
                    queue[index].song = song
                } else {
                    index = queue.count
                    queue.append(PlaybackQueueEntry(song: song))
                }
                let seconds = audioPlayer.currentTime
                let shouldPlay = audioPlayer.isPlaying
                try await loadSonosQueue(
                    queue,
                    currentIndex: index,
                    song: song,
                    seconds: seconds,
                    autoplay: shouldPlay,
                    group: group,
                    groupVolume: volume,
                    client: client,
                    generation: generation,
                    reportStart: false
                )
            } else {
                sonosSession = SonosActiveSession(
                    group: group, syncedCount: 0, entryIDs: [], ownsQueue: false,
                    expectedQueueVersion: nil, lastTrack: 0, startedAt: Date()
                )
                sonosQueueSynced = 0
                sonosQueueTotal = 0
                audioPlayer.selectSonosRoute(groupID: group.id, groupVolume: Double(volume) / 100)
            }
            sonosMessage = nil
        } catch {
            guard generation == sonosGeneration else { return }
            audioPlayer.resumeAfterFailedSonosHandoff()
            sonosMessage = error.localizedDescription
            statusMessage = error.localizedDescription
            if audioPlayer.route != .local {
                await detachSonos(with: error.localizedDescription)
            }
        }
    }

    func playOnSonos(
        _ entry: PlaybackQueueEntry,
        song: NavidromeSong,
        replacingQueueWith replacement: [PlaybackQueueEntry]?,
        client: NavidromeClient
    ) async throws {
        guard let active = sonosSession else { throw SonosError.invalidResponse }
        if let replacement {
            sonosGeneration += 1
            let generation = sonosGeneration
            sonosSyncTask?.cancel()
            await sonosSyncTask?.value
            sonosQueueWriteTask?.cancel()
            await sonosQueueWriteTask?.value
            guard generation == sonosGeneration else { return }
            var queue = replacement
            guard let index = queue.firstIndex(where: { $0.id == entry.id }) else { throw SonosError.invalidResponse }
            queue[index].song = song
            try await loadSonosQueue(
                queue,
                currentIndex: index,
                song: song,
                seconds: 0,
                autoplay: true,
                group: active.group,
                groupVolume: Int((audioPlayer.volume * 100).rounded()),
                client: client,
                generation: generation,
                reportStart: true
            )
            playbackQueue = queue
        } else if !active.ownsQueue {
            guard let index = playbackQueue.firstIndex(where: { $0.id == entry.id }) else {
                throw SonosError.invalidResponse
            }
            var queue = playbackQueue
            queue[index].song = song
            sonosGeneration += 1
            try await loadSonosQueue(
                queue, currentIndex: index, song: song, seconds: 0, autoplay: true,
                group: active.group, groupVolume: Int((audioPlayer.volume * 100).rounded()),
                client: client, generation: sonosGeneration, reportStart: true
            )
        } else {
            guard let index = playbackQueue.firstIndex(where: { $0.id == entry.id }) else {
                throw SonosError.invalidResponse
            }
            if index >= active.syncedCount, let sync = sonosSyncTask { await sync.value }
            guard let current = sonosSession, current.group.id == active.group.id,
                  index < current.syncedCount else {
                throw SonosError.invalidResponse
            }
            try await sonosUPnP.seekTrack(index, on: current.group.coordinator)
            try await sonosUPnP.transport("Play", on: current.group.coordinator)
            if currentPlaybackQueueEntryID != entry.id { audioPlayer.endSonosTrack(finished: false) }
            currentPlaybackQueueEntryID = entry.id
            playbackQueue[index].song = song
            audioPlayer.updateSonosPlayback(
                song: song, at: 0, duration: Double(song.duration ?? 0),
                isPlaying: true, event: .started
            )
            sonosSession?.lastTrack = index + 1
        }
        currentPlaybackQueueEntryID = entry.id
        updateNowPlayingQueueState()
    }

    private func loadSonosQueue(
        _ queue: [PlaybackQueueEntry],
        currentIndex: Int,
        song: NavidromeSong,
        seconds: Double,
        autoplay: Bool,
        group: SonosGroup,
        groupVolume: Int,
        client: NavidromeClient,
        generation: Int,
        reportStart: Bool
    ) async throws {
        guard !queue.isEmpty else { throw SonosError.invalidResponse }
        let device = group.coordinator
        let stream = try client.streamURL(for: song)
        try Self.checkSpeakerReachability(of: stream)
        sonosQueueSynced = 0
        sonosQueueTotal = queue.count
        sonosSyncTask = nil
        sonosMessage = "Copying queue to Sonos…"
        _ = try? await sonosUPnP.transport("Stop", on: device)
        try await sonosUPnP.clearQueue(device)

        let initialCount = min(queue.count, currentIndex + 2)
        var loaded = 0
        do {
            while loaded < initialCount {
                guard generation == sonosGeneration else { throw CancellationError() }
                let end = min(loaded + 16, initialCount)
                let items = try queue[loaded..<end].map { try Self.queueItem($0, client: client) }
                let length = try await sonosUPnP.addQueueItems(items, to: device)
                if let length, length != end { throw SonosError.queueChanged }
                loaded = end
                sonosQueueSynced = loaded
            }
            try await sonosUPnP.useQueue(device)
            try await sonosUPnP.seekTrack(currentIndex, on: device)
            if seconds >= 1 { try await sonosUPnP.seekTime(seconds, on: device) }
            guard generation == sonosGeneration else { throw CancellationError() }
            if audioPlayer.route == .local { audioPlayer.pauseForSonosHandoff() }
            if autoplay { try await sonosUPnP.transport("Play", on: device) }
            guard generation == sonosGeneration else { throw CancellationError() }
        } catch {
            audioPlayer.resumeAfterFailedSonosHandoff()
            _ = try? await sonosUPnP.clearQueue(device)
            throw error
        }

        guard generation == sonosGeneration else { return }
        if reportStart, audioPlayer.route != .local, audioPlayer.currentSong != nil {
            audioPlayer.endSonosTrack(finished: false)
        }
        sonosSession = SonosActiveSession(
            group: group,
            syncedCount: loaded,
            entryIDs: queue.map(\.id),
            ownsQueue: true,
            expectedQueueVersion: nil,
            lastTrack: currentIndex + 1,
            startedAt: Date()
        )
        playbackQueue = queue
        currentPlaybackQueueEntryID = queue[currentIndex].id
        audioPlayer.beginSonosPlayback(
            song: song, groupID: group.id, at: seconds, isPlaying: autoplay,
            groupVolume: Double(groupVolume) / 100, reportStart: reportStart
        )
        sonosMessage = loaded < queue.count ? "Copying queue: \(loaded) of \(queue.count)" : nil
        startSonosPolling(generation: generation)
        if loaded < queue.count {
            startSonosRemainderSync(queue: queue, client: client, generation: generation)
        } else {
            sonosSession?.expectedQueueVersion = try? await sonosUPnP.queueVersion(on: device)
        }
    }

    private func startSonosRemainderSync(
        queue: [PlaybackQueueEntry], client: NavidromeClient, generation: Int
    ) {
        sonosSyncTask = Task { [weak self] in
            guard let self else { return }
            do {
                while generation == sonosGeneration,
                      let session = sonosSession,
                      session.syncedCount < queue.count {
                    try Task.checkCancellation()
                    let start = session.syncedCount
                    let end = min(start + 16, queue.count)
                    let items = try queue[start..<end].map { try Self.queueItem($0, client: client) }
                    let length = try await sonosUPnP.addQueueItems(items, to: session.group.coordinator)
                    if let length, length != end { throw SonosError.queueChanged }
                    guard generation == sonosGeneration else { return }
                    sonosSession?.syncedCount = end
                    sonosQueueSynced = end
                    sonosMessage = end < queue.count ? "Copying queue: \(end) of \(queue.count)" : nil
                }
                guard generation == sonosGeneration, let session = sonosSession else { return }
                sonosSession?.expectedQueueVersion = try? await sonosUPnP.queueVersion(on: session.group.coordinator)
                sonosSyncTask = nil
            } catch is CancellationError {
                return
            } catch {
                guard generation == sonosGeneration else { return }
                await detachSonos(with: "Sonos queue copy failed: \(error.localizedDescription)")
            }
        }
    }

    private static func queueItem(_ entry: PlaybackQueueEntry, client: NavidromeClient) throws -> SonosQueueItem {
        let stream = try client.streamURL(for: entry.song)
        try checkSpeakerReachability(of: stream)
        let artworkID = entry.song.coverArt ?? entry.song.albumId
        let artwork = artworkID.flatMap { try? client.coverArtURL(id: $0, size: 512) }
        return SonosQueueItem(
            entryID: entry.id, song: entry.song, streamURL: stream, artworkURL: artwork
        )
    }

    private static func checkSpeakerReachability(of url: URL) throws {
        let host = url.host?.lowercased() ?? ""
        if host == "localhost" || host == "127.0.0.1" || host == "::1" || host.hasSuffix(".localhost") {
            throw SonosError.localServerAddress
        }
    }

    func insertIntoSonosQueue(_ songs: [NavidromeSong], afterCurrent: Bool) {
        guard !songs.isEmpty else { return }
        let generation = sonosGeneration
        let previous = sonosQueueWriteTask
        sonosQueueWriteTask = Task { [weak self] in
            await previous?.value
            await self?.performSonosInsertion(songs, afterCurrent: afterCurrent, generation: generation)
        }
    }

    private func performSonosInsertion(_ songs: [NavidromeSong], afterCurrent: Bool, generation: Int) async {
        if let sync = sonosSyncTask { await sync.value }
        guard generation == sonosGeneration, let current = sonosSession,
              current.ownsQueue, let client else { return }
        let insertionIndex: Int
        if afterCurrent, let entryID = currentPlaybackQueueEntryID,
           let index = playbackQueue.firstIndex(where: { $0.id == entryID }) {
            insertionIndex = index + 1
        } else {
            insertionIndex = playbackQueue.count
        }
        let additions = songs.map { PlaybackQueueEntry(song: $0) }
        sonosQueueMutationInFlight = true
        defer { sonosQueueMutationInFlight = false }
        do {
            let device = current.group.coordinator
            guard try await sonosUPnP.currentSource(on: device) == SonosUPnP.queueURI(for: device) else {
                throw SonosError.sourceChanged
            }
            if let expected = current.expectedQueueVersion {
                guard try await sonosUPnP.queueVersion(on: device) == expected else {
                    throw SonosError.queueChanged
                }
            }
            var offset = 0
            while offset < additions.count {
                try Task.checkCancellation()
                guard generation == sonosGeneration else { return }
                let end = min(offset + 16, additions.count)
                let items = try additions[offset..<end].map { try Self.queueItem($0, client: client) }
                let position = insertionIndex == playbackQueue.count ? 0 : insertionIndex + offset + 1
                let length = try await sonosUPnP.addQueueItems(items, to: device, at: position)
                guard generation == sonosGeneration else { return }
                if let length, length != playbackQueue.count + end { throw SonosError.queueChanged }
                offset = end
            }
            guard generation == sonosGeneration, sonosSession?.group.id == current.group.id else { return }
            playbackQueue.insert(contentsOf: additions, at: insertionIndex)
            sonosSession?.entryIDs.insert(contentsOf: additions.map(\.id), at: insertionIndex)
            sonosSession?.syncedCount += additions.count
            sonosQueueSynced = sonosSession?.syncedCount ?? 0
            sonosQueueTotal = playbackQueue.count
            sonosSession?.expectedQueueVersion = try? await sonosUPnP.queueVersion(on: current.group.coordinator)
            persistPlaybackState()
            updateNowPlayingQueueState()
            statusMessage = afterCurrent ? "Playing next" : "Added to queue"
        } catch {
            guard generation == sonosGeneration else { return }
            let message = "Could not update the Sonos queue: \(error.localizedDescription)"
            if let sonosError = error as? SonosError {
                switch sonosError {
                case .sourceChanged, .queueChanged:
                    await detachSonos(with: message)
                    return
                default:
                    break
                }
            }
            sonosGeneration += 1
            let cleanupGeneration = sonosGeneration
            sonosCleanupTask = Task {
                guard cleanupGeneration == sonosGeneration else { return }
                await leaveSonosOutput(clearPlayback: false)
                sonosMessage = message
                statusMessage = message
            }
        }
    }

    func navigateSonos(_ command: String) {
        guard let session = sonosSession else { return }
        let generation = sonosGeneration
        Task {
            do {
                try await sonosUPnP.transport(command, on: session.group.coordinator)
                guard generation == sonosGeneration else { return }
                await pollSonosOnce(generation: generation, tick: 0)
            } catch {
                if generation == sonosGeneration { sonosMessage = error.localizedDescription }
            }
        }
    }

    func handleSonosCommand(_ command: SonosPlaybackCommand) {
        guard let session = sonosSession else { return }
        if case .stop = command {
            sonosGeneration += 1
            let generation = sonosGeneration
            sonosCleanupTask = Task {
                guard generation == sonosGeneration else { return }
                await leaveSonosOutput(clearPlayback: true)
            }
            return
        }
        let generation = sonosGeneration
        Task {
            do {
                switch command {
                case .play:
                    try await sonosUPnP.transport("Play", on: session.group.coordinator)
                    guard generation == sonosGeneration else { return }
                    if let song = audioPlayer.currentSong {
                        audioPlayer.updateSonosPlayback(
                            song: song, at: audioPlayer.currentTime, duration: audioPlayer.duration,
                            isPlaying: true, event: .resumed
                        )
                    }
                case .pause:
                    try await sonosUPnP.transport("Pause", on: session.group.coordinator)
                    guard generation == sonosGeneration else { return }
                    if let song = audioPlayer.currentSong {
                        audioPlayer.updateSonosPlayback(
                            song: song, at: audioPlayer.currentTime, duration: audioPlayer.duration,
                            isPlaying: false, event: .paused
                        )
                    }
                case .stop:
                    break
                case .seek(let seconds):
                    try await sonosUPnP.seekTime(seconds, on: session.group.coordinator)
                    guard generation == sonosGeneration else { return }
                    if let song = audioPlayer.currentSong {
                        audioPlayer.updateSonosPlayback(
                            song: song, at: seconds, duration: audioPlayer.duration,
                            isPlaying: audioPlayer.isPlaying, event: .seeked
                        )
                    }
                case .volume(let volume):
                    try await sonosUPnP.setGroupVolume(Int((volume * 100).rounded()), on: session.group.coordinator)
                }
            } catch {
                if generation == sonosGeneration {
                    sonosMessage = error.localizedDescription
                    statusMessage = error.localizedDescription
                }
            }
        }
    }

    func switchToLocalOutput() {
        sonosGeneration += 1
        let generation = sonosGeneration
        let activation = sonosActivationTask
        sonosActivationTask?.cancel()
        sonosCleanupTask = Task {
            await activation?.value
            guard generation == sonosGeneration else { return }
            await leaveSonosOutput(clearPlayback: false)
        }
    }

    private func leaveSonosOutput(clearPlayback: Bool) async {
        guard let session = sonosSession else {
            audioPlayer.resumeAfterFailedSonosHandoff()
            sonosQueueSynced = 0
            sonosQueueTotal = 0
            return
        }
        let song = clearPlayback ? nil : audioPlayer.currentSong
        let seconds = audioPlayer.currentTime
        let autoplay = !clearPlayback && audioPlayer.isPlaying
        sonosGeneration += 1
        sonosPollTask?.cancel()
        sonosSyncTask?.cancel()
        sonosQueueWriteTask?.cancel()
        await sonosSyncTask?.value
        await sonosQueueWriteTask?.value
        await stopAndClearOwnedQueue(session)
        sonosSession = nil
        sonosQueueSynced = 0
        sonosQueueTotal = 0
        sonosMessage = nil
        let url: URL? = if let song, let client { try? client.streamURL(for: song) } else { nil }
        audioPlayer.leaveSonosRoute(song: song, url: url, at: seconds, autoplay: autoplay)
        if let song, url == nil { audioPlayer.restore(song: song, at: seconds) }
        updateNowPlayingQueueState()
        persistPlaybackState()
    }

    private func stopAndClearOwnedQueue(_ session: SonosActiveSession) async {
        guard session.ownsQueue else { return }
        let device = session.group.coordinator
        guard (try? await sonosUPnP.currentSource(on: device)) == SonosUPnP.queueURI(for: device) else { return }
        _ = try? await sonosUPnP.transport("Stop", on: device)
        _ = try? await sonosUPnP.clearQueue(device)
    }

    func resetSonosForServerChange() {
        sonosGeneration += 1
        sonosActivationTask?.cancel()
        guard let session = sonosSession else { return }
        sonosPollTask?.cancel()
        sonosSyncTask?.cancel()
        let sync = sonosSyncTask
        sonosQueueWriteTask?.cancel()
        let write = sonosQueueWriteTask
        sonosSession = nil
        sonosQueueSynced = 0
        sonosQueueTotal = 0
        audioPlayer.leaveSonosRoute(song: nil, url: nil, at: 0, autoplay: false)
        sonosCleanupTask = Task {
            await sync?.value
            await write?.value
            await stopAndClearOwnedQueue(session)
        }
    }

    func stopSonosForTermination() async {
        sonosGeneration += 1
        sonosActivationTask?.cancel()
        await sonosActivationTask?.value
        await sonosCleanupTask?.value
        guard let session = sonosSession else { return }
        sonosPollTask?.cancel()
        sonosSyncTask?.cancel()
        sonosQueueWriteTask?.cancel()
        await sonosSyncTask?.value
        await sonosQueueWriteTask?.value
        if let song = audioPlayer.currentSong {
            audioPlayer.updateSonosPlayback(
                song: song, at: audioPlayer.currentTime, duration: audioPlayer.duration,
                isPlaying: false, event: .paused
            )
        }
        persistPlaybackState()
        await stopAndClearOwnedQueue(session)
        sonosSession = nil
    }

    private func startSonosPolling(generation: Int) {
        sonosPollTask?.cancel()
        sonosPollTask = Task { [weak self] in
            var tick = 0
            while let self, !Task.isCancelled, generation == sonosGeneration {
                await pollSonosOnce(generation: generation, tick: tick)
                tick += 1
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    func pollSonosOnce(generation: Int, tick: Int) async {
        guard generation == sonosGeneration, let session = sonosSession, session.ownsQueue else { return }
        do {
            let position = try await sonosUPnP.position(on: session.group.coordinator)
            guard generation == sonosGeneration, let current = sonosSession else { return }
            let expectedSource = SonosUPnP.queueURI(for: current.group.coordinator)
            if !position.sourceURI.isEmpty, position.sourceURI != expectedSource {
                await detachSonos(with: SonosError.sourceChanged.localizedDescription)
                return
            }
            if position.transportState == "STOPPED", audioPlayer.isPlaying,
               (position.transportStatus != "OK" ||
                (position.seconds < 1 && Date().timeIntervalSince(current.startedAt) > 8)) {
                let message = "Sonos could not play this stream. Make sure the speaker can reach the Navidrome URL."
                await leaveSonosOutput(clearPlayback: false)
                sonosMessage = message
                statusMessage = message
                return
            }
            if position.track == 0, position.transportState == "STOPPED",
               audioPlayer.isPlaying, Date().timeIntervalSince(current.startedAt) > 2 {
                audioPlayer.endSonosTrack(
                    finished: audioPlayer.duration > 0
                        && audioPlayer.currentTime >= audioPlayer.duration - 2
                )
                statusMessage = "Reached end of queue"
            }
            if position.track > 0, position.track <= current.syncedCount,
               playbackQueue.indices.contains(position.track - 1) {
                let index = position.track - 1
                let entry = playbackQueue[index]
                if currentPlaybackQueueEntryID != entry.id {
                    let finished = position.track == current.lastTrack + 1
                        && audioPlayer.duration > 0
                        && audioPlayer.currentTime >= audioPlayer.duration - 2
                    audioPlayer.endSonosTrack(finished: finished)
                    currentPlaybackQueueEntryID = entry.id
                    audioPlayer.updateSonosPlayback(
                        song: entry.song, at: position.seconds,
                        duration: position.duration, isPlaying: position.transportState == "PLAYING",
                        event: .started
                    )
                    sonosSession?.lastTrack = position.track
                    updateNowPlayingArtwork(for: entry.song)
                    updateNowPlayingQueueState()
                    if let serverKey {
                        try? store.markPlayed(entry.song, serverKey: serverKey)
                        try? await refreshRecentSongs()
                    }
                } else if let song = audioPlayer.currentSong {
                    let playing = position.transportState == "PLAYING" || position.transportState == "TRANSITIONING"
                    let event: AudioPlaybackEvent.Trigger = playing == audioPlayer.isPlaying
                        ? .progressed : (playing ? .resumed : .paused)
                    audioPlayer.updateSonosPlayback(
                        song: song, at: position.seconds, duration: position.duration,
                        isPlaying: playing, event: event
                    )
                }
            }
            if tick > 0, tick.isMultiple(of: 5), sonosSyncTask == nil {
                if !sonosQueueMutationInFlight {
                    let version = try await sonosUPnP.queueVersion(on: current.group.coordinator)
                    guard generation == sonosGeneration else { return }
                    if let expected = current.expectedQueueVersion, version != expected {
                        await detachSonos(with: SonosError.queueChanged.localizedDescription)
                        return
                    }
                    if current.expectedQueueVersion == nil {
                        sonosSession?.expectedQueueVersion = version
                    }
                }
                let volume = try? await sonosUPnP.groupVolume(on: current.group.coordinator)
                guard generation == sonosGeneration else { return }
                if let volume { audioPlayer.setSonosVolume(Double(volume) / 100) }
            }
            if tick > 0, tick.isMultiple(of: 30),
               let groups = try? await sonosUPnP.discoverGroups(),
               generation == sonosGeneration,
               !groups.contains(where: { $0.id == current.group.id && $0.coordinator.id == current.group.coordinator.id }) {
                await detachSonos(with: "The Sonos group changed. Select it again to continue.")
            }
        } catch {
            guard generation == sonosGeneration else { return }
            sonosMessage = "Could not reach Sonos: \(error.localizedDescription)"
        }
    }

    private func detachSonos(with message: String) async {
        guard sonosSession != nil else { return }
        sonosGeneration += 1
        sonosPollTask?.cancel()
        sonosSyncTask?.cancel()
        sonosSession = nil
        sonosQueueSynced = 0
        sonosQueueTotal = 0
        sonosMessage = message
        statusMessage = message
        let song = audioPlayer.currentSong
        let seconds = audioPlayer.currentTime
        let url: URL? = if let song, let client { try? client.streamURL(for: song) } else { nil }
        audioPlayer.leaveSonosRoute(song: song, url: url, at: seconds, autoplay: false)
        if let song, url == nil { audioPlayer.restore(song: song, at: seconds) }
        persistPlaybackState()
    }
}
