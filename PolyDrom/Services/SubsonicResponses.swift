//
//  SubsonicResponses.swift
//  PolyDrom
//
//  Created by zikasak on 07/07/2026.
//

import Foundation

struct PingEnvelope: Decodable {
    let subsonicResponse: BasicSubsonicResponse

    enum CodingKeys: String, CodingKey {
        case subsonicResponse = "subsonic-response"
    }
}

struct SearchEnvelope: Decodable {
    let subsonicResponse: SearchResponse

    enum CodingKeys: String, CodingKey {
        case subsonicResponse = "subsonic-response"
    }
}

struct RandomSongsEnvelope: Decodable {
    let subsonicResponse: RandomSongsResponse

    enum CodingKeys: String, CodingKey {
        case subsonicResponse = "subsonic-response"
    }
}

struct SongEnvelope: Decodable {
    let subsonicResponse: SongResponse

    enum CodingKeys: String, CodingKey {
        case subsonicResponse = "subsonic-response"
    }
}

struct AlbumListEnvelope: Decodable {
    let subsonicResponse: AlbumListResponse

    enum CodingKeys: String, CodingKey {
        case subsonicResponse = "subsonic-response"
    }
}

struct ArtistsEnvelope: Decodable {
    let subsonicResponse: ArtistsResponse

    enum CodingKeys: String, CodingKey {
        case subsonicResponse = "subsonic-response"
    }
}

struct ArtistEnvelope: Decodable {
    let subsonicResponse: ArtistResponse

    enum CodingKeys: String, CodingKey {
        case subsonicResponse = "subsonic-response"
    }
}

struct AlbumEnvelope: Decodable {
    let subsonicResponse: AlbumResponse

    enum CodingKeys: String, CodingKey {
        case subsonicResponse = "subsonic-response"
    }
}

struct PlaylistsEnvelope: Decodable {
    let subsonicResponse: PlaylistsResponse

    enum CodingKeys: String, CodingKey {
        case subsonicResponse = "subsonic-response"
    }
}

struct PlaylistEnvelope: Decodable {
    let subsonicResponse: PlaylistResponse

    enum CodingKeys: String, CodingKey {
        case subsonicResponse = "subsonic-response"
    }
}

struct LyricsEnvelope: Decodable {
    let subsonicResponse: LyricsResponse

    enum CodingKeys: String, CodingKey {
        case subsonicResponse = "subsonic-response"
    }
}

struct BasicSubsonicResponse: Decodable {
    let status: String
    let error: SubsonicServerError?

    func throwIfNeeded() throws {
        if status == "failed" {
            throw NavidromeError.server(message: error?.message ?? "The Navidrome server returned an error.")
        }
    }
}

struct SearchResponse: Decodable {
    let status: String
    let error: SubsonicServerError?
    let searchResult3: SearchResult?

    func throwIfNeeded() throws {
        if status == "failed" {
            throw NavidromeError.server(message: error?.message ?? "The Navidrome server returned an error.")
        }
    }
}

struct RandomSongsResponse: Decodable {
    let status: String
    let error: SubsonicServerError?
    let randomSongs: SongContainer?

    func throwIfNeeded() throws {
        if status == "failed" {
            throw NavidromeError.server(message: error?.message ?? "The Navidrome server returned an error.")
        }
    }
}

struct SongResponse: Decodable {
    let status: String
    let error: SubsonicServerError?
    let song: NavidromeSong?

    func throwIfNeeded() throws {
        if status == "failed" {
            throw NavidromeError.server(message: error?.message ?? "The Navidrome server returned an error.")
        }
    }
}

struct AlbumListResponse: Decodable {
    let status: String
    let error: SubsonicServerError?
    let albumList2: AlbumContainer?

    func throwIfNeeded() throws {
        if status == "failed" {
            throw NavidromeError.server(message: error?.message ?? "The Navidrome server returned an error.")
        }
    }
}

struct ArtistsResponse: Decodable {
    let status: String
    let error: SubsonicServerError?
    let artists: ArtistsContainer?

    func throwIfNeeded() throws {
        if status == "failed" {
            throw NavidromeError.server(message: error?.message ?? "The Navidrome server returned an error.")
        }
    }
}

struct ArtistResponse: Decodable {
    let status: String
    let error: SubsonicServerError?
    let artist: ArtistDetail?

    func throwIfNeeded() throws {
        if status == "failed" {
            throw NavidromeError.server(message: error?.message ?? "The Navidrome server returned an error.")
        }
    }
}

struct AlbumResponse: Decodable {
    let status: String
    let error: SubsonicServerError?
    let album: AlbumDetail?

    func throwIfNeeded() throws {
        if status == "failed" {
            throw NavidromeError.server(message: error?.message ?? "The Navidrome server returned an error.")
        }
    }
}

struct PlaylistsResponse: Decodable {
    let status: String
    let error: SubsonicServerError?
    let playlists: PlaylistContainer?

    func throwIfNeeded() throws {
        if status == "failed" {
            throw NavidromeError.server(message: error?.message ?? "The Navidrome server returned an error.")
        }
    }
}

struct PlaylistResponse: Decodable {
    let status: String
    let error: SubsonicServerError?
    let playlist: PlaylistDetail?

    func throwIfNeeded() throws {
        if status == "failed" {
            throw NavidromeError.server(message: error?.message ?? "The Navidrome server returned an error.")
        }
    }
}

struct LyricsResponse: Decodable {
    let status: String
    let error: SubsonicServerError?
    let lyricsList: LyricsList?

