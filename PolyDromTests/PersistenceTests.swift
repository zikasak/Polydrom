import CoreData
import Foundation
import Testing
@testable import PolyDrom

@Suite(.serialized)
@MainActor
struct PersistenceTests {
    @Test func serverLifecycleTrimsUpdatesSortsTouchesAndDeletes() throws {
        let credentials = MemoryCredentialStore()
        let store = LibraryStore(persistence: PersistenceController(inMemory: true), keychain: credentials)

        let first = try store.saveServer(address: "  host.local  ", username: " user ", password: "one")
        Thread.sleep(forTimeInterval: 0.002)
        let second = try store.saveServer(address: "https://two.example", username: "two", password: "two", name: "Second")

        #expect(first.address == "host.local")
        #expect(first.username == "user")
        #expect(first.password == "one")
        #expect(try store.servers().map(\.id) == [second.id, first.id])
        #expect(credentials.savedCredentialIDs.count == 2)

        Thread.sleep(forTimeInterval: 0.002)
        try store.touchServer(first)
        #expect(try store.servers().first?.id == first.id)

        let updated = try store.saveServer(address: "host.local", username: "user", password: "changed", name: "Updated")
        #expect(updated.id == first.id)
        #expect(updated.name == "Updated")
        #expect(updated.password == "changed")
        #expect(credentials.passwords[first.credentialID] == "changed")

        try store.deleteServer(updated)
        #expect(try store.servers().map(\.id) == [second.id])
        #expect(credentials.deletedCredentialIDs == [first.credentialID])

        try store.deleteServer(updated)
        try store.touchServer(updated)
        #expect(try store.servers().count == 1)
    }

    @Test func credentialFailuresPropagateFromSave() {
        let credentials = MemoryCredentialStore()
        credentials.error = TestFailure.intentional
        let store = LibraryStore(persistence: PersistenceController(inMemory: true), keychain: credentials)

        #expect(throws: TestFailure.self) {
            try store.saveServer(address: "host", username: "user", password: "secret")
        }
    }

    @Test func credentialFailuresPropagateFromLoad() throws {
        let credentials = MemoryCredentialStore()
        let store = LibraryStore(persistence: PersistenceController(inMemory: true), keychain: credentials)
        _ = try store.saveServer(address: "host", username: "user", password: "secret")
        credentials.error = TestFailure.intentional

        #expect(throws: TestFailure.self) {
            try store.servers()
        }
    }

    @Test func songsUpsertUpdateRemainServerScopedAndRespectLimit() async throws {
        let store = LibraryStore(
            persistence: PersistenceController(inMemory: true),
            keychain: MemoryCredentialStore()
        )
        let original = makeSong(id: "one", title: "Original", duration: nil, coverArt: "cover")
        let other = makeSong(id: "two", title: "Other", artist: nil, album: nil)

        try store.upsertSongs([original, other], serverKey: "server-a")
        #expect(try store.recentSongs(serverKey: "server-a").isEmpty)
        let shuffledLibrary = try await store.randomSongs(serverKey: "server-a")
        #expect(shuffledLibrary.count == 2)
        #expect(Set(shuffledLibrary.map(\.id)) == ["one", "two"])
        #expect(try await store.randomSongs(serverKey: "server-a", count: 1).count == 1)
        #expect(try await store.randomSongs(serverKey: "server-a", count: 0).isEmpty)

        try store.markPlayed(original, serverKey: "server-a")
        Thread.sleep(forTimeInterval: 0.002)
        try store.markPlayed(other, serverKey: "server-a")
        try store.markPlayed(makeSong(id: "one", title: "Updated", duration: 42), serverKey: "server-a")
        try store.markPlayed(makeSong(id: "one", title: "Other Server"), serverKey: "server-b")

        let recent = try store.recentSongs(serverKey: "server-a")
        #expect(recent.count == 2)
        #expect(recent.first?.id == "one")
        #expect(recent.first?.title == "Updated")
        #expect(recent.first?.duration == 42)
        #expect(try store.recentSongs(serverKey: "server-a", limit: 1).count == 1)
        #expect(try store.recentSongs(serverKey: "server-b").map(\.title) == ["Other Server"])
    }

    @Test func keychainErrorsExposeStatusCode() {
        #expect(KeychainError.unexpectedStatus(-50).localizedDescription == "Keychain error -50")
        #expect(NavidromeError.invalidURL.localizedDescription == "The server address is not a valid URL.")
        #expect(NavidromeError.server(message: "Nope").localizedDescription == "Nope")
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
        let playlist = NavidromePlaylist(id: "playlist", name: "Mix", songCount: 2, changed: added)
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
                favorites: .empty,
                catalogToken: "other",
                checkedAt: Date()
            ),
            serverKey: "server-b"
        )

        #expect(try await store.hasCachedLibrary(serverKey: "server-a"))
        #expect(try await store.metadataSyncState(serverKey: "server-a").catalogToken == "scan-1")
        #expect(try await store.artists(serverKey: "server-a").map(\.id) == ["artist"])
        #expect(try await store.artists(serverKey: "server-b").map(\.id) == ["other"])
        #expect(try await store.albums(serverKey: "server-a").map(\.id) == ["album"])
        #expect(try await store.songs(serverKey: "server-a", albumID: "album").map(\.id) == ["first", "second"])
        #expect(try await store.songs(serverKey: "server-a", playlistID: "playlist").map(\.id) == ["second", "first"])
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
                favorites: .empty,
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
        let profile = try store.saveServer(
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

        try store.deleteServer(profile)

        #expect(!(try await store.hasCachedLibrary(serverKey: profile.serverKey)))
        #expect(!(try await store.metadataSyncState(serverKey: profile.serverKey).isComplete))
        #expect(try await store.artists(serverKey: profile.serverKey).isEmpty)
        #expect(try await store.albums(serverKey: profile.serverKey).isEmpty)
        #expect(try await store.playlists(serverKey: profile.serverKey).isEmpty)
        #expect(try await store.favoriteSongs(serverKey: profile.serverKey).isEmpty)
        #expect(try await store.recentSongsAsync(serverKey: profile.serverKey).isEmpty)
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
                favorites: .empty,
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

    @Test func songOnlyStoreMigratesWithoutLosingProfilesOrPlaybackHistory() async throws {
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

        let migratedStore = LibraryStore(
            persistence: PersistenceController(storeURL: storeURL),
            keychain: MemoryCredentialStore()
        )

        let profiles = try migratedStore.servers()
        #expect(profiles.map(\.id) == [serverID])
        #expect(profiles.first?.password == "")
        #expect(
            try migratedStore.recentSongs(serverKey: "https://legacy.example|user").map(\.id)
                == ["legacy-song"]
        )
        #expect(!(try await migratedStore.hasCachedLibrary(serverKey: "https://legacy.example|user")))
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
