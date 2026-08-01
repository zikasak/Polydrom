//
//  AppCoordinator.swift
//  PolyDrom
//
//  Created by zikasak on 07/07/2026.
//

import Combine
import Foundation

@MainActor
final class AppCoordinator: ObservableObject {
    @Published var serverAddress = ""
    @Published var username = ""
    @Published var password = ""
    @Published var servers: [ServerProfile] = []
    @Published var activeServer: ServerProfile?
    @Published var selectedSection: LibrarySection = .home
    @Published var statusMessage = "Disconnected"
    @Published var isBusy = false
    @Published var isOnline = false
    @Published var hasCachedLibrary = false
    @Published var isRefreshingMetadata = false
    @Published var isClearingCache = false
    @Published var lastMetadataCheckAt: Date?
    @Published var metadataRefreshInterval: MetadataRefreshInterval {
        didSet {
            guard metadataRefreshInterval != oldValue else { return }
            userDefaults.set(metadataRefreshInterval.rawValue, forKey: Self.metadataRefreshIntervalKey)
            restartMetadataMonitor(refreshImmediately: false)
        }
    }
    @Published var searchText = ""
    @Published var searchResults: [NavidromeSong] = []
    @Published var randomSongs: [NavidromeSong] = []
    @Published var recentlyAddedAlbums: [NavidromeAlbum] = []
    @Published var recentlyPlayedAlbums: [NavidromeAlbum] = []
    @Published var homeRandomAlbums: [NavidromeAlbum] = []
    @Published var featuredAlbums: [NavidromeAlbum] = []
    @Published var albums: [NavidromeAlbum] = []
    @Published var artists: [NavidromeArtist] = []
    @Published var artistAlbums: [NavidromeAlbum] = []
    @Published var selectedArtist: NavidromeArtist?
    @Published var selectedAlbum: NavidromeAlbum?
    @Published var albumSongs: [NavidromeSong] = []
    @Published var playlists: [NavidromePlaylist] = []
    @Published var selectedPlaylist: NavidromePlaylist?
    @Published var playlistSongs: [NavidromeSong] = []
    @Published var playlistCreationRequest: PlaylistCreationRequest?
    @Published var isPlaylistMutating = false
    @Published var favoriteArtists: [NavidromeArtist] = []
    @Published var favoriteAlbums: [NavidromeAlbum] = []
    @Published var favoriteSongs: [NavidromeSong] = []
    @Published var recentSongs: [NavidromeSong] = []
    @Published var favoriteArtistIDs: Set<String> = []
    @Published var favoriteAlbumIDs: Set<String> = []
    @Published var favoriteIDs: Set<String> = []
    @Published var playbackQueue: [PlaybackQueueEntry] = []
    @Published var currentPlaybackQueueEntryID: UUID?
    @Published var currentLyrics: SongLyrics?
    @Published var lyricsMessage = "No lyrics loaded."
    @Published var isLoadingLyrics = false

    let audioPlayer: AudioPlayer

    let store: LibraryStore
    private let serverRegistry: ServerRegistry
    private let clientFactory: @MainActor (ServerProfile) -> NavidromeClient?
    private let coverArtCache: CoverArtCache
    private let syncCoordinator: LibrarySyncCoordinator
    private let userDefaults: UserDefaults
    var client: NavidromeClient?
    private var metadataMonitorTask: Task<Void, Never>?
    private var metadataSyncTask: Task<MetadataSyncOutcome, Error>?
    private var metadataRefreshID: UUID?
    private var scanRetryTask: Task<Void, Never>?
    private var isApplicationActive = false
    private var lyricsSongID: String?
    private var albumCoverPrefetchTask: Task<Void, Never>?
    private var artistCoverPrefetchTask: Task<Void, Never>?
    private var songCoverPrefetchTask: Task<Void, Never>?
    private var nowPlayingArtworkTask: Task<Void, Never>?
    private var loadedArtistAlbumsID: String?
    private var loadedAlbumSongsID: String?
    var loadedPlaylistSongsID: String?
    private let coverArtPrefetchLimit = 200
    private let thumbnailCoverSize = 96
    private let gridCoverSize = 220
    private let interchangeableThumbnailSizes = [72, 80, 96]
    private var didAttemptInitialConnection = false
    private var didRequestFirstRunSettings = false
    private var hasLoadedHome = false
    var sessionGeneration: UInt = 0
    private var artistFavoriteUpdatesInFlight = Set<String>()
    private var albumFavoriteUpdatesInFlight = Set<String>()
    private var songFavoriteUpdatesInFlight = Set<String>()
    private static let metadataRefreshIntervalKey = "metadataRefreshInterval"

    var isConnected: Bool {
        activeServer != nil && isOnline
    }

    var canBrowseLibrary: Bool {
        activeServer != nil && (isOnline || hasCachedLibrary)
    }

