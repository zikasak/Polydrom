import Foundation
import OSLog

private enum QueueAction {
    case play
    case next
    case end
}

extension AppCoordinator {
    // MARK: - Starting playback

    func play(
        _ songs: [NavidromeSong],
        startingAt index: Int,
        expectedSession: SessionIdentity? = nil
    ) {
        guard songs.indices.contains(index) else { return }

        AppLog.playback.info("Queued \(songs.count, privacy: .public) songs for playback")
        let queue = songs.map { PlaybackQueueEntry(song: $0) }
        Task {
            await startPlayback(of: queue[index], replacingQueueWith: queue, expectedSession: expectedSession)
        }
    }

    func play(_ entry: PlaybackQueueEntry) {
        Task {
            await startPlayback(of: entry)
        }
    }

    func play(_ album: NavidromeAlbum) {
        performQueueAction(.play) { try await self.cachedSongs(for: album) }
    }

    func play(_ artist: NavidromeArtist) {
        performQueueAction(.play) { try await self.cachedSongs(for: artist) }
    }

    func playRandomSongs(count: Int? = nil) async {
        await playShuffledSongs { serverKey in
            try await self.store.randomSongs(serverKey: serverKey, count: count)
        }
    }

    func playSongsShuffledByAlbum() async {
        await playShuffledSongs { serverKey in
            try await self.store.songsShuffledByAlbum(serverKey: serverKey)
        }
    }

    /// Starts a mix of `song` and the songs that sound most like it. A song that
    /// is already playing keeps playing, with the mix queued right after it.
    func playSimilarSongs(to song: NavidromeSong, count: Int = 50) async {
        guard let session = currentSession, isOnline, supportsSonicSimilarity, let client else {
            statusMessage = "Similar songs are not available on this server."
            return
        }

        // The controls stay usable while the server answers, so the mix is
        // dropped if another one was asked for or playback moved on meanwhile.
        let requestID = UUID()
        similarSongsRequestID = requestID
        let entryIDAtRequest = currentPlaybackQueueEntryID
        var isStillWanted: Bool {
            isCurrentSession(session)
                && similarSongsRequestID == requestID
                && currentPlaybackQueueEntryID == entryIDAtRequest
        }

        isBusy = true
        defer { isBusy = false }

        do {
            let songs = try await client.sonicallySimilarSongs(to: song.id, count: count)
                .filter { $0.id != song.id }
            guard isStillWanted else { return }
            guard !songs.isEmpty else {
                statusMessage = "No similar songs found."
                return
            }

            await warmCachedSongCovers(songs)
            guard isStillWanted else { return }
            prefetchSongCovers(songs)
            if audioPlayer.currentSong?.id == song.id, currentPlaybackQueueIndex != nil {
                playNext(songs)
            } else {
                play([song] + songs, startingAt: 0, expectedSession: session)
            }
        } catch {
            guard isStillWanted else { return }
            AppLog.playback.error("Could not load similar songs: \(error.localizedDescription, privacy: .private)")
            statusMessage = error.localizedDescription
        }
    }

    /// Starts `entry`, replacing the queue when one is given. `expectedSession`
    /// drops a request that was prepared for an earlier connection.
    func startPlayback(
        of entry: PlaybackQueueEntry,
        replacingQueueWith queue: [PlaybackQueueEntry]? = nil,
        expectedSession: SessionIdentity? = nil
    ) async {
        if let expectedSession, !isCurrentSession(expectedSession) { return }
        guard let session = expectedSession ?? currentSession, isOnline, let client else {
            AppLog.playback.warning("Playback requested while the app is offline")
            statusMessage = "Connect to the server to play music."
            return
        }

        let song = entry.song
        do {
            let streams = try client.playbackStreamURLs(for: song)
            await warmCachedSongCovers([song])
            guard isCurrentSession(session) else { return }

            if sonosSession != nil {
                try await playOnSonos(entry, replacingQueueWith: queue, client: client)
            } else {
                var nextQueue = queue ?? playbackQueue
                guard let index = nextQueue.firstIndex(where: { $0.id == entry.id }) else { return }
                nextQueue[index].song = song
                playbackQueue = nextQueue
                currentPlaybackQueueEntryID = entry.id
                audioPlayer.play(song: song, url: streams.url, fallbackURL: streams.fallbackURL)
            }
            if lyricsSongID != song.id {
                lyricsSongID = nil
                currentLyrics = nil
                lyricsMessage = "No lyrics loaded."
            }
            updateNowPlayingQueueState()
            pendingPlaybackRestore = nil
            didRestorePlayback = true
            persistPlaybackState()
            AppLog.playback.debug("Playback URL prepared for song \(song.id, privacy: .private(mask: .hash))")
            updateNowPlayingArtwork(for: song)
            let queueToWarm = playbackQueue.map(\.song)
            Task { [weak self] in
                guard let self, self.isCurrentSession(session) else { return }
                await warmCachedSongCovers(queueToWarm)
                guard self.isCurrentSession(session) else { return }
                prefetchSongCovers(queueToWarm)
            }
            guard isCurrentSession(session) else { return }
            try store.markPlayed(song, serverKey: session.serverKey)
            try await refreshRecentSongs()
            guard isCurrentSession(session) else { return }
            statusMessage = "Playing \(song.title)"
        } catch {
            guard isCurrentSession(session) else { return }
            AppLog.playback.error("Could not start playback: \(error.localizedDescription, privacy: .private)")
            statusMessage = error.localizedDescription
        }
    }

    // MARK: - Queue

