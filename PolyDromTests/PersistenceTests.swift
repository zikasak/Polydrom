import CoreData
import Foundation
import Testing
@testable import PolyDrom

@Suite(.serialized)
@MainActor
struct PersistenceTests {
    @Test func playbackStateMigratesFromUserDefaultsAndStoresLargeValuesOnDisk() throws {
        let suiteName = "PlaybackFilePersistenceTests.\(UUID().uuidString)"
        let userDefaults = UserDefaults(suiteName: suiteName)!
        let directory = try temporaryDirectory()
        let fileURL = directory.appendingPathComponent("playback-state.json")
        defer { userDefaults.removePersistentDomain(forName: suiteName) }
        defer { try? FileManager.default.removeItem(at: directory) }

        let entry = PlaybackQueueEntry(song: makeSong(id: "legacy-song"))
        let state = PersistedPlaybackState(
            serverKey: "server",
            queue: [entry],
            currentQueueEntryID: entry.id,
            currentSong: entry.song,
            position: 12,
            isPlaying: false
        )
        let legacyData = try JSONEncoder().encode(state)
        userDefaults.set(legacyData, forKey: PlaybackPersistence.userDefaultsKey)

        let persistence = PlaybackPersistence(userDefaults: userDefaults, fileURL: fileURL)
        #expect(persistence.load() == state)
        #expect(userDefaults.object(forKey: PlaybackPersistence.userDefaultsKey) == nil)
        #expect(FileManager.default.fileExists(atPath: fileURL.path))

        userDefaults.set(legacyData, forKey: PlaybackPersistence.userDefaultsKey)
        #expect(persistence.load() == state)
        #expect(userDefaults.object(forKey: PlaybackPersistence.userDefaultsKey) == nil)

        let largeSong = makeSong(id: "large-song", title: String(repeating: "x", count: 5_000_000))
        let largeState = PersistedPlaybackState(
            serverKey: "server",
            queue: [PlaybackQueueEntry(song: largeSong)],
            currentQueueEntryID: nil,
            currentSong: largeSong,
            position: 0,
            isPlaying: false
        )
        persistence.save(largeState)

        #expect(userDefaults.object(forKey: PlaybackPersistence.userDefaultsKey) == nil)
        #expect(persistence.load() == largeState)
    }

    @Test func serverLifecycleTrimsUpdatesSortsTouchesAndDeletes() async throws {
        let credentials = MemoryCredentialStore()
        let registry = ServerRegistry(fileURL: nil, keychain: credentials)

        let first = try registry.save(address: "  host.local  ", username: " user ", password: "one")
        try await Task.sleep(for: .milliseconds(2))
        let second = try registry.save(address: "https://two.example", username: "two", password: "two", name: "Second")

        #expect(first.address == "host.local")
        #expect(first.username == "user")
        #expect(first.password == "one")
        #expect(try registry.servers().map(\.id) == [second.id, first.id])
        #expect(credentials.savedCredentialIDs.count == 2)

        try await Task.sleep(for: .milliseconds(2))
        try registry.touch(first)
        #expect(try registry.servers().first?.id == first.id)

        let updated = try registry.save(address: "host.local", username: "user", password: "changed", name: "Updated")
        #expect(updated.id == first.id)
        #expect(updated.name == "Updated")
        #expect(updated.password == "changed")
        #expect(credentials.passwords[first.credentialID] == "changed")

        try registry.delete(updated)
        #expect(try registry.servers().map(\.id) == [second.id])
        #expect(credentials.deletedCredentialIDs == [first.credentialID])

        try registry.delete(updated)
        try registry.touch(updated)
        #expect(try registry.servers().count == 1)
    }

