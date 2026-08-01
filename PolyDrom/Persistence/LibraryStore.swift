import CoreData
import Foundation

struct CachedPlaylistDescriptor: Equatable {
    let id: String
    let changed: Date?
    let songCount: Int?
}

@MainActor
final class LibraryStore {
    private let container: NSPersistentContainer
    private let context: NSManagedObjectContext
    private let keychain: any CredentialStoring
    let initializationError: PersistenceError?

    init(persistence: PersistenceController, keychain: any CredentialStoring) {
        container = persistence.container
        context = persistence.container.viewContext
        self.keychain = keychain
        initializationError = persistence.loadFailure
    }

    convenience init() {
        self.init(persistence: .shared, keychain: KeychainStore())
    }

    func servers() throws -> [ServerProfile] {
        let request = NSFetchRequest<NSManagedObject>(entityName: "VDServer")
        request.sortDescriptors = [
            NSSortDescriptor(key: "lastConnectedAt", ascending: false),
            NSSortDescriptor(key: "createdAt", ascending: false)
        ]
        return try context.fetch(request).map { try serverProfile(from: $0) }
    }

    /// Deletes data owned by a server without touching its credentials. The
    /// server registry is the only credential owner in the current layout.
    func purgeLibrary(serverKey: String) throws {
        try purgeMetadata(serverKey: serverKey, in: context)
        try save()
    }

    /// Deletes cached metadata for every saved server without touching server
    /// profiles or their credentials.
    func purgeAllLibraryCache() throws {
        try purgeMetadata(serverKey: nil, in: context)
        try save()
    }

    func markPlayed(_ song: NavidromeSong, serverKey: String) throws {
        let songObject = try Self.upsertSong(song, serverKey: serverKey, isFavorite: nil, in: context)
        let now = Date()
        songObject.setValue(now, forKey: "lastPlayedAt")

        if let albumID = song.albumId,
           let album = try Self.object(entityName: "VDAlbum", idKey: "albumID", id: albumID, serverKey: serverKey, in: context) {
            album.setValue(now, forKey: "lastPlayedAt")
        }
        try save()
    }

    // MARK: - Cached queries

    func metadataSyncState(serverKey: String) async throws -> MetadataSyncState {
        try await performBackground { context in
            guard let object = try Self.syncStateObject(serverKey: serverKey, in: context) else {
                return MetadataSyncState(catalogToken: nil, lastCheckedAt: nil, isComplete: false)
            }
            return MetadataSyncState(
                catalogToken: object.value(forKey: "catalogToken") as? String,
                lastCheckedAt: object.value(forKey: "lastCheckedAt") as? Date,
                isComplete: object.value(forKey: "isComplete") as? Bool ?? false
            )
        }
    }

    func artists(serverKey: String) async throws -> [NavidromeArtist] {
        try await performBackground { context in
            let request = NSFetchRequest<NSManagedObject>(entityName: "VDArtist")
            request.predicate = NSPredicate(format: "serverKey == %@ AND (albumCount == nil OR albumCount > 0)", serverKey)
            request.sortDescriptors = [
                NSSortDescriptor(
                    key: "name",
                    ascending: true,
                    selector: #selector(NSString.localizedCaseInsensitiveCompare(_:))
                )
            ]
            return try context.fetch(request).map(Self.artist(from:))
        }
    }