    func throwIfNeeded() throws {
        if status == "failed" {
            throw NavidromeError.server(message: error?.message ?? "The Navidrome server returned an error.")
        }
    }
}

struct LyricsList: Decodable {
    let structuredLyrics: FlexibleArray<SongLyrics>

    enum CodingKeys: String, CodingKey {
        case structuredLyrics
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        structuredLyrics = (try? container.decode(FlexibleArray<SongLyrics>.self, forKey: .structuredLyrics)) ?? FlexibleArray(values: [])
    }
}

struct SearchResult: Decodable {
    let artists: FlexibleArray<NavidromeArtist>
    let albums: FlexibleArray<NavidromeAlbum>
    let songs: FlexibleArray<NavidromeSong>

    enum CodingKeys: String, CodingKey {
        case artists = "artist"
        case albums = "album"
        case songs = "song"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        artists = (try? container.decode(FlexibleArray<NavidromeArtist>.self, forKey: .artists)) ?? FlexibleArray(values: [])
        albums = (try? container.decode(FlexibleArray<NavidromeAlbum>.self, forKey: .albums)) ?? FlexibleArray(values: [])
        songs = (try? container.decode(FlexibleArray<NavidromeSong>.self, forKey: .songs)) ?? FlexibleArray(values: [])
    }
}

struct SongContainer: Decodable {
    let songs: FlexibleArray<NavidromeSong>

    enum CodingKeys: String, CodingKey {
        case songs = "song"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        songs = (try? container.decode(FlexibleArray<NavidromeSong>.self, forKey: .songs)) ?? FlexibleArray(values: [])
    }
}

struct AlbumContainer: Decodable {
    let albums: FlexibleArray<NavidromeAlbum>

    enum CodingKeys: String, CodingKey {
        case albums = "album"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        albums = (try? container.decode(FlexibleArray<NavidromeAlbum>.self, forKey: .albums)) ?? FlexibleArray(values: [])
    }
}

struct ArtistsContainer: Decodable {
    let indexes: FlexibleArray<ArtistIndex>

    enum CodingKeys: String, CodingKey {
        case indexes = "index"
    }

    var allArtists: [NavidromeArtist] {
        indexes.values.flatMap(\.artists.values)
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        indexes = (try? container.decode(FlexibleArray<ArtistIndex>.self, forKey: .indexes)) ?? FlexibleArray(values: [])
    }
}

struct ArtistIndex: Decodable {
    let artists: FlexibleArray<NavidromeArtist>

    enum CodingKeys: String, CodingKey {
        case artists = "artist"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        artists = (try? container.decode(FlexibleArray<NavidromeArtist>.self, forKey: .artists)) ?? FlexibleArray(values: [])
    }
}

struct ArtistDetail: Decodable {
    let albums: FlexibleArray<NavidromeAlbum>

    enum CodingKeys: String, CodingKey {
        case albums = "album"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        albums = (try? container.decode(FlexibleArray<NavidromeAlbum>.self, forKey: .albums)) ?? FlexibleArray(values: [])
    }
}

struct AlbumDetail: Decodable {
    let songs: FlexibleArray<NavidromeSong>

    enum CodingKeys: String, CodingKey {
        case songs = "song"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        songs = (try? container.decode(FlexibleArray<NavidromeSong>.self, forKey: .songs)) ?? FlexibleArray(values: [])
    }
}

struct PlaylistContainer: Decodable {
    let playlists: FlexibleArray<NavidromePlaylist>

    enum CodingKeys: String, CodingKey {
        case playlists = "playlist"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        playlists = (try? container.decode(FlexibleArray<NavidromePlaylist>.self, forKey: .playlists)) ?? FlexibleArray(values: [])
    }
}

struct PlaylistDetail: Decodable {
    let songs: FlexibleArray<NavidromeSong>

    enum CodingKeys: String, CodingKey {
        case songs = "entry"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        songs = (try? container.decode(FlexibleArray<NavidromeSong>.self, forKey: .songs)) ?? FlexibleArray(values: [])
    }
}

struct SubsonicServerError: Decodable {
    let message: String
}

struct FlexibleArray<Element: Decodable>: Decodable {
    let values: [Element]

    init(values: [Element]) {
        self.values = values
    }

    init(from decoder: Decoder) throws {
        if var container = try? decoder.unkeyedContainer() {
            var values: [Element] = []

            while !container.isAtEnd {
                if let value = try? container.decode(Element.self) {
                    values.append(value)
                } else {
                    let currentIndex = container.currentIndex
                    _ = try? container.decode(DiscardedDecodableValue.self)

                    if container.currentIndex == currentIndex {
                        break
                    }
                }
            }

            self.values = values
            return
        }

        let container = try decoder.singleValueContainer()

        if let value = try? container.decode(Element.self) {
            self.values = [value]
        } else {
            self.values = []
        }
    }
}

private struct DiscardedDecodableValue: Decodable {
    init(from decoder: Decoder) throws {
        if var container = try? decoder.unkeyedContainer() {
            while !container.isAtEnd {
                _ = try? container.decode(DiscardedDecodableValue.self)
            }
            return
        }

        if let container = try? decoder.container(keyedBy: DiscardedCodingKey.self) {
            for key in container.allKeys {
                _ = try? container.decode(DiscardedDecodableValue.self, forKey: key)
            }
            return
        }

        _ = try? decoder.singleValueContainer()
    }
}

private struct DiscardedCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int?

    init?(stringValue: String) {
        self.stringValue = stringValue
        self.intValue = nil
    }

    init?(intValue: Int) {
        self.stringValue = String(intValue)
        self.intValue = intValue
    }
}