    @Test func credentialFailuresPropagateFromSave() {
        let credentials = MemoryCredentialStore()
        credentials.error = TestFailure.intentional
        let registry = ServerRegistry(fileURL: nil, keychain: credentials)

        #expect(throws: TestFailure.self) {
            try registry.save(address: "host", username: "user", password: "secret")
        }
    }

    @Test func credentialFailuresPropagateFromLoad() throws {
        let credentials = MemoryCredentialStore()
        let registry = ServerRegistry(fileURL: nil, keychain: credentials)
        _ = try registry.save(address: "host", username: "user", password: "secret")
        credentials.error = TestFailure.intentional

        #expect(throws: TestFailure.self) {
            try registry.servers()
        }
    }

    @Test func songsUpsertUpdateRemainServerScopedAndRespectLimit() async throws {
        let store = LibraryStore(
            persistence: PersistenceController(inMemory: true),
            keychain: MemoryCredentialStore()
        )
        let original = makeSong(id: "one", title: "Original", duration: nil, coverArt: "cover")
        let other = makeSong(id: "two", title: "Other", artist: nil, album: nil)

        try await store.apply(
            LibrarySnapshot(
                artists: [],
                albums: [],
                songs: [original, other],
                playlists: [],
                favorites: FavoriteMetadata(),
                catalogToken: "initial",
                checkedAt: Date()
            ),
            serverKey: "server-a"
        )
        #expect(try await store.recentSongsAsync(serverKey: "server-a").isEmpty)
        let shuffledLibrary = try await store.randomSongs(serverKey: "server-a")
        #expect(shuffledLibrary.count == 2)
        #expect(Set(shuffledLibrary.map(\.id)) == ["one", "two"])
        #expect(try await store.randomSongs(serverKey: "server-a", count: 1).count == 1)
        #expect(try await store.randomSongs(serverKey: "server-a", count: 0).isEmpty)

        try store.markPlayed(original, serverKey: "server-a")
        try await Task.sleep(for: .milliseconds(2))
        try store.markPlayed(other, serverKey: "server-a")
        try store.markPlayed(makeSong(id: "one", title: "Updated", duration: 42), serverKey: "server-a")
        try store.markPlayed(makeSong(id: "one", title: "Other Server"), serverKey: "server-b")

        let recent = try await store.recentSongsAsync(serverKey: "server-a")
        #expect(recent.count == 2)
        #expect(recent.first?.id == "one")
        #expect(recent.first?.title == "Updated")
        #expect(recent.first?.duration == 42)
        #expect(try await store.recentSongsAsync(serverKey: "server-a", limit: 1).count == 1)
        #expect(try await store.recentSongsAsync(serverKey: "server-b").map(\.title) == ["Other Server"])
    }

    @Test func albumShuffleKeepsAlbumsOrderedAndContiguous() async throws {
        let store = LibraryStore(
            persistence: PersistenceController(inMemory: true),
            keychain: MemoryCredentialStore()
        )
        let songs = [
            NavidromeSong(id: "a-2", title: "Second", albumId: "album-a", track: 2, discNumber: 1),
            NavidromeSong(id: "b-2", title: "Second Disc", albumId: "album-b", track: 1, discNumber: 2),
            NavidromeSong(id: "standalone-1", title: "Standalone One", albumId: nil),
            NavidromeSong(id: "a-1", title: "First", albumId: "album-a", track: 1, discNumber: 1),
            NavidromeSong(id: "b-1", title: "First Disc", albumId: "album-b", track: 4, discNumber: 1),
            NavidromeSong(id: "c-2", title: "Zulu", albumId: "album-c"),
            NavidromeSong(id: "c-1", title: "Alpha", albumId: "album-c"),
            NavidromeSong(id: "standalone-2", title: "Standalone Two", albumId: "")
        ]
        try await store.apply(
            LibrarySnapshot(
                artists: [],
                albums: [],
                songs: songs,
                playlists: [],
                favorites: FavoriteMetadata(),
                catalogToken: "album-shuffle",
                checkedAt: Date()
            ),
            serverKey: "server-a"
        )
        try await store.apply(
            LibrarySnapshot(
                artists: [],
                albums: [],
                songs: [NavidromeSong(id: "other-server", title: "Other")],
                playlists: [],
                favorites: FavoriteMetadata(),
                catalogToken: "other-server",
                checkedAt: Date()
            ),
            serverKey: "server-b"
        )

        let shuffled = try await store.songsShuffledByAlbum(serverKey: "server-a")

        #expect(shuffled.count == songs.count)
        #expect(Set(shuffled.map(\.id)) == Set(songs.map(\.id)))
        #expect(shuffled.filter { $0.albumId == "album-a" }.map(\.id) == ["a-1", "a-2"])
        #expect(shuffled.filter { $0.albumId == "album-b" }.map(\.id) == ["b-1", "b-2"])
        #expect(shuffled.filter { $0.albumId == "album-c" }.map(\.id) == ["c-1", "c-2"])
        let albumAPositions = albumPositions("album-a", in: shuffled)
        let albumBPositions = albumPositions("album-b", in: shuffled)
        let albumCPositions = albumPositions("album-c", in: shuffled)
        #expect(albumAPositions.count == 2)
        let albumAFirst = try #require(albumAPositions.first)
        let albumALast = try #require(albumAPositions.last)
        #expect(albumALast - albumAFirst == 1)
        #expect(albumBPositions.count == 2)
        let albumBFirst = try #require(albumBPositions.first)
        let albumBLast = try #require(albumBPositions.last)
        #expect(albumBLast - albumBFirst == 1)
        #expect(albumCPositions.count == 2)
        let albumCFirst = try #require(albumCPositions.first)
        let albumCLast = try #require(albumCPositions.last)
        #expect(albumCLast - albumCFirst == 1)
        #expect(Set(shuffled.filter { ($0.albumId ?? "").isEmpty }.map(\.id)) == ["standalone-1", "standalone-2"])
    }

    @Test func keychainErrorsExposeStatusCode() {
        #expect(KeychainError.unexpectedStatus(-50).localizedDescription == "Keychain error -50")
        #expect(NavidromeError.invalidURL.localizedDescription == "The server address is not a valid URL.")
        #expect(NavidromeError.server(message: "Nope").localizedDescription == "Nope")
    }

    @Test func unusableMusicCacheIsRecreatedWithoutARegistryDependency() async throws {
        let directory = try temporaryDirectory()
        let cacheURL = directory.appendingPathComponent("LibraryCache.sqlite")
        try FileManager.default.createDirectory(at: cacheURL, withIntermediateDirectories: true)

        let persistence = PersistenceController(storeURL: cacheURL)
        #expect(persistence.loadFailure == nil)

        let store = LibraryStore(persistence: persistence, keychain: MemoryCredentialStore())
        try await store.apply(
            LibrarySnapshot(
                artists: [],
                albums: [],
                songs: [makeSong(id: "recovered")],
                playlists: [],
                favorites: FavoriteMetadata(),
                catalogToken: "recovered",
                checkedAt: Date()
            ),
            serverKey: "server"
        )

        #expect(try await store.metadataSyncState(serverKey: "server").isComplete)
        #expect(FileManager.default.fileExists(atPath: cacheURL.path))
    }

    @Test func completeMetadataSnapshotsAreQueryableOrderedScopedAndReconciled() async throws {
        let store = LibraryStore(
            persistence: PersistenceController(inMemory: true),
            keychain: MemoryCredentialStore()
        )
        let added = Date(timeIntervalSince1970: 200)
        let played = Date(timeIntervalSince1970: 300)
        let artist = NavidromeArtist(id: "artist", name: "Artist", albumCount: 1)
        let album = NavidromeAlbum(
            id: "album",
            name: "Album",
            artist: "Artist",
            artistId: "artist",
            songCount: 2,
            year: 2026,
            created: added,
            played: played
        )
        let second = NavidromeSong(
            id: "second",
            title: "Second",
            artist: "Artist",
            album: "Album",
            albumId: "album",
            artistId: "artist",
            track: 2
        )
        let first = NavidromeSong(
            id: "first",
            title: "First",
            artist: "Artist",
            album: "Album",
            albumId: "album",
            artistId: "artist",
            track: 1
        )
        let playlist = NavidromePlaylist(
            id: "playlist",
            name: "Mix",
            songCount: 2,
            changed: added,
            isReadOnly: true
        )
        let snapshot = LibrarySnapshot(
            artists: [artist],
            albums: [album],
            songs: [second, first],
            playlists: [PlaylistMetadataSnapshot(playlist: playlist, songs: [second, first])],
            favorites: FavoriteMetadata(artistIDs: ["artist"], albumIDs: ["album"], songIDs: ["first"]),
            catalogToken: "scan-1",
            checkedAt: Date(timeIntervalSince1970: 400)
        )

        try await store.apply(snapshot, serverKey: "server-a")
        try await store.apply(
            LibrarySnapshot(
                artists: [NavidromeArtist(id: "other", name: "Other", albumCount: 1)],
                albums: [],
                songs: [],
                playlists: [],
                favorites: FavoriteMetadata(),
                catalogToken: "other",
                checkedAt: Date()
            ),
            serverKey: "server-b"
        )

        #expect(try await store.metadataSyncState(serverKey: "server-a").isComplete)
        #expect(try await store.metadataSyncState(serverKey: "server-a").catalogToken == "scan-1")
        #expect(try await store.artists(serverKey: "server-a").map(\.id) == ["artist"])
        #expect(try await store.artists(serverKey: "server-b").map(\.id) == ["other"])
        #expect(try await store.albums(serverKey: "server-a").map(\.id) == ["album"])
        #expect(try await store.songs(serverKey: "server-a", albumID: "album").map(\.id) == ["first", "second"])
        #expect(try await store.songs(serverKey: "server-a", playlistID: "playlist").map(\.id) == ["second", "first"])
        #expect(try await store.playlists(serverKey: "server-a").first?.isReadOnly == true)
        #expect(try await store.searchSongs("artist", serverKey: "server-a").count == 2)
        #expect(try await store.favoriteArtists(serverKey: "server-a").map(\.id) == ["artist"])
        #expect(try await store.favoriteAlbums(serverKey: "server-a").map(\.id) == ["album"])
        #expect(try await store.favoriteSongs(serverKey: "server-a").map(\.id) == ["first"])
        #expect(try await store.homeMetadata(serverKey: "server-a").recentlyAdded.map(\.id) == ["album"])

        try store.markPlayed(first, serverKey: "server-a")
        #expect(try await store.recentSongsAsync(serverKey: "server-a").map(\.id) == ["first"])

        try await store.apply(
            LibrarySnapshot(
                artists: [artist],
                albums: [album],
                songs: [first],
                playlists: [],
                favorites: FavoriteMetadata(),
                catalogToken: "scan-2",
                checkedAt: Date()
            ),
            serverKey: "server-a"
        )
        #expect(try await store.songs(serverKey: "server-a", albumID: "album").map(\.id) == ["first"])
        #expect(try await store.playlists(serverKey: "server-a").isEmpty)
        #expect(try await store.favoriteSongs(serverKey: "server-a").isEmpty)
        #expect(try await store.recentSongsAsync(serverKey: "server-a").map(\.id) == ["first"])
    }

    @Test func deletingAProfilePurgesItsMetadataHistoryAndSyncState() async throws {
        let store = LibraryStore(
            persistence: PersistenceController(inMemory: true),
            keychain: MemoryCredentialStore()
        )
        let registry = ServerRegistry(fileURL: nil, keychain: MemoryCredentialStore())
        let profile = try registry.save(
            address: "https://delete.example",
            username: "user",
            password: "password"
        )
        let song = makeSong(id: "song")
        try await store.apply(
            LibrarySnapshot(
                artists: [NavidromeArtist(id: "artist", name: "Artist", albumCount: 1)],
                albums: [NavidromeAlbum(id: "album", name: "Album", artistId: "artist")],
                songs: [song],
                playlists: [
                    PlaylistMetadataSnapshot(
                        playlist: NavidromePlaylist(id: "playlist", name: "Playlist", songCount: 1),
                        songs: [song]
                    )
                ],
                favorites: FavoriteMetadata(songIDs: ["song"]),
                catalogToken: "scan",
                checkedAt: Date()
            ),
            serverKey: profile.serverKey
        )
        try store.markPlayed(song, serverKey: profile.serverKey)

        try registry.delete(profile)
        try store.purgeLibrary(serverKey: profile.serverKey)

        #expect(!(try await store.metadataSyncState(serverKey: profile.serverKey).isComplete))
        #expect(try await store.artists(serverKey: profile.serverKey).isEmpty)
        #expect(try await store.albums(serverKey: profile.serverKey).isEmpty)
        #expect(try await store.genres(serverKey: profile.serverKey).isEmpty)
        #expect(try await store.playlists(serverKey: profile.serverKey).isEmpty)
        #expect(try await store.favoriteSongs(serverKey: profile.serverKey).isEmpty)
        #expect(try await store.recentSongsAsync(serverKey: profile.serverKey).isEmpty)
    }

    @Test func genresAreIndexedOrderedScopedAndReconciled() async throws {
        let store = LibraryStore(
            persistence: PersistenceController(inMemory: true),
            keychain: MemoryCredentialStore()
        )
        let zebra = makeSong(
            id: "zebra",
            title: "Zebra",
            albumId: "album-a",
            genres: [" Rock ", "Alternative"]
        )
        let alpha = makeSong(
            id: "alpha",
            title: "Alpha",
            albumId: "album-b",
            genres: ["rock", "Ambient"]
        )
        let untagged = makeSong(id: "untagged", title: "Untagged", genres: [])

        try await store.apply(
            LibrarySnapshot(
                artists: [],
                albums: [],
                songs: [zebra, alpha, untagged],
                playlists: [
                    PlaylistMetadataSnapshot(
                        playlist: NavidromePlaylist(id: "mix", name: "Mix", songCount: 1),
                        songs: [makeSong(id: "alpha", title: "Alpha", albumId: "album-b", genres: ["rock"])]
                    )
                ],
                favorites: FavoriteMetadata(songIDs: [alpha.id]),
                catalogToken: "scan-1",
                checkedAt: Date()
            ),
            serverKey: "server-a"
        )
        try await store.apply(
            LibrarySnapshot(
                artists: [],
                albums: [],
                songs: [makeSong(id: "other", genres: ["Jazz"])],
                playlists: [],
                favorites: FavoriteMetadata(),
                catalogToken: "scan-other",
                checkedAt: Date()
            ),
            serverKey: "server-b"
        )

        let genres = try await store.genres(serverKey: "server-a")
        let expectedAlphaGenres = ["rock", "Ambient"]
        #expect(genres.map(\.name) == ["Alternative", "Ambient", "Rock"])
        #expect(genres.map(\.songCount) == [1, 1, 2])
        let rockSongs = try await store.songs(serverKey: "server-a", genreID: "rock")
        #expect(rockSongs.map(\.id) == ["alpha", "zebra"])
        #expect(rockSongs.first(where: { $0.id == alpha.id })?.genres == expectedAlphaGenres)
        #expect(try await store.songs(serverKey: "server-a", albumID: "album-b").first?.genres == expectedAlphaGenres)
        #expect(try await store.songs(serverKey: "server-a", playlistID: "mix").first?.genres == expectedAlphaGenres)
        #expect(try await store.favoriteSongs(serverKey: "server-a").first?.genres == expectedAlphaGenres)
        #expect(try await store.searchSongs("Alpha", serverKey: "server-a").first?.genres == expectedAlphaGenres)
        #expect(try await store.randomSongs(serverKey: "server-a").first(where: { $0.id == alpha.id })?.genres == expectedAlphaGenres)
        #expect(try await store.songsShuffledByAlbum(serverKey: "server-a").first(where: { $0.id == alpha.id })?.genres == expectedAlphaGenres)
        try store.markPlayed(alpha, serverKey: "server-a")
        #expect(try await store.recentSongsAsync(serverKey: "server-a").first?.genres == expectedAlphaGenres)
        #expect(try await store.genres(serverKey: "server-b").map(\.name) == ["Jazz"])
        #expect(try await store.metadataSyncState(serverKey: "server-a").catalogVersion == MetadataSyncState.currentCatalogVersion)

        try await store.apply(
            LibrarySnapshot(
                artists: [],
                albums: [],
                songs: [makeSong(id: "zebra", title: "Zebra", genres: ["Electronic"])],
                playlists: [],
                favorites: FavoriteMetadata(),
                catalogToken: "scan-2",
                checkedAt: Date()
            ),
            serverKey: "server-a"
        )

        #expect(try await store.genres(serverKey: "server-a").map(\.name) == ["Electronic"])
        #expect(try await store.songs(serverKey: "server-a", genreID: "rock").isEmpty)
        #expect(try await store.songs(serverKey: "server-a", genreID: "electronic").map(\.id) == ["zebra"])
    }

    @Test func staleCatalogVersionRequiresAFullRefresh() {
        let stale = MetadataSyncState(
            catalogToken: "unchanged",
            lastCheckedAt: Date(),
            isComplete: true,
            catalogVersion: MetadataSyncState.currentCatalogVersion - 1
        )
        let current = MetadataSyncState(
            catalogToken: "unchanged",
            lastCheckedAt: Date(),
            isComplete: true,
            catalogVersion: MetadataSyncState.currentCatalogVersion
        )

        #expect(stale.requiresCatalogUpgrade)
        #expect(!current.requiresCatalogUpgrade)
    }

    @Test func clearingAllLibraryCachePreservesSavedServersAndCredentials() async throws {
        let credentials = MemoryCredentialStore()
        let registry = ServerRegistry(fileURL: nil, keychain: credentials)
        let profile = try registry.save(
            address: "https://cache.example",
            username: "user",
            password: "password"
        )
        let store = LibraryStore(
            persistence: PersistenceController(inMemory: true),
            keychain: credentials
        )
        try await store.apply(
            LibrarySnapshot(
                artists: [NavidromeArtist(id: "artist", name: "Artist", albumCount: 1)],
                albums: [],
                songs: [makeSong()],
                playlists: [],
                favorites: FavoriteMetadata(),
                catalogToken: "scan",
                checkedAt: Date()
            ),
            serverKey: profile.serverKey
        )

        try store.purgeAllLibraryCache()

        #expect(!(try await store.metadataSyncState(serverKey: profile.serverKey).isComplete))
        #expect(try await store.artists(serverKey: profile.serverKey).isEmpty)
        #expect(try await store.genres(serverKey: profile.serverKey).isEmpty)
        #expect(try await store.songs(serverKey: profile.serverKey, albumID: "missing").isEmpty)
        #expect(try registry.servers().map(\.id) == [profile.id])
        #expect(credentials.passwords[profile.credentialID] == "password")
    }

    @Test func largeInitialSnapshotReconcilesWithoutPerRecordFetches() async throws {
        let store = LibraryStore(
            persistence: PersistenceController(inMemory: true),
            keychain: MemoryCredentialStore()
        )
        let artistCount = 400
        let albumCount = 400
        let songCount = 9_000
        let artists = (0..<artistCount).map {
            NavidromeArtist(id: "artist-\($0)", name: "Artist \($0)", albumCount: 1)
        }
        let albums = (0..<albumCount).map {
            NavidromeAlbum(
                id: "album-\($0)",
                name: "Album \($0)",
                artist: "Artist \($0)",
                artistId: "artist-\($0)",
                songCount: songCount / albumCount
            )
        }
        let songs = (0..<songCount).map {
            let albumIndex = $0 % albumCount
            return NavidromeSong(
                id: "song-\($0)",
                title: "Song \($0)",
                artist: "Artist \(albumIndex)",
                album: "Album \(albumIndex)",
                albumId: "album-\(albumIndex)",
                artistId: "artist-\(albumIndex)",
                track: $0 / albumCount
            )
        }

        let clock = ContinuousClock()
        let startedAt = clock.now
        try await store.apply(
            LibrarySnapshot(
                artists: artists,
                albums: albums,
                songs: songs,
                playlists: [],
                favorites: FavoriteMetadata(),
                catalogToken: "large-snapshot",
                checkedAt: Date()
            ),
            serverKey: "large-server"
        )
        let elapsed = startedAt.duration(to: clock.now)

        #expect(elapsed < .seconds(30))
        #expect(try await store.artists(serverKey: "large-server").count == artistCount)
        #expect(try await store.albums(serverKey: "large-server").count == albumCount)
        #expect(try await store.songs(serverKey: "large-server", albumID: "album-0").count == 23)
        #expect(try await store.metadataSyncState(serverKey: "large-server").isComplete)
    }

    @Test func legacyImportPreservesServerAndKeychainIdentityWhileCacheIsRebuilt() async throws {
        let directory = try temporaryDirectory()
        let storeURL = directory.appendingPathComponent("Legacy.sqlite")
        let legacyContainer = NSPersistentContainer(
            name: "PolyDrom",
            managedObjectModel: legacySongOnlyModel()
        )
        legacyContainer.persistentStoreDescriptions.first?.url = storeURL
        var loadError: Error?
        legacyContainer.loadPersistentStores { _, error in loadError = error }
        try #require(loadError == nil)

        let server = NSEntityDescription.insertNewObject(
            forEntityName: "VDServer",
            into: legacyContainer.viewContext
        )
        let serverID = UUID()
        server.setValue(serverID, forKey: "uuid")
        server.setValue("Legacy", forKey: "name")
        server.setValue("https://legacy.example", forKey: "address")
        server.setValue("user", forKey: "username")
        server.setValue("credential", forKey: "credentialID")
        server.setValue("legacy-plaintext-secret", forKey: "password")
        server.setValue(Date(timeIntervalSince1970: 10), forKey: "createdAt")

        let song = NSEntityDescription.insertNewObject(
            forEntityName: "VDSong",
            into: legacyContainer.viewContext
        )
        song.setValue(UUID(), forKey: "uuid")
        song.setValue("legacy-song", forKey: "songID")
        song.setValue("https://legacy.example|user", forKey: "serverKey")
        song.setValue("Legacy Song", forKey: "title")
        song.setValue(Int64(4), forKey: "playCount")
        song.setValue(Date(timeIntervalSince1970: 20), forKey: "cachedAt")
        song.setValue(Date(timeIntervalSince1970: 30), forKey: "lastPlayedAt")
        try legacyContainer.viewContext.save()
        if let persistentStore = legacyContainer.persistentStoreCoordinator.persistentStores.first {
            try legacyContainer.persistentStoreCoordinator.remove(persistentStore)
        }

        let credentials = MemoryCredentialStore()
        credentials.passwords["credential"] = "keychain-secret"
        let legacyStore = LibraryStore(
            persistence: PersistenceController(storeURL: storeURL),
            keychain: credentials
        )
        let registry = ServerRegistry(fileURL: nil, keychain: credentials)
        try registry.importLegacyServersIfNeeded(from: legacyStore)

        let profiles = try registry.servers()
        #expect(profiles.map(\.id) == [serverID])
        #expect(profiles.first?.credentialID == "credential")
        #expect(profiles.first?.password == "keychain-secret")
        #expect(credentials.savedCredentialIDs.isEmpty)

        let rebuiltCache = LibraryStore(
            persistence: PersistenceController(inMemory: true),
            keychain: credentials
        )
        #expect(try await rebuiltCache.recentSongsAsync(serverKey: "https://legacy.example|user").isEmpty)
        #expect(!(try await rebuiltCache.metadataSyncState(serverKey: "https://legacy.example|user").isComplete))
    }

    private func albumPositions(_ albumID: String, in songs: [NavidromeSong]) -> [Int] {
        songs.indices.filter { songs[$0].albumId == albumID }
    }
}

