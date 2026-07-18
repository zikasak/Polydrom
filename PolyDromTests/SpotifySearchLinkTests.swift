import Foundation
import Testing
@testable import PolyDrom

struct SpotifySearchLinkTests {
    @Test func albumSearchIncludesTrimmedAlbumAndArtistFilters() throws {
        let album = try decodeAlbum(#"{"id":"album","name":"  Abbey Road  ","artist":"  The Beatles  "}"#)

        #expect(
            SpotifySearchLink.url(for: album).absoluteString
                == "https://open.spotify.com/search/album%3AAbbey%20Road%20artist%3AThe%20Beatles"
        )
    }

    @Test(arguments: [
        #"{"id":"album","name":"Album"}"#,
        #"{"id":"album","name":"Album","artist":""}"#,
        #"{"id":"album","name":"Album","artist":"   "}"#
    ])
    func albumSearchOmitsMissingOrBlankArtistFilter(_ json: String) throws {
        let album = try decodeAlbum(json)

        #expect(
            SpotifySearchLink.url(for: album).absoluteString
                == "https://open.spotify.com/search/album%3AAlbum"
        )
    }

    @Test func artistSearchUsesTrimmedArtistFilter() throws {
        let artist = try decodeArtist(#"{"id":"artist","name":"  Miles Davis  "}"#)

        #expect(
            SpotifySearchLink.url(for: artist).absoluteString
                == "https://open.spotify.com/search/artist%3AMiles%20Davis"
        )
    }

    @Test func reservedAndUnicodeCharactersStayInOneEncodedSearchPathComponent() throws {
        let album = try decodeAlbum(#"{"id":"album","name":"Björk / Vol. 1?","artist":"A&B #1"}"#)
        let components = try #require(
            URLComponents(url: SpotifySearchLink.url(for: album), resolvingAgainstBaseURL: false)
        )
        let pathComponents = components.percentEncodedPath.split(separator: "/")

        #expect(components.scheme == "https")
        #expect(components.host == "open.spotify.com")
        #expect(pathComponents.count == 2)
        #expect(pathComponents.first == "search")
        #expect(components.percentEncodedPath.contains("%C3%B6"))
        #expect(components.percentEncodedPath.contains("%2F"))
        #expect(components.percentEncodedPath.contains("%26"))
        #expect(components.percentEncodedPath.contains("%3F"))
        #expect(components.percentEncodedPath.contains("%23"))
    }

    private func decodeAlbum(_ json: String) throws -> NavidromeAlbum {
        try JSONDecoder().decode(NavidromeAlbum.self, from: Data(json.utf8))
    }

    private func decodeArtist(_ json: String) throws -> NavidromeArtist {
        try JSONDecoder().decode(NavidromeArtist.self, from: Data(json.utf8))
    }
}
