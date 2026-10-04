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
        self.init(persistence: .shared, keychain: CredentialStore())
    }

    func servers() throws -> [ServerProfile] {
        let request = NSFetchRequest<NSManagedObject>(entityName: LibraryEntity.server.rawValue)
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
        let songObject = Self.upsertSong(
            song,
            serverKey: serverKey,
            isFavorite: nil,
            existing: try Self.object(.song, id: song.id, serverKey: serverKey, in: context),
            in: context
        )
        let now = Date()
        songObject.setValue(now, forKey: "lastPlayedAt")

        if let albumID = song.albumId,
           let album = try Self.object(.album, id: albumID, serverKey: serverKey, in: context) {
            album.setValue(now, forKey: "lastPlayedAt")
        }
        try save()
    }

    // MARK: - Cached queries

    func metadataSyncState(serverKey: String) async throws -> MetadataSyncState {
        try await performBackground { context in
            guard let object = try Self.syncStateObject(serverKey: serverKey, in: context) else {
                return MetadataSyncState(
                    catalogToken: nil,
                    lastCheckedAt: nil,
                    isComplete: false,
                    catalogVersion: 0
                )
            }
            return MetadataSyncState(
                catalogToken: object.string("catalogToken"),
                lastCheckedAt: object.date("lastCheckedAt"),
                isComplete: object.bool("isComplete"),
                catalogVersion: object.int("catalogVersion").map(Int64.init) ?? 0
            )
        }
    }

    func artists(serverKey: String) async throws -> [NavidromeArtist] {
        try await performBackground { context in
            let request = Self.request(
                .artist,
                serverKey: serverKey,
                matching: NSPredicate(format: "albumCount == nil OR albumCount > 0"),
                sortedBy: [.caseInsensitive("name")]
            )
            return try context.fetch(request).map(Self.artist(from:))
        }
    }

    func albums(serverKey: String, artistID: String? = nil) async throws -> [NavidromeAlbum] {
        try await performBackground { context in
            let request: NSFetchRequest<NSManagedObject>
            if let artistID {
                request = Self.request(
                    .album,
                    serverKey: serverKey,
                    matching: NSPredicate(format: "artistID == %@", artistID),
                    sortedBy: [.ascending("year"), .caseInsensitive("name")]
                )
            } else {
                request = Self.request(.album, serverKey: serverKey, sortedBy: [.caseInsensitive("name")])
            }
            return try context.fetch(request).map(Self.album(from:))
        }
    }

    func songs(serverKey: String, albumID: String) async throws -> [NavidromeSong] {
        try await performBackground { context in
            let request = Self.request(
                .song,
                serverKey: serverKey,
                matching: NSPredicate(format: "albumId == %@", albumID),
                sortedBy: Self.albumTrackOrder
            )
            return try context.fetch(request).map(Self.song(from:))
        }
    }

    func genres(serverKey: String) async throws -> [NavidromeGenre] {
        try await performBackground { context in
            let request = Self.request(.genre, serverKey: serverKey, sortedBy: [.caseInsensitive("name")])
            return try context.fetch(request).map(Self.genre(from:))
        }
    }

    func songs(serverKey: String, genreID: String) async throws -> [NavidromeSong] {
        try await performBackground { context in
            let membershipRequest = Self.request(
                .genreSong,
                serverKey: serverKey,
                matching: NSPredicate(format: "genreID == %@", genreID)
            )
            let songIDs = try context.fetch(membershipRequest).compactMap { $0.string("songID") }
            guard !songIDs.isEmpty else { return [] }

            let request = Self.request(
                .song,
                serverKey: serverKey,
                matching: NSPredicate(format: "songID IN %@", songIDs),
                sortedBy: [
                    .caseInsensitive("title"),
                    .caseInsensitive("artist"),
                    .caseInsensitive("album"),
                    .ascending("discNumber"),
                    .ascending("track"),
                    .ascending("songID")
                ]
            )
            return try context.fetch(request).map(Self.song(from:))
        }
    }

    func playlists(serverKey: String) async throws -> [NavidromePlaylist] {
        try await performBackground { context in
            let request = Self.request(.playlist, serverKey: serverKey, sortedBy: [.caseInsensitive("name")])
            return try context.fetch(request).map(Self.playlist(from:))
        }
    }

    func playlistDescriptors(serverKey: String) async throws -> [CachedPlaylistDescriptor] {
        try await performBackground { context in
            try context.fetch(Self.request(.playlist, serverKey: serverKey)).map {
                CachedPlaylistDescriptor(
                    id: $0.string("playlistID") ?? "",
                    changed: $0.date("changedAt"),
                    songCount: $0.int("songCount")
                )
            }
        }
    }

    func songs(serverKey: String, playlistID: String) async throws -> [NavidromeSong] {
        try await performBackground { context in
            let entryRequest = Self.playlistEntryRequest(playlistID: playlistID, serverKey: serverKey)
            let songIDs = try context.fetch(entryRequest).compactMap { $0.string("songID") }
            guard !songIDs.isEmpty else { return [] }

            let songRequest = Self.request(
                .song,
                serverKey: serverKey,
                matching: NSPredicate(format: "songID IN %@", songIDs)
            )
            let songsByID = Dictionary(uniqueKeysWithValues: try context.fetch(songRequest).map {
                ($0.string("songID") ?? "", Self.song(from: $0))
            })
            return songIDs.compactMap { songsByID[$0] }
        }
    }

    func favoriteArtists(serverKey: String) async throws -> [NavidromeArtist] {
        try await performBackground { context in
            try context.fetch(Self.favoritesRequest(.artist, serverKey: serverKey, sortKey: "name"))
                .map(Self.artist(from:))
        }
    }

    func favoriteAlbums(serverKey: String) async throws -> [NavidromeAlbum] {
        try await performBackground { context in
            try context.fetch(Self.favoritesRequest(.album, serverKey: serverKey, sortKey: "name"))
                .map(Self.album(from:))
        }
    }

    func favoriteSongs(serverKey: String) async throws -> [NavidromeSong] {
        try await performBackground { context in
            try context.fetch(Self.favoritesRequest(.song, serverKey: serverKey, sortKey: "title"))
                .map(Self.song(from:))
        }
    }

    func recentSongs(serverKey: String, limit: Int = 50) async throws -> [NavidromeSong] {
        try await performBackground { context in
            let request = Self.request(
                .song,
                serverKey: serverKey,
                matching: NSPredicate(format: "lastPlayedAt != nil"),
                sortedBy: [NSSortDescriptor(key: "lastPlayedAt", ascending: false)]
            )
            request.fetchLimit = limit
            return try context.fetch(request).map(Self.song(from:))
        }
    }

    func searchSongs(_ query: String, serverKey: String, limit: Int = 100) async throws -> [NavidromeSong] {
        try await performBackground { context in
            let request = Self.request(
                .song,
                serverKey: serverKey,
                matching: NSCompoundPredicate(orPredicateWithSubpredicates: [
                    NSPredicate(format: "title CONTAINS[cd] %@", query),
                    NSPredicate(format: "artist CONTAINS[cd] %@", query),
                    NSPredicate(format: "album CONTAINS[cd] %@", query)
                ]),
                sortedBy: [.caseInsensitive("title")]
            )
            request.fetchLimit = limit
            return try context.fetch(request).map(Self.song(from:))
        }
    }

    func randomSongs(serverKey: String, count: Int? = nil) async throws -> [NavidromeSong] {
        try await performBackground { context in
            let shuffledSongs = try context.fetch(Self.request(.song, serverKey: serverKey)).shuffled()
            guard let count else {
                return shuffledSongs.map(Self.song(from:))
            }
            return shuffledSongs.prefix(max(0, count)).map(Self.song(from:))
        }
    }

    func songsShuffledByAlbum(serverKey: String) async throws -> [NavidromeSong] {
        try await performBackground { context in
            let request = Self.request(.song, serverKey: serverKey, sortedBy: Self.albumTrackOrder)
            let songs = try context.fetch(request).map(Self.song(from:))
            let albumGroups = Dictionary(grouping: songs) { song in
                if let albumID = song.albumId, !albumID.isEmpty {
                    return "album:\(albumID)"
                }
                return "song:\(song.id)"
            }
            return albumGroups.values.shuffled().flatMap { $0 }
        }
    }

    func homeMetadata(serverKey: String) async throws -> CachedHomeMetadata {
        try await performBackground { context in
            let shelfSize = 12
            let objects = try context.fetch(Self.request(.album, serverKey: serverKey))

            func newest(by date: (NSManagedObject) -> Date?) -> [NavidromeAlbum] {
                objects
                    .compactMap { object in date(object).map { (object: object, date: $0) } }
                    .sorted { $0.date > $1.date }
                    .prefix(shelfSize)
                    .map { Self.album(from: $0.object) }
            }

            let shuffled = objects.shuffled()
            return CachedHomeMetadata(
                recentlyAdded: newest { $0.date("created") },
                recentlyPlayed: newest { $0.date("lastPlayedAt") ?? $0.date("serverPlayedAt") },
                random: shuffled.prefix(shelfSize).map(Self.album(from:)),
                featured: shuffled.prefix(5).map(Self.album(from:))
            )
        }
    }

    // MARK: - Atomic reconciliation

    func apply(_ snapshot: LibrarySnapshot, serverKey: String) async throws {
        try await performBackground { context in
            let favorites = snapshot.favorites

            let existingArtists = try Self.objectsByID(.artist, serverKey: serverKey, in: context)
            Self.deleteMissing(existingArtists, incomingIDs: Set(snapshot.artists.map(\.id)), in: context)
            for artist in snapshot.artists {
                Self.upsertArtist(
                    artist,
                    serverKey: serverKey,
                    isFavorite: favorites.artistIDs.contains(artist.id),
                    existing: existingArtists[artist.id],
                    in: context
                )
            }

            let existingAlbums = try Self.objectsByID(.album, serverKey: serverKey, in: context)
            Self.deleteMissing(existingAlbums, incomingIDs: Set(snapshot.albums.map(\.id)), in: context)
            for album in snapshot.albums {
                Self.upsertAlbum(
                    album,
                    serverKey: serverKey,
                    isFavorite: favorites.albumIDs.contains(album.id),
                    existing: existingAlbums[album.id],
                    in: context
                )
            }

            var allSongs = snapshot.songs
            var knownSongIDs = Set(allSongs.map(\.id))
            for song in snapshot.playlists.flatMap(\.songs) where knownSongIDs.insert(song.id).inserted {
                allSongs.append(song)
            }
            let existingSongs = try Self.objectsByID(.song, serverKey: serverKey, in: context)
            Self.deleteMissing(existingSongs, incomingIDs: knownSongIDs, in: context)
            for song in allSongs {
                Self.upsertSong(
                    song,
                    serverKey: serverKey,
                    isFavorite: favorites.songIDs.contains(song.id),
                    replaceGenres: true,
                    existing: existingSongs[song.id],
                    in: context
                )
            }
            try Self.replaceGenres(with: allSongs, serverKey: serverKey, in: context)

            // Every playlist song was already written with the catalog above.
            try Self.replacePlaylists(
                summaries: snapshot.playlists.map(\.playlist),
                refreshed: snapshot.playlists,
                upsertsSongs: false,
                serverKey: serverKey,
                in: context
            )

            let state = try Self.syncStateObject(serverKey: serverKey, createIfMissing: true, in: context)
            state?.setValue(snapshot.catalogToken, forKey: "catalogToken")
            state?.setValue(snapshot.checkedAt, forKey: "lastCheckedAt")
            state?.setValue(true, forKey: "isComplete")
            state?.setValue(MetadataSyncState.currentCatalogVersion, forKey: "catalogVersion")
            try context.save()
        }
    }

    /// Returns whether any playlist or favorite actually changed.
    func applyUserMetadata(
        playlists: [NavidromePlaylist],
        refreshedPlaylists: [PlaylistMetadataSnapshot],
        favorites: FavoriteMetadata,
        serverKey: String,
        checkedAt: Date
    ) async throws -> Bool {
        try await performBackground { context in
            try Self.replacePlaylists(
                summaries: playlists,
                refreshed: refreshedPlaylists,
                serverKey: serverKey,
                in: context
            )
            try Self.replaceFavoriteFlags(.artist, favoriteIDs: favorites.artistIDs, serverKey: serverKey, in: context)
            try Self.replaceFavoriteFlags(.album, favoriteIDs: favorites.albumIDs, serverKey: serverKey, in: context)
            try Self.replaceFavoriteFlags(.song, favoriteIDs: favorites.songIDs, serverKey: serverKey, in: context)
            // Checked before the timestamp is stamped, which always dirties the context.
            let didChange = context.hasChanges
            let state = try Self.syncStateObject(serverKey: serverKey, createIfMissing: true, in: context)
            state?.setValue(checkedAt, forKey: "lastCheckedAt")
            try context.save()
            return didChange
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

    func setFavorite(_ isFavorite: Bool, _ record: LibraryRecord, id: String, serverKey: String) async throws {
        try await performBackground { context in
            if let object = try Self.object(record, id: id, serverKey: serverKey, in: context) {
                object.setValue(isFavorite, forKey: "isFavorite")
                try context.save()
            }
        }
    }

    // MARK: - Core Data helpers

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
        for entity in LibraryEntity.libraryCache {
            let request = NSFetchRequest<NSManagedObject>(entityName: entity.rawValue)
            if let serverKey {
                request.predicate = NSPredicate(format: "serverKey == %@", serverKey)
            }
            try context.fetch(request).forEach(context.delete)
        }
    }

    private func save() throws {
        guard context.hasChanges else { return }
        try context.save()
    }

    // MARK: - Requests

    /// Disc, then track, then title: the order songs have on their album.
    private nonisolated static var albumTrackOrder: [NSSortDescriptor] {
        [.ascending("discNumber"), .ascending("track"), .caseInsensitive("title")]
    }

    /// A request for one server's rows of `entity`, optionally narrowed by `condition`.
    private nonisolated static func request(
        _ entity: LibraryEntity,
        serverKey: String,
        matching condition: NSPredicate? = nil,
        sortedBy sortDescriptors: [NSSortDescriptor] = []
    ) -> NSFetchRequest<NSManagedObject> {
        let request = NSFetchRequest<NSManagedObject>(entityName: entity.rawValue)
        let serverScope = NSPredicate(format: "serverKey == %@", serverKey)
        request.predicate = condition.map {
            NSCompoundPredicate(andPredicateWithSubpredicates: [serverScope, $0])
        } ?? serverScope
        request.sortDescriptors = sortDescriptors
        return request
    }

    private nonisolated static func favoritesRequest(
        _ entity: LibraryEntity,
        serverKey: String,
        sortKey: String
    ) -> NSFetchRequest<NSManagedObject> {
        request(
            entity,
            serverKey: serverKey,
            matching: NSPredicate(format: "isFavorite == YES"),
            sortedBy: [.caseInsensitive(sortKey)]
        )
    }

    private nonisolated static func playlistEntryRequest(
        playlistID: String,
        serverKey: String
    ) -> NSFetchRequest<NSManagedObject> {
        request(
            .playlistEntry,
            serverKey: serverKey,
            matching: NSPredicate(format: "playlistID == %@", playlistID),
            sortedBy: [.ascending("position")]
        )
    }

    private nonisolated static func object(
        _ record: LibraryRecord,
        id: String,
        serverKey: String,
        in context: NSManagedObjectContext
    ) throws -> NSManagedObject? {
        let request = request(
            record.entity,
            serverKey: serverKey,
            matching: NSPredicate(format: "%K == %@", record.idKey, id)
        )
        request.fetchLimit = 1
        return try context.fetch(request).first
    }

    private nonisolated static func objectsByID(
        _ record: LibraryRecord,
        serverKey: String,
        ids: Set<String>? = nil,
        in context: NSManagedObjectContext
    ) throws -> [String: NSManagedObject] {
        let request = request(
            record.entity,
            serverKey: serverKey,
            matching: ids.map { NSPredicate(format: "%K IN %@", record.idKey, Array($0)) }
        )
        return Dictionary(
            uniqueKeysWithValues: try context.fetch(request).compactMap { object in
                guard let id = object.string(record.idKey) else { return nil }
                return (id, object)
            }
        )
    }

    private nonisolated static func syncStateObject(
        serverKey: String,
        createIfMissing: Bool = false,
        in context: NSManagedObjectContext
    ) throws -> NSManagedObject? {
        let request = request(.syncState, serverKey: serverKey)
        request.fetchLimit = 1
        if let object = try context.fetch(request).first { return object }
        guard createIfMissing else { return nil }
        let object = insert(.syncState, into: context)
        object.setValue(serverKey, forKey: "serverKey")
        object.setValue(false, forKey: "isComplete")
        return object
    }

    private nonisolated static func insert(
        _ entity: LibraryEntity,
        into context: NSManagedObjectContext
    ) -> NSManagedObject {
        NSEntityDescription.insertNewObject(forEntityName: entity.rawValue, into: context)
    }

    // MARK: - Reconciliation

    private nonisolated static func replaceGenres(
        with songs: [NavidromeSong],
        serverKey: String,
        in context: NSManagedObjectContext
    ) throws {
        var displayNames: [String: String] = [:]
        var songIDsByGenre: [String: Set<String>] = [:]
        for song in songs {
            for name in song.genres {
                let genreID = NavidromeGenre.normalizedID(for: name)
                guard !genreID.isEmpty else { continue }
                if displayNames[genreID] == nil {
                    displayNames[genreID] = name
                }
                songIDsByGenre[genreID, default: []].insert(song.id)
            }
        }

        // Memberships are diffed rather than rebuilt: there is one row per song
        // and genre, and almost none of them change between scans.
        var staleGenres = try objectsByID(.genre, serverKey: serverKey, in: context)
        var staleMemberships: [String: [String: NSManagedObject]] = [:]
        for membership in try context.fetch(request(.genreSong, serverKey: serverKey)) {
            guard let genreID = membership.string("genreID"),
                  let songID = membership.string("songID") else {
                context.delete(membership)
                continue
            }
            staleMemberships[genreID, default: [:]][songID] = membership
        }

        for (genreID, songIDs) in songIDsByGenre {
            guard let name = displayNames[genreID] else { continue }
            let genre = staleGenres.removeValue(forKey: genreID) ?? insert(.genre, into: context)
            assign(serverKey, forKey: "serverKey", to: genre)
            assign(genreID, forKey: "genreID", to: genre)
            assign(name, forKey: "name", to: genre)
            assign(Int64(songIDs.count), forKey: "songCount", to: genre)

            var staleSongs = staleMemberships.removeValue(forKey: genreID) ?? [:]
            for songID in songIDs where staleSongs.removeValue(forKey: songID) == nil {
                let membership = insert(.genreSong, into: context)
                membership.setValue(serverKey, forKey: "serverKey")
                membership.setValue(genreID, forKey: "genreID")
                membership.setValue(songID, forKey: "songID")
            }
            staleSongs.values.forEach(context.delete)
        }

        staleGenres.values.forEach(context.delete)
        for memberships in staleMemberships.values {
            memberships.values.forEach(context.delete)
        }
    }

    private nonisolated static func replacePlaylists(
        summaries: [NavidromePlaylist],
        refreshed: [PlaylistMetadataSnapshot],
        upsertsSongs: Bool = true,
        serverKey: String,
        in context: NSManagedObjectContext
    ) throws {
        let incomingIDs = Set(summaries.map(\.id))
        let existingPlaylists = try objectsByID(.playlist, serverKey: serverKey, in: context)
        deleteMissing(existingPlaylists, incomingIDs: incomingIDs, in: context)

        let staleEntryRequest = request(
            .playlistEntry,
            serverKey: serverKey,
            matching: incomingIDs.isEmpty ? nil : NSPredicate(format: "NOT (playlistID IN %@)", Array(incomingIDs))
        )
        try context.fetch(staleEntryRequest).forEach(context.delete)

        for playlist in summaries {
            upsertPlaylist(playlist, serverKey: serverKey, existing: existingPlaylists[playlist.id], in: context)
        }

        // Only the songs these playlists reference are loaded, not the library.
        var existingSongs: [String: NSManagedObject] = [:]
        if upsertsSongs {
            let playlistSongIDs = Set(refreshed.flatMap { $0.songs.map(\.id) })
            if !playlistSongIDs.isEmpty {
                existingSongs = try objectsByID(.song, serverKey: serverKey, ids: playlistSongIDs, in: context)
            }
        }
        for snapshot in refreshed {
            if upsertsSongs {
                for song in snapshot.songs {
                    existingSongs[song.id] = upsertSong(
                        song,
                        serverKey: serverKey,
                        isFavorite: nil,
                        existing: existingSongs[song.id],
                        in: context
                    )
                }
            }
            let entryRequest = playlistEntryRequest(playlistID: snapshot.playlist.id, serverKey: serverKey)
            let oldEntries = try context.fetch(entryRequest)
            for (position, song) in snapshot.songs.enumerated() {
                let entry = position < oldEntries.count ? oldEntries[position] : insert(.playlistEntry, into: context)
                assign(serverKey, forKey: "serverKey", to: entry)
                assign(snapshot.playlist.id, forKey: "playlistID", to: entry)
                assign(song.id, forKey: "songID", to: entry)
                assign(Int64(position), forKey: "position", to: entry)
            }
            oldEntries.dropFirst(snapshot.songs.count).forEach(context.delete)
        }
    }

    private nonisolated static func replaceFavoriteFlags(
        _ record: LibraryRecord,
        favoriteIDs: Set<String>,
        serverKey: String,
        in context: NSManagedObjectContext
    ) throws {
        // Only rows whose flag can change are loaded: current favorites and new ones.
        let request = request(
            record.entity,
            serverKey: serverKey,
            matching: NSPredicate(format: "isFavorite == YES OR %K IN %@", record.idKey, Array(favoriteIDs))
        )
        for object in try context.fetch(request) {
            let id = object.string(record.idKey) ?? ""
            assign(favoriteIDs.contains(id), forKey: "isFavorite", to: object)
        }
    }

    private nonisolated static func deleteMissing(
        _ existing: [String: NSManagedObject],
        incomingIDs: Set<String>,
        in context: NSManagedObjectContext
    ) {
        for (id, object) in existing where !incomingIDs.contains(id) {
            context.delete(object)
        }
    }

    /// Assigning an attribute marks the object as changed even when the value is
    /// identical, which makes a save rewrite every row of an unchanged library.
    private nonisolated static func assign(_ value: Any?, forKey key: String, to object: NSManagedObject) {
        let current = object.value(forKey: key)
        if current == nil, value == nil { return }
        if let current = current as? NSObject, let value, current.isEqual(value) { return }
        object.setValue(value, forKey: key)
    }

    private nonisolated static func upsertArtist(
        _ artist: NavidromeArtist,
        serverKey: String,
        isFavorite: Bool,
        existing: NSManagedObject?,
        in context: NSManagedObjectContext
    ) {
        let object = existing ?? insert(.artist, into: context)
        assign(serverKey, forKey: "serverKey", to: object)
        assign(artist.id, forKey: "artistID", to: object)
        assign(artist.name, forKey: "name", to: object)
        assign(artist.albumCount.map { Int64($0) }, forKey: "albumCount", to: object)
        assign(artist.coverArt, forKey: "coverArt", to: object)
        assign(artist.artistImageURL, forKey: "artistImageURL", to: object)
        assign(isFavorite, forKey: "isFavorite", to: object)
    }

    private nonisolated static func upsertAlbum(
        _ album: NavidromeAlbum,
        serverKey: String,
        isFavorite: Bool,
        existing: NSManagedObject?,
        in context: NSManagedObjectContext
    ) {
        let object = existing ?? insert(.album, into: context)
        assign(serverKey, forKey: "serverKey", to: object)
        assign(album.id, forKey: "albumID", to: object)
        assign(album.name, forKey: "name", to: object)
        assign(album.artist, forKey: "artist", to: object)
        assign(album.artistId, forKey: "artistID", to: object)
        assign(album.songCount.map { Int64($0) }, forKey: "songCount", to: object)
        assign(album.year.map { Int64($0) }, forKey: "year", to: object)
        assign(album.coverArt, forKey: "coverArt", to: object)
        assign(album.created, forKey: "created", to: object)
        assign(album.played, forKey: "serverPlayedAt", to: object)
        assign(isFavorite, forKey: "isFavorite", to: object)
    }

    /// `isFavorite` is left untouched when nil. Genres are only written for a
    /// new row unless `replaceGenres` is set, as playlist entries may omit them.
    /// A missing file format likewise never erases a known one.
    @discardableResult
    private nonisolated static func upsertSong(
        _ song: NavidromeSong,
        serverKey: String,
        isFavorite: Bool?,
        replaceGenres: Bool = false,
        existing: NSManagedObject?,
        in context: NSManagedObjectContext
    ) -> NSManagedObject {
        let object = existing ?? insert(.song, into: context)
        assign(serverKey, forKey: "serverKey", to: object)
        assign(song.id, forKey: "songID", to: object)
        assign(song.title, forKey: "title", to: object)
        assign(song.artist, forKey: "artist", to: object)
        assign(song.album, forKey: "album", to: object)
        assign(song.duration.map { Int64($0) }, forKey: "duration", to: object)
        assign(song.coverArt, forKey: "coverArt", to: object)
        assign(song.albumId, forKey: "albumId", to: object)
        assign(song.artistId, forKey: "artistId", to: object)
        assign(song.track.map { Int64($0) }, forKey: "track", to: object)
        assign(song.discNumber.map { Int64($0) }, forKey: "discNumber", to: object)
        assign(song.created, forKey: "created", to: object)
        assign(song.played, forKey: "serverPlayedAt", to: object)
        if replaceGenres || object.value(forKey: "genresData") == nil,
           let genresData = try? genresEncoder.encode(song.genres) {
            assign(genresData, forKey: "genresData", to: object)
        }
        if let suffix = song.suffix { assign(suffix, forKey: "suffix", to: object) }
        if let isFavorite { assign(isFavorite, forKey: "isFavorite", to: object) }
        return object
    }

    private nonisolated static func upsertPlaylist(
        _ playlist: NavidromePlaylist,
        serverKey: String,
        existing: NSManagedObject?,
        in context: NSManagedObjectContext
    ) {
        let object = existing ?? insert(.playlist, into: context)
        assign(serverKey, forKey: "serverKey", to: object)
        assign(playlist.id, forKey: "playlistID", to: object)
        assign(playlist.name, forKey: "name", to: object)
        assign(playlist.songCount.map { Int64($0) }, forKey: "songCount", to: object)
        assign(playlist.owner, forKey: "owner", to: object)
        assign(playlist.changed, forKey: "changedAt", to: object)
        assign(playlist.isReadOnly, forKey: "isReadOnly", to: object)
    }

    // MARK: - Model mapping

    private nonisolated static let genresEncoder = JSONEncoder()

    private func serverProfile(from object: NSManagedObject) throws -> ServerProfile {
        let credentialID = object.string("credentialID") ?? UUID().uuidString
        let password = try keychain.password(for: credentialID) ?? ""

        return ServerProfile(
            id: object.value(forKey: "uuid") as? UUID ?? UUID(),
            name: object.string("name") ?? "",
            address: object.string("address") ?? "",
            username: object.string("username") ?? "",
            credentialID: credentialID,
            password: password,
            createdAt: object.date("createdAt") ?? Date(),
            lastConnectedAt: object.date("lastConnectedAt")
        )
    }

    private nonisolated static func song(from object: NSManagedObject) -> NavidromeSong {
        NavidromeSong(
            id: object.string("songID") ?? "",
            title: object.string("title") ?? "Untitled",
            artist: object.string("artist"),
            album: object.string("album"),
            duration: object.int("duration"),
            coverArt: object.string("coverArt"),
            albumId: object.string("albumId"),
            artistId: object.string("artistId"),
            track: object.int("track"),
            discNumber: object.int("discNumber"),
            created: object.date("created"),
            played: object.date("serverPlayedAt"),
            suffix: object.string("suffix"),
            genres: decodedGenres(from: object)
        )
    }

    private nonisolated static func decodedGenres(from object: NSManagedObject) -> [String] {
        guard let data = object.value(forKey: "genresData") as? Data else { return [] }
        return (try? JSONDecoder().decode([String].self, from: data)) ?? []
    }

    private nonisolated static func album(from object: NSManagedObject) -> NavidromeAlbum {
        NavidromeAlbum(
            id: object.string("albumID") ?? "",
            name: object.string("name") ?? "Untitled Album",
            artist: object.string("artist"),
            artistId: object.string("artistID"),
            songCount: object.int("songCount"),
            year: object.int("year"),
            coverArt: object.string("coverArt"),
            created: object.date("created"),
            played: object.date("serverPlayedAt")
        )
    }

    private nonisolated static func genre(from object: NSManagedObject) -> NavidromeGenre {
        NavidromeGenre(
            name: object.string("name") ?? "",
            songCount: object.int("songCount") ?? 0
        )
    }

    private nonisolated static func artist(from object: NSManagedObject) -> NavidromeArtist {
        NavidromeArtist(
            id: object.string("artistID") ?? "",
            name: object.string("name") ?? "",
            albumCount: object.int("albumCount"),
            coverArt: object.string("coverArt"),
            artistImageURL: object.string("artistImageURL")
        )
    }

    private nonisolated static func playlist(from object: NSManagedObject) -> NavidromePlaylist {
        NavidromePlaylist(
            id: object.string("playlistID") ?? "",
            name: object.string("name") ?? "Untitled Playlist",
            songCount: object.int("songCount"),
            owner: object.string("owner"),
            changed: object.date("changedAt"),
            isReadOnly: object.bool("isReadOnly")
        )
    }
}

private extension NSSortDescriptor {
    nonisolated static func ascending(_ key: String) -> NSSortDescriptor {
        NSSortDescriptor(key: key, ascending: true)
    }

    nonisolated static func caseInsensitive(_ key: String) -> NSSortDescriptor {
        NSSortDescriptor(
            key: key,
            ascending: true,
            selector: #selector(NSString.localizedCaseInsensitiveCompare(_:))
        )
    }
}

private extension NSManagedObject {
    nonisolated func string(_ key: String) -> String? {
        value(forKey: key) as? String
    }

    nonisolated func date(_ key: String) -> Date? {
        value(forKey: key) as? Date
    }

    nonisolated func bool(_ key: String) -> Bool {
        value(forKey: key) as? Bool ?? false
    }

    nonisolated func int(_ key: String) -> Int? {
        if let value = value(forKey: key) as? Int64 { return Int(value) }
        if let value = value(forKey: key) as? NSNumber { return value.intValue }
        return nil
    }
}
