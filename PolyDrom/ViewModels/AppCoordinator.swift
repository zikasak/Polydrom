//
//  AppCoordinator.swift
//  PolyDrom
//
//  Created by zikasak on 07/07/2026.
//

import Combine
import Foundation
import OSLog

/// Identifies the connection that asynchronous work started under, so its result
/// can be dropped once the server was switched, reconnected, or deleted.
struct SessionIdentity: Sendable {
    let generation: UInt
    let serverKey: String
}

@MainActor
final class AppCoordinator: ObservableObject {
    let objectWillChange = ObservableObjectPublisher()
    @Published var serverAddress = ""
    @Published var username = ""
    @Published var password = ""
    @Published var servers: [ServerProfile] = []
    @Published var activeServer: ServerProfile? {
        didSet { refreshEditablePlaylists() }
    }
    @Published var selectedSection: LibrarySection = .home
    @Published var statusMessage = "Disconnected"
    @Published var isBusy = false
    @Published var isOnline = false {
        didSet { refreshEditablePlaylists() }
    }
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
    @Published var coverArtCrawlEnabled: Bool {
        didSet {
            guard coverArtCrawlEnabled != oldValue else { return }
            userDefaults.set(coverArtCrawlEnabled, forKey: Self.coverArtCrawlEnabledKey)
            coverArtCrawlSettingDidChange()
        }
    }
    @Published var coverArtCacheLimit: CoverArtCacheLimit {
        didSet {
            guard coverArtCacheLimit != oldValue else { return }
            userDefaults.set(coverArtCacheLimit.rawValue, forKey: Self.coverArtCacheLimitKey)
            applyCoverArtCacheLimit()
        }
    }
    @Published var coverArtCacheSize: Int?
    @Published var searchText = ""
    @Published var searchResults: [NavidromeSong] = [] {
        didSet { searchResultsSnapshot = SongListSnapshot(searchResults, previous: searchResultsSnapshot) }
    }
    @Published var randomSongs: [NavidromeSong] = [] {
        didSet { randomSongsSnapshot = SongListSnapshot(randomSongs, previous: randomSongsSnapshot) }
    }
    @Published var recentlyAddedAlbums: [NavidromeAlbum] = []
    @Published var recentlyPlayedAlbums: [NavidromeAlbum] = []
    @Published var homeRandomAlbums: [NavidromeAlbum] = []
    @Published var featuredAlbums: [NavidromeAlbum] = []
    @Published var albums: [NavidromeAlbum] = [] {
        didSet { albumsSnapshot = ViewCollectionSnapshot(albums) }
    }
    @Published var artists: [NavidromeArtist] = [] {
        didSet { artistsSnapshot = ViewCollectionSnapshot(artists) }
    }
    @Published var genres: [NavidromeGenre] = []
    @Published var selectedGenre: NavidromeGenre?
    @Published var genreSongs: [NavidromeSong] = [] {
        didSet { genreSongsSnapshot = SongListSnapshot(genreSongs, previous: genreSongsSnapshot) }
    }
    @Published var artistAlbums: [NavidromeAlbum] = [] {
        didSet { artistAlbumsSnapshot = ViewCollectionSnapshot(artistAlbums) }
    }
    @Published var selectedArtist: NavidromeArtist?
    @Published var selectedAlbum: NavidromeAlbum?
    @Published var albumSongs: [NavidromeSong] = [] {
        didSet { albumSongsSnapshot = SongListSnapshot(albumSongs, previous: albumSongsSnapshot) }
    }
    @Published var playlists: [NavidromePlaylist] = [] {
        didSet { refreshEditablePlaylists() }
    }
    @Published var selectedPlaylist: NavidromePlaylist?
    @Published var playlistSongs: [NavidromeSong] = [] {
        didSet { playlistSongsSnapshot = SongListSnapshot(playlistSongs, previous: playlistSongsSnapshot) }
    }
    @Published var playlistCreationRequest: PlaylistCreationRequest?
    @Published var isPlaylistMutating = false {
        didSet { refreshEditablePlaylists() }
    }
    @Published var favoriteArtists: [NavidromeArtist] = [] {
        didSet { favoriteArtistsSnapshot = ViewCollectionSnapshot(favoriteArtists) }
    }
    @Published var favoriteAlbums: [NavidromeAlbum] = [] {
        didSet { favoriteAlbumsSnapshot = ViewCollectionSnapshot(favoriteAlbums) }
    }
    @Published var favoriteSongs: [NavidromeSong] = [] {
        didSet { favoriteSongsSnapshot = SongListSnapshot(favoriteSongs, previous: favoriteSongsSnapshot) }
    }
    @Published var recentSongs: [NavidromeSong] = [] {
        didSet { recentSongsSnapshot = SongListSnapshot(recentSongs, previous: recentSongsSnapshot) }
    }
    @Published var favoriteArtistIDs: Set<String> = [] {
        didSet { favoriteArtistIDsRevision = UUID() }
    }
    @Published var favoriteAlbumIDs: Set<String> = [] {
        didSet { favoriteAlbumIDsRevision = UUID() }
    }
    @Published var favoriteIDs: Set<String> = []
    @Published var playbackQueue: [PlaybackQueueEntry] = [] {
        didSet {
            playbackQueueIndices = Dictionary(
                playbackQueue.enumerated().map { ($0.element.id, $0.offset) },
                uniquingKeysWith: { first, _ in first }
            )
        }
    }
    @Published var currentPlaybackQueueEntryID: UUID?
    @Published var currentLyrics: SongLyrics? {
        didSet {
            lyricsTimeline = LyricsTimeline(currentLyrics)
            lyricsRevision = UUID()
        }
    }
    @Published var lyricsMessage = "No lyrics loaded."
    @Published var isLoadingLyrics = false
    @Published var sonosGroups: [SonosGroup] = []
    @Published var sonosIsDiscovering = false
    @Published var sonosMessage: String?

