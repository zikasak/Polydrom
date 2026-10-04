import Foundation

enum MetadataRefreshInterval: Int, CaseIterable, Identifiable, Sendable {
    case manually = 0
    case fiveMinutes = 300
    case fifteenMinutes = 900
    case thirtyMinutes = 1_800
    case oneHour = 3_600

    var id: Self { self }

    var title: String {
        switch self {
        case .manually:
            "Manually"
        case .fiveMinutes:
            "Every 5 minutes"
        case .fifteenMinutes:
            "Every 15 minutes"
        case .thirtyMinutes:
            "Every 30 minutes"
        case .oneHour:
            "Every hour"
        }
    }

    var seconds: Int64? {
        self == .manually ? nil : Int64(rawValue)
    }
}

struct CatalogChangeState: Equatable, Sendable {
    let isScanning: Bool
    let token: String?
}

struct MetadataSyncState: Equatable, Sendable {
    /// Raised whenever the cache starts keeping something an existing cache
    /// lacks, which makes the next refresh download the whole catalog again.
    /// Version 2 added each song's file format.
    static let currentCatalogVersion: Int64 = 2

    let catalogToken: String?
    let lastCheckedAt: Date?
    let isComplete: Bool
    let catalogVersion: Int64

    var requiresCatalogUpgrade: Bool {
        catalogVersion < Self.currentCatalogVersion
    }
}

/// Everything the user has starred on the server.
struct StarredItems: Sendable {
    let artists: [NavidromeArtist]
    let albums: [NavidromeAlbum]
    let songs: [NavidromeSong]
}

struct FavoriteMetadata: Equatable, Sendable {
    var artistIDs: Set<String>
    var albumIDs: Set<String>
    var songIDs: Set<String>

    init(
        artistIDs: Set<String> = [],
        albumIDs: Set<String> = [],
        songIDs: Set<String> = []
    ) {
        self.artistIDs = artistIDs
        self.albumIDs = albumIDs
        self.songIDs = songIDs
    }

    init(starred: StarredItems) {
        self.init(
            artistIDs: Set(starred.artists.map(\.id)),
            albumIDs: Set(starred.albums.map(\.id)),
            songIDs: Set(starred.songs.map(\.id))
        )
    }
}

struct PlaylistMetadataSnapshot: Equatable, Sendable {
    let playlist: NavidromePlaylist
    let songs: [NavidromeSong]
}

struct LibrarySnapshot: Equatable, Sendable {
    let artists: [NavidromeArtist]
    let albums: [NavidromeAlbum]
    let songs: [NavidromeSong]
    let playlists: [PlaylistMetadataSnapshot]
    let favorites: FavoriteMetadata
    let catalogToken: String?
    let checkedAt: Date
}

struct CachedHomeMetadata: Equatable, Sendable {
    let recentlyAdded: [NavidromeAlbum]
    let recentlyPlayed: [NavidromeAlbum]
    let random: [NavidromeAlbum]
    let featured: [NavidromeAlbum]
}
