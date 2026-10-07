import Foundation
import OSLog

/// Sonos reports volume as a whole percentage; the player uses a 0...1 fraction.
enum SonosVolume {
    static func percent(from fraction: Double) -> Int {
        Int((fraction * 100).rounded())
    }

    static func fraction(from percent: Int) -> Double {
        Double(percent) / 100
    }
}

/// Where a track starts on Sonos and whether that counts as a new play.
private struct SonosTrackStart {
    let seconds: Double
    let autoplay: Bool
    /// False when Sonos only takes over a song that was already being played.
    let reportStart: Bool

    static let fromBeginning = SonosTrackStart(seconds: 0, autoplay: true, reportStart: true)
}

struct SonosActiveSession {
    let group: SonosGroup
    let sourceURI: String?
    let trackURI: String?
    let startedAt: Date
    var lastProgressAt: Date?
}

@MainActor
extension AppCoordinator {
    /// The first search after launch often comes back empty while macOS is still granting Local
    /// Network access, so the launch-time refresh passes `retryDelays` to search again on its own.
    func refreshSonosGroups(retryDelays: [Duration] = []) async {
        guard !sonosIsDiscovering else { return }
        sonosIsDiscovering = true
        sonosMessage = nil
        defer { sonosIsDiscovering = false }
        var failure: Error = SonosError.discoveryUnavailable
        var pendingDelays = retryDelays[...]
        while true {
            do {
                let groups = try await sonosUPnP.discoverGroups()
                if !groups.isEmpty {
                    sonosGroups = groups
                    return
                }
                failure = SonosError.discoveryUnavailable
            } catch {
                failure = error
            }
            guard let delay = pendingDelays.popFirst(), (try? await Task.sleep(for: delay)) != nil else { break }
        }
        sonosGroups = []
        sonosMessage = failure.localizedDescription
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
        guard isOnline, let client, let session = currentSession else {
            sonosMessage = "Connect to Navidrome before selecting Sonos."
            return
        }
        sonosPollTask?.cancel()
        await sonosPollTask?.value
        if let old = sonosSession { await stopOwnedTrack(old) }
        guard generation == sonosGeneration, isCurrentSession(session) else { return }

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
                // The song is already playing here, so Sonos picks it up where it is.
                let handoff = SonosTrackStart(
                    seconds: audioPlayer.currentTime, autoplay: audioPlayer.isPlaying, reportStart: false
                )
                try await loadSonosTrack(
                    queue,
                    currentIndex: index,
                    start: handoff,
                    group: group,
                    groupVolume: volume,
                    client: client,
                    generation: generation
                )
            } else {
                sonosSession = SonosActiveSession(
                    group: group, sourceURI: nil, trackURI: nil, startedAt: Date()
                )
                audioPlayer.selectSonosRoute(groupID: group.id, groupVolume: SonosVolume.fraction(from: volume))
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
        replacingQueueWith replacement: [PlaybackQueueEntry]?,
        client: NavidromeClient
    ) async throws {
        guard let active = sonosSession else { throw SonosError.invalidResponse }
        var queue = replacement ?? playbackQueue
        guard let index = queue.firstIndex(where: { $0.id == entry.id }) else {
            throw SonosError.invalidResponse
        }
        queue[index].song = entry.song
        sonosGeneration += 1
        sonosPollTask?.cancel()
        try await loadSonosTrack(
            queue, currentIndex: index, start: .fromBeginning,
            group: active.group, groupVolume: SonosVolume.percent(from: audioPlayer.volume),
            client: client, generation: sonosGeneration
        )
    }