    func albums(serverKey: String, artistID: String? = nil) async throws -> [NavidromeAlbum] {
        try await performBackground { context in
            let request = NSFetchRequest<NSManagedObject>(entityName: "VDAlbum")
            if let artistID {
                request.predicate = NSPredicate(format: "serverKey == %@ AND artistID == %@", serverKey, artistID)
                request.sortDescriptors = [
                    NSSortDescriptor(key: "year", ascending: true),
                    NSSortDescriptor(key: "name", ascending: true, selector: #selector(NSString.localizedCaseInsensitiveCompare(_:)))
                ]
            } else {
                request.predicate = NSPredicate(format: "serverKey == %@", serverKey)
                request.sortDescriptors = [
                    NSSortDescriptor(
                        key: "name",
                        ascending: true,
                        selector: #selector(NSString.localizedCaseInsensitiveCompare(_:))
                    )
                ]
            }
            return try context.fetch(request).map(Self.album(from:))
        }
    }

    func songs(serverKey: String, albumID: String) async throws -> [NavidromeSong] {
        try await performBackground { context in
            let request = Self.songFetchRequest()
            request.predicate = NSPredicate(format: "serverKey == %@ AND albumId == %@", serverKey, albumID)
            request.sortDescriptors = [
                NSSortDescriptor(key: "discNumber", ascending: true),
                NSSortDescriptor(key: "track", ascending: true),
                NSSortDescriptor(key: "title", ascending: true, selector: #selector(NSString.localizedCaseInsensitiveCompare(_:)))
            ]
            return try context.fetch(request).map(Self.song(from:))
        }
    }

    func playlists(serverKey: String) async throws -> [NavidromePlaylist] {
        try await performBackground { context in
            let request = NSFetchRequest<NSManagedObject>(entityName: "VDPlaylist")
            request.predicate = NSPredicate(format: "serverKey == %@", serverKey)
            request.sortDescriptors = [
                NSSortDescriptor(
                    key: "name",
                    ascending: true,
                    selector: #selector(NSString.localizedCaseInsensitiveCompare(_:))
                )
            ]
            return try context.fetch(request).map(Self.playlist(from:))
        }
    }

    func playlistDescriptors(serverKey: String) async throws -> [CachedPlaylistDescriptor] {
        try await performBackground { context in
            let request = NSFetchRequest<NSManagedObject>(entityName: "VDPlaylist")
            request.predicate = NSPredicate(format: "serverKey == %@", serverKey)
            return try context.fetch(request).map {
                CachedPlaylistDescriptor(
                    id: $0.value(forKey: "playlistID") as? String ?? "",
                    changed: $0.value(forKey: "changedAt") as? Date,
                    songCount: Self.int($0.value(forKey: "songCount"))
                )
            }
        }
    }

    func songs(serverKey: String, playlistID: String) async throws -> [NavidromeSong] {
        try await performBackground { context in
            let entryRequest = NSFetchRequest<NSManagedObject>(entityName: "VDPlaylistEntry")
            entryRequest.predicate = NSPredicate(format: "serverKey == %@ AND playlistID == %@", serverKey, playlistID)
            entryRequest.sortDescriptors = [NSSortDescriptor(key: "position", ascending: true)]
            let songIDs = try context.fetch(entryRequest).compactMap { $0.value(forKey: "songID") as? String }
            guard !songIDs.isEmpty else { return [] }

            let songRequest = Self.songFetchRequest()
            songRequest.predicate = NSPredicate(format: "serverKey == %@ AND songID IN %@", serverKey, songIDs)
            let songsByID = Dictionary(uniqueKeysWithValues: try context.fetch(songRequest).map {
                (($0.value(forKey: "songID") as? String ?? ""), Self.song(from: $0))
            })
            return songIDs.compactMap { songsByID[$0] }
        }
    }

    func favoriteArtists(serverKey: String) async throws -> [NavidromeArtist] {
        try await performBackground { context in
            let request = NSFetchRequest<NSManagedObject>(entityName: "VDArtist")
            request.predicate = NSPredicate(format: "serverKey == %@ AND isFavorite == YES", serverKey)
            request.sortDescriptors = [
                NSSortDescriptor(
                    key: "name",
                    ascending: true,
                    selector: #selector(NSString.localizedCaseInsensitiveCompare(_:))
                )
            ]
            return try context.fetch(request).map(Self.artist(from:))
        }
    }

    func favoriteAlbums(serverKey: String) async throws -> [NavidromeAlbum] {
        try await performBackground { context in
            let request = NSFetchRequest<NSManagedObject>(entityName: "VDAlbum")
            request.predicate = NSPredicate(format: "serverKey == %@ AND isFavorite == YES", serverKey)
            request.sortDescriptors = [
                NSSortDescriptor(
                    key: "name",
                    ascending: true,
                    selector: #selector(NSString.localizedCaseInsensitiveCompare(_:))
                )
            ]
            return try context.fetch(request).map(Self.album(from:))
        }
    }

    func favoriteSongs(serverKey: String) async throws -> [NavidromeSong] {
        try await performBackground { context in
            let request = Self.songFetchRequest()
            request.predicate = NSPredicate(format: "serverKey == %@ AND isFavorite == YES", serverKey)
            request.sortDescriptors = [
                NSSortDescriptor(
                    key: "title",
                    ascending: true,
                    selector: #selector(NSString.localizedCaseInsensitiveCompare(_:))
                )
            ]
            return try context.fetch(request).map(Self.song(from:))
        }
    }

    func recentSongsAsync(serverKey: String, limit: Int = 50) async throws -> [NavidromeSong] {
        try await performBackground { context in
            let request = Self.songFetchRequest()
            request.predicate = NSPredicate(format: "serverKey == %@ AND lastPlayedAt != nil", serverKey)
            request.sortDescriptors = [NSSortDescriptor(key: "lastPlayedAt", ascending: false)]
            request.fetchLimit = limit
            return try context.fetch(request).map(Self.song(from:))
        }
    }

    func searchSongs(_ query: String, serverKey: String, limit: Int = 100) async throws -> [NavidromeSong] {
        try await performBackground { context in
            let request = Self.songFetchRequest()
            request.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
                NSPredicate(format: "serverKey == %@", serverKey),
                NSCompoundPredicate(orPredicateWithSubpredicates: [
                    NSPredicate(format: "title CONTAINS[cd] %@", query),
                    NSPredicate(format: "artist CONTAINS[cd] %@", query),
                    NSPredicate(format: "album CONTAINS[cd] %@", query)
                ])
            ])
            request.sortDescriptors = [
                NSSortDescriptor(
                    key: "title",
                    ascending: true,
                    selector: #selector(NSString.localizedCaseInsensitiveCompare(_:))
                )
            ]
            request.fetchLimit = limit
            return try context.fetch(request).map(Self.song(from:))
        }
    }

