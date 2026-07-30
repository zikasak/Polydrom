import Foundation

struct CatalogChangeState: Equatable {
    let isScanning: Bool
    let itemCount: Int?
    let token: String?
}

struct MetadataSyncState: Equatable {
    let catalogToken: String?
    let lastCheckedAt: Date?
    let lastFullSyncAt: Date?
    let isComplete: Bool
}

struct FavoriteMetadata: Equatable {
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

    static let empty = FavoriteMetadata(artistIDs: [], albumIDs: [], songIDs: [])
}

struct PlaylistMetadataSnapshot: Equatable {
    let playlist: NavidromePlaylist
    let songs: [NavidromeSong]
}

struct LibrarySnapshot: Equatable {
    let artists: [NavidromeArtist]
    let albums: [NavidromeAlbum]
    let songs: [NavidromeSong]
    let playlists: [PlaylistMetadataSnapshot]
    let favorites: FavoriteMetadata
    let catalogToken: String?
    let checkedAt: Date
}

struct CachedHomeMetadata: Equatable {
    let recentlyAdded: [NavidromeAlbum]
    let recentlyPlayed: [NavidromeAlbum]
    let random: [NavidromeAlbum]
    let featured: [NavidromeAlbum]
}
