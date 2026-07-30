import Foundation

enum MetadataSyncOutcome: Equatable {
    case full
    case metadataOnly
    case deferredForScan
}

enum LibrarySyncError: LocalizedError {
    case catalogChangedDuringSync

    var errorDescription: String? {
        switch self {
        case .catalogChangedDuringSync:
            "The server library changed during refresh. It will be checked again shortly."
        }
    }
}

@MainActor
final class LibrarySyncCoordinator {
    private let store: LibraryStore
    private let pageSize: Int
    private var inFlight: [
        String: (id: UUID, task: Task<MetadataSyncOutcome, Error>)
    ] = [:]

    init(store: LibraryStore, pageSize: Int = 500) {
        self.store = store
        self.pageSize = max(1, pageSize)
    }

    func synchronize(client: NavidromeClient, serverKey: String) async throws -> MetadataSyncOutcome {
        if let existing = inFlight[serverKey] {
            return try await withTaskCancellationHandler {
                try await existing.task.value
            } onCancel: {
                existing.task.cancel()
            }
        }

        let id = UUID()
        let task = Task {
            try await performSynchronization(client: client, serverKey: serverKey, retryCount: 0)
        }
        inFlight[serverKey] = (id, task)
        defer {
            if inFlight[serverKey]?.id == id {
                inFlight[serverKey] = nil
            }
        }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    private func performSynchronization(
        client: NavidromeClient,
        serverKey: String,
        retryCount: Int
    ) async throws -> MetadataSyncOutcome {
        try Task.checkCancellation()
        let changeState = try await client.catalogChangeState()
        guard !changeState.isScanning else { return .deferredForScan }

        async let playlistsRequest = client.playlists()
        async let starredRequest = client.starredItems()
        let syncState = try await store.metadataSyncState(serverKey: serverKey)
        let requiresFullCatalog = !syncState.isComplete
            || changeState.token == nil
            || syncState.catalogToken != changeState.token

        if requiresFullCatalog {
            async let artistsRequest = loadAllArtists(client: client)
            async let albumsRequest = loadAllAlbums(client: client)
            async let songsRequest = loadAllSongs(client: client)

            let (loadedArtists, loadedAlbums, loadedSongs, playlists, starred) = try await (
                artistsRequest,
                albumsRequest,
                songsRequest,
                playlistsRequest,
                starredRequest
            )
            let playlistSnapshots = try await loadPlaylistSnapshots(playlists, client: client)
            let finalChangeState = try await client.catalogChangeState()

            guard !finalChangeState.isScanning, finalChangeState.token == changeState.token else {
                guard retryCount == 0 else { throw LibrarySyncError.catalogChangedDuringSync }
                return try await performSynchronization(
                    client: client,
                    serverKey: serverKey,
                    retryCount: retryCount + 1
                )
            }

            try Task.checkCancellation()
            let artists = merging(loadedArtists, starred.artists)
            let albums = merging(loadedAlbums, starred.albums)
            let songs = merging(loadedSongs, starred.songs)
            try await store.apply(
                LibrarySnapshot(
                    artists: artists,
                    albums: albums,
                    songs: songs,
                    playlists: playlistSnapshots,
                    favorites: FavoriteMetadata(
                        artistIDs: Set(starred.artists.map(\.id)),
                        albumIDs: Set(starred.albums.map(\.id)),
                        songIDs: Set(starred.songs.map(\.id))
                    ),
                    catalogToken: finalChangeState.token,
                    checkedAt: Date()
                ),
                serverKey: serverKey
            )
            return .full
        }

        let (playlists, starred) = try await (playlistsRequest, starredRequest)
        let cachedDescriptors = try await store.playlistDescriptors(serverKey: serverKey)
        let cachedByID = Dictionary(uniqueKeysWithValues: cachedDescriptors.map { ($0.id, $0) })
        let changedPlaylists = playlists.filter { playlist in
            guard let cached = cachedByID[playlist.id] else { return true }
            guard let changed = playlist.changed, let cachedChanged = cached.changed else { return true }
            return changed != cachedChanged || playlist.songCount != cached.songCount
        }
        let refreshed = try await loadPlaylistSnapshots(changedPlaylists, client: client)
        try Task.checkCancellation()
        try await store.applyUserMetadata(
            playlists: playlists,
            refreshedPlaylists: refreshed,
            favorites: FavoriteMetadata(
                artistIDs: Set(starred.artists.map(\.id)),
                albumIDs: Set(starred.albums.map(\.id)),
                songIDs: Set(starred.songs.map(\.id))
            ),
            serverKey: serverKey,
            checkedAt: Date()
        )
        return .metadataOnly
    }

    private func merging<Value: Identifiable>(_ primary: [Value], _ additions: [Value]) -> [Value] where Value.ID: Hashable {
        var values = primary
        var ids = Set(primary.map(\.id))
        values.append(contentsOf: additions.filter { ids.insert($0.id).inserted })
        return values
    }

    private func loadAllArtists(client: NavidromeClient) async throws -> [NavidromeArtist] {
        var values: [NavidromeArtist] = []
        var seen = Set<String>()
        var offset = 0
        while true {
            try Task.checkCancellation()
            let page = try await client.artistPage(size: pageSize, offset: offset)
            let additions = page.filter { seen.insert($0.id).inserted }
            values.append(contentsOf: additions)
            guard page.count == pageSize, !additions.isEmpty else { return values }
            offset += pageSize
        }
    }

    private func loadAllAlbums(client: NavidromeClient) async throws -> [NavidromeAlbum] {
        var values: [NavidromeAlbum] = []
        var seen = Set<String>()
        var offset = 0
        while true {
            try Task.checkCancellation()
            let page = try await client.albumMetadataPage(size: pageSize, offset: offset)
            let additions = page.filter { seen.insert($0.id).inserted }
            values.append(contentsOf: additions)
            guard page.count == pageSize, !additions.isEmpty else { return values }
            offset += pageSize
        }
    }

    private func loadAllSongs(client: NavidromeClient) async throws -> [NavidromeSong] {
        var values: [NavidromeSong] = []
        var seen = Set<String>()
        var offset = 0
        while true {
            try Task.checkCancellation()
            let page = try await client.songMetadataPage(size: pageSize, offset: offset)
            let additions = page.filter { seen.insert($0.id).inserted }
            values.append(contentsOf: additions)
            guard page.count == pageSize, !additions.isEmpty else { return values }
            offset += pageSize
        }
    }

    private func loadPlaylistSnapshots(
        _ playlists: [NavidromePlaylist],
        client: NavidromeClient
    ) async throws -> [PlaylistMetadataSnapshot] {
        var snapshots: [PlaylistMetadataSnapshot] = []
        snapshots.reserveCapacity(playlists.count)
        for playlist in playlists {
            try Task.checkCancellation()
            snapshots.append(
                PlaylistMetadataSnapshot(
                    playlist: playlist,
                    songs: try await client.songs(for: playlist)
                )
            )
        }
        return snapshots
    }
}