    func randomSongs(serverKey: String, count: Int? = nil) async throws -> [NavidromeSong] {
        try await performBackground { context in
            let request = Self.songFetchRequest()
            request.predicate = NSPredicate(format: "serverKey == %@", serverKey)
            let shuffledSongs = try context.fetch(request).shuffled()
            guard let count else {
                return shuffledSongs.map(Self.song(from:))
            }
            return Array(shuffledSongs.prefix(max(0, count))).map(Self.song(from:))
        }
    }

    func homeMetadata(serverKey: String) async throws -> CachedHomeMetadata {
        try await performBackground { context in
            let request = NSFetchRequest<NSManagedObject>(entityName: "VDAlbum")
            request.predicate = NSPredicate(format: "serverKey == %@", serverKey)
            let objects = try context.fetch(request)
            let added = objects
                .filter { $0.value(forKey: "created") is Date }
                .sorted { ($0.value(forKey: "created") as? Date ?? .distantPast) > ($1.value(forKey: "created") as? Date ?? .distantPast) }
                .prefix(12)
                .map(Self.album(from:))
            let played = objects
                .filter { ($0.value(forKey: "lastPlayedAt") as? Date) != nil || ($0.value(forKey: "serverPlayedAt") as? Date) != nil }
                .sorted {
                    let lhs = ($0.value(forKey: "lastPlayedAt") as? Date) ?? ($0.value(forKey: "serverPlayedAt") as? Date) ?? .distantPast
                    let rhs = ($1.value(forKey: "lastPlayedAt") as? Date) ?? ($1.value(forKey: "serverPlayedAt") as? Date) ?? .distantPast
                    return lhs > rhs
                }
                .prefix(12)
                .map(Self.album(from:))
            let shuffled = objects.shuffled()
            return CachedHomeMetadata(
                recentlyAdded: Array(added),
                recentlyPlayed: Array(played),
                random: Array(shuffled.prefix(12).map(Self.album(from:))),
                featured: Array(shuffled.prefix(5).map(Self.album(from:)))
            )
        }
    }

    // MARK: - Atomic reconciliation

