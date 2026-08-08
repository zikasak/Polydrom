import Foundation
import Testing
@testable import PolyDrom

@Suite(.serialized)
@MainActor
struct NavidromeClientTests {
    @Test func initializerNormalizesAddressesAndRejectsWhitespace() throws {
        #expect(NavidromeClient(profile: makeProfile(address: " \n ")) == nil)

        let client = try #require(NavidromeClient(profile: makeProfile(address: " music.example.com/path ")))
        let url = try client.streamURL(for: makeSong())
        #expect(url.scheme == "http")
        #expect(url.host == "music.example.com")
        #expect(url.path == "/path/rest/stream.view")
    }

    @Test func generatedURLsContainValidAuthenticationAndEndpointParameters() throws {
        let client = try #require(NavidromeClient(profile: makeProfile(username: "alice", password: "secret")))
        let stream = try client.streamURL(for: makeSong(id: "s"))
        let cover = try client.coverArtURL(id: "art", size: 320)

        for url in [stream, cover] {
            let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
            let items = components.queryItems ?? []
            #expect(items.first(where: { $0.name == "u" })?.value == "alice")
            #expect(items.first(where: { $0.name == "v" })?.value == "1.16.1")
            #expect(items.first(where: { $0.name == "c" })?.value == "PolyDrom")
            #expect(items.first(where: { $0.name == "s" })?.value?.count == 32)
            #expect(items.first(where: { $0.name == "t" })?.value?.count == 32)
            #expect(!items.contains(where: { $0.name == "f" }))
        }
        #expect(queryValue("id", in: URLRequest(url: stream)) == "s")
        #expect(queryValue("format", in: URLRequest(url: stream)) == "mp3")
        #expect(queryValue("id", in: URLRequest(url: cover)) == "art")
        #expect(queryValue("size", in: URLRequest(url: cover)) == "320")
    }