private func legacySongOnlyModel() -> NSManagedObjectModel {
    let model = NSManagedObjectModel()
    let server = NSEntityDescription()
    server.name = "VDServer"
    server.managedObjectClassName = NSStringFromClass(NSManagedObject.self)
    server.properties = [
        legacyAttribute("uuid", .UUIDAttributeType, isOptional: false),
        legacyAttribute("name", .stringAttributeType),
        legacyAttribute("address", .stringAttributeType, isOptional: false),
        legacyAttribute("username", .stringAttributeType, isOptional: false),
        legacyAttribute("credentialID", .stringAttributeType),
        legacyAttribute("password", .stringAttributeType),
        legacyAttribute("createdAt", .dateAttributeType, isOptional: false),
        legacyAttribute("lastConnectedAt", .dateAttributeType)
    ]
    server.uniquenessConstraints = [["address", "username"]]

    let song = NSEntityDescription()
    song.name = "VDSong"
    song.managedObjectClassName = NSStringFromClass(NSManagedObject.self)
    song.properties = [
        legacyAttribute("uuid", .UUIDAttributeType, isOptional: false),
        legacyAttribute("songID", .stringAttributeType, isOptional: false),
        legacyAttribute("serverKey", .stringAttributeType, isOptional: false),
        legacyAttribute("title", .stringAttributeType, isOptional: false),
        legacyAttribute("artist", .stringAttributeType),
        legacyAttribute("album", .stringAttributeType),
        legacyAttribute("duration", .integer64AttributeType),
        legacyAttribute("suffix", .stringAttributeType),
        legacyAttribute("coverArt", .stringAttributeType),
        legacyAttribute("albumId", .stringAttributeType),
        legacyAttribute("artistId", .stringAttributeType),
        legacyAttribute("playCount", .integer64AttributeType, isOptional: false, defaultValue: 0),
        legacyAttribute("cachedAt", .dateAttributeType, isOptional: false),
        legacyAttribute("lastPlayedAt", .dateAttributeType)
    ]
    song.uniquenessConstraints = [["serverKey", "songID"]]
    model.entities = [server, song]
    return model
}

private func legacyAttribute(
    _ name: String,
    _ type: NSAttributeType,
    isOptional: Bool = true,
    defaultValue: Any? = nil
) -> NSAttributeDescription {
    let attribute = NSAttributeDescription()
    attribute.name = name
    attribute.attributeType = type
    attribute.isOptional = isOptional
    attribute.defaultValue = defaultValue
    return attribute
}