    func apply(_ snapshot: LibrarySnapshot, serverKey: String) async throws {
        try await performBackground { context in
            let now = snapshot.checkedAt
            let favoriteArtists = snapshot.favorites.artistIDs
            let favoriteAlbums = snapshot.favorites.albumIDs
            let favoriteSongs = snapshot.favorites.songIDs

            let existingArtists = try Self.objectsByID(
                entityName: "VDArtist",
                idKey: "artistID",
                serverKey: serverKey,
                in: context
            )
            try Self.reconcile(
                entityName: "VDArtist",
                idKey: "artistID",
                serverKey: serverKey,
                incomingIDs: Set(snapshot.artists.map(\.id)),
                in: context
            )
            for artist in snapshot.artists {
                try Self.upsertArtist(
                    artist,
                    serverKey: serverKey,
                    isFavorite: favoriteArtists.contains(artist.id),
                    existing: existingArtists[artist.id],
                    existingObjectsArePreloaded: true,
                    in: context
                )
            }

            let existingAlbums = try Self.objectsByID(
                entityName: "VDAlbum",
                idKey: "albumID",
                serverKey: serverKey,
                in: context
            )
            try Self.reconcile(
                entityName: "VDAlbum",
                idKey: "albumID",
                serverKey: serverKey,
                incomingIDs: Set(snapshot.albums.map(\.id)),
                in: context
            )
            for album in snapshot.albums {
                try Self.upsertAlbum(
                    album,
                    serverKey: serverKey,
                    isFavorite: favoriteAlbums.contains(album.id),
                    existing: existingAlbums[album.id],
                    existingObjectsArePreloaded: true,
                    in: context
                )
            }

            var allSongs = snapshot.songs
            var knownSongIDs = Set(allSongs.map(\.id))
            for song in snapshot.playlists.flatMap(\.songs) where knownSongIDs.insert(song.id).inserted {
                allSongs.append(song)
            }
            let existingSongs = try Self.objectsByID(
                entityName: "VDSong",
                idKey: "songID",
                serverKey: serverKey,
                in: context
            )
            try Self.reconcile(
                entityName: "VDSong",
                idKey: "songID",
                serverKey: serverKey,
                incomingIDs: Set(allSongs.map(\.id)),
                in: context
            )
            for song in allSongs {
                _ = try Self.upsertSong(
                    song,
                    serverKey: serverKey,
                    isFavorite: favoriteSongs.contains(song.id),
                    existing: existingSongs[song.id],
                    existingObjectsArePreloaded: true,
                    in: context
                )
            }

            try Self.replacePlaylists(
                summaries: snapshot.playlists.map(\.playlist),
                refreshed: snapshot.playlists,
                serverKey: serverKey,
                in: context
            )

            let state = try Self.syncStateObject(serverKey: serverKey, createIfMissing: true, in: context)
            state?.setValue(snapshot.catalogToken, forKey: "catalogToken")
            state?.setValue(now, forKey: "lastCheckedAt")
            state?.setValue(true, forKey: "isComplete")
            try context.save()
        }
    }

    func applyUserMetadata(
        playlists: [NavidromePlaylist],
        refreshedPlaylists: [PlaylistMetadataSnapshot],
        favorites: FavoriteMetadata,
        serverKey: String,
        checkedAt: Date
    ) async throws {
        try await performBackground { context in
            try Self.replacePlaylists(
                summaries: playlists,
                refreshed: refreshedPlaylists,
                serverKey: serverKey,
                in: context
            )
            try Self.replaceFavoriteFlags(
                entityName: "VDArtist",
                idKey: "artistID",
                favoriteIDs: favorites.artistIDs,
                serverKey: serverKey,
                in: context
            )
            try Self.replaceFavoriteFlags(
                entityName: "VDAlbum",
                idKey: "albumID",
                favoriteIDs: favorites.albumIDs,
                serverKey: serverKey,
                in: context
            )
            try Self.replaceFavoriteFlags(
                entityName: "VDSong",
                idKey: "songID",
                favoriteIDs: favorites.songIDs,
                serverKey: serverKey,
                in: context
            )
            let state = try Self.syncStateObject(serverKey: serverKey, createIfMissing: true, in: context)
            state?.setValue(checkedAt, forKey: "lastCheckedAt")
            try context.save()
        }
    }