    // Prepared only when source data changes, never in a view body.
    private(set) var searchResultsSnapshot = SongListSnapshot()
    private(set) var randomSongsSnapshot = SongListSnapshot()
    private(set) var genreSongsSnapshot = SongListSnapshot()
    private(set) var albumSongsSnapshot = SongListSnapshot()
    private(set) var playlistSongsSnapshot = SongListSnapshot()
    private(set) var favoriteSongsSnapshot = SongListSnapshot()
    private(set) var recentSongsSnapshot = SongListSnapshot()
    private(set) var albumsSnapshot = ViewCollectionSnapshot<NavidromeAlbum>()
    private(set) var artistAlbumsSnapshot = ViewCollectionSnapshot<NavidromeAlbum>()
    private(set) var favoriteAlbumsSnapshot = ViewCollectionSnapshot<NavidromeAlbum>()
    private(set) var artistsSnapshot = ViewCollectionSnapshot<NavidromeArtist>()
    private(set) var favoriteArtistsSnapshot = ViewCollectionSnapshot<NavidromeArtist>()
    private(set) var favoriteAlbumIDsRevision = UUID()
    private(set) var favoriteArtistIDsRevision = UUID()
    private(set) var lyricsTimeline = LyricsTimeline()
    private(set) var lyricsRevision = UUID()

    // MARK: - Collaborators

    let audioPlayer: AudioPlayer
    let store: LibraryStore
    let serverRegistry: ServerRegistry
    let clientFactory: @MainActor (ServerProfile) -> NavidromeClient?
    let coverArtCache: CoverArtCache
    let syncCoordinator: LibrarySyncCoordinator
    let playbackReporter: PlaybackReporter
    let playbackPersistence: PlaybackPersistence
    let sonosUPnP: SonosUPnP
    private let userDefaults: UserDefaults

    // MARK: - Session

