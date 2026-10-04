import Foundation
import OSLog

enum MetadataSyncOutcome: Equatable {
    case full
    case metadataOnly
    /// The check completed and the cached library already matched the server.
    case unchanged
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

/// Caps the requests one synchronization has in flight. The catalog loaders run
/// side by side, so the cap has to be shared rather than applied per loader.
private actor RequestLimiter {
    private var available: Int
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(limit: Int) {
        available = limit
    }

    nonisolated func run<Value: Sendable>(
        _ operation: @Sendable () async throws -> Value
    ) async throws -> Value {
        await acquire()
        do {
            // Waiting is not interrupted by cancellation; slots free up quickly
            // because canceled requests fail fast, and the check happens here.
            try Task.checkCancellation()
            let value = try await operation()
            await release()
            return value
        } catch {
            await release()
            throw error
        }
    }

    private func acquire() async {
        if available > 0 {
            available -= 1
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    private func release() {
        if waiters.isEmpty {
            available += 1
        } else {
            waiters.removeFirst().resume()
        }
    }
}

@MainActor
final class LibrarySyncCoordinator {
    private let store: LibraryStore
    private let pageSize: Int
    private let maxConcurrentRequests: Int
    private var inFlight: [
        String: (id: UUID, task: Task<MetadataSyncOutcome, Error>)
    ] = [:]

    init(store: LibraryStore, pageSize: Int = 500, maxConcurrentRequests: Int = 4) {
        self.store = store
        self.pageSize = max(1, pageSize)
        self.maxConcurrentRequests = max(1, maxConcurrentRequests)
    }

    func synchronize(client: NavidromeClient, serverKey: String) async throws -> MetadataSyncOutcome {
        if let existing = inFlight[serverKey] {
            AppLog.sync.debug("Joining in-flight metadata sync for server \(serverKey, privacy: .private(mask: .hash))")
            return try await withTaskCancellationHandler {
                try await existing.task.value
            } onCancel: {
                existing.task.cancel()
            }
        }

        let id = UUID()
        AppLog.sync.info("Metadata sync started for server \(serverKey, privacy: .private(mask: .hash))")
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
            do {
                let outcome = try await task.value
                AppLog.sync.info(
                    "Metadata sync finished for server \(serverKey, privacy: .private(mask: .hash)): \(String(describing: outcome), privacy: .public)"
                )
                return outcome
            } catch {
                AppLog.sync.error(
                    "Metadata sync failed for server \(serverKey, privacy: .private(mask: .hash)): \(error.localizedDescription, privacy: .private)"
                )
                throw error
            }
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
        guard !changeState.isScanning else {
            AppLog.sync.notice("Metadata sync deferred because the server is scanning")
            return .deferredForScan
        }

        let limiter = RequestLimiter(limit: maxConcurrentRequests)
        async let playlistsRequest = limiter.run { try await client.playlists() }
        async let starredRequest = limiter.run { try await client.starredItems() }
        let syncState = try await store.metadataSyncState(serverKey: serverKey)
        let requiresFullCatalog = !syncState.isComplete
            || syncState.requiresCatalogUpgrade
            || changeState.token == nil
            || syncState.catalogToken != changeState.token

        if requiresFullCatalog {
            AppLog.sync.info("Performing full catalog sync")
            async let artistsRequest = loadAllArtists(client: client, limiter: limiter)
            async let albumsRequest = loadAllAlbums(client: client, limiter: limiter)
            async let songsRequest = loadAllSongs(client: client, limiter: limiter)

            let (loadedArtists, loadedAlbums, loadedSongs, playlists, starred) = try await (
                artistsRequest,
                albumsRequest,
                songsRequest,
                playlistsRequest,
                starredRequest
            )
            let playlistSnapshots = try await loadPlaylistSnapshots(playlists, client: client, limiter: limiter)
            let finalChangeState = try await client.catalogChangeState()

            guard !finalChangeState.isScanning, finalChangeState.token == changeState.token else {
                guard retryCount == 0 else {
                    AppLog.sync.error("Catalog changed during metadata sync after retry")
                    throw LibrarySyncError.catalogChangedDuringSync
                }
                AppLog.sync.warning("Catalog changed during metadata sync; retrying once")
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
                    favorites: FavoriteMetadata(starred: starred),
                    catalogToken: finalChangeState.token,
                    checkedAt: Date()
                ),
                serverKey: serverKey
            )
            AppLog.sync.info("Full catalog sync applied")
            AppLog.sync.debug(
                "Full sync counts: \(artists.count, privacy: .public) artists, \(albums.count, privacy: .public) albums"
            )
            AppLog.sync.debug(
                "Full sync counts: \(songs.count, privacy: .public) songs, \(playlistSnapshots.count, privacy: .public) playlists"
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
        AppLog.sync.info(
            "Metadata-only sync: \(playlists.count, privacy: .public) playlists, \(changedPlaylists.count, privacy: .public) changed"
        )
        let refreshed = try await loadPlaylistSnapshots(changedPlaylists, client: client, limiter: limiter)
        try Task.checkCancellation()
        let didChange = try await store.applyUserMetadata(
            playlists: playlists,
            refreshedPlaylists: refreshed,
            favorites: FavoriteMetadata(starred: starred),
            serverKey: serverKey,
            checkedAt: Date()
        )
        return didChange ? .metadataOnly : .unchanged
    }

    private func merging<Value: Identifiable>(_ primary: [Value], _ additions: [Value]) -> [Value] where Value.ID: Hashable {
        var values = primary
        var ids = Set(primary.map(\.id))
        values.append(contentsOf: additions.filter { ids.insert($0.id).inserted })
        return values
    }

    private func loadAllArtists(client: NavidromeClient, limiter: RequestLimiter) async throws -> [NavidromeArtist] {
        try await loadAllPages("artist", limiter: limiter) { [pageSize] offset in
            try await client.artistPage(size: pageSize, offset: offset)
        }
    }

    private func loadAllAlbums(client: NavidromeClient, limiter: RequestLimiter) async throws -> [NavidromeAlbum] {
        try await loadAllPages("album", limiter: limiter) { [pageSize] offset in
            try await client.albumMetadataPage(size: pageSize, offset: offset)
        }
    }

    private func loadAllSongs(client: NavidromeClient, limiter: RequestLimiter) async throws -> [NavidromeSong] {
        try await loadAllPages("song", limiter: limiter) { [pageSize] offset in
            try await client.songMetadataPage(size: pageSize, offset: offset)
        }
    }

    /// Downloads every page of a catalog listing. The first page is requested on
    /// its own so a small library costs one request; a full first page switches to
    /// waves of concurrent requests, which is what keeps large libraries fast.
    /// The limiter keeps the total across all loaders within the configured cap.
    private func loadAllPages<Value: Identifiable & Sendable>(
        _ kind: String,
        limiter: RequestLimiter,
        fetchPage: @escaping @Sendable (_ offset: Int) async throws -> [Value]
    ) async throws -> [Value] where Value.ID == String {
        var values: [Value] = []
        var seen = Set<String>()
        var nextOffset = 0
        var waveSize = 1
        while true {
            try Task.checkCancellation()
            let offsets = (0..<waveSize).map { nextOffset + $0 * pageSize }
            let pages = try await withThrowingTaskGroup(
                of: (offset: Int, page: [Value]).self,
                returning: [(offset: Int, page: [Value])].self
            ) { group in
                for offset in offsets {
                    group.addTask {
                        (offset, try await limiter.run { try await fetchPage(offset) })
                    }
                }
                var pages: [(offset: Int, page: [Value])] = []
                for try await page in group {
                    pages.append(page)
                }
                return pages.sorted { $0.offset < $1.offset }
            }
            for (offset, page) in pages {
                let additions = page.filter { seen.insert($0.id).inserted }
                values.append(contentsOf: additions)
                AppLog.sync.debug(
                    "Loaded \(kind, privacy: .public) page at offset \(offset, privacy: .public): \(additions.count, privacy: .public) new records"
                )
                guard page.count == pageSize, !additions.isEmpty else { return values }
            }
            nextOffset += waveSize * pageSize
            waveSize = maxConcurrentRequests
        }
    }

    private func loadPlaylistSnapshots(
        _ playlists: [NavidromePlaylist],
        client: NavidromeClient,
        limiter: RequestLimiter
    ) async throws -> [PlaylistMetadataSnapshot] {
        guard !playlists.isEmpty else { return [] }
        try Task.checkCancellation()
        let maxConcurrentRequests = self.maxConcurrentRequests
        return try await withThrowingTaskGroup(
            of: (index: Int, snapshot: PlaylistMetadataSnapshot).self,
            returning: [PlaylistMetadataSnapshot].self
        ) { group in
            var snapshots = [PlaylistMetadataSnapshot?](repeating: nil, count: playlists.count)
            for (index, playlist) in playlists.enumerated() {
                if index >= maxConcurrentRequests, let loaded = try await group.next() {
                    snapshots[loaded.index] = loaded.snapshot
                }
                group.addTask {
                    let songs = try await limiter.run { try await client.songs(for: playlist) }
                    return (index, PlaylistMetadataSnapshot(playlist: playlist, songs: songs))
                }
            }
            for try await loaded in group {
                snapshots[loaded.index] = loaded.snapshot
            }
            return snapshots.compactMap { $0 }
        }
    }
}