    private func loadSonosTrack(
        _ queue: [PlaybackQueueEntry],
        currentIndex: Int,
        start: SonosTrackStart,
        group: SonosGroup,
        groupVolume: Int,
        client: NavidromeClient,
        generation: Int
    ) async throws {
        guard queue.indices.contains(currentIndex) else { throw SonosError.invalidResponse }
        let device = group.coordinator
        let track = try await Self.track(
            queue[currentIndex], client: client, negotiatesFormat: supportsTranscodeDecisions
        )
        try checkSonosGeneration(generation)
        _ = try? await sonosUPnP.transport("Stop", on: device)
        var step = "RemoveAllTracksFromQueue"
        do {
            try checkSonosGeneration(generation)
            try await sonosUPnP.clearQueue(device)
            try checkSonosGeneration(generation)
            step = "AddURIToQueue"
            try await sonosUPnP.enqueueTrack(track, on: device)
            try checkSonosGeneration(generation)
            step = "SetAVTransportURI"
            try await sonosUPnP.useQueue(device)
            try checkSonosGeneration(generation)
            step = "Seek TRACK_NR"
            try await sonosUPnP.seekFirstTrack(on: device)
            step = "Seek REL_TIME \(Int(start.seconds))s"
            if start.seconds >= 1 { try await sonosUPnP.seekTime(start.seconds, on: device) }
            try checkSonosGeneration(generation)
            if audioPlayer.route == .local { audioPlayer.pauseForSonosHandoff() }
            step = "Play"
            if start.autoplay { try await sonosUPnP.transport("Play", on: device) }
            try checkSonosGeneration(generation)
        } catch {
            guard generation == sonosGeneration else { throw error }
            let failedStep = step
            let reason = Self.describe(error)
            AppLog.sonos.error("Sonos track load failed at \(failedStep, privacy: .public): \(reason, privacy: .public)")
            audioPlayer.resumeAfterFailedSonosHandoff()
            if audioPlayer.route != .local {
                await detachSonos(with: error.localizedDescription)
            } else {
                _ = try? await sonosUPnP.clearQueue(device)
            }
            throw error
        }

        guard generation == sonosGeneration else { return }
        if start.reportStart, audioPlayer.route != .local, audioPlayer.currentSong != nil,
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
            song: queue[currentIndex].song, groupID: group.id, at: start.seconds, isPlaying: start.autoplay,
            groupVolume: SonosVolume.fraction(from: groupVolume), reportStart: start.reportStart
        )
        sonosMessage = nil
        startSonosPolling(generation: generation)
        updateNowPlayingQueueState()
    }

    /// A newer Sonos request supersedes the one that captured `generation`.
    private func checkSonosGeneration(_ generation: Int) throws {
        guard generation == sonosGeneration else { throw CancellationError() }
    }

    nonisolated private static func describe(_ error: Error) -> String {
        let error = error as NSError
        return "\(error.domain) \(error.code): \(error.localizedDescription)"
    }

    /// Formats Sonos plays natively are streamed as the original file, which keeps
    /// byte-range seeking available; transcoded streams lack it.
    nonisolated static func sonosStreamFormat(for song: NavidromeSong) -> (format: String, mimeType: String) {
        sonosMimeType(forContainer: song.suffix).map { ("raw", $0) } ?? ("mp3", "audio/mpeg")
    }

    /// The content type Sonos expects for a file of this kind, or nil when it cannot play it.
    nonisolated private static func sonosMimeType(forContainer container: String?) -> String? {
        switch container?.lowercased() {
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
    }

    /// What a Sonos speaker decodes. It stops without an error on anything above 48 kHz, so a
    /// high-resolution file has to reach it resampled, as FLAC where the server can produce it.
    nonisolated static let sonosClientInfo: TranscodeClientInfo = {
        let limitations = [
            TranscodeClientInfo.Limitation(name: "audioSamplerate", values: ["48000"]),
            TranscodeClientInfo.Limitation(name: "audioBitdepth", values: ["24"]),
            TranscodeClientInfo.Limitation(name: "audioChannels", values: ["2"])
        ]
        let playable: [(container: String, codecs: [String])] = [
            ("mp3", ["mp3"]), ("flac", ["flac"]), ("m4a", ["aac", "alac"]), ("ogg", ["vorbis"]),
            ("wma", []), ("wav", []), ("aiff", [])
        ]
        return TranscodeClientInfo(
            name: "PolyDrom",
            platform: "Sonos",
            directPlayProfiles: playable.map {
                .init(containers: [$0.container], audioCodecs: $0.codecs, maxAudioChannels: 2)
            },
            transcodingProfiles: ["flac", "mp3"].map {
                .init(container: $0, audioCodec: $0, maxAudioChannels: 2)
            },
            codecProfiles: ["flac", "alac", "pcm", "aac", "vorbis", "mp3"].map {
                .init(name: $0, limitations: limitations)
            }
        )
    }()

    /// The stream Sonos should fetch for `song`. A server that negotiates formats is told what the
    /// speaker decodes and picks the stream; otherwise the file extension decides.
    nonisolated static func sonosStream(
        for song: NavidromeSong, client: NavidromeClient, negotiatesFormat: Bool
    ) async throws -> (url: URL, mimeType: String) {
        if negotiatesFormat,
           let decision = try? await client.transcodeDecision(
               for: song, clientInfo: sonosClientInfo, timeoutInterval: 4
           ) {
            if decision.canDirectPlay,
               let mimeType = sonosMimeType(forContainer: decision.sourceStream?.container ?? song.suffix) {
                return (try client.streamURL(for: song), mimeType)
            }
            if decision.canTranscode, let transcodeParams = decision.transcodeParams,
               let mimeType = sonosMimeType(forContainer: decision.transcodeStream?.container) {
                return (try client.transcodeStreamURL(for: song, transcodeParams: transcodeParams), mimeType)
            }
        }
        let (format, mimeType) = sonosStreamFormat(for: song)
        return (try client.streamURL(for: song, format: format), mimeType)
    }

    private static func track(
        _ entry: PlaybackQueueEntry, client: NavidromeClient, negotiatesFormat: Bool
    ) async throws -> SonosTrack {
        let (stream, mimeType) = try await sonosStream(
            for: entry.song, client: client, negotiatesFormat: negotiatesFormat
        )
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
            pendingSonosVolume = SonosVolume.percent(from: volume)
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
                let device = session.group.coordinator
                switch command {
                case .play:
                    try await sonosUPnP.transport("Play", on: device)
                    guard generation == sonosGeneration else { return }
                    showSonosPlayback(at: audioPlayer.currentTime, isPlaying: true, event: .resumed)
                case .pause:
                    try await sonosUPnP.transport("Pause", on: device)
                    guard generation == sonosGeneration else { return }
                    showSonosPlayback(at: audioPlayer.currentTime, isPlaying: false, event: .paused)
                case .seek(let seconds):
                    try await sonosUPnP.seekTime(seconds, on: device)
                    guard generation == sonosGeneration else { return }
                    showSonosPlayback(at: seconds, isPlaying: audioPlayer.isPlaying, event: .seeked)
                case .stop, .volume:
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

    /// Mirrors a transport change the speaker accepted in the player's state.
    private func showSonosPlayback(at seconds: Double, isPlaying: Bool, event: AudioPlaybackEvent.Trigger) {
        sonosSession?.lastProgressAt = isPlaying ? Date() : nil
        guard let song = audioPlayer.currentSong else { return }
        audioPlayer.updateSonosPlayback(
            song: song, at: seconds, duration: audioPlayer.duration, isPlaying: isPlaying, event: event
        )
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
        moveSonosPlaybackToLocalOutput(song: song, at: seconds, autoplay: autoplay)
        updateNowPlayingQueueState()
        persistPlaybackState()
    }

    /// Hands `song` back to the local player at the position Sonos reached. Without
    /// a stream to load it is left ready to resume once the server is reachable.
    private func moveSonosPlaybackToLocalOutput(song: NavidromeSong?, at seconds: Double, autoplay: Bool) {
        let streams = song.flatMap { song in try? client?.playbackStreamURLs(for: song) }
        audioPlayer.leaveSonosRoute(
            song: song, url: streams?.url, fallbackURL: streams?.fallbackURL, at: seconds, autoplay: autoplay
        )
        if let song, streams == nil { audioPlayer.restore(song: song, at: seconds) }
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
        showSonosPlayback(at: audioPlayer.currentTime, isPlaying: false, event: .paused)
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
                if let volume { audioPlayer.setSonosVolume(SonosVolume.fraction(from: volume)) }
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
        moveSonosPlaybackToLocalOutput(song: audioPlayer.currentSong, at: audioPlayer.currentTime, autoplay: false)
        persistPlaybackState()
    }
}
