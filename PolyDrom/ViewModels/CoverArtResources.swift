import Foundation

private enum CoverArtLimits {
    /// Resources kept before the memo is dropped and rebuilt on demand.
    static let resources = 20_000
    static let prefetch = 200
    /// Covers decoded before a list is shown. Decoding more than the decoded
    /// image cache holds would delay the list only to evict its first rows.
    static let warm = 1_000
}

private enum CoverArtSize {
    static let thumbnail = 96
    /// Thumbnail sizes requested by different views; any of them can stand in
    /// for another without looking soft.
    static let interchangeableThumbnails = [72, 80, 96]
}

extension AppCoordinator {
    /// The size album and artist grids request, which is also what the crawl downloads.
    var gridCoverSize: Int { 220 }

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

    private func coverArtResource(id: String, size: Int) -> CoverArtResource? {
        guard let client, let serverKey else { return nil }
        let cacheKey = "\(serverKey)|\(id)|\(size)"
        if let resource = coverArtResources[cacheKey] {
            return resource
        }

        guard let url = try? client.coverArtURL(id: id, size: size) else { return nil }
        let fallbackCacheKeys: [String]

        if CoverArtSize.interchangeableThumbnails.contains(size) {
            fallbackCacheKeys = CoverArtSize.interchangeableThumbnails
                .filter { $0 != size }
                .map { "\(serverKey)|\(id)|\($0)" }
        } else {
            fallbackCacheKeys = []
        }

        let resource = CoverArtResource(
            cacheKey: cacheKey,
            url: url,
            fallbackCacheKeys: fallbackCacheKeys
        )
        if coverArtResources.count >= CoverArtLimits.resources {
            coverArtResources.removeAll(keepingCapacity: true)
        }
        coverArtResources[cacheKey] = resource
        return resource
    }

    func warmCachedAlbumCovers(_ albums: [NavidromeAlbum]) async {
        let resources = albums.prefix(CoverArtLimits.warm).compactMap { coverArtResource(for: $0, size: gridCoverSize) }
        await coverArtCache.warmCachedImages(resources)
    }

    func warmCachedArtistCovers(_ artists: [NavidromeArtist]) async {
        let resources = artists.prefix(CoverArtLimits.warm).compactMap { coverArtResource(for: $0, size: gridCoverSize) }
        await coverArtCache.warmCachedImages(resources)
    }

    func warmCachedSongCovers(_ songs: [NavidromeSong]) async {
        let resources = songs.prefix(CoverArtLimits.warm).compactMap { coverArtResource(for: $0, size: CoverArtSize.thumbnail) }
        await coverArtCache.warmCachedImages(resources)
    }

    func prefetchAlbumCovers(_ albums: [NavidromeAlbum]) {
        let resources = albums.prefix(CoverArtLimits.prefetch).compactMap { coverArtResource(for: $0, size: gridCoverSize) }
        albumCoverPrefetchTask?.cancel()
        albumCoverPrefetchTask = prefetchCoverArt(resources)
    }

    func prefetchArtistCovers(_ artists: [NavidromeArtist]) {
        let resources = artists.prefix(CoverArtLimits.prefetch).compactMap { coverArtResource(for: $0, size: gridCoverSize) }
        artistCoverPrefetchTask?.cancel()
        artistCoverPrefetchTask = prefetchCoverArt(resources)
    }

    func prefetchSongCovers(_ songs: [NavidromeSong]) {
        let resources = songs.prefix(CoverArtLimits.prefetch).compactMap { coverArtResource(for: $0, size: CoverArtSize.thumbnail) }
        songCoverPrefetchTask?.cancel()
        songCoverPrefetchTask = prefetchCoverArt(resources)
    }

    func cancelCoverArtPrefetchTasks() {
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
}