    var client: NavidromeClient? {
        didSet {
            coverArtResources.removeAll()
            cancelCoverArtCrawl()
        }
    }
    var sessionGeneration: UInt = 0
    var didAttemptInitialConnection = false
    var didRequestFirstRunSettings = false
    var isApplicationActive = false

    // MARK: - Library

    var hasLoadedHome = false
    var loadedArtistAlbumsID: String?
    var loadedAlbumSongsID: String?
    var loadedGenreSongsID: String?
    var loadedPlaylistSongsID: String?
    /// IDs of the favorites whose server update has not finished, so a second
    /// toggle of the same item cannot race the first.
    var favoriteUpdatesInFlight: [LibraryRecord: Set<String>] = [:]

    // MARK: - Metadata refresh

    var metadataMonitorTask: Task<Void, Never>?
    var metadataSyncTask: Task<MetadataSyncOutcome, Error>?
    /// Set while a refresh may have written to the cache without the result being
    /// loaded back, e.g. when it was canceled between the save and the reload.
    var hasUnloadedMetadataChanges = false
    var metadataRefreshID: UUID?
    var scanRetryTask: Task<Void, Never>?

    // MARK: - Cover art

    var coverArtCrawl: (id: UUID, task: Task<Void, Never>)?
    /// The server whose covers were crawled since launch, so later refreshes that
    /// find nothing new do not walk the whole library again.
    var coverArtCrawledServerKey: String?
    /// Cover art URLs carry a freshly salted auth token, so building one per row
    /// render is costly. Resources are reused until the client changes.
    var coverArtResources: [String: CoverArtResource] = [:]
    var albumCoverPrefetchTask: Task<Void, Never>?
    var artistCoverPrefetchTask: Task<Void, Never>?
    var songCoverPrefetchTask: Task<Void, Never>?
    var nowPlayingArtworkTask: Task<Void, Never>?

    // MARK: - Playback

    private(set) var playbackQueueIndices: [UUID: Int] = [:]

    var lyricsSongID: String?
    var pendingPlaybackRestore: PersistedPlaybackState?
    var didRestorePlayback = false

    // MARK: - Sonos

    var sonosSession: SonosActiveSession?
    var sonosPollTask: Task<Void, Never>?
    var sonosGeneration = 0
    var sonosActivationTask: Task<Void, Never>?
    var sonosCleanupTask: Task<Void, Never>?
    var sonosVolumeTask: Task<Void, Never>?
    var sonosVolumeTaskGeneration = -1
    var pendingSonosVolume: Int?
    var sonosVolumeErrorMessage: String?

    private static let metadataRefreshIntervalKey = "metadataRefreshInterval"
    private static let coverArtCrawlEnabledKey = "coverArtCrawlEnabled"
    private static let coverArtCacheLimitKey = "coverArtCacheLimit"

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

    let playlistMenuState = PlaylistMenuState()

    private func refreshEditablePlaylists() {
        playlistMenuState.playlists = playlists.filter(canEdit)
        playlistMenuState.canCreatePlaylist = canCreatePlaylist
    }

    var currentSession: SessionIdentity? {
        serverKey.map { SessionIdentity(generation: sessionGeneration, serverKey: $0) }
    }

    func isCurrentSession(_ session: SessionIdentity) -> Bool {
        sessionGeneration == session.generation && serverKey == session.serverKey
    }

