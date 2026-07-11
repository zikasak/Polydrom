//
//  AppViewModel.swift
//  PolyDrom
//
//  Created by zikasak on 07/07/2026.
//

import Combine
import Foundation

@MainActor
final class AppViewModel: ObservableObject {
    @Published var serverAddress = ""
    @Published var username = ""
    @Published var password = ""
    @Published var servers: [ServerProfile] = []
    @Published var activeServer: ServerProfile?
    @Published var selectedSection: LibrarySection = .search
    @Published var statusMessage = "Disconnected"
    @Published var isBusy = false
    @Published var searchText = ""
    @Published var searchResults: [NavidromeSong] = []
    @Published var randomSongs: [NavidromeSong] = []
    @Published var albums: [NavidromeAlbum] = []
    @Published var artists: [NavidromeArtist] = []
    @Published var artistAlbums: [NavidromeAlbum] = []
    @Published var selectedArtist: NavidromeArtist?
    @Published var selectedAlbum: NavidromeAlbum?
    @Published var albumSongs: [NavidromeSong] = []
    @Published var playlists: [NavidromePlaylist] = []
    @Published var selectedPlaylist: NavidromePlaylist?
    @Published var playlistSongs: [NavidromeSong] = []
    @Published var favoriteSongs: [NavidromeSong] = []
    @Published var recentSongs: [NavidromeSong] = []
    @Published var favoriteIDs: Set<String> = []
    @Published var playbackQueue: [NavidromeSong] = []
    @Published var currentLyrics: SongLyrics?
    @Published var lyricsMessage = "No lyrics loaded."
    @Published var isLoadingLyrics = false

    let audioPlayer: AudioPlayer

    private let store: LibraryStore
    private var client: NavidromeClient?
    private var playbackQueueIndex: Int?
    private var playbackQueueNeedsSongHydration = false
    private var lyricsSongID: String?
    private var albumCoverPrefetchTask: Task<Void, Never>?
    private var songCoverPrefetchTask: Task<Void, Never>?
    private var nowPlayingArtworkTask: Task<Void, Never>?
    private var loadedArtistAlbumsID: String?
    private var loadedAlbumSongsID: String?
    private var loadedPlaylistSongsID: String?
    private let libraryPageSize = 200
    private let coverArtPrefetchLimit = 48
    private var didAttemptInitialConnection = false

    var isConnected: Bool {
        activeServer != nil && client != nil
    }

    var serverKey: String? {
        activeServer?.serverKey
    }

    init() {
        self.store = LibraryStore()
        self.audioPlayer = AudioPlayer()
        configureAudioPlayer()
        loadServers()
    }

    init(store: LibraryStore, audioPlayer: AudioPlayer) {
        self.store = store
        self.audioPlayer = audioPlayer
        configureAudioPlayer()
        loadServers()
    }