    func playNext(_ songs: [NavidromeSong]) {
        guard !songs.isEmpty else { return }

        guard let currentIndex = currentPlaybackQueueIndex else {
            play(songs, startingAt: 0)
            return
        }

        playbackQueue.insert(contentsOf: songs.map { PlaybackQueueEntry(song: $0) }, at: currentIndex + 1)
        persistPlaybackState()
        updateNowPlayingQueueState()
        statusMessage = songs.count == 1 ? "Playing next" : "Playing next: \(songs.count) songs"
    }

    func playNext(_ album: NavidromeAlbum) {
        performQueueAction(.next) { try await self.cachedSongs(for: album) }
    }

    func playNext(_ artist: NavidromeArtist) {
        performQueueAction(.next) { try await self.cachedSongs(for: artist) }
    }

    func addToQueue(_ songs: [NavidromeSong]) {
        guard !songs.isEmpty else { return }
        playbackQueue.append(contentsOf: songs.map { PlaybackQueueEntry(song: $0) })
        persistPlaybackState()
        updateNowPlayingQueueState()
        statusMessage = songs.count == 1 ? "Added to queue" : "Added \(songs.count) songs to queue"
    }

    func addToQueue(_ album: NavidromeAlbum) {
        performQueueAction(.end) { try await self.cachedSongs(for: album) }
    }

    func addToQueue(_ artist: NavidromeArtist) {
        performQueueAction(.end) { try await self.cachedSongs(for: artist) }
    }

    // MARK: - Moving through the queue

    func playPreviousTrack() {
        playAdjacentTrack(offset: -1)
    }

    func playNextTrack() {
        playAdjacentTrack(offset: 1)
    }

    func canPlayPreviousTrack() -> Bool {
        isOnline && adjacentQueueEntry(offset: -1) != nil
    }

    func canPlayNextTrack() -> Bool {
        isOnline && adjacentQueueEntry(offset: 1) != nil
    }

    func playNextTrackAfterCurrentSongFinished() {
        guard canPlayNextTrack() else {
            updateNowPlayingQueueState()
            statusMessage = "Reached end of queue"
            return
        }

        playNextTrack()
    }

    // MARK: - Now Playing

    func updateNowPlayingQueueState() {
        audioPlayer.setNowPlayingQueueState(
            canPlayPrevious: canPlayPreviousTrack(),
            canPlayNext: canPlayNextTrack()
        )
    }

    func updateNowPlayingArtwork(for song: NavidromeSong) {
        nowPlayingArtworkTask?.cancel()
        guard let resource = coverArtResource(for: song, size: 512) else {
            audioPlayer.setNowPlayingArtworkData(nil, for: song.id)
            return
        }

        nowPlayingArtworkTask = Task { [weak audioPlayer] in
            let data = try? await coverArtCache.data(for: resource)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                audioPlayer?.setNowPlayingArtworkData(data, for: song.id)
            }
        }
    }

    // MARK: - Helpers

    private var currentPlaybackQueueIndex: Int? {
        guard audioPlayer.currentSong != nil, let currentPlaybackQueueEntryID else { return nil }
        return playbackQueueIndices[currentPlaybackQueueEntryID]
    }

    private func adjacentQueueEntry(offset: Int) -> PlaybackQueueEntry? {
        guard let currentIndex = currentPlaybackQueueIndex,
              playbackQueue.indices.contains(currentIndex + offset) else { return nil }
        return playbackQueue[currentIndex + offset]
    }

    private func playAdjacentTrack(offset: Int) {
        guard let entry = adjacentQueueEntry(offset: offset) else { return }
        Task {
            await startPlayback(of: entry)
        }
    }

    private func playShuffledSongs(_ loadSongs: (_ serverKey: String) async throws -> [NavidromeSong]) async {
        guard let session = currentSession else {
            statusMessage = "Select a library first."
            return
        }

        isBusy = true
        defer { isBusy = false }

        do {
            let songs = try await loadSongs(session.serverKey)
            guard isCurrentSession(session) else { return }
            guard !songs.isEmpty else {
                statusMessage = "No cached songs available."
                return
            }

            await warmCachedSongCovers(songs)
            guard isCurrentSession(session) else { return }
            prefetchSongCovers(songs)
            play(songs, startingAt: 0, expectedSession: session)
        } catch {
            guard isCurrentSession(session) else { return }
            statusMessage = error.localizedDescription
        }
    }

    private func performQueueAction(
        _ action: QueueAction,
        loadSongs: @escaping () async throws -> [NavidromeSong]
    ) {
        guard serverKey != nil else {
            statusMessage = "Select a library first."
            return
        }

        Task {
            isBusy = true
            defer { isBusy = false }

            do {
                let songs = try await loadSongs()
                guard !songs.isEmpty else {
                    statusMessage = "No songs found."
                    return
                }

                await warmCachedSongCovers(songs)
                prefetchSongCovers(songs)

                switch action {
                case .play:
                    play(songs, startingAt: 0)
                case .next:
                    playNext(songs)
                case .end:
                    addToQueue(songs)
                }
            } catch {
                AppLog.playback.error("Queue action failed: \(error.localizedDescription, privacy: .private)")
                statusMessage = error.localizedDescription
            }
        }
    }

    private func cachedSongs(for album: NavidromeAlbum) async throws -> [NavidromeSong] {
        guard let serverKey else { return [] }
        return try await store.songs(serverKey: serverKey, albumID: album.id)
    }

    private func cachedSongs(for artist: NavidromeArtist) async throws -> [NavidromeSong] {
        guard let serverKey else { return [] }
        var songs: [NavidromeSong] = []
        for album in try await store.albums(serverKey: serverKey, artistID: artist.id) {
            try Task.checkCancellation()
            songs.append(contentsOf: try await store.songs(serverKey: serverKey, albumID: album.id))
        }
        return songs
    }
}
