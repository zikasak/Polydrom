import Foundation

struct CatalogChangeState: Equatable, Sendable {
    let isScanning: Bool
    let token: String?
}

struct MetadataSyncState: Equatable, Sendable {
    let catalogToken: String?
    let lastCheckedAt: Date?
    let isComplete: Bool
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
