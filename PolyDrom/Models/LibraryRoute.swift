import Foundation

/// A detail page that can be pushed onto the library's navigation stack.
enum LibraryRoute: Hashable {
    case album(NavidromeAlbum)
    case artist(NavidromeArtist)
    case genre(NavidromeGenre)
    case playlist(NavidromePlaylist)

    func identifiesPlaylist(_ id: String) -> Bool {
        if case .playlist(let playlist) = self {
            return playlist.id == id
        }
        return false
    }

    /// Whether both routes show the same item, even if its details differ.
    func identifiesSameDestination(as other: LibraryRoute) -> Bool {
        switch (self, other) {
        case (.album(let lhs), .album(let rhs)):
            return lhs.id == rhs.id
        case (.artist(let lhs), .artist(let rhs)):
            return lhs.id == rhs.id
        case (.genre(let lhs), .genre(let rhs)):
            return lhs.id == rhs.id
        case (.playlist(let lhs), .playlist(let rhs)):
            return lhs.id == rhs.id
        default:
            return false
        }
    }
}
