//
//  SpotifySearchLink.swift
//  PolyDrom
//

import Foundation

enum SpotifySearchLink {
    static func url(for album: NavidromeAlbum) -> URL {
        var filters = ["album:\(normalized(album.name))"]

        if let albumArtist = album.artist {
            let artist = normalized(albumArtist)
            if !artist.isEmpty {
                filters.append("artist:\(artist)")
            }
        }

        return searchURL(for: filters.joined(separator: " "))
    }

    static func url(for artist: NavidromeArtist) -> URL {
        searchURL(for: "artist:\(normalized(artist.name))")
    }

    private static let pathComponentAllowed = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"
    )

    private static func normalized(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func searchURL(for query: String) -> URL {
        let encodedQuery = query.addingPercentEncoding(withAllowedCharacters: pathComponentAllowed)!
        return URL(string: "https://open.spotify.com/search/\(encodedQuery)")!
    }
}
