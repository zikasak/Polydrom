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
    @Published var favoriteArtists: [NavidromeArtist] = []
    @Published var favoriteAlbums: [NavidromeAlbum] = []
    @Published var favoriteSongs: [NavidromeSong] = []
    @Published var recentSongs: [NavidromeSong] = []
    @Published var favoriteArtistIDs: Set<String> = []
    @Published var favoriteAlbumIDs: Set<String> = []
    @Published var favoriteIDs: Set<String> = []
    @Published var playbackQueue: [NavidromeSong] = []
    @Published var currentLyrics: SongLyrics?
    @Published var lyricsMessage = "No lyrics loaded."
    @Published var isLoadingLyrics = false

    let audioPlayer: AudioPlayer

    private let store: LibraryStore
    private var client: NavidromeClient?
    private var playbackQueueIndex: Int?
    private var lyricsSongID: String?
    private var albumCoverPrefetchTask: Task<Void, Never>?
    private var artistCoverPrefetchTask: Task<Void, Never>?
    private var songCoverPrefetchTask: Task<Void, Never>?
    private var nowPlayingArtworkTask: Task<Void, Never>?
    private var loadedArtistAlbumsID: String?
    private var loadedAlbumSongsID: String?
    private var loadedPlaylistSongsID: String?
    private let libraryPageSize = 200
    private let coverArtPrefetchLimit = 200
    private let thumbnailCoverSize = 96
    private let gridCoverSize = 220
    private let interchangeableThumbnailSizes = [72, 80, 96]
    private var didAttemptInitialConnection = false
    private var artistFavoriteUpdatesInFlight = Set<String>()
    private var albumFavoriteUpdatesInFlight = Set<String>()
    private var songFavoriteUpdatesInFlight = Set<String>()

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
            do {
                try await refreshLibraryLists()
                statusMessage = "Connected to \(profile.displayName)"
            } catch {
                statusMessage = "Connected to \(profile.displayName), but favorites could not sync: \(error.localizedDescription)"
            }
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
        case .favorites:
            do {
                try await refreshFavorites()
            } catch {
                statusMessage = error.localizedDescription
            }
        case .recent:
            do {
                try await refreshRecentSongs()
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
            let results = try await client.searchSongs(matching: query)
            try cache(results)
            await warmCachedSongCovers(results)
            searchResults = results
            prefetchSongCovers(results)
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
            let songs = try await client.randomSongs()
            try cache(songs)
            await warmCachedSongCovers(songs)
            randomSongs = songs
            prefetchSongCovers(songs)
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
                await warmCachedAlbumCovers(newAlbums)
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
                await warmCachedArtistCovers(newArtists)
                artists = sortedVisibleArtists(loadedArtists)

                if offset == 0 {
                    prefetchArtistCovers(loadedArtists)
                }

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
            let albums = try await client.albums(for: artist)
            await warmCachedAlbumCovers(albums)
            artistAlbums = albums
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
            let songs = try await client.songs(for: album)
            try cache(songs)
            await warmCachedSongCovers(songs)
            albumSongs = songs
            guard !Task.isCancelled else { return }
            loadedAlbumSongsID = album.id
            prefetchSongCovers(songs)
            statusMessage = songs.isEmpty ? "No songs for \(album.name)." : "Loaded \(album.name)"
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
            let songs = try await client.songs(for: playlist)
            try cache(songs)
            await warmCachedSongCovers(songs)
            playlistSongs = songs
            guard !Task.isCancelled else { return }
            loadedPlaylistSongsID = playlist.id
            prefetchSongCovers(songs)
            statusMessage = songs.isEmpty ? "No songs for \(playlist.name)." : "Loaded \(playlist.name)"
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func play(_ song: NavidromeSong, in queue: [NavidromeSong]) {
        let shouldHydrateSong = selectedSection == .random
        Task {
            await play(song, in: queue, shouldHydrateSong: shouldHydrateSong)
        }
    }

    func play(_ album: NavidromeAlbum) {
        performQueueAction(.play) { client in
            try await client.songs(for: album)
        }
    }

    func play(_ artist: NavidromeArtist) {
        performQueueAction(.play) { client in
            try await self.songs(for: artist, using: client)
        }
    }

    func playNext(_ songs: [NavidromeSong]) {
        guard !songs.isEmpty else { return }

        guard let currentIndex = currentPlaybackQueueIndex else {
            play(songs[0], in: songs)
            return
        }

        playbackQueue.insert(contentsOf: songs, at: currentIndex + 1)
        updateNowPlayingQueueState()
        statusMessage = songs.count == 1 ? "Playing next" : "Playing next: \(songs.count) songs"
    }

    func playNext(_ album: NavidromeAlbum) {
        performQueueAction(.next) { client in
            try await client.songs(for: album)
        }
    }

    func playNext(_ artist: NavidromeArtist) {
        performQueueAction(.next) { client in
            try await self.songs(for: artist, using: client)
        }
    }

    func addToQueue(_ songs: [NavidromeSong]) {
        guard !songs.isEmpty else { return }
        playbackQueue.append(contentsOf: songs)
        updateNowPlayingQueueState()
        statusMessage = songs.count == 1 ? "Added to queue" : "Added \(songs.count) songs to queue"
    }

    func addToQueue(_ album: NavidromeAlbum) {
        performQueueAction(.end) { client in
            try await client.songs(for: album)
        }
    }

    func addToQueue(_ artist: NavidromeArtist) {
        performQueueAction(.end) { client in
            try await self.songs(for: artist, using: client)
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
            await warmCachedSongCovers([songToPlay])
            playbackQueue = queue.isEmpty ? [song] : queue
            playbackQueueIndex = playbackQueue.firstIndex(of: song)
            if lyricsSongID != songToPlay.id {
                lyricsSongID = nil
                currentLyrics = nil
                lyricsMessage = "No lyrics loaded."
            }
            updateNowPlayingQueueState()
            audioPlayer.play(song: songToPlay, url: url)
            updateNowPlayingArtwork(for: songToPlay)
            let queueToWarm = playbackQueue
            Task { [weak self] in
                guard let self else { return }
                await warmCachedSongCovers(queueToWarm)
                prefetchSongCovers(queueToWarm)
            }
            try store.markPlayed(songToPlay, serverKey: serverKey)
            try await refreshRecentSongs()
            statusMessage = "Playing \(songToPlay.title)"
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    private var currentPlaybackQueueIndex: Int? {
        guard let currentSong = audioPlayer.currentSong else { return nil }

        if let playbackQueueIndex,
           playbackQueue.indices.contains(playbackQueueIndex),
           playbackQueue[playbackQueueIndex].id == currentSong.id {
            return playbackQueueIndex
        }

        return playbackQueue.firstIndex { $0.id == currentSong.id }
    }

    private func performQueueAction(
        _ action: QueueAction,
        loadSongs: @escaping (NavidromeClient) async throws -> [NavidromeSong]
    ) {
        guard let client else {
            statusMessage = "Connect first."
            return
        }

        Task {
            isBusy = true
            defer { isBusy = false }

            do {
                let songs = try await loadSongs(client)
                guard !songs.isEmpty else {
                    statusMessage = "No songs found."
                    return
                }

                try cache(songs)
                await warmCachedSongCovers(songs)
                prefetchSongCovers(songs)

                switch action {
                case .play:
                    play(songs[0], in: songs)
                case .next:
                    playNext(songs)
                case .end:
                    addToQueue(songs)
                }
            } catch {
                statusMessage = error.localizedDescription
            }
        }
    }

    private func songs(for artist: NavidromeArtist, using client: NavidromeClient) async throws -> [NavidromeSong] {
        var songs: [NavidromeSong] = []
        for album in try await client.albums(for: artist) {
            try Task.checkCancellation()
            songs.append(contentsOf: try await client.songs(for: album))
        }
        return songs
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
        guard let coverArt = song.coverArt ?? song.albumId else { return nil }
        return coverArtResource(id: coverArt, size: size)
    }

    func coverArtResource(for album: NavidromeAlbum, size: Int = 96) -> CoverArtResource? {
        let coverArt = album.coverArt ?? album.id
        return coverArtResource(id: coverArt, size: size)
    }

    func coverArtResource(for artist: NavidromeArtist, size: Int = 160) -> CoverArtResource? {
        if let imageURL = artist.artistImageURL, let url = URL(string: imageURL) {
            return CoverArtResource(cacheKey: "\(serverKey ?? "server")|artist|\(artist.id)|\(size)|\(imageURL)", url: url)
        }

        return coverArtResource(id: artist.coverArt ?? artist.id, size: size)
    }

    func toggleFavorite(_ song: NavidromeSong) {
        guard let client, let serverKey, songFavoriteUpdatesInFlight.insert(song.id).inserted else { return }

        let wasFavorite = favoriteIDs.contains(song.id)
        let nextValue = !wasFavorite
        setFavoriteState(nextValue, for: song)

        Task { [weak self] in
            do {
                try await client.setStarred(nextValue, itemID: song.id)
            } catch {
                guard let self, self.serverKey == serverKey else { return }
                self.songFavoriteUpdatesInFlight.remove(song.id)
                self.setFavoriteState(wasFavorite, for: song)
                self.statusMessage = error.localizedDescription
                return
            }

            guard let self, self.serverKey == serverKey else { return }
            do {
                try await self.refreshFavorites()
                self.statusMessage = nextValue ? "Added to favorites" : "Removed from favorites"
            } catch {
                self.statusMessage = "Favorite updated in Navidrome, but could not refresh: \(error.localizedDescription)"
            }
            self.songFavoriteUpdatesInFlight.remove(song.id)
        }
    }

    func isFavorite(_ song: NavidromeSong) -> Bool {
        favoriteIDs.contains(song.id)
    }

    func toggleFavorite(_ album: NavidromeAlbum) {
        guard let client, let serverKey, albumFavoriteUpdatesInFlight.insert(album.id).inserted else { return }

        let wasFavorite = favoriteAlbumIDs.contains(album.id)
        let nextValue = !wasFavorite
        setFavoriteState(nextValue, for: album)

        Task { [weak self] in
            do {
                try await client.setStarred(nextValue, itemID: album.id)
            } catch {
                guard let self, self.serverKey == serverKey else { return }
                self.albumFavoriteUpdatesInFlight.remove(album.id)
                self.setFavoriteState(wasFavorite, for: album)
                self.statusMessage = error.localizedDescription
                return
            }

            guard let self, self.serverKey == serverKey else { return }
            do {
                try await self.refreshFavorites()
                self.statusMessage = nextValue ? "Added album to favorites" : "Removed album from favorites"
            } catch {
                self.statusMessage = "Favorite updated in Navidrome, but could not refresh: \(error.localizedDescription)"
            }
            self.albumFavoriteUpdatesInFlight.remove(album.id)
        }
    }

    func isFavorite(_ album: NavidromeAlbum) -> Bool {
        favoriteAlbumIDs.contains(album.id)
    }

    func toggleFavorite(_ artist: NavidromeArtist) {
        guard let client, let serverKey, artistFavoriteUpdatesInFlight.insert(artist.id).inserted else { return }

        let wasFavorite = favoriteArtistIDs.contains(artist.id)
        let nextValue = !wasFavorite
        setFavoriteState(nextValue, for: artist)

        Task { [weak self] in
            do {
                try await client.setStarred(nextValue, itemID: artist.id)
            } catch {
                guard let self, self.serverKey == serverKey else { return }
                self.artistFavoriteUpdatesInFlight.remove(artist.id)
                self.setFavoriteState(wasFavorite, for: artist)
                self.statusMessage = error.localizedDescription
                return
            }

            guard let self, self.serverKey == serverKey else { return }
            do {
                try await self.refreshFavorites()
                self.statusMessage = nextValue ? "Added artist to favorites" : "Removed artist from favorites"
            } catch {
                self.statusMessage = "Favorite updated in Navidrome, but could not refresh: \(error.localizedDescription)"
            }
            self.artistFavoriteUpdatesInFlight.remove(artist.id)
        }
    }

    func isFavorite(_ artist: NavidromeArtist) -> Bool {
        favoriteArtistIDs.contains(artist.id)
    }

    private func cache(_ songs: [NavidromeSong]) throws {
        guard let serverKey else { return }
        try store.upsertSongs(songs, serverKey: serverKey)
    }

    private func refreshLibraryLists() async throws {
        try await refreshFavorites()
        try await refreshRecentSongs()
    }

    private func refreshFavorites() async throws {
        guard let client, let serverKey else { return }
        let starredItems = try await client.starredItems()
        let loadedFavoriteArtists = starredItems.artists
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        let loadedFavoriteAlbums = starredItems.albums
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        let loadedFavoriteSongs = starredItems.songs
            .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        try store.upsertSongs(loadedFavoriteSongs, serverKey: serverKey)
        await warmCachedArtistCovers(loadedFavoriteArtists)
        await warmCachedAlbumCovers(loadedFavoriteAlbums)
        await warmCachedSongCovers(loadedFavoriteSongs)
        guard self.serverKey == serverKey else { return }
        favoriteArtistIDs = Set(loadedFavoriteArtists.map(\.id))
        favoriteArtists = loadedFavoriteArtists
        favoriteAlbumIDs = Set(loadedFavoriteAlbums.map(\.id))
        favoriteAlbums = loadedFavoriteAlbums
        favoriteIDs = Set(loadedFavoriteSongs.map(\.id))
        favoriteSongs = loadedFavoriteSongs
        prefetchArtistCovers(loadedFavoriteArtists)
        prefetchAlbumCovers(loadedFavoriteAlbums)
        prefetchSongCovers(loadedFavoriteSongs)
    }

    private func refreshRecentSongs() async throws {
        guard let serverKey else { return }
        let loadedRecentSongs = try store.recentSongs(serverKey: serverKey)
        await warmCachedSongCovers(loadedRecentSongs)
        guard self.serverKey == serverKey else { return }
        recentSongs = loadedRecentSongs
        prefetchSongCovers(loadedRecentSongs)
    }

    private func setFavoriteState(_ isFavorite: Bool, for song: NavidromeSong) {
        if isFavorite {
            favoriteIDs.insert(song.id)
            if !favoriteSongs.contains(where: { $0.id == song.id }) {
                favoriteSongs.append(song)
                favoriteSongs.sort { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
            }
        } else {
            favoriteIDs.remove(song.id)
            favoriteSongs.removeAll { $0.id == song.id }
        }
    }

    private func setFavoriteState(_ isFavorite: Bool, for album: NavidromeAlbum) {
        if isFavorite {
            favoriteAlbumIDs.insert(album.id)
            if !favoriteAlbums.contains(where: { $0.id == album.id }) {
                favoriteAlbums.append(album)
                favoriteAlbums.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            }
        } else {
            favoriteAlbumIDs.remove(album.id)
            favoriteAlbums.removeAll { $0.id == album.id }
        }
    }

    private func setFavoriteState(_ isFavorite: Bool, for artist: NavidromeArtist) {
        if isFavorite {
            favoriteArtistIDs.insert(artist.id)
            if !favoriteArtists.contains(where: { $0.id == artist.id }) {
                favoriteArtists.append(artist)
                favoriteArtists.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            }
        } else {
            favoriteArtistIDs.remove(artist.id)
            favoriteArtists.removeAll { $0.id == artist.id }
        }
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
        favoriteArtists = []
        favoriteAlbums = []
        favoriteSongs = []
        recentSongs = []
        favoriteArtistIDs = []
        favoriteAlbumIDs = []
        favoriteIDs = []
        artistFavoriteUpdatesInFlight = []
        albumFavoriteUpdatesInFlight = []
        songFavoriteUpdatesInFlight = []
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
        let cacheKey = "\(serverKey)|\(id)|\(size)"
        let fallbackCacheKeys: [String]

        if interchangeableThumbnailSizes.contains(size) {
            fallbackCacheKeys = interchangeableThumbnailSizes
                .filter { $0 != size }
                .map { "\(serverKey)|\(id)|\($0)" }
        } else {
            fallbackCacheKeys = []
        }

        return CoverArtResource(
            cacheKey: cacheKey,
            url: url,
            fallbackCacheKeys: fallbackCacheKeys
        )
    }

    private func warmCachedAlbumCovers(_ albums: [NavidromeAlbum]) async {
        let resources = albums.compactMap { coverArtResource(for: $0, size: gridCoverSize) }
        await CoverArtCache.shared.warmCachedImages(resources)
    }

    private func warmCachedArtistCovers(_ artists: [NavidromeArtist]) async {
        let resources = artists.compactMap { coverArtResource(for: $0, size: gridCoverSize) }
        await CoverArtCache.shared.warmCachedImages(resources)
    }

    private func warmCachedSongCovers(_ songs: [NavidromeSong]) async {
        let resources = songs.compactMap { coverArtResource(for: $0, size: thumbnailCoverSize) }
        await CoverArtCache.shared.warmCachedImages(resources)
    }

    private func prefetchAlbumCovers(_ albums: [NavidromeAlbum]) {
        let resources = albums.prefix(coverArtPrefetchLimit).compactMap { coverArtResource(for: $0, size: gridCoverSize) }
        albumCoverPrefetchTask?.cancel()
        albumCoverPrefetchTask = prefetchCoverArt(resources)
    }

    private func prefetchArtistCovers(_ artists: [NavidromeArtist]) {
        let resources = artists.prefix(coverArtPrefetchLimit).compactMap { coverArtResource(for: $0, size: gridCoverSize) }
        artistCoverPrefetchTask?.cancel()
        artistCoverPrefetchTask = prefetchCoverArt(resources)
    }

    private func prefetchSongCovers(_ songs: [NavidromeSong]) {
        let songsToPrefetch = songs.prefix(coverArtPrefetchLimit)
        let resources = songsToPrefetch.compactMap { coverArtResource(for: $0, size: thumbnailCoverSize) }
        songCoverPrefetchTask?.cancel()
        songCoverPrefetchTask = prefetchCoverArt(resources)
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

private enum QueueAction {
    case play
    case next
    case end
}