    func loadServers() {
        do {
            servers = try store.servers()
            if let latest = servers.first, activeServer == nil {
                serverAddress = latest.address
                username = latest.username
                password = latest.password
            }
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func connectFromForm() async {
        do {
            let profile = try store.saveServer(address: serverAddress, username: username, password: password)
            await connect(profile)
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func connectToLatestServer() async {
        guard !didAttemptInitialConnection, !isConnected, !isBusy else { return }
        didAttemptInitialConnection = true

        if servers.isEmpty {
            loadServers()
        }

        guard let latest = servers.first else { return }
        statusMessage = "Connecting to \(latest.displayName)..."
        await connect(latest)
    }

    func connect(_ profile: ServerProfile) async {
        guard let nextClient = NavidromeClient(profile: profile) else {
            statusMessage = "Enter a valid server address."
            return
        }

        let previousServerKey = activeServer?.serverKey
        isBusy = true
        defer { isBusy = false }

        do {
            try await nextClient.ping()
            client = nextClient
            activeServer = profile
            if previousServerKey != profile.serverKey {
                clearRemoteLibraryState()
            }
            serverAddress = profile.address
            username = profile.username
            password = profile.password
            try store.touchServer(profile)
            loadServers()
            try refreshLocalLists()
            statusMessage = "Connected to \(profile.displayName)"
            await refreshSelectedSection()
        } catch {
            client = nil
            activeServer = nil
            statusMessage = error.localizedDescription
        }
    }

    func deleteServer(_ profile: ServerProfile) {
        do {
            try store.deleteServer(profile)
            if activeServer?.id == profile.id {
                activeServer = nil
                client = nil
                audioPlayer.stop()
            }
            loadServers()
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func selectSection(_ section: LibrarySection) {
        selectedSection = section
        Task { await refreshSelectedSection() }
    }

    func refreshSelectedSection(force: Bool = false) async {
        guard isConnected else { return }

        switch selectedSection {
        case .search:
            let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
            if !query.isEmpty, force || searchResults.isEmpty {
                await search()
            } else if (force || searchResults.isEmpty) && query.isEmpty {
                await loadRandomSongs()
            }
        case .random:
            if force || randomSongs.isEmpty {
                await loadRandomSongs()
            }
        case .albums:
            if force || albums.isEmpty {
                await loadAlbums()
            }
        case .artists:
            if force || artists.isEmpty {
                await loadArtists()
            }
        case .playlists:
            if force || playlists.isEmpty {
                await loadPlaylists()
            }
        case .favorites, .recent:
            do {
                try refreshLocalLists()
            } catch {
                statusMessage = error.localizedDescription
            }
        }
    }

    func search() async {
        guard let client else {
            statusMessage = "Connect first."
            return
        }

        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            searchResults = []
            statusMessage = "Enter a search term."
            return
        }

        isBusy = true
        defer { isBusy = false }

        do {
            searchResults = try await client.searchSongs(matching: query)
            try cache(searchResults)
            prefetchSongCovers(searchResults)
            statusMessage = searchResults.isEmpty ? "No songs found." : "\(searchResults.count) songs found"
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func loadRandomSongs() async {
        guard let client else { return }
        isBusy = true
        defer { isBusy = false }

        do {
            randomSongs = try await client.randomSongs()
            try cache(randomSongs)
            prefetchSongCovers(randomSongs)
            statusMessage = randomSongs.isEmpty ? "No random songs returned." : "Loaded random songs"
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func loadAlbums() async {
        guard let client else { return }
        isBusy = true
        defer { isBusy = false }

        do {
            var loadedAlbums: [NavidromeAlbum] = []
            var seenAlbumIDs = Set<String>()
            var offset = 0

            while true {
                let page = try await client.albumPage(type: .newest, size: libraryPageSize, offset: offset)
                guard !Task.isCancelled else { return }

                let newAlbums = page.filter { seenAlbumIDs.insert($0.id).inserted }
                loadedAlbums.append(contentsOf: newAlbums)
                albums = loadedAlbums

                if offset == 0 {
                    prefetchAlbumCovers(loadedAlbums)
                }

                if page.count < libraryPageSize || newAlbums.isEmpty {
                    statusMessage = loadedAlbums.isEmpty ? "No albums returned." : "Loaded \(loadedAlbums.count) albums"
                    return
                }

                statusMessage = "Loaded \(loadedAlbums.count) albums..."
                offset += libraryPageSize
            }
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func loadArtists() async {
        guard let client else { return }
        isBusy = true
        defer { isBusy = false }

        do {
            var loadedArtists: [NavidromeArtist] = []
            var seenArtistIDs = Set<String>()
            var offset = 0

            while true {
                let page = try await client.artistPage(size: libraryPageSize, offset: offset)
                guard !Task.isCancelled else { return }

                let newArtists = page.filter { seenArtistIDs.insert($0.id).inserted }
                loadedArtists.append(contentsOf: newArtists)
                artists = sortedVisibleArtists(loadedArtists)

                if page.count < libraryPageSize || newArtists.isEmpty {
                    statusMessage = artists.isEmpty ? "No artists returned." : "Loaded \(artists.count) artists"
                    return
                }

                statusMessage = "Loaded \(artists.count) artists..."
                offset += libraryPageSize
            }
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func loadPlaylists() async {
        guard let client else { return }
        isBusy = true
        defer { isBusy = false }

        do {
            playlists = try await client.playlists()
            statusMessage = playlists.isEmpty ? "No playlists returned." : "Loaded playlists"
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func loadAlbums(for artist: NavidromeArtist, force: Bool = false) async {
        guard let client else { return }
        if !force, loadedArtistAlbumsID == artist.id {
            selectedArtist = artist
            return
        }

        selectedArtist = artist
        selectedAlbum = nil
        artistAlbums = []
        albumSongs = []
        loadedArtistAlbumsID = nil
        loadedAlbumSongsID = nil
        isBusy = true
        defer { isBusy = false }

        do {
            artistAlbums = try await client.albums(for: artist)
            guard !Task.isCancelled else { return }
            loadedArtistAlbumsID = artist.id
            prefetchAlbumCovers(artistAlbums)
            statusMessage = artistAlbums.isEmpty ? "No albums for \(artist.name)." : "Loaded \(artist.name)"
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func loadSongs(for album: NavidromeAlbum, force: Bool = false) async {
        guard let client else { return }
        if !force, loadedAlbumSongsID == album.id {
            selectedAlbum = album
            return
        }

        selectedAlbum = album
        albumSongs = []
        loadedAlbumSongsID = nil
        isBusy = true
        defer { isBusy = false }

        do {
            albumSongs = try await client.songs(for: album)
            guard !Task.isCancelled else { return }
            loadedAlbumSongsID = album.id
            try cache(albumSongs)
            prefetchSongCovers(albumSongs)
            statusMessage = albumSongs.isEmpty ? "No songs for \(album.name)." : "Loaded \(album.name)"
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func loadSongs(for playlist: NavidromePlaylist, force: Bool = false) async {
        guard let client else { return }
        if !force, loadedPlaylistSongsID == playlist.id {
            selectedPlaylist = playlist
            return
        }

        selectedPlaylist = playlist
        playlistSongs = []
        loadedPlaylistSongsID = nil
        isBusy = true
        defer { isBusy = false }

        do {
            playlistSongs = try await client.songs(for: playlist)
            guard !Task.isCancelled else { return }
            loadedPlaylistSongsID = playlist.id
            try cache(playlistSongs)
            prefetchSongCovers(playlistSongs)
            statusMessage = playlistSongs.isEmpty ? "No songs for \(playlist.name)." : "Loaded \(playlist.name)"
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func play(_ song: NavidromeSong) {
        play(song, in: [song])
    }

    func play(_ song: NavidromeSong, in queue: [NavidromeSong]) {
        let shouldHydrateSong = selectedSection == .random
        Task {
            await play(song, in: queue, shouldHydrateSong: shouldHydrateSong)
        }
    }

    private func play(_ song: NavidromeSong, in queue: [NavidromeSong], shouldHydrateSong: Bool) async {
        guard let client, let serverKey else {
            statusMessage = "Connect first."
            return
        }

        do {
            let songToPlay = try await resolvedSongForPlayback(song, shouldHydrateSong: shouldHydrateSong)
            let url = try client.streamURL(for: songToPlay)
            playbackQueue = queue.isEmpty ? [song] : queue
            playbackQueueIndex = playbackQueue.firstIndex(of: song)
            playbackQueueNeedsSongHydration = shouldHydrateSong
            if lyricsSongID != songToPlay.id {
                lyricsSongID = nil
                currentLyrics = nil
                lyricsMessage = "No lyrics loaded."
            }
            updateNowPlayingQueueState()
            audioPlayer.play(song: songToPlay, url: url)
            updateNowPlayingArtwork(for: songToPlay)
            try store.markPlayed(songToPlay, serverKey: serverKey)
            try refreshLocalLists()
            statusMessage = "Playing \(songToPlay.title)"
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func playPreviousTrack() {
        guard let playbackQueueIndex, playbackQueue.indices.contains(playbackQueueIndex - 1) else { return }
        Task {
            await play(playbackQueue[playbackQueueIndex - 1], in: playbackQueue, shouldHydrateSong: false)
        }
    }

    func playNextTrack() {
        guard let playbackQueueIndex, playbackQueue.indices.contains(playbackQueueIndex + 1) else { return }
        Task {
            await play(playbackQueue[playbackQueueIndex + 1], in: playbackQueue, shouldHydrateSong: false)
        }
    }

    func canPlayPreviousTrack() -> Bool {
        guard let playbackQueueIndex else { return false }
        return playbackQueue.indices.contains(playbackQueueIndex - 1)
    }

    func canPlayNextTrack() -> Bool {
        guard let playbackQueueIndex else { return false }
        return playbackQueue.indices.contains(playbackQueueIndex + 1)
    }

    func loadLyrics(for song: NavidromeSong, force: Bool = false) async {
        guard let client else {
            currentLyrics = nil
            lyricsMessage = "Connect to a server to load lyrics."
            return
        }

        if !force, lyricsSongID == song.id {
            return
        }

        lyricsSongID = song.id
        currentLyrics = nil
        lyricsMessage = "Loading lyrics..."
        isLoadingLyrics = true
        defer { isLoadingLyrics = false }

        do {
            let availableLyrics = try await client.lyrics(for: song)
            guard lyricsSongID == song.id else { return }
            currentLyrics = availableLyrics.first(where: \.synced) ?? availableLyrics.first
            lyricsMessage = currentLyrics == nil ? "No lyrics are available for this song." : ""
        } catch {
            guard lyricsSongID == song.id else { return }
            currentLyrics = nil
            lyricsMessage = "Lyrics could not be loaded: \(error.localizedDescription)"
        }
    }

    func coverArtResource(for song: NavidromeSong, size: Int = 80) -> CoverArtResource? {
        guard let coverArt = song.coverArt else { return nil }
        return coverArtResource(id: coverArt, size: size)
    }

    func coverArtResource(for album: NavidromeAlbum, size: Int = 96) -> CoverArtResource? {
        guard let coverArt = album.coverArt else { return nil }
        return coverArtResource(id: coverArt, size: size)
    }

    func coverArtResource(for artist: NavidromeArtist, size: Int = 160) -> CoverArtResource? {
        if let imageURL = artist.artistImageURL, let url = URL(string: imageURL) {
            return CoverArtResource(cacheKey: "\(serverKey ?? "server")|artist|\(artist.id)|\(size)|\(imageURL)", url: url)
        }

        return coverArtResource(id: artist.coverArt ?? artist.id, size: size)
    }

    func toggleFavorite(_ song: NavidromeSong) {
        guard let serverKey else { return }

        do {
            let nextValue = !favoriteIDs.contains(song.id)
            try store.setFavorite(song, serverKey: serverKey, isFavorite: nextValue)
            try refreshLocalLists()
            statusMessage = nextValue ? "Added to favorites" : "Removed from favorites"
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func isFavorite(_ song: NavidromeSong) -> Bool {
        favoriteIDs.contains(song.id)
    }

    private func cache(_ songs: [NavidromeSong]) throws {
        guard let serverKey else { return }
        try store.upsertSongs(songs, serverKey: serverKey)
        favoriteIDs = try store.favoriteIDs(serverKey: serverKey)
    }

    private func refreshLocalLists() throws {
        guard let serverKey else { return }
        favoriteIDs = try store.favoriteIDs(serverKey: serverKey)
        favoriteSongs = try store.favoriteSongs(serverKey: serverKey)
        recentSongs = try store.recentSongs(serverKey: serverKey)
        prefetchSongCovers(favoriteSongs + recentSongs)
    }

    private func configureAudioPlayer() {
        audioPlayer.onSongFinished = { [weak self] in
            self?.playNextTrackAfterCurrentSongFinished()
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

    private func playNextTrackAfterCurrentSongFinished() {
        guard canPlayNextTrack() else {
            updateNowPlayingQueueState()
            statusMessage = "Reached end of queue"
            return
        }

        playNextTrack()
    }

    private func resolvedSongForPlayback(_ song: NavidromeSong, shouldHydrateSong: Bool) async throws -> NavidromeSong {
        guard shouldHydrateSong, let client else {
            return song
        }

        do {
            return try await client.song(id: song.id) ?? song
        } catch {
            return song
        }
    }

    private func clearRemoteLibraryState() {
        searchResults = []
        randomSongs = []
        albums = []
        artists = []
        artistAlbums = []
        selectedArtist = nil
        selectedAlbum = nil
        albumSongs = []
        playlists = []
        selectedPlaylist = nil
        playlistSongs = []
        favoriteSongs = []
        recentSongs = []
        favoriteIDs = []
        loadedArtistAlbumsID = nil
        loadedAlbumSongsID = nil
        loadedPlaylistSongsID = nil
    }

    private func sortedVisibleArtists(_ artists: [NavidromeArtist]) -> [NavidromeArtist] {
        artists
            .filter { ($0.albumCount ?? 0) > 0 }
            .sorted {
                $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
    }

    private func coverArtResource(id: String, size: Int) -> CoverArtResource? {
        guard let client, let serverKey else { return nil }
        guard let url = try? client.coverArtURL(id: id, size: size) else { return nil }
        return CoverArtResource(cacheKey: "\(serverKey)|\(id)|\(size)", url: url)
    }

    private func prefetchAlbumCovers(_ albums: [NavidromeAlbum], size: Int = 220) {
        let resources = albums.prefix(coverArtPrefetchLimit).compactMap { coverArtResource(for: $0, size: size) }
        albumCoverPrefetchTask?.cancel()
        albumCoverPrefetchTask = prefetchCoverArt(resources)
    }

    private func prefetchSongCovers(_ songs: [NavidromeSong], size: Int = 72) {
        let songsToPrefetch = songs.prefix(coverArtPrefetchLimit)
        let rowResources = songsToPrefetch.compactMap { coverArtResource(for: $0, size: size) }
        let playerResources = songsToPrefetch.compactMap { coverArtResource(for: $0, size: 96) }
        songCoverPrefetchTask?.cancel()
        songCoverPrefetchTask = prefetchCoverArt(rowResources + playerResources)
    }

    private func prefetchCoverArt(_ resources: [CoverArtResource]) -> Task<Void, Never>? {
        guard !resources.isEmpty else { return nil }
        return Task {
            await CoverArtCache.shared.prefetch(resources)
        }
    }

    private func updateNowPlayingQueueState() {
        audioPlayer.setNowPlayingQueueState(
            canPlayPrevious: canPlayPreviousTrack(),
            canPlayNext: canPlayNextTrack()
        )
    }

    private func updateNowPlayingArtwork(for song: NavidromeSong) {
        nowPlayingArtworkTask?.cancel()
        guard let resource = coverArtResource(for: song, size: 512) else {
            audioPlayer.setNowPlayingArtworkData(nil, for: song.id)
            return
        }

        nowPlayingArtworkTask = Task { [weak audioPlayer] in
            let data = try? await CoverArtCache.shared.data(for: resource)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                audioPlayer?.setNowPlayingArtworkData(data, for: song.id)
            }
        }
    }
}
