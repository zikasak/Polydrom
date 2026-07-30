//
//  SubsonicResponses.swift
//  PolyDrom
//
//  Created by zikasak on 07/07/2026.
//

import Foundation

struct SubsonicEnvelope<Response: Decodable>: Decodable {
    let subsonicResponse: Response

    enum CodingKeys: String, CodingKey {
        case subsonicResponse = "subsonic-response"
    }
}

typealias PingEnvelope = SubsonicEnvelope<BasicSubsonicResponse>
typealias SearchEnvelope = SubsonicEnvelope<SearchResponse>
typealias RandomSongsEnvelope = SubsonicEnvelope<RandomSongsResponse>
typealias SongEnvelope = SubsonicEnvelope<SongResponse>
typealias AlbumListEnvelope = SubsonicEnvelope<AlbumListResponse>
typealias ArtistEnvelope = SubsonicEnvelope<ArtistResponse>
typealias AlbumEnvelope = SubsonicEnvelope<AlbumResponse>
typealias PlaylistsEnvelope = SubsonicEnvelope<PlaylistsResponse>
typealias PlaylistEnvelope = SubsonicEnvelope<PlaylistResponse>
typealias LyricsEnvelope = SubsonicEnvelope<LyricsResponse>
typealias StarredEnvelope = SubsonicEnvelope<StarredResponse>
typealias ScanStatusEnvelope = SubsonicEnvelope<ScanStatusResponse>

protocol SubsonicResponse: Decodable {
    var status: String { get }
    var error: SubsonicServerError? { get }
}

extension SubsonicResponse {
    func throwIfNeeded() throws {
        if status == "failed" {
            throw NavidromeError.server(message: error?.message ?? "The Navidrome server returned an error.")
        }
    }
}

struct BasicSubsonicResponse: SubsonicResponse {
    let status: String
    let error: SubsonicServerError?
}

struct SearchResponse: SubsonicResponse {
    let status: String
    let error: SubsonicServerError?
    let searchResult3: SearchResult?
}

struct RandomSongsResponse: SubsonicResponse {
    let status: String
    let error: SubsonicServerError?
    let randomSongs: SongContainer?
}

struct SongResponse: SubsonicResponse {
    let status: String
    let error: SubsonicServerError?
    let song: NavidromeSong?
}

struct AlbumListResponse: SubsonicResponse {
    let status: String
    let error: SubsonicServerError?
    let albumList2: AlbumContainer?
}

struct ArtistResponse: SubsonicResponse {
    let status: String
    let error: SubsonicServerError?
    let artist: ArtistDetail?
}

struct AlbumResponse: SubsonicResponse {
    let status: String
    let error: SubsonicServerError?
    let album: AlbumDetail?
}

struct PlaylistsResponse: SubsonicResponse {
    let status: String
    let error: SubsonicServerError?
    let playlists: PlaylistContainer?
}

struct PlaylistResponse: SubsonicResponse {
    let status: String
    let error: SubsonicServerError?
    let playlist: PlaylistDetail?
}

struct LyricsResponse: SubsonicResponse {
    let status: String
    let error: SubsonicServerError?
    let lyricsList: LyricsList?
}

struct StarredResponse: SubsonicResponse {
    let status: String
    let error: SubsonicServerError?
    let starred2: StarredContainer?
}

struct ScanStatusResponse: SubsonicResponse {
    let status: String
    let error: SubsonicServerError?
    let scanStatus: ScanStatus?
}

struct ScanStatus: Decodable {
    let scanning: Bool
    let count: Int?
    let lastScan: String?

    enum CodingKeys: String, CodingKey {
        case scanning
        case count
        case lastScan
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        scanning = (try? container.decode(Bool.self, forKey: .scanning)) ?? false
        if let value = try? container.decode(Int.self, forKey: .count) {
            count = value
        } else if let value = try? container.decode(String.self, forKey: .count) {
            count = Int(value)
        } else {
            count = nil
        }
        if let value = try? container.decode(String.self, forKey: .lastScan) {
            lastScan = value
        } else if let value = try? container.decode(Double.self, forKey: .lastScan) {
            lastScan = String(value)
        } else {
            lastScan = nil
        }
    }
}

struct StarredContainer: Decodable {
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