    func applyPlaylistMetadata(
        playlists: [NavidromePlaylist],
        refreshedPlaylists: [PlaylistMetadataSnapshot],
        serverKey: String
    ) async throws {
        try await performBackground { context in
            try Self.replacePlaylists(
                summaries: playlists,
                refreshed: refreshedPlaylists,
                serverKey: serverKey,
                in: context
            )
            try context.save()
        }
    }

    func setFavorite(_ isFavorite: Bool, artistID: String, serverKey: String) async throws {
        try await setFavorite(isFavorite, entityName: "VDArtist", idKey: "artistID", id: artistID, serverKey: serverKey)
    }

    func setFavorite(_ isFavorite: Bool, albumID: String, serverKey: String) async throws {
        try await setFavorite(isFavorite, entityName: "VDAlbum", idKey: "albumID", id: albumID, serverKey: serverKey)
    }

    func setFavorite(_ isFavorite: Bool, songID: String, serverKey: String) async throws {
        try await setFavorite(isFavorite, entityName: "VDSong", idKey: "songID", id: songID, serverKey: serverKey)
    }

    // MARK: - Core Data helpers

    private func setFavorite(
        _ isFavorite: Bool,
        entityName: String,
        idKey: String,
        id: String,
        serverKey: String
    ) async throws {
        try await performBackground { context in
            if let object = try Self.object(entityName: entityName, idKey: idKey, id: id, serverKey: serverKey, in: context) {
                object.setValue(isFavorite, forKey: "isFavorite")
                try context.save()
            }
        }
    }

    private func performBackground<T>(
        _ operation: @escaping @Sendable (NSManagedObjectContext) throws -> T
    ) async throws -> T {
        let backgroundContext = container.newBackgroundContext()
        backgroundContext.mergePolicy = NSMergePolicy(merge: .mergeByPropertyObjectTrumpMergePolicyType)
        return try await backgroundContext.perform {
            try operation(backgroundContext)
        }
    }

    private func purgeMetadata(serverKey: String?, in context: NSManagedObjectContext) throws {
        for entityName in ["VDPlaylistEntry", "VDPlaylist", "VDSong", "VDAlbum", "VDArtist", "VDMetadataSyncState"] {
            let request = NSFetchRequest<NSManagedObject>(entityName: entityName)
            if let serverKey {
                request.predicate = NSPredicate(format: "serverKey == %@", serverKey)
            }
            try context.fetch(request).forEach(context.delete)
        }
    }

    private nonisolated static func replacePlaylists(
        summaries: [NavidromePlaylist],
        refreshed: [PlaylistMetadataSnapshot],
        serverKey: String,
        in context: NSManagedObjectContext
    ) throws {
        let incomingIDs = Set(summaries.map(\.id))
        let existingPlaylists = try objectsByID(
            entityName: "VDPlaylist",
            idKey: "playlistID",
            serverKey: serverKey,
            in: context
        )
        try reconcile(
            entityName: "VDPlaylist",
            idKey: "playlistID",
            serverKey: serverKey,
            incomingIDs: incomingIDs,
            in: context
        )

        let staleEntryRequest = NSFetchRequest<NSManagedObject>(entityName: "VDPlaylistEntry")
        if incomingIDs.isEmpty {
            staleEntryRequest.predicate = NSPredicate(format: "serverKey == %@", serverKey)
        } else {
            staleEntryRequest.predicate = NSPredicate(
                format: "serverKey == %@ AND NOT (playlistID IN %@)",
                serverKey,
                Array(incomingIDs)
            )
        }
        try context.fetch(staleEntryRequest).forEach(context.delete)

        for playlist in summaries {
            try upsertPlaylist(
                playlist,
                serverKey: serverKey,
                existing: existingPlaylists[playlist.id],
                existingObjectsArePreloaded: true,
                in: context
            )
        }

        var existingSongs = try objectsByID(
            entityName: "VDSong",
            idKey: "songID",
            serverKey: serverKey,
            in: context
        )
        for snapshot in refreshed {
            for song in snapshot.songs {
                let object = try upsertSong(
                    song,
                    serverKey: serverKey,
                    isFavorite: nil,
                    existing: existingSongs[song.id],
                    existingObjectsArePreloaded: true,
                    in: context
                )
                existingSongs[song.id] = object
            }
            let oldEntries = NSFetchRequest<NSManagedObject>(entityName: "VDPlaylistEntry")
            oldEntries.predicate = NSPredicate(
                format: "serverKey == %@ AND playlistID == %@",
                serverKey,
                snapshot.playlist.id
            )
            try context.fetch(oldEntries).forEach(context.delete)
            for (position, song) in snapshot.songs.enumerated() {
                let entry = NSEntityDescription.insertNewObject(forEntityName: "VDPlaylistEntry", into: context)
                entry.setValue(serverKey, forKey: "serverKey")
                entry.setValue(snapshot.playlist.id, forKey: "playlistID")
                entry.setValue(song.id, forKey: "songID")
                entry.setValue(Int64(position), forKey: "position")
            }
        }
    }

