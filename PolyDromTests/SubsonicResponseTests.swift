import Foundation
import Testing
@testable import PolyDrom

@Suite(.serialized)
struct SubsonicResponseTests {
    @Test func successfulAndFailedResponsesCoverBothErrorBranches() throws {
        let ok = try JSONDecoder().decode(PingEnvelope.self, from: Data(#"{"subsonic-response":{"status":"ok"}}"#.utf8))
        try ok.subsonicResponse.throwIfNeeded()

        let fallback = try JSONDecoder().decode(PingEnvelope.self, from: Data(#"{"subsonic-response":{"status":"failed"}}"#.utf8))
        #expect(throws: NavidromeError.self) { try fallback.subsonicResponse.throwIfNeeded() }
        do {
            try fallback.subsonicResponse.throwIfNeeded()
        } catch {
            #expect(error.localizedDescription == "The Navidrome server returned an error.")
        }
    }

    @Test func everyContainerDefaultsMissingAndMalformedValuesToEmpty() throws {
        let decoder = JSONDecoder()
        #expect(try decoder.decode(StarredContainer.self, from: Data(#"{}"#.utf8)).artists.values.isEmpty)
        #expect(try decoder.decode(LyricsList.self, from: Data(#"{}"#.utf8)).structuredLyrics.values.isEmpty)
        #expect(try decoder.decode(SearchResult.self, from: Data(#"{}"#.utf8)).artists.values.isEmpty)
        #expect(try decoder.decode(SearchResult.self, from: Data(#"{"artist":false,"song":3}"#.utf8)).songs.values.isEmpty)
        #expect(try decoder.decode(PlaylistContainer.self, from: Data(#"{}"#.utf8)).playlists.values.isEmpty)
        #expect(try decoder.decode(PlaylistDetail.self, from: Data(#"{}"#.utf8)).songs.values.isEmpty)
    }

    @Test func everyContainerDecodesSingletons() throws {
        let decoder = JSONDecoder()
        let search = try decoder.decode(SearchResult.self, from: Data(#"{"artist":{"id":"a","name":"Artist"},"song":{"id":"s","title":"Song"}}"#.utf8))
        let playlists = try decoder.decode(PlaylistContainer.self, from: Data(#"{"playlist":{"id":"p","name":"Playlist"}}"#.utf8))
        let playlist = try decoder.decode(PlaylistDetail.self, from: Data(#"{"entry":{"id":"s","title":"Song"}}"#.utf8))
        let lyrics = try decoder.decode(LyricsList.self, from: Data(#"{"structuredLyrics":{"lang":"en","line":{"value":"Line"}}}"#.utf8))

        #expect(search.artists.values.map(\.id) == ["a"])
        #expect(search.songs.values.map(\.id) == ["s"])
        #expect(playlists.playlists.values.count == 1)
        #expect(playlist.songs.values.count == 1)
        #expect(lyrics.structuredLyrics.values.count == 1)
    }

    @Test func flexibleArraySkipsMalformedNestedElementsAndContinues() throws {
        let json = #"[{"id":"one","title":"One"},{"bad":[1,{"deep":true},null]},[1,2],"junk",{"id":"two","title":"Two"}]"#
        let values = try JSONDecoder().decode(FlexibleArray<NavidromeSong>.self, from: Data(json.utf8)).values
        #expect(values.map(\.id) == ["one", "two"])

        let scalar = try JSONDecoder().decode(FlexibleArray<NavidromeSong>.self, from: Data(#"false"#.utf8))
        #expect(scalar.values.isEmpty)
        #expect(FlexibleArray(values: values).values == values)
    }

    @Test func envelopeAliasesDecodeRepresentativePayloads() throws {
        let payloads: [(Data, (Data) throws -> Bool)] = [
            (Data(#"{"subsonic-response":{"status":"ok","playlists":{"playlist":[]}}}"#.utf8), { try JSONDecoder().decode(PlaylistsEnvelope.self, from: $0).subsonicResponse.status == "ok" }),
            (Data(#"{"subsonic-response":{"status":"ok","playlist":{"entry":[]}}}"#.utf8), { try JSONDecoder().decode(PlaylistEnvelope.self, from: $0).subsonicResponse.status == "ok" })
        ]
        for (data, decode) in payloads {
            #expect(try decode(data))
        }
    }
}