    var canClearCache: Bool {
        !isBusy && !isRefreshingMetadata && !isClearingCache
    }

    var canConnectFromForm: Bool {
        !isBusy
            && !serverAddress.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var serverKey: String? {
        activeServer?.serverKey
    }

    var canCreatePlaylist: Bool {
        isOnline && !isPlaylistMutating
    }

    var editablePlaylists: [NavidromePlaylist] {
        playlists.filter(canEdit)
    }

    init(
        store: LibraryStore = LibraryStore(),
        audioPlayer: AudioPlayer = AudioPlayer(),
        clientFactory: @escaping @MainActor (ServerProfile) -> NavidromeClient? = { NavidromeClient(profile: $0) },
        coverArtCache: CoverArtCache = .shared,
        serverRegistry: ServerRegistry? = nil,
        userDefaults: UserDefaults = .standard
    ) {
        self.store = store
        let suppliedRegistry = serverRegistry
        self.serverRegistry = suppliedRegistry ?? ServerRegistry()
        self.audioPlayer = audioPlayer
        self.clientFactory = clientFactory
        self.coverArtCache = coverArtCache
        self.syncCoordinator = LibrarySyncCoordinator(store: store)
        self.userDefaults = userDefaults
        if userDefaults.object(forKey: Self.metadataRefreshIntervalKey) == nil {
            self.metadataRefreshInterval = .fifteenMinutes
        } else {
            self.metadataRefreshInterval = MetadataRefreshInterval(
                rawValue: userDefaults.integer(forKey: Self.metadataRefreshIntervalKey)
            ) ?? .fifteenMinutes
        }
        if suppliedRegistry == nil,
           let legacyStoreURL = PersistenceController.legacyStoreURL,
           FileManager.default.fileExists(atPath: legacyStoreURL.path) {
            let legacyStore = LibraryStore(
                persistence: PersistenceController(
                    storeURL: legacyStoreURL,
                    recoverDisposableCache: false
                ),
                keychain: KeychainStore()
            )
            try? self.serverRegistry.importLegacyServersIfNeeded(from: legacyStore)
        } else {
            try? self.serverRegistry.importLegacyServersIfNeeded(from: store)
        }
        configureAudioPlayer()
        loadServers()
        if let initializationError = store.initializationError {
            statusMessage = initializationError.localizedDescription
        }
    }

    func loadServers() {
        do {
            try serverRegistry.importLegacyServersIfNeeded(from: store)
            servers = try serverRegistry.servers()
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
            let profile = try serverRegistry.save(address: serverAddress, username: username, password: password)
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

    func takeFirstRunSettingsPresentationRequest() -> Bool {
        guard servers.isEmpty, !didRequestFirstRunSettings else { return false }
        didRequestFirstRunSettings = true
        return true
    }

    func connect(_ profile: ServerProfile) async {
        guard let nextClient = clientFactory(profile) else {
            statusMessage = "Enter a valid server address."
            return
        }

        sessionGeneration &+= 1
        let generation = sessionGeneration
        let previousServerKey = activeServer?.serverKey
        cancelMetadataRefresh()
        scanRetryTask?.cancel()
        if previousServerKey != profile.serverKey {
            clearRemoteLibraryState()
        }
        activeServer = profile
        client = nextClient
        isOnline = false
        serverAddress = profile.address
        username = profile.username
        password = profile.password
        await reloadCachedLibrary(for: generation)

        isBusy = true
        defer { isBusy = false }

        do {
            try await nextClient.ping()
            guard isCurrentSession(generation, serverKey: profile.serverKey) else { return }
            isOnline = true
            try serverRegistry.touch(profile)
            loadServers()
            await refreshMetadata(for: generation)
        } catch {
            guard isCurrentSession(generation, serverKey: profile.serverKey) else { return }
            isOnline = false
            statusMessage = hasCachedLibrary
                ? "Offline — showing cached library. \(error.localizedDescription)"
                : error.localizedDescription
        }
    }

    func deleteServer(_ profile: ServerProfile) {
        let refreshToDrain: Task<MetadataSyncOutcome, Error>?
        if activeServer?.id == profile.id {
            sessionGeneration &+= 1
            refreshToDrain = metadataSyncTask
            metadataMonitorTask?.cancel()
            cancelMetadataRefresh()
            scanRetryTask?.cancel()
        } else {
            refreshToDrain = nil
        }

        do {
            try serverRegistry.delete(profile)
            try store.purgeLibrary(serverKey: profile.serverKey)
            if activeServer?.id == profile.id {
                activeServer = nil
                client = nil
                isOnline = false
                hasCachedLibrary = false
                audioPlayer.stop()
                clearRemoteLibraryState()
            }
            loadServers()
            if let refreshToDrain {
                Task { [weak self] in
                    _ = try? await refreshToDrain.value
                    guard let self else { return }
                    // A background reconciliation that was already committing
                    // when cancellation arrived must not recreate this profile's cache.
                    try? self.store.purgeLibrary(serverKey: profile.serverKey)
                    self.loadServers()
                }
            }
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func clearLibraryCache() {
        guard canClearCache else { return }

        isClearingCache = true
        defer { isClearingCache = false }
        sessionGeneration &+= 1
        cancelMetadataRefresh()
        scanRetryTask?.cancel()
        scanRetryTask = nil

        do {
            try store.purgeAllLibraryCache()
            clearRemoteLibraryState()
            statusMessage = "Library cache cleared. Refresh metadata to rebuild it."
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func clearCoverArtCache() async {
        guard canClearCache else { return }

        isClearingCache = true
        defer { isClearingCache = false }
        cancelCoverArtPrefetchTasks()
        nowPlayingArtworkTask?.cancel()

        do {
            try await coverArtCache.clear()
            statusMessage = "Cover art cache cleared."
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func selectSection(_ section: LibrarySection) {
        selectedSection = section
        Task { await refreshSelectedSection() }
    }

    func refreshSelectedSection(force: Bool = false) async {
        guard canBrowseLibrary else { return }

        switch selectedSection {
        case .home:
            if force || !hasLoadedHome {
                await loadHome()
            }
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

    func loadHome() async {
        let generation = sessionGeneration
        guard let serverKey else { return }
        isBusy = true
        defer { isBusy = false }

        do {
            let home = try await store.homeMetadata(serverKey: serverKey)
            let allAlbums = home.recentlyAdded + home.recentlyPlayed + home.random + home.featured
            await warmCachedAlbumCovers(allAlbums)
            guard !Task.isCancelled, isCurrentSession(generation, serverKey: serverKey) else { return }

            recentlyAddedAlbums = home.recentlyAdded
            recentlyPlayedAlbums = home.recentlyPlayed
            homeRandomAlbums = home.random
            featuredAlbums = home.featured
            hasLoadedHome = true
            prefetchAlbumCovers(allAlbums)
            if allAlbums.isEmpty {
                statusMessage = "No cached albums for Home."
            }
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func playRandomSongs(count: Int? = nil) async {
        guard let serverKey else {
            statusMessage = "Select a library first."
            return
        }

        isBusy = true
        defer { isBusy = false }

        do {
            let songs = try await store.randomSongs(serverKey: serverKey, count: count)
            guard !songs.isEmpty else {
                statusMessage = "No cached songs available."
                return
            }

            await warmCachedSongCovers(songs)
            prefetchSongCovers(songs)
            play(songs, startingAt: 0)
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func search() async {
        let generation = sessionGeneration
        guard let serverKey else {
            statusMessage = "Select a library first."
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
            let results = try await store.searchSongs(query, serverKey: serverKey)
            await warmCachedSongCovers(results)
            guard isCurrentSession(generation, serverKey: serverKey) else { return }
            searchResults = results
            prefetchSongCovers(results)
            statusMessage = searchResults.isEmpty ? "No songs found." : "\(searchResults.count) songs found"
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func loadRandomSongs() async {
        let generation = sessionGeneration
        guard let serverKey else { return }
        isBusy = true
        defer { isBusy = false }

        do {
            let songs = try await store.randomSongs(serverKey: serverKey, count: 50)
            await warmCachedSongCovers(songs)
            guard isCurrentSession(generation, serverKey: serverKey) else { return }
            randomSongs = songs
            prefetchSongCovers(songs)
            statusMessage = randomSongs.isEmpty ? "No random songs returned." : "Loaded random songs"
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func loadAlbums() async {
        let generation = sessionGeneration
        guard let serverKey else { return }
        isBusy = true
        defer { isBusy = false }

        do {
            let loadedAlbums = try await store.albums(serverKey: serverKey)
            await warmCachedAlbumCovers(loadedAlbums)
            guard isCurrentSession(generation, serverKey: serverKey) else { return }
            albums = loadedAlbums
            prefetchAlbumCovers(loadedAlbums)
            statusMessage = loadedAlbums.isEmpty ? "No cached albums." : "Loaded \(loadedAlbums.count) albums"
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func loadArtists() async {
        let generation = sessionGeneration
        guard let serverKey else { return }
        isBusy = true
        defer { isBusy = false }

        do {
            let loadedArtists = try await store.artists(serverKey: serverKey)
            await warmCachedArtistCovers(loadedArtists)
            guard isCurrentSession(generation, serverKey: serverKey) else { return }
            artists = sortedVisibleArtists(loadedArtists)
            prefetchArtistCovers(loadedArtists)
            statusMessage = artists.isEmpty ? "No cached artists." : "Loaded \(artists.count) artists"
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func loadPlaylists() async {
        let generation = sessionGeneration
        guard let serverKey else { return }
        isBusy = true
        defer { isBusy = false }

        do {
            let loadedPlaylists = try await store.playlists(serverKey: serverKey)
            guard isCurrentSession(generation, serverKey: serverKey) else { return }
            playlists = loadedPlaylists
            statusMessage = playlists.isEmpty ? "No cached playlists." : "Loaded playlists"
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func loadAlbums(for artist: NavidromeArtist, force: Bool = false) async {
        let generation = sessionGeneration
        guard let serverKey else { return }
        if !force, loadedArtistAlbumsID == artist.id {
            if selectedArtist?.id != artist.id {
                selectedArtist = artist
            }
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
            let albums = try await store.albums(serverKey: serverKey, artistID: artist.id)
            await warmCachedAlbumCovers(albums)
            artistAlbums = albums
            guard !Task.isCancelled, isCurrentSession(generation, serverKey: serverKey) else { return }
            loadedArtistAlbumsID = artist.id
            prefetchAlbumCovers(artistAlbums)
            statusMessage = artistAlbums.isEmpty ? "No albums for \(artist.name)." : "Loaded \(artist.name)"
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func loadSongs(for album: NavidromeAlbum, force: Bool = false) async {
        let generation = sessionGeneration
        guard let serverKey else { return }
        if !force, loadedAlbumSongsID == album.id {
            if selectedAlbum?.id != album.id {
                selectedAlbum = album
            }
            return
        }

        selectedAlbum = album
        albumSongs = []
        loadedAlbumSongsID = nil
        isBusy = true
        defer { isBusy = false }

        do {
            let songs = try await store.songs(serverKey: serverKey, albumID: album.id)
            await warmCachedSongCovers(songs)
            albumSongs = songs
            guard !Task.isCancelled, isCurrentSession(generation, serverKey: serverKey) else { return }
            loadedAlbumSongsID = album.id
            prefetchSongCovers(songs)
            statusMessage = songs.isEmpty ? "No songs for \(album.name)." : "Loaded \(album.name)"
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func loadSongs(for playlist: NavidromePlaylist, force: Bool = false) async {
        let generation = sessionGeneration
        guard let serverKey else { return }
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
            let songs = try await store.songs(serverKey: serverKey, playlistID: playlist.id)
            await warmCachedSongCovers(songs)
            playlistSongs = songs
            guard !Task.isCancelled, isCurrentSession(generation, serverKey: serverKey) else { return }
            loadedPlaylistSongsID = playlist.id
            prefetchSongCovers(songs)
            statusMessage = songs.isEmpty ? "No songs for \(playlist.name)." : "Loaded \(playlist.name)"
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func play(_ songs: [NavidromeSong], startingAt index: Int) {
        guard songs.indices.contains(index) else { return }

        let queue = songs.map { PlaybackQueueEntry(song: $0) }
        let shouldHydrateSong = selectedSection == .random
        Task {
            await play(queue[index], replacingQueueWith: queue, shouldHydrateSong: shouldHydrateSong)
        }
    }

    func play(_ entry: PlaybackQueueEntry) {
        let shouldHydrateSong = selectedSection == .random
        Task {
            await play(entry, shouldHydrateSong: shouldHydrateSong)
        }
    }

    func play(_ album: NavidromeAlbum) {
        performQueueAction(.play) {
            guard let serverKey = self.serverKey else { return [] }
            return try await self.store.songs(serverKey: serverKey, albumID: album.id)
        }
    }

    func play(_ artist: NavidromeArtist) {
        performQueueAction(.play) {
            try await self.cachedSongs(for: artist)
        }
    }

    func playNext(_ songs: [NavidromeSong]) {
        guard !songs.isEmpty else { return }

        guard let currentIndex = currentPlaybackQueueIndex else {
            play(songs, startingAt: 0)
            return
        }

        playbackQueue.insert(contentsOf: songs.map { PlaybackQueueEntry(song: $0) }, at: currentIndex + 1)
        updateNowPlayingQueueState()
        statusMessage = songs.count == 1 ? "Playing next" : "Playing next: \(songs.count) songs"
    }

    func playNext(_ album: NavidromeAlbum) {
        performQueueAction(.next) {
            guard let serverKey = self.serverKey else { return [] }
            return try await self.store.songs(serverKey: serverKey, albumID: album.id)
        }
    }

    func playNext(_ artist: NavidromeArtist) {
        performQueueAction(.next) {
            try await self.cachedSongs(for: artist)
        }
    }

    func addToQueue(_ songs: [NavidromeSong]) {
        guard !songs.isEmpty else { return }
        playbackQueue.append(contentsOf: songs.map { PlaybackQueueEntry(song: $0) })
        updateNowPlayingQueueState()
        statusMessage = songs.count == 1 ? "Added to queue" : "Added \(songs.count) songs to queue"
    }

    func addToQueue(_ album: NavidromeAlbum) {
        performQueueAction(.end) {
            guard let serverKey = self.serverKey else { return [] }
            return try await self.store.songs(serverKey: serverKey, albumID: album.id)
        }
    }

    func addToQueue(_ artist: NavidromeArtist) {
        performQueueAction(.end) {
            try await self.cachedSongs(for: artist)
        }
    }

    private func play(
        _ entry: PlaybackQueueEntry,
        replacingQueueWith queue: [PlaybackQueueEntry]? = nil,
        shouldHydrateSong: Bool
    ) async {
        guard isOnline, let client, let serverKey else {
            statusMessage = "Connect to the server to play music."
            return
        }

        do {
            let songToPlay = try await resolvedSongForPlayback(entry.song, shouldHydrateSong: shouldHydrateSong)
            let url = try client.streamURL(for: songToPlay)
            await warmCachedSongCovers([songToPlay])

            if var queue {
                guard let index = queue.firstIndex(where: { $0.id == entry.id }) else { return }
                queue[index].song = songToPlay
                playbackQueue = queue
            } else {
                guard let index = playbackQueue.firstIndex(where: { $0.id == entry.id }) else { return }
                playbackQueue[index].song = songToPlay
            }
            currentPlaybackQueueEntryID = entry.id
            if lyricsSongID != songToPlay.id {
                lyricsSongID = nil
                currentLyrics = nil
                lyricsMessage = "No lyrics loaded."
            }
            updateNowPlayingQueueState()
            audioPlayer.play(song: songToPlay, url: url)
            updateNowPlayingArtwork(for: songToPlay)
            let queueToWarm = playbackQueue.map(\.song)
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
        guard audioPlayer.currentSong != nil, let currentPlaybackQueueEntryID else { return nil }
        return playbackQueue.firstIndex { $0.id == currentPlaybackQueueEntryID }
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
                statusMessage = error.localizedDescription
            }
        }
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

    func playPreviousTrack() {
        guard let currentIndex = currentPlaybackQueueIndex,
              playbackQueue.indices.contains(currentIndex - 1) else { return }
        let entry = playbackQueue[currentIndex - 1]
        Task {
            await play(entry, shouldHydrateSong: false)
        }
    }

    func playNextTrack() {
        guard let currentIndex = currentPlaybackQueueIndex,
              playbackQueue.indices.contains(currentIndex + 1) else { return }
        let entry = playbackQueue[currentIndex + 1]
        Task {
            await play(entry, shouldHydrateSong: false)
        }
    }

    func canPlayPreviousTrack() -> Bool {
        guard isOnline else { return false }
        guard let currentIndex = currentPlaybackQueueIndex else { return false }
        return playbackQueue.indices.contains(currentIndex - 1)
    }

    func canPlayNextTrack() -> Bool {
        guard isOnline else { return false }
        guard let currentIndex = currentPlaybackQueueIndex else { return false }
        return playbackQueue.indices.contains(currentIndex + 1)
    }

    func loadLyrics(for song: NavidromeSong, force: Bool = false) async {
        let generation = sessionGeneration
        guard isOnline, let client, let serverKey else {
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
            guard lyricsSongID == song.id, isCurrentSession(generation, serverKey: serverKey) else { return }
            currentLyrics = availableLyrics.first(where: \.synced) ?? availableLyrics.first
            lyricsMessage = currentLyrics == nil ? "No lyrics are available for this song." : ""
        } catch {
            guard lyricsSongID == song.id, isCurrentSession(generation, serverKey: serverKey) else { return }
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
        guard isOnline, let client, let serverKey, songFavoriteUpdatesInFlight.insert(song.id).inserted else {
            if !isOnline { statusMessage = "Connect to the server to update favorites." }
            return
        }

        let wasFavorite = favoriteIDs.contains(song.id)
        let nextValue = !wasFavorite
        let generation = sessionGeneration
        setFavoriteState(nextValue, for: song)

        Task { [weak self] in
            do {
                try await client.setStarred(nextValue, itemID: song.id)
            } catch {
                guard let self, self.isCurrentSession(generation, serverKey: serverKey) else { return }
                self.songFavoriteUpdatesInFlight.remove(song.id)
                self.setFavoriteState(wasFavorite, for: song)
                self.statusMessage = error.localizedDescription
                return
            }

            guard let self, self.isCurrentSession(generation, serverKey: serverKey) else { return }
            do {
                try await self.store.setFavorite(nextValue, songID: song.id, serverKey: serverKey)
                try await self.loadCachedFavorites()
                self.statusMessage = nextValue ? "Added to favorites" : "Removed from favorites"
            } catch {
                self.statusMessage = "Favorite updated in Navidrome, but could not cache it: \(error.localizedDescription)"
            }
            self.songFavoriteUpdatesInFlight.remove(song.id)
        }
    }

    func isFavorite(_ song: NavidromeSong) -> Bool {
        favoriteIDs.contains(song.id)
    }

    func toggleFavorite(_ album: NavidromeAlbum) {
        guard isOnline, let client, let serverKey, albumFavoriteUpdatesInFlight.insert(album.id).inserted else {
            if !isOnline { statusMessage = "Connect to the server to update favorites." }
            return
        }

        let wasFavorite = favoriteAlbumIDs.contains(album.id)
        let nextValue = !wasFavorite
        let generation = sessionGeneration
        setFavoriteState(nextValue, for: album)

        Task { [weak self] in
            do {
                try await client.setStarred(nextValue, itemID: album.id)
            } catch {
                guard let self, self.isCurrentSession(generation, serverKey: serverKey) else { return }
                self.albumFavoriteUpdatesInFlight.remove(album.id)
                self.setFavoriteState(wasFavorite, for: album)
                self.statusMessage = error.localizedDescription
                return
            }

            guard let self, self.isCurrentSession(generation, serverKey: serverKey) else { return }
            do {
                try await self.store.setFavorite(nextValue, albumID: album.id, serverKey: serverKey)
                try await self.loadCachedFavorites()
                self.statusMessage = nextValue ? "Added album to favorites" : "Removed album from favorites"
            } catch {
                self.statusMessage = "Favorite updated in Navidrome, but could not cache it: \(error.localizedDescription)"
            }
            self.albumFavoriteUpdatesInFlight.remove(album.id)
        }
    }

    func isFavorite(_ album: NavidromeAlbum) -> Bool {
        favoriteAlbumIDs.contains(album.id)
    }

    func toggleFavorite(_ artist: NavidromeArtist) {
        guard isOnline, let client, let serverKey, artistFavoriteUpdatesInFlight.insert(artist.id).inserted else {
            if !isOnline { statusMessage = "Connect to the server to update favorites." }
            return
        }

        let wasFavorite = favoriteArtistIDs.contains(artist.id)
        let nextValue = !wasFavorite
        let generation = sessionGeneration
        setFavoriteState(nextValue, for: artist)

        Task { [weak self] in
            do {
                try await client.setStarred(nextValue, itemID: artist.id)
            } catch {
                guard let self, self.isCurrentSession(generation, serverKey: serverKey) else { return }
                self.artistFavoriteUpdatesInFlight.remove(artist.id)
                self.setFavoriteState(wasFavorite, for: artist)
                self.statusMessage = error.localizedDescription
                return
            }

            guard let self, self.isCurrentSession(generation, serverKey: serverKey) else { return }
            do {
                try await self.store.setFavorite(nextValue, artistID: artist.id, serverKey: serverKey)
                try await self.loadCachedFavorites()
                self.statusMessage = nextValue ? "Added artist to favorites" : "Removed artist from favorites"
            } catch {
                self.statusMessage = "Favorite updated in Navidrome, but could not cache it: \(error.localizedDescription)"
            }
            self.artistFavoriteUpdatesInFlight.remove(artist.id)
        }
    }

    func isFavorite(_ artist: NavidromeArtist) -> Bool {
        favoriteArtistIDs.contains(artist.id)
    }

    func albumForNavigation(from song: NavidromeSong) -> NavidromeAlbum? {
        guard let fallback = NavidromeAlbum(song: song) else { return nil }

        if let selectedAlbum, selectedAlbum.id == fallback.id {
            return selectedAlbum
        }

        return artistAlbums.first { $0.id == fallback.id }
            ?? albums.first { $0.id == fallback.id }
            ?? recentlyAddedAlbums.first { $0.id == fallback.id }
            ?? recentlyPlayedAlbums.first { $0.id == fallback.id }
            ?? homeRandomAlbums.first { $0.id == fallback.id }
            ?? featuredAlbums.first { $0.id == fallback.id }
            ?? favoriteAlbums.first { $0.id == fallback.id }
            ?? fallback
    }

    func artistForNavigation(from song: NavidromeSong) -> NavidromeArtist? {
        guard let fallback = NavidromeArtist(song: song) else { return nil }

        if let selectedArtist, selectedArtist.id == fallback.id {
            return selectedArtist
        }

        return artists.first { $0.id == fallback.id }
            ?? favoriteArtists.first { $0.id == fallback.id }
            ?? fallback
    }

    private func refreshFavorites() async throws {
        try await loadCachedFavorites()
    }

    private func loadCachedFavorites() async throws {
        let generation = sessionGeneration
        guard let serverKey else { return }
        async let artistsRequest = store.favoriteArtists(serverKey: serverKey)
        async let albumsRequest = store.favoriteAlbums(serverKey: serverKey)
        async let songsRequest = store.favoriteSongs(serverKey: serverKey)
        let (loadedFavoriteArtists, loadedFavoriteAlbums, loadedFavoriteSongs) = try await (
            artistsRequest,
            albumsRequest,
            songsRequest
        )
        await warmCachedArtistCovers(loadedFavoriteArtists)
        await warmCachedAlbumCovers(loadedFavoriteAlbums)
        await warmCachedSongCovers(loadedFavoriteSongs)
        guard isCurrentSession(generation, serverKey: serverKey) else { return }
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
        let generation = sessionGeneration
        guard let serverKey else { return }
        let loadedRecentSongs = try await store.recentSongsAsync(serverKey: serverKey)
        await warmCachedSongCovers(loadedRecentSongs)
        guard isCurrentSession(generation, serverKey: serverKey) else { return }
        recentSongs = loadedRecentSongs
        prefetchSongCovers(loadedRecentSongs)
    }

    func refreshMetadata(for requestedGeneration: UInt? = nil) async {
        let generation = requestedGeneration ?? sessionGeneration
        guard generation == sessionGeneration, metadataRefreshID == nil, let client, let serverKey else { return }
        let wasOnline = isOnline
        let refreshID = UUID()
        metadataRefreshID = refreshID
        isRefreshingMetadata = true
        defer {
            if metadataRefreshID == refreshID {
                metadataRefreshID = nil
                metadataSyncTask = nil
                isRefreshingMetadata = false
            }
        }

        do {
            if !isOnline {
                try await client.ping()
                guard isCurrentSession(generation, serverKey: serverKey) else { return }
                isOnline = true
            }

            statusMessage = hasCachedLibrary
                ? "Checking library metadata…"
                : "Building local metadata cache…"
            let syncTask = Task {
                try await syncCoordinator.synchronize(client: client, serverKey: serverKey)
            }
            metadataSyncTask = syncTask
            let outcome = try await syncTask.value
            guard isCurrentSession(generation, serverKey: serverKey) else { return }
            switch outcome {
            case .full:
                await reloadCachedLibrary(for: generation)
                statusMessage = metadataCompletionMessage(prefix: "Library metadata updated")
            case .metadataOnly:
                await reloadCachedLibrary(for: generation)
                statusMessage = metadataCompletionMessage(prefix: "Library metadata is up to date")
            case .deferredForScan:
                statusMessage = "Navidrome is scanning. Refresh will retry shortly."
                scheduleScanRetry(serverKey: serverKey, generation: generation)
            }
        } catch is CancellationError {
            return
        } catch {
            guard isCurrentSession(generation, serverKey: serverKey) else { return }
            if !wasOnline || error is URLError {
                isOnline = false
            }
            statusMessage = hasCachedLibrary
                ? "Refresh failed — showing cached library. \(error.localizedDescription)"
                : error.localizedDescription
        }
    }

    func setApplicationActive(_ isActive: Bool) {
        isApplicationActive = isActive
        metadataMonitorTask?.cancel()
        metadataMonitorTask = nil
        if !isActive {
            scanRetryTask?.cancel()
            cancelMetadataRefresh()
            return
        }

        restartMetadataMonitor(refreshImmediately: true)
    }

    private func restartMetadataMonitor(refreshImmediately: Bool) {
        metadataMonitorTask?.cancel()
        metadataMonitorTask = nil
        guard isApplicationActive, let refreshIntervalSeconds = metadataRefreshInterval.seconds else { return }

        metadataMonitorTask = Task { [weak self] in
            guard let self else { return }
            if refreshImmediately {
                await refreshMetadata()
            }
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(refreshIntervalSeconds))
                } catch {
                    return
                }
                await refreshMetadata()
            }
        }
    }

    private func scheduleScanRetry(serverKey: String, generation: UInt) {
        guard isApplicationActive else { return }
        scanRetryTask?.cancel()
        scanRetryTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(30))
            } catch {
                return
            }
            guard let self,
                  self.isCurrentSession(generation, serverKey: serverKey),
                  self.isApplicationActive else { return }
            await self.refreshMetadata(for: generation)
        }
    }

    private func cancelMetadataRefresh() {
        metadataSyncTask?.cancel()
        metadataSyncTask = nil
        metadataRefreshID = nil
        isRefreshingMetadata = false
    }

    private func metadataCompletionMessage(prefix: String) -> String {
        let completedAt = lastMetadataCheckAt ?? Date()
        return "\(prefix) at \(completedAt.formatted(date: .omitted, time: .shortened))"
    }

    private func reloadCachedLibrary(for requestedGeneration: UInt? = nil) async {
        let generation = requestedGeneration ?? sessionGeneration
        guard let serverKey else { return }
        do {
            let syncState = try await store.metadataSyncState(serverKey: serverKey)
            guard isCurrentSession(generation, serverKey: serverKey) else { return }
            hasCachedLibrary = syncState.isComplete
            lastMetadataCheckAt = syncState.lastCheckedAt
            guard syncState.isComplete else { return }

            async let artistsRequest = store.artists(serverKey: serverKey)
            async let albumsRequest = store.albums(serverKey: serverKey)
            async let playlistsRequest = store.playlists(serverKey: serverKey)
            async let homeRequest = store.homeMetadata(serverKey: serverKey)
            async let favoriteArtistsRequest = store.favoriteArtists(serverKey: serverKey)
            async let favoriteAlbumsRequest = store.favoriteAlbums(serverKey: serverKey)
            async let favoriteSongsRequest = store.favoriteSongs(serverKey: serverKey)
            async let recentRequest = store.recentSongsAsync(serverKey: serverKey)

            let (
                loadedArtists,
                loadedAlbums,
                loadedPlaylists,
                home,
                loadedFavoriteArtists,
                loadedFavoriteAlbums,
                loadedFavoriteSongs,
                loadedRecentSongs
            ) = try await (
                artistsRequest,
                albumsRequest,
                playlistsRequest,
                homeRequest,
                favoriteArtistsRequest,
                favoriteAlbumsRequest,
                favoriteSongsRequest,
                recentRequest
            )
            guard isCurrentSession(generation, serverKey: serverKey) else { return }
            artists = sortedVisibleArtists(loadedArtists)
            albums = loadedAlbums
            playlists = loadedPlaylists
            recentlyAddedAlbums = home.recentlyAdded
            recentlyPlayedAlbums = home.recentlyPlayed
            homeRandomAlbums = home.random
            featuredAlbums = home.featured
            hasLoadedHome = true
            favoriteArtists = loadedFavoriteArtists
            favoriteArtistIDs = Set(loadedFavoriteArtists.map(\.id))
            favoriteAlbums = loadedFavoriteAlbums
            favoriteAlbumIDs = Set(loadedFavoriteAlbums.map(\.id))
            favoriteSongs = loadedFavoriteSongs
            favoriteIDs = Set(loadedFavoriteSongs.map(\.id))
            recentSongs = loadedRecentSongs

            if let selectedArtist {
                artistAlbums = try await store.albums(serverKey: serverKey, artistID: selectedArtist.id)
                loadedArtistAlbumsID = selectedArtist.id
            }
            if let selectedAlbum {
                albumSongs = try await store.songs(serverKey: serverKey, albumID: selectedAlbum.id)
                loadedAlbumSongsID = selectedAlbum.id
            }
            if let selectedPlaylist {
                playlistSongs = try await store.songs(serverKey: serverKey, playlistID: selectedPlaylist.id)
                loadedPlaylistSongsID = selectedPlaylist.id
            }
            guard isCurrentSession(generation, serverKey: serverKey) else { return }
        } catch {
            guard isCurrentSession(generation, serverKey: serverKey) else { return }
            statusMessage = error.localizedDescription
        }
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
        _ = shouldHydrateSong
        return song
    }

    private func clearRemoteLibraryState() {
        hasCachedLibrary = false
        lastMetadataCheckAt = nil
        searchResults = []
        randomSongs = []
        recentlyAddedAlbums = []
        recentlyPlayedAlbums = []
        homeRandomAlbums = []
        featuredAlbums = []
        hasLoadedHome = false
        albums = []
        artists = []
        artistAlbums = []
        selectedArtist = nil
        selectedAlbum = nil
        albumSongs = []
        playlists = []
        selectedPlaylist = nil
        playlistSongs = []
        playlistCreationRequest = nil
        isPlaylistMutating = false
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

    func isCurrentSession(_ generation: UInt, serverKey: String) -> Bool {
        sessionGeneration == generation && self.serverKey == serverKey
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
        await coverArtCache.warmCachedImages(resources)
    }

    private func warmCachedArtistCovers(_ artists: [NavidromeArtist]) async {
        let resources = artists.compactMap { coverArtResource(for: $0, size: gridCoverSize) }
        await coverArtCache.warmCachedImages(resources)
    }

    func warmCachedSongCovers(_ songs: [NavidromeSong]) async {
        let resources = songs.compactMap { coverArtResource(for: $0, size: thumbnailCoverSize) }
        await coverArtCache.warmCachedImages(resources)
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

    func prefetchSongCovers(_ songs: [NavidromeSong]) {
        let songsToPrefetch = songs.prefix(coverArtPrefetchLimit)
        let resources = songsToPrefetch.compactMap { coverArtResource(for: $0, size: thumbnailCoverSize) }
        songCoverPrefetchTask?.cancel()
        songCoverPrefetchTask = prefetchCoverArt(resources)
    }

    private func cancelCoverArtPrefetchTasks() {
        albumCoverPrefetchTask?.cancel()
        artistCoverPrefetchTask?.cancel()
        songCoverPrefetchTask?.cancel()
        albumCoverPrefetchTask = nil
        artistCoverPrefetchTask = nil
        songCoverPrefetchTask = nil
    }

    private func prefetchCoverArt(_ resources: [CoverArtResource]) -> Task<Void, Never>? {
        guard !resources.isEmpty else { return nil }
        return Task {
            await coverArtCache.prefetch(resources)
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
            let data = try? await coverArtCache.data(for: resource)
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