    private nonisolated static func replaceFavoriteFlags(
        entityName: String,
        idKey: String,
        favoriteIDs: Set<String>,
        serverKey: String,
        in context: NSManagedObjectContext
    ) throws {
        let request = NSFetchRequest<NSManagedObject>(entityName: entityName)
        request.predicate = NSPredicate(format: "serverKey == %@", serverKey)
        for object in try context.fetch(request) {
            let id = object.value(forKey: idKey) as? String ?? ""
            object.setValue(favoriteIDs.contains(id), forKey: "isFavorite")
        }
    }

    private nonisolated static func reconcile(
        entityName: String,
        idKey: String,
        serverKey: String,
        incomingIDs: Set<String>,
        in context: NSManagedObjectContext
    ) throws {
        let request = NSFetchRequest<NSManagedObject>(entityName: entityName)
        request.predicate = NSPredicate(format: "serverKey == %@", serverKey)
        for object in try context.fetch(request) {
            let id = object.value(forKey: idKey) as? String ?? ""
            if !incomingIDs.contains(id) {
                context.delete(object)
            }
        }
    }

    private nonisolated static func objectsByID(
        entityName: String,
        idKey: String,
        serverKey: String,
        in context: NSManagedObjectContext
    ) throws -> [String: NSManagedObject] {
        let request = NSFetchRequest<NSManagedObject>(entityName: entityName)
        request.predicate = NSPredicate(format: "serverKey == %@", serverKey)
        return Dictionary(
            uniqueKeysWithValues: try context.fetch(request).compactMap { object in
                guard let id = object.value(forKey: idKey) as? String else { return nil }
                return (id, object)
            }
        )
    }

    @discardableResult
    private nonisolated static func upsertArtist(
        _ artist: NavidromeArtist,
        serverKey: String,
        isFavorite: Bool,
        existing: NSManagedObject? = nil,
        existingObjectsArePreloaded: Bool = false,
        in context: NSManagedObjectContext
    ) throws -> NSManagedObject {
        let object = try resolvedObject(
            existing: existing,
            existingObjectsArePreloaded: existingObjectsArePreloaded,
            entityName: "VDArtist",
            idKey: "artistID",
            id: artist.id,
            serverKey: serverKey,
            in: context
        )
        object.setValue(serverKey, forKey: "serverKey")
        object.setValue(artist.id, forKey: "artistID")
        object.setValue(artist.name, forKey: "name")
        object.setValue(artist.albumCount.map { Int64($0) }, forKey: "albumCount")
        object.setValue(artist.coverArt, forKey: "coverArt")
        object.setValue(artist.artistImageURL, forKey: "artistImageURL")
        object.setValue(isFavorite, forKey: "isFavorite")
        return object
    }

    @discardableResult
    private nonisolated static func upsertAlbum(
        _ album: NavidromeAlbum,
        serverKey: String,
        isFavorite: Bool,
        existing: NSManagedObject? = nil,
        existingObjectsArePreloaded: Bool = false,
        in context: NSManagedObjectContext
    ) throws -> NSManagedObject {
        let object = try resolvedObject(
            existing: existing,
            existingObjectsArePreloaded: existingObjectsArePreloaded,
            entityName: "VDAlbum",
            idKey: "albumID",
            id: album.id,
            serverKey: serverKey,
            in: context
        )
        object.setValue(serverKey, forKey: "serverKey")
        object.setValue(album.id, forKey: "albumID")
        object.setValue(album.name, forKey: "name")
        object.setValue(album.artist, forKey: "artist")
        object.setValue(album.artistId, forKey: "artistID")
        object.setValue(album.songCount.map { Int64($0) }, forKey: "songCount")
        object.setValue(album.year.map { Int64($0) }, forKey: "year")
        object.setValue(album.coverArt, forKey: "coverArt")
        object.setValue(album.created, forKey: "created")
        object.setValue(album.played, forKey: "serverPlayedAt")
        object.setValue(isFavorite, forKey: "isFavorite")
        return object
    }

