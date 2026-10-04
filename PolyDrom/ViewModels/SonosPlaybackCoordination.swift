import Foundation
import OSLog

struct SonosActiveSession {
    let group: SonosGroup
    let sourceURI: String?
    let trackURI: String?
    let startedAt: Date
    var lastProgressAt: Date?
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
        sonosPollTask?.cancel()
        await sonosPollTask?.value
        if let old = sonosSession { await stopOwnedTrack(old) }
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
                try await loadSonosTrack(
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
                    group: group, sourceURI: nil, trackURI: nil, startedAt: Date()
                )
                audioPlayer.selectSonosRoute(groupID: group.id, groupVolume: Double(volume) / 100)
            }
            sonosMessage = nil
        } catch {
            guard generation == sonosGeneration else { return }
            let reason = Self.describe(error)
            AppLog.sonos.error("Sonos activation failed: \(reason, privacy: .public)")
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
        var queue = replacement ?? playbackQueue
        guard let index = queue.firstIndex(where: { $0.id == entry.id }) else {
            throw SonosError.invalidResponse
        }
        queue[index].song = song
        sonosGeneration += 1
        sonosPollTask?.cancel()
        try await loadSonosTrack(
            queue, currentIndex: index, song: song, seconds: 0, autoplay: true,
            group: active.group, groupVolume: Int((audioPlayer.volume * 100).rounded()),
            client: client, generation: sonosGeneration, reportStart: true
        )
    }

    private func loadSonosTrack(
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
        guard queue.indices.contains(currentIndex) else { throw SonosError.invalidResponse }
        let device = group.coordinator
        let track = try Self.track(queue[currentIndex], client: client)
        guard generation == sonosGeneration else { throw CancellationError() }
        _ = try? await sonosUPnP.transport("Stop", on: device)
        var step = "RemoveAllTracksFromQueue"
        do {
            guard generation == sonosGeneration else { throw CancellationError() }
            try await sonosUPnP.clearQueue(device)
            guard generation == sonosGeneration else { throw CancellationError() }
            step = "AddURIToQueue"
            try await sonosUPnP.enqueueTrack(track, on: device)
            guard generation == sonosGeneration else { throw CancellationError() }
            step = "SetAVTransportURI"
            try await sonosUPnP.useQueue(device)
            guard generation == sonosGeneration else { throw CancellationError() }
            step = "Seek TRACK_NR"
            try await sonosUPnP.seekFirstTrack(on: device)
            step = "Seek REL_TIME \(Int(seconds))s"
            if seconds >= 1 { try await sonosUPnP.seekTime(seconds, on: device) }
            guard generation == sonosGeneration else { throw CancellationError() }
            if audioPlayer.route == .local { audioPlayer.pauseForSonosHandoff() }
            step = "Play"
            if autoplay { try await sonosUPnP.transport("Play", on: device) }
            guard generation == sonosGeneration else { throw CancellationError() }
        } catch {
            guard generation == sonosGeneration else { throw error }
            let failedStep = step
            let reason = Self.describe(error)
            AppLog.sonos.error("Sonos track load failed at \(failedStep, privacy: .public): \(reason, privacy: .public)")
            audioPlayer.resumeAfterFailedSonosHandoff()
            if audioPlayer.route != .local { await detachSonos(with: error.localizedDescription) }
            else { _ = try? await sonosUPnP.clearQueue(device) }
            throw error
        }

        guard generation == sonosGeneration else { return }
        if reportStart, audioPlayer.route != .local, audioPlayer.currentSong != nil,
           audioPlayer.isPlaying {
            audioPlayer.endSonosTrack(finished: false)
        }
        sonosSession = SonosActiveSession(
            group: group, sourceURI: SonosUPnP.queueURI(for: device),
            trackURI: track.streamURL.absoluteString, startedAt: Date()
        )
        playbackQueue = queue
        currentPlaybackQueueEntryID = queue[currentIndex].id
        audioPlayer.beginSonosPlayback(
            song: song, groupID: group.id, at: seconds, isPlaying: autoplay,
            groupVolume: Double(groupVolume) / 100, reportStart: reportStart
        )
        sonosMessage = nil
        startSonosPolling(generation: generation)
        updateNowPlayingQueueState()
    }

    nonisolated private static func describe(_ error: Error) -> String {
        let error = error as NSError
        return "\(error.domain) \(error.code): \(error.localizedDescription)"
    }

    /// Formats Sonos plays natively are streamed as the original file, which keeps
    /// byte-range seeking available; transcoded streams lack it.
    nonisolated static func sonosStreamFormat(for song: NavidromeSong) -> (format: String, mimeType: String) {
        let mimeType: String? = switch song.suffix?.lowercased() {
        case "mp3": "audio/mpeg"
        case "flac": "audio/flac"
        case "m4a", "mp4": "audio/mp4"
        case "aac": "audio/aac"
        case "ogg", "oga": "audio/ogg"
        case "wma": "audio/x-ms-wma"
        case "wav": "audio/wav"
        case "aif", "aiff": "audio/aiff"
        default: nil
        }
        return mimeType.map { ("raw", $0) } ?? ("mp3", "audio/mpeg")
    }

    private static func track(_ entry: PlaybackQueueEntry, client: NavidromeClient) throws -> SonosTrack {
        let (format, mimeType) = sonosStreamFormat(for: entry.song)
        let stream = try client.streamURL(for: entry.song, format: format)
        try checkSpeakerReachability(of: stream)
        let artworkID = entry.song.coverArt ?? entry.song.albumId
        let artwork = artworkID.flatMap { try? client.coverArtURL(id: $0, size: 512) }
        return SonosTrack(
            entryID: entry.id, song: entry.song, streamURL: stream, artworkURL: artwork,
            mimeType: mimeType
        )
    }

    private static func checkSpeakerReachability(of url: URL) throws {
        let host = url.host?.lowercased() ?? ""
        if host == "localhost" || host == "127.0.0.1" || host == "::1" || host.hasSuffix(".localhost") {
            throw SonosError.localServerAddress
        }
    }

    func handleSonosCommand(_ command: SonosPlaybackCommand) {
        guard let session = sonosSession else { return }
        if case .volume(let volume) = command {
            pendingSonosVolume = Int((volume * 100).rounded())
            let generation = sonosGeneration
            if sonosVolumeTask != nil, sonosVolumeTaskGeneration == generation { return }
            sonosVolumeTaskGeneration = generation
            sonosVolumeTask = Task { await sendPendingSonosVolume(on: session.group.coordinator, generation: generation) }
            return
        }
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
                    sonosSession?.lastProgressAt = Date()
                    if let song = audioPlayer.currentSong {
                        audioPlayer.updateSonosPlayback(
                            song: song, at: audioPlayer.currentTime, duration: audioPlayer.duration,
                            isPlaying: true, event: .resumed
                        )
                    }
                case .pause:
                    try await sonosUPnP.transport("Pause", on: session.group.coordinator)
                    guard generation == sonosGeneration else { return }
                    sonosSession?.lastProgressAt = nil
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
                    sonosSession?.lastProgressAt = audioPlayer.isPlaying ? Date() : nil
                    if let song = audioPlayer.currentSong {
                        audioPlayer.updateSonosPlayback(
                            song: song, at: seconds, duration: audioPlayer.duration,
                            isPlaying: audioPlayer.isPlaying, event: .seeked
                        )
                    }
                case .volume:
                    break
                }
            } catch {
                let commandName = String(describing: command)
                let reason = Self.describe(error)
                AppLog.sonos.error("Sonos command \(commandName, privacy: .public) failed: \(reason, privacy: .public)")
                if generation == sonosGeneration {
                    sonosMessage = error.localizedDescription
                    statusMessage = error.localizedDescription
                }
            }
        }
    }

    private func sendPendingSonosVolume(on device: SonosDevice, generation: Int) async {
        defer {
            if sonosVolumeTaskGeneration == generation {
                sonosVolumeTask = nil
                pendingSonosVolume = nil
            }
        }
        while generation == sonosGeneration {
            // Coalesce slider updates before sending, then keep only one request in flight.
            try? await Task.sleep(for: .milliseconds(100))
            guard generation == sonosGeneration, let volume = pendingSonosVolume else { return }
            pendingSonosVolume = nil
            do {
                try await sonosUPnP.setGroupVolume(volume, on: device)
                guard generation == sonosGeneration else { return }
                clearSonosVolumeError()
            } catch {
                guard generation == sonosGeneration else { return }
                let reason = Self.describe(error)
                AppLog.sonos.error("Sonos volume command failed: \(reason, privacy: .public)")
                let actualVolume = try? await sonosUPnP.groupVolume(on: device)
                guard generation == sonosGeneration else { return }
                if actualVolume.map({ abs($0 - volume) <= 1 }) == true {
                    clearSonosVolumeError()
                } else if pendingSonosVolume == nil {
                    let message = "Could not change Sonos volume: \(error.localizedDescription)"
                    sonosVolumeErrorMessage = message
                    sonosMessage = message
                    statusMessage = message
                }
            }
            if pendingSonosVolume == nil { return }
        }
    }

    private func clearSonosVolumeError() {
        guard let message = sonosVolumeErrorMessage else { return }
        if sonosMessage == message { sonosMessage = nil }
        if statusMessage == message { statusMessage = "Sonos volume changed" }
        sonosVolumeErrorMessage = nil
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
            return
        }
        let song = clearPlayback ? nil : audioPlayer.currentSong
        let seconds = audioPlayer.currentTime
        let autoplay = !clearPlayback && audioPlayer.isPlaying
        sonosGeneration += 1
        sonosPollTask?.cancel()
        await stopOwnedTrack(session)
        sonosSession = nil
        sonosMessage = nil
        let url: URL? = if let song, let client { try? client.streamURL(for: song) } else { nil }
        let fallbackURL: URL? = if let song, let client { try? client.streamURL(for: song, format: "mp3") } else { nil }
        audioPlayer.leaveSonosRoute(song: song, url: url, fallbackURL: fallbackURL, at: seconds, autoplay: autoplay)
        if let song, url == nil { audioPlayer.restore(song: song, at: seconds) }
        updateNowPlayingQueueState()
        persistPlaybackState()
    }

    private func stopOwnedTrack(_ session: SonosActiveSession) async {
        guard let sourceURI = session.sourceURI else { return }
        let device = session.group.coordinator
        guard let position = try? await sonosUPnP.position(on: device),
              position.sourceURI == sourceURI else { return }
        if let trackURI = session.trackURI,
           !position.trackURI.isEmpty,
           position.trackURI != trackURI { return }
        _ = try? await sonosUPnP.transport("Stop", on: device)
        _ = try? await sonosUPnP.clearQueue(device)
    }

    func resetSonosForServerChange() {
        sonosGeneration += 1
        sonosActivationTask?.cancel()
        guard let session = sonosSession else { return }
        sonosPollTask?.cancel()
        sonosSession = nil
        audioPlayer.leaveSonosRoute(song: nil, url: nil, at: 0, autoplay: false)
        sonosCleanupTask = Task {
            await stopOwnedTrack(session)
        }
    }

    func stopSonosForTermination() async {
        sonosGeneration += 1
        sonosActivationTask?.cancel()
        await sonosActivationTask?.value
        await sonosCleanupTask?.value
        guard let session = sonosSession else { return }
        sonosPollTask?.cancel()
        if let song = audioPlayer.currentSong {
            audioPlayer.updateSonosPlayback(
                song: song, at: audioPlayer.currentTime, duration: audioPlayer.duration,
                isPlaying: false, event: .paused
            )
        }
        persistPlaybackState()
        await stopOwnedTrack(session)
        sonosSession = nil
    }

    private func startSonosPolling(generation: Int) {
        sonosPollTask?.cancel()
        sonosPollTask = Task { [weak self] in
            var tick = 0
            while let self, !Task.isCancelled, generation == sonosGeneration {
                if tick > 0, tick.isMultiple(of: 30) {
                    Task { await self.checkSonosGroup(generation: generation) }
                }
                await pollSonosOnce(generation: generation, tick: tick)
                tick += 1
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    func pollSonosOnce(generation: Int, tick: Int) async {
        guard generation == sonosGeneration, let session = sonosSession,
              let expectedSource = session.sourceURI,
              let expectedTrack = session.trackURI else { return }
        do {
            let position = try await sonosUPnP.position(on: session.group.coordinator)
            guard generation == sonosGeneration, let current = sonosSession else { return }
            if !position.sourceURI.isEmpty, position.sourceURI != expectedSource {
                let actualSource = position.sourceURI
                AppLog.sonos.warning(
                    "Sonos source changed: expected \(expectedSource, privacy: .public), got \(actualSource, privacy: .private)"
                )
                await detachSonos(with: SonosError.sourceChanged.localizedDescription)
                return
            }
            if !position.trackURI.isEmpty, position.trackURI != expectedTrack {
                let actualTrack = position.trackURI
                AppLog.sonos.warning(
                    "Sonos track changed: expected \(expectedTrack, privacy: .private), got \(actualTrack, privacy: .private)"
                )
                await detachSonos(with: SonosError.sourceChanged.localizedDescription)
                return
            }
            if position.transportState == "STOPPED", audioPlayer.isPlaying {
                let duration = max(audioPlayer.duration, position.duration)
                let lastKnownSeconds = audioPlayer.currentTime
                let sinceProgress = current.lastProgressAt.map { Date().timeIntervalSince($0) } ?? 0
                let projectedSeconds = lastKnownSeconds + sinceProgress
                let finished = duration > 0
                    && max(projectedSeconds, position.seconds) >= duration - 2
                let elapsed = Date().timeIntervalSince(current.startedAt)
                let playerDuration = audioPlayer.duration
                let status = position.transportStatus
                let sonosSeconds = position.seconds
                let sonosDuration = position.duration
                AppLog.sonos.notice(
                    """
                    Sonos stopped: finished=\(finished, privacy: .public) \
                    status=\(status, privacy: .public) \
                    sonosSeconds=\(sonosSeconds, privacy: .public) \
                    lastKnownSeconds=\(lastKnownSeconds, privacy: .public) \
                    sinceProgress=\(sinceProgress, privacy: .public) \
                    sonosDuration=\(sonosDuration, privacy: .public) \
                    playerDuration=\(playerDuration, privacy: .public) \
                    sinceStart=\(elapsed, privacy: .public)
                    """
                )
                if finished {
                    audioPlayer.endSonosTrack(finished: true)
                    playNextTrackAfterCurrentSongFinished()
                    return
                }
                if position.transportStatus != "OK" || (position.seconds < 1 && elapsed > 8) {
                    let message = "Sonos could not play this stream. Make sure the speaker can reach the Navidrome URL."
                    AppLog.sonos.warning("Leaving Sonos: stopped without finishing the track")
                    await leaveSonosOutput(clearPlayback: false)
                    sonosMessage = message
                    statusMessage = message
                    return
                }
                if position.seconds > 0, elapsed > 2 {
                    audioPlayer.endSonosTrack(finished: false)
                    return
                }
                return
            }
            if let song = audioPlayer.currentSong,
               position.transportState != "STOPPED" {
                let playing = position.transportState == "PLAYING" || position.transportState == "TRANSITIONING"
                // Sonos rewinds to 0 when a track ends, and the transport state is fetched before
                // the position, so a poll can still say PLAYING at 0. Keep the last real position
                // so the following STOPPED poll recognises the track as finished.
                let duration = max(audioPlayer.duration, position.duration)
                let sinceProgress = current.lastProgressAt.map { Date().timeIntervalSince($0) } ?? 0
                if playing, position.seconds < 1, duration > 0,
                   audioPlayer.currentTime + sinceProgress >= duration - 2 {
                    return
                }
                let event: AudioPlaybackEvent.Trigger = playing == audioPlayer.isPlaying
                    ? .progressed : (playing ? .resumed : .paused)
                audioPlayer.updateSonosPlayback(
                    song: song, at: position.seconds, duration: position.duration,
                    isPlaying: playing, event: event
                )
                sonosSession?.lastProgressAt = playing ? Date() : nil
            }
            if tick > 0, tick.isMultiple(of: 5) {
                let volume = try? await sonosUPnP.groupVolume(on: current.group.coordinator)
                guard generation == sonosGeneration else { return }
                if let volume { audioPlayer.setSonosVolume(Double(volume) / 100) }
            }
        } catch {
            guard generation == sonosGeneration else { return }
            let reason = Self.describe(error)
            AppLog.sonos.error("Sonos poll failed: \(reason, privacy: .public)")
            sonosMessage = "Could not reach Sonos: \(error.localizedDescription)"
        }
    }

    private func checkSonosGroup(generation: Int) async {
        guard generation == sonosGeneration, let current = sonosSession,
              let groups = try? await sonosUPnP.discoverGroups(),
              generation == sonosGeneration,
              !groups.contains(where: { $0.id == current.group.id && $0.coordinator.id == current.group.coordinator.id })
        else { return }
        let expectedGroupID = current.group.id
        let groupCount = groups.count
        let coordinatorGroupID = groups.first { $0.coordinator.id == current.group.coordinator.id }?.id ?? "none"
        AppLog.sonos.warning(
            """
            Sonos group \(expectedGroupID, privacy: .public) not found among \(groupCount, privacy: .public) \
            groups; coordinator now in group \(coordinatorGroupID, privacy: .public)
            """
        )
        await detachSonos(with: "The Sonos group changed. Select it again to continue.")
    }

    private func detachSonos(with message: String) async {
        guard sonosSession != nil else { return }
        AppLog.sonos.warning("Detaching Sonos: \(message, privacy: .public)")
        sonosGeneration += 1
        sonosPollTask?.cancel()
        sonosSession = nil
        sonosMessage = message
        statusMessage = message
        let song = audioPlayer.currentSong
        let seconds = audioPlayer.currentTime
        let url: URL? = if let song, let client { try? client.streamURL(for: song) } else { nil }
        let fallbackURL: URL? = if let song, let client { try? client.streamURL(for: song, format: "mp3") } else { nil }
        audioPlayer.leaveSonosRoute(song: song, url: url, fallbackURL: fallbackURL, at: seconds, autoplay: false)
        if let song, url == nil { audioPlayer.restore(song: song, at: seconds) }
        persistPlaybackState()
    }
}
