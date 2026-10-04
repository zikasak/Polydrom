import Foundation

/// The Core Data entities of the library cache. The raw values are the entity
/// names in the persistent store, so they must not change.
enum LibraryEntity: String, CaseIterable, Sendable {
    case server = "VDServer"
    case song = "VDSong"
    case artist = "VDArtist"
    case album = "VDAlbum"
    case genre = "VDGenre"
    case genreSong = "VDGenreSong"
    case playlist = "VDPlaylist"
    case playlistEntry = "VDPlaylistEntry"
    case syncState = "VDMetadataSyncState"

    /// Everything that is rebuilt from the server, as opposed to the legacy
    /// server profiles.
    static let libraryCache: [LibraryEntity] = [
        .playlistEntry, .playlist, .genreSong, .genre, .song, .album, .artist, .syncState
    ]
}

/// Entities that cache a server record under the identifier the server gave it.
enum LibraryRecord: Hashable, Sendable {
    case song
    case artist
    case album
    case genre
    case playlist

    var entity: LibraryEntity {
        switch self {
        case .song: .song
        case .artist: .artist
        case .album: .album
        case .genre: .genre
        case .playlist: .playlist
        }
    }

    var idKey: String {
        switch self {
        case .song: "songID"
        case .artist: "artistID"
        case .album: "albumID"
        case .genre: "genreID"
        case .playlist: "playlistID"
        }
    }
}