    @discardableResult
    private nonisolated static func upsertSong(
        _ song: NavidromeSong,
        serverKey: String,
        isFavorite: Bool?,
        existing: NSManagedObject? = nil,
        existingObjectsArePreloaded: Bool = false,
        in context: NSManagedObjectContext
    ) throws -> NSManagedObject {
        let object = try resolvedObject(
            existing: existing,
            existingObjectsArePreloaded: existingObjectsArePreloaded,
            entityName: "VDSong",
            idKey: "songID",
            id: song.id,
            serverKey: serverKey,
            in: context
        )

        object.setValue(serverKey, forKey: "serverKey")
        object.setValue(song.id, forKey: "songID")
        object.setValue(song.title, forKey: "title")
        object.setValue(song.artist, forKey: "artist")
        object.setValue(song.album, forKey: "album")
        object.setValue(song.duration.map { Int64($0) }, forKey: "duration")
        object.setValue(song.coverArt, forKey: "coverArt")
        object.setValue(song.albumId, forKey: "albumId")
        object.setValue(song.artistId, forKey: "artistId")
        object.setValue(song.track.map { Int64($0) }, forKey: "track")
        object.setValue(song.discNumber.map { Int64($0) }, forKey: "discNumber")
        object.setValue(song.created, forKey: "created")
        object.setValue(song.played, forKey: "serverPlayedAt")
        if let isFavorite { object.setValue(isFavorite, forKey: "isFavorite") }
        return object
    }

    @discardableResult
    private nonisolated static func upsertPlaylist(
        _ playlist: NavidromePlaylist,
        serverKey: String,
        existing: NSManagedObject? = nil,
        existingObjectsArePreloaded: Bool = false,
        in context: NSManagedObjectContext
    ) throws -> NSManagedObject {
        let object = try resolvedObject(
            existing: existing,
            existingObjectsArePreloaded: existingObjectsArePreloaded,
            entityName: "VDPlaylist",
            idKey: "playlistID",
            id: playlist.id,
            serverKey: serverKey,
            in: context
        )
        object.setValue(serverKey, forKey: "serverKey")
        object.setValue(playlist.id, forKey: "playlistID")
        object.setValue(playlist.name, forKey: "name")
        object.setValue(playlist.songCount.map { Int64($0) }, forKey: "songCount")
        object.setValue(playlist.owner, forKey: "owner")
        object.setValue(playlist.changed, forKey: "changedAt")
        object.setValue(playlist.isReadOnly, forKey: "isReadOnly")
        return object
    }

    private nonisolated static func resolvedObject(
        existing: NSManagedObject?,
        existingObjectsArePreloaded: Bool,
        entityName: String,
        idKey: String,
        id: String,
        serverKey: String,
        in context: NSManagedObjectContext
    ) throws -> NSManagedObject {
        if let existing {
            return existing
        }
        if !existingObjectsArePreloaded,
           let fetched = try object(
               entityName: entityName,
               idKey: idKey,
               id: id,
               serverKey: serverKey,
               in: context
           ) {
            return fetched
        }
        return NSEntityDescription.insertNewObject(forEntityName: entityName, into: context)
    }

    private nonisolated static func syncStateObject(
        serverKey: String,
        createIfMissing: Bool = false,
        in context: NSManagedObjectContext
    ) throws -> NSManagedObject? {
        let request = NSFetchRequest<NSManagedObject>(entityName: "VDMetadataSyncState")
        request.predicate = NSPredicate(format: "serverKey == %@", serverKey)
        request.fetchLimit = 1
        if let object = try context.fetch(request).first { return object }
        guard createIfMissing else { return nil }
        let object = NSEntityDescription.insertNewObject(forEntityName: "VDMetadataSyncState", into: context)
        object.setValue(serverKey, forKey: "serverKey")
        object.setValue(false, forKey: "isComplete")
        return object
    }