    init(
        store: LibraryStore = LibraryStore(),
        audioPlayer: AudioPlayer = AudioPlayer(),
        clientFactory: @escaping @MainActor (ServerProfile) -> NavidromeClient? = { NavidromeClient(profile: $0) },
        coverArtCache: CoverArtCache = .shared,
        serverRegistry: ServerRegistry? = nil,
        userDefaults: UserDefaults = .standard, playbackFileURL: URL? = nil,
        sonosUPnP: SonosUPnP = SonosUPnP()
    ) {
        self.store = store
        let suppliedRegistry = serverRegistry
        self.serverRegistry = suppliedRegistry ?? ServerRegistry()
        self.audioPlayer = audioPlayer
        self.clientFactory = clientFactory
        self.coverArtCache = coverArtCache
        self.syncCoordinator = LibrarySyncCoordinator(store: store)
        self.playbackReporter = PlaybackReporter()
        self.userDefaults = userDefaults
        self.playbackPersistence = PlaybackPersistence(userDefaults: userDefaults, fileURL: playbackFileURL)
        self.sonosUPnP = sonosUPnP
        if userDefaults.object(forKey: Self.metadataRefreshIntervalKey) == nil {
            self.metadataRefreshInterval = .fifteenMinutes
        } else {
            self.metadataRefreshInterval = MetadataRefreshInterval(
                rawValue: userDefaults.integer(forKey: Self.metadataRefreshIntervalKey)
            ) ?? .fifteenMinutes
        }
        self.coverArtCrawlEnabled = userDefaults.object(forKey: Self.coverArtCrawlEnabledKey) as? Bool ?? true
        self.coverArtCacheLimit = CoverArtCacheLimit(
            rawValue: userDefaults.integer(forKey: Self.coverArtCacheLimitKey)
        ) ?? .default
        if suppliedRegistry == nil,
           let legacyStoreURL = PersistenceController.legacyStoreURL,
           FileManager.default.fileExists(atPath: legacyStoreURL.path) {
            let legacyStore = LibraryStore(
                persistence: PersistenceController(
                    storeURL: legacyStoreURL,
                    recoverDisposableCache: false
                ),
                keychain: CredentialStore()
            )
            try? self.serverRegistry.importLegacyServersIfNeeded(from: legacyStore)
        } else {
            try? self.serverRegistry.importLegacyServersIfNeeded(from: store)
        }
        configureAudioPlayer()
        applyCoverArtCacheLimit()
        restorePersistedPlaybackState()
        loadServers()
        if let initializationError = store.initializationError {
            AppLog.persistence.error(
                "Library store initialized with an error: \(initializationError.localizedDescription, privacy: .private)"
            )
            statusMessage = initializationError.localizedDescription
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
            AppLog.persistence.info("Cleared the library cache")
            clearRemoteLibraryState()
            statusMessage = "Library cache cleared. Refresh metadata to rebuild it."
        } catch {
            AppLog.persistence.error("Failed to clear the library cache: \(error.localizedDescription, privacy: .private)")
            statusMessage = error.localizedDescription
        }
    }

    func clearCoverArtCache() async {
        guard canClearCache else { return }

        isClearingCache = true
        defer { isClearingCache = false }
        cancelCoverArtPrefetchTasks()
        cancelCoverArtCrawl()
        coverArtCrawledServerKey = nil
        nowPlayingArtworkTask?.cancel()

        do {
            try await coverArtCache.clear()
            await refreshCoverArtCacheSize()
            AppLog.cache.info("Cleared the cover art cache")
            statusMessage = "Cover art cache cleared."
        } catch {
            AppLog.cache.error("Failed to clear the cover art cache: \(error.localizedDescription, privacy: .private)")
            statusMessage = error.localizedDescription
        }
    }

    func selectSection(_ section: LibrarySection) {
        AppLog.app.debug("Selected library section: \(section.rawValue, privacy: .public)")
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
            guard force || searchResults.isEmpty else { return }
            if searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                await loadRandomSongs()
            } else {
                await search()
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
        case .genres:
            if force || genres.isEmpty {
                await loadGenres()
            }
        case .playlists:
            if force || playlists.isEmpty {
                await loadPlaylists()
            }
        case .favorites:
            do {
                try await loadCachedFavorites()
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

    func clearRemoteLibraryState() {
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
        genres = []
        selectedGenre = nil
        genreSongs = []
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
        favoriteUpdatesInFlight = [:]
        loadedArtistAlbumsID = nil
        loadedAlbumSongsID = nil
        loadedGenreSongsID = nil
        loadedPlaylistSongsID = nil
    }
}