    @Test func allAPIEndpointsDecodeSuccessEmptyAndFallbackBranches() async throws {
        let handler: StubURLProtocol.Handler = { request in
            switch apiMethod(in: request) {
            case "ping":
                return envelope(#"{"status":"ok"}"#)
            case "getOpenSubsonicExtensions":
                return envelope(#"{"status":"ok","openSubsonicExtensions":[{"name":"playbackReport","versions":[1]}]}"#)
            case "getScanStatus":
                return envelope(#"{"status":"ok","scanStatus":{"scanning":false,"count":"4","lastScan":"scan-token"}}"#)
            case "getRandomSongs":
                return envelope(#"{"status":"ok","randomSongs":{"song":{"id":"random","title":"Random"}}}"#)
            case "getSong":
                return envelope(#"{"status":"ok","song":{"id":"hydrated","title":"Hydrated"}}"#)
            case "search3":
                if queryValue("albumCount", in: request) != "0" {
                    return envelope(#"{"status":"ok","searchResult3":{"album":[{"id":"metadata-album","name":"Metadata Album"}]}}"#)
                }
                if queryValue("query", in: request) == "" && queryValue("songCount", in: request) != "0" {
                    return envelope(#"{"status":"ok","searchResult3":{"song":[{"id":"metadata-song","title":"Metadata Song","track":2,"discNumber":1}]}}"#)
                }
                if queryValue("artistCount", in: request) == "0" {
                    return envelope(#"{"status":"ok","searchResult3":{"song":[{"id":"search","title":"Found"}]}}"#)
                }
                return envelope(#"{"status":"ok","searchResult3":{"artist":[{"id":"artist","name":"Artist"}]}}"#)
            case "getAlbumList2":
                return envelope(#"{"status":"ok","albumList2":{"album":[{"id":"late","name":"Late","artistId":"fallback","year":2022},{"id":"early","name":"Early","artist":"Fallback","year":2020},{"id":"none","name":"None","artistId":"fallback"},{"id":"other","name":"Other","artistId":"other"}]}}"#)
            case "getArtist":
                if queryValue("id", in: request) == "direct" {
                    return envelope(#"{"status":"ok","artist":{"album":{"id":"direct-album","name":"Direct"}}}"#)
                }
                return envelope(#"{"status":"ok","artist":{"album":[]}}"#)
            case "getAlbum":
                return envelope(#"{"status":"ok","album":{"song":{"id":"album-song","title":"Album Song"}}}"#)
            case "getPlaylists":
                return envelope(#"{"status":"ok","playlists":{"playlist":{"id":"playlist","name":"Mix"}}}"#)
            case "getPlaylist":
                return envelope(#"{"status":"ok","playlist":{"entry":{"id":"playlist-song","title":"Playlist Song"}}}"#)
            case "createPlaylist":
                #expect(queryValue("name", in: request) == "Road Trip")
                #expect(queryValues("songId", in: request) == ["first", "second", "first"])
                return envelope(#"{"status":"ok","playlist":{"id":"created","name":"Road Trip","songCount":3,"entry":[]}}"#)
            case "updatePlaylist":
                #expect(queryValue("playlistId", in: request) == "created")
                #expect(queryValue("name", in: request) == "Renamed")
                #expect(queryValues("songIdToAdd", in: request) == ["third", "third"])
                #expect(queryValues("songIndexToRemove", in: request) == ["0", "2"])
                return envelope(#"{"status":"ok"}"#)
            case "deletePlaylist":
                #expect(queryValue("id", in: request) == "created")
                return envelope(#"{"status":"ok"}"#)
            case "getLyricsBySongId":
                return envelope(#"{"status":"ok","lyricsList":{"structuredLyrics":{"lang":"en","synced":true,"line":{"value":"Line"}}}}"#)
            case "getStarred2":
                return envelope(#"{"status":"ok","starred2":{"artist":{"id":"star-a","name":"Star Artist"},"album":{"id":"star-b","name":"Star Album"},"song":{"id":"star-s","title":"Star Song"}}}"#)
            case "star", "unstar":
                return envelope(#"{"status":"ok"}"#)
            case "reportPlayback":
                #expect(queryValue("mediaId", in: request) == "playing-song")
                #expect(queryValue("mediaType", in: request) == "song")
                #expect(queryValue("positionMs", in: request) == "12500")
                #expect(queryValue("state", in: request) == "paused")
                #expect(queryValue("playbackRate", in: request) == "1.0")
                #expect(queryValue("ignoreScrobble", in: request) == "false")
                return envelope(#"{"status":"ok"}"#)
            case "scrobble":
                #expect(queryValue("id", in: request) == "playing-song")
                #expect(["false", "true"].contains(queryValue("submission", in: request)))
                #expect(queryValue("position", in: request) == nil)
                return envelope(#"{"status":"ok"}"#)
            default:
                return StubURLProtocol.Response(statusCode: 404, json: "{}")
            }
        }
        let session = StubURLProtocol.session(handler: handler)

        let client = try #require(NavidromeClient(profile: makeProfile(), session: session))
        try await client.ping()
        let extensions = try await client.openSubsonicExtensions()
        #expect(extensions == [OpenSubsonicExtension(name: "playbackReport", versions: [1])])
        #expect(extensions[0].supports(version: 1))
        #expect(!extensions[0].supports(version: 2))
        let changeState = try await client.catalogChangeState()
        #expect(changeState.token == "scan-token")
        #expect(!changeState.isScanning)
        #expect(try await client.artistPage(size: 20, offset: 10).map(\.id) == ["artist"])
        #expect(try await client.albumMetadataPage(size: 20, offset: 10).map(\.id) == ["metadata-album"])
        #expect(try await client.songMetadataPage(size: 20, offset: 10).map(\.id) == ["metadata-song"])
        #expect(try await client.songMetadata(for: "hydrated")?.id == "hydrated")

        let playlists = try await client.playlists()
        #expect(playlists.map(\.id) == ["playlist"])
        #expect(try await client.songs(for: playlists[0]).map(\.id) == ["playlist-song"])
        let created = try await client.createPlaylist(
            name: "Road Trip",
            songIDs: ["first", "second", "first"]
        )
        #expect(created.id == "created")
        try await client.updatePlaylist(
            playlistID: created.id,
            name: "Renamed",
            songIDsToAdd: ["third", "third"],
            indicesToRemove: [0, 2]
        )
        try await client.deletePlaylist(id: created.id)
        #expect(try await client.lyrics(for: makeSong()).first?.lines.first?.value == "Line")

        let starred = try await client.starredItems()
        #expect(starred.artists.map(\.id) == ["star-a"])
        #expect(starred.albums.map(\.id) == ["star-b"])
        #expect(starred.songs.map(\.id) == ["star-s"])
        try await client.setStarred(true, itemID: "star-s")
        try await client.setStarred(false, itemID: "star-s")
        try await client.reportPlayback(
            songID: "playing-song",
            positionMilliseconds: 12_500,
            state: .paused
        )
        try await client.scrobble(songID: "playing-song", submission: false)
        try await client.scrobble(songID: "playing-song", submission: true)
    }

    @Test func optionalContainersReturnEmptyCollections() async throws {
        let handler: StubURLProtocol.Handler = { request in
            let extra: String
            switch apiMethod(in: request) {
            case "getRandomSongs": extra = ""
            case "getSong": extra = ""
            case "search3": extra = ""
            case "getAlbumList2": extra = ""
            case "getArtist": extra = ""
            case "getAlbum": extra = ""
            case "getPlaylists": extra = ""
            case "getPlaylist": extra = ""
            case "getLyricsBySongId": extra = ""
            case "getStarred2": extra = ""
            case "getScanStatus": extra = ""
            default: extra = ""
            }
            _ = extra
            return envelope(#"{"status":"ok"}"#)
        }
        let client = try #require(
            NavidromeClient(profile: makeProfile(), session: StubURLProtocol.session(handler: handler))
        )
        #expect(try await client.catalogChangeState().token == nil)
        #expect(try await client.openSubsonicExtensions().isEmpty)
        #expect(try await client.artistPage(size: 1, offset: 0).isEmpty)
        #expect(try await client.albumMetadataPage(size: 1, offset: 0).isEmpty)
        #expect(try await client.songMetadataPage(size: 1, offset: 0).isEmpty)
        #expect(try await client.playlists().isEmpty)
        #expect(try await client.songs(for: JSONDecoder().decode(NavidromePlaylist.self, from: Data(#"{"id":"p","name":"P"}"#.utf8))).isEmpty)
        #expect(try await client.lyrics(for: makeSong()).isEmpty)
        let starred = try await client.starredItems()
        #expect(starred.artists.isEmpty && starred.albums.isEmpty && starred.songs.isEmpty)
    }

    @Test func HTTPServerAndDecodeErrorsPropagate() async throws {
        let httpClient = try #require(NavidromeClient(
            profile: makeProfile(),
            session: StubURLProtocol.session { _ in StubURLProtocol.Response(statusCode: 503, json: "{}") }
        ))
        do {
            try await httpClient.ping()
            Issue.record("Expected HTTP failure")
        } catch {
            #expect(error.localizedDescription == "HTTP 503")
        }

        let decodingClient = try #require(NavidromeClient(
            profile: makeProfile(),
            session: StubURLProtocol.session { _ in StubURLProtocol.Response(data: Data("not-json".utf8)) }
        ))
        await #expect(throws: DecodingError.self) { try await decodingClient.ping() }

        let serverClient = try #require(NavidromeClient(
            profile: makeProfile(),
            session: StubURLProtocol.session { _ in envelope(#"{"status":"failed","error":{"message":"Denied"}}"#) }
        ))
        do {
            try await serverClient.ping()
            Issue.record("Expected server failure")
        } catch {
            #expect(error.localizedDescription == "Denied")
        }
    }
}