    private nonisolated static func object(
        entityName: String,
        idKey: String,
        id: String,
        serverKey: String,
        in context: NSManagedObjectContext
    ) throws -> NSManagedObject? {
        let request = NSFetchRequest<NSManagedObject>(entityName: entityName)
        request.predicate = NSPredicate(format: "%K == %@ AND serverKey == %@", idKey, id, serverKey)
        request.fetchLimit = 1
        return try context.fetch(request).first
    }

    private nonisolated static func songFetchRequest() -> NSFetchRequest<NSManagedObject> {
        NSFetchRequest<NSManagedObject>(entityName: "VDSong")
    }

    private func serverProfile(from object: NSManagedObject) throws -> ServerProfile {
        let credentialID = object.value(forKey: "credentialID") as? String ?? UUID().uuidString
        let password = try keychain.password(for: credentialID) ?? ""

        return ServerProfile(
            id: object.value(forKey: "uuid") as? UUID ?? UUID(),
            name: object.value(forKey: "name") as? String ?? "",
            address: object.value(forKey: "address") as? String ?? "",
            username: object.value(forKey: "username") as? String ?? "",
            credentialID: credentialID,
            password: password,
            createdAt: object.value(forKey: "createdAt") as? Date ?? Date(),
            lastConnectedAt: object.value(forKey: "lastConnectedAt") as? Date
        )
    }

    private nonisolated static func song(from object: NSManagedObject) -> NavidromeSong {
        NavidromeSong(
            id: object.value(forKey: "songID") as? String ?? "",
            title: object.value(forKey: "title") as? String ?? "Untitled",
            artist: object.value(forKey: "artist") as? String,
            album: object.value(forKey: "album") as? String,
            duration: int(object.value(forKey: "duration")),
            coverArt: object.value(forKey: "coverArt") as? String,
            albumId: object.value(forKey: "albumId") as? String,
            artistId: object.value(forKey: "artistId") as? String,
            track: int(object.value(forKey: "track")),
            discNumber: int(object.value(forKey: "discNumber")),
            created: object.value(forKey: "created") as? Date,
            played: object.value(forKey: "serverPlayedAt") as? Date
        )
    }

    private nonisolated static func album(from object: NSManagedObject) -> NavidromeAlbum {
        NavidromeAlbum(
            id: object.value(forKey: "albumID") as? String ?? "",
            name: object.value(forKey: "name") as? String ?? "Untitled Album",
            artist: object.value(forKey: "artist") as? String,
            artistId: object.value(forKey: "artistID") as? String,
            songCount: int(object.value(forKey: "songCount")),
            year: int(object.value(forKey: "year")),
            coverArt: object.value(forKey: "coverArt") as? String,
            created: object.value(forKey: "created") as? Date,
            played: object.value(forKey: "serverPlayedAt") as? Date
        )
    }

    private nonisolated static func artist(from object: NSManagedObject) -> NavidromeArtist {
        NavidromeArtist(
            id: object.value(forKey: "artistID") as? String ?? "",
            name: object.value(forKey: "name") as? String ?? "",
            albumCount: int(object.value(forKey: "albumCount")),
            coverArt: object.value(forKey: "coverArt") as? String,
            artistImageURL: object.value(forKey: "artistImageURL") as? String
        )
    }

    private nonisolated static func playlist(from object: NSManagedObject) -> NavidromePlaylist {
        NavidromePlaylist(
            id: object.value(forKey: "playlistID") as? String ?? "",
            name: object.value(forKey: "name") as? String ?? "Untitled Playlist",
            songCount: int(object.value(forKey: "songCount")),
            owner: object.value(forKey: "owner") as? String,
            changed: object.value(forKey: "changedAt") as? Date,
            isReadOnly: object.value(forKey: "isReadOnly") as? Bool ?? false
        )
    }

    private nonisolated static func int(_ value: Any?) -> Int? {
        if let value = value as? Int64 { return Int(value) }
        if let value = value as? NSNumber { return value.intValue }
        return nil
    }

    private func save() throws {
        guard context.hasChanges else { return }
        try context.save()
    }
}
