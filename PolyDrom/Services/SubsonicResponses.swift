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
typealias SongEnvelope = SubsonicEnvelope<SongResponse>
typealias SearchEnvelope = SubsonicEnvelope<SearchResponse>
typealias PlaylistsEnvelope = SubsonicEnvelope<PlaylistsResponse>
typealias PlaylistEnvelope = SubsonicEnvelope<PlaylistResponse>
typealias LyricsEnvelope = SubsonicEnvelope<LyricsResponse>
typealias StarredEnvelope = SubsonicEnvelope<StarredResponse>
typealias ScanStatusEnvelope = SubsonicEnvelope<ScanStatusResponse>
typealias OpenSubsonicExtensionsEnvelope = SubsonicEnvelope<OpenSubsonicExtensionsResponse>
typealias SonicMatchesEnvelope = SubsonicEnvelope<SonicMatchesResponse>
typealias TranscodeDecisionEnvelope = SubsonicEnvelope<TranscodeDecisionResponse>

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

struct SongResponse: SubsonicResponse {
    let status: String
    let error: SubsonicServerError?
    let song: NavidromeSong?
}

struct SearchResponse: SubsonicResponse {
    let status: String
    let error: SubsonicServerError?
    let searchResult3: SearchResult?
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

struct OpenSubsonicExtensionsResponse: SubsonicResponse {
    let status: String
    let error: SubsonicServerError?
    let openSubsonicExtensions: [OpenSubsonicExtension]?
}

struct OpenSubsonicExtension: Decodable, Equatable, Sendable {
    let name: String
    let versions: [Int]

    func supports(version: Int) -> Bool {
        versions.contains(version)
    }
}

extension [OpenSubsonicExtension] {
    func supports(_ name: String, version: Int = 1) -> Bool {
        contains { $0.name.caseInsensitiveCompare(name) == .orderedSame && $0.supports(version: version) }
    }
}

struct TranscodeDecisionResponse: SubsonicResponse {
    let status: String
    let error: SubsonicServerError?
    let transcodeDecision: TranscodeDecision?
}

/// How the server would deliver a song to a player with the capabilities it was told about.
struct TranscodeDecision: Decodable, Sendable {
    struct Stream: Decodable, Sendable {
        let container: String?
    }

    let canDirectPlay: Bool
    let canTranscode: Bool
    /// Opaque token that selects the agreed transcode in `getTranscodeStream`.
    let transcodeParams: String?
    let sourceStream: Stream?
    let transcodeStream: Stream?
}

/// What a player can decode, as the `transcoding` extension expects it.
struct TranscodeClientInfo: Encodable, Sendable {
    struct DirectPlayProfile: Encodable, Sendable {
        let containers: [String]
        /// Empty accepts whatever codec the container holds.
        let audioCodecs: [String]
        var protocols = ["http"]
        let maxAudioChannels: Int
    }

    struct TranscodingProfile: Encodable, Sendable {
        let container: String
        let audioCodec: String
        var `protocol` = "http"
        let maxAudioChannels: Int
    }

    struct CodecProfile: Encodable, Sendable {
        var type = "AudioCodec"
        let name: String
        let limitations: [Limitation]
    }

    struct Limitation: Encodable, Sendable {
        let name: String
        var comparison = "LessThanEqual"
        let values: [String]
        var required = true
    }

    let name: String
    let platform: String
    let directPlayProfiles: [DirectPlayProfile]
    /// Tried in order when the original cannot be played as it is.
    let transcodingProfiles: [TranscodingProfile]
    let codecProfiles: [CodecProfile]
}

struct SonicMatchesResponse: SubsonicResponse {
    let status: String
    let error: SubsonicServerError?
    let matches: FlexibleArray<SonicMatch>

    enum CodingKeys: String, CodingKey {
        case status
        case error
        case matches = "sonicMatch"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        status = try container.decode(String.self, forKey: .status)
        error = try container.decodeIfPresent(SubsonicServerError.self, forKey: .error)
        matches = container.decodeFlexibleArray(of: SonicMatch.self, forKey: .matches)
    }
}

/// A song that sounds like the one asked about, as ranked by the server's
/// sonic analysis plugin.
struct SonicMatch: Decodable {
    let song: NavidromeSong

    enum CodingKeys: String, CodingKey {
        case song = "entry"
    }
}

struct ScanStatus: Decodable, Sendable {
    let scanning: Bool
    let lastScan: String?

    enum CodingKeys: String, CodingKey {
        case scanning
        case lastScan
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        scanning = (try? container.decode(Bool.self, forKey: .scanning)) ?? false
        if let value = try? container.decode(String.self, forKey: .lastScan) {
            lastScan = value
        } else if let value = try? container.decode(Double.self, forKey: .lastScan) {
            lastScan = String(value)
        } else {
            lastScan = nil
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
        structuredLyrics = container.decodeFlexibleArray(of: SongLyrics.self, forKey: .structuredLyrics)
    }
}

/// The artists, albums, and songs of a search or starred listing.
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
        artists = container.decodeFlexibleArray(of: NavidromeArtist.self, forKey: .artists)
        albums = container.decodeFlexibleArray(of: NavidromeAlbum.self, forKey: .albums)
        songs = container.decodeFlexibleArray(of: NavidromeSong.self, forKey: .songs)
    }
}

typealias StarredContainer = SearchResult

struct PlaylistContainer: Decodable {
    let playlists: FlexibleArray<NavidromePlaylist>

    enum CodingKeys: String, CodingKey {
        case playlists = "playlist"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        playlists = container.decodeFlexibleArray(of: NavidromePlaylist.self, forKey: .playlists)
    }
}

struct PlaylistDetail: Decodable {
    let summary: NavidromePlaylist?
    let songs: FlexibleArray<NavidromeSong>

    enum CodingKeys: String, CodingKey {
        case songs = "entry"
    }

    init(from decoder: Decoder) throws {
        summary = try? NavidromePlaylist(from: decoder)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        songs = container.decodeFlexibleArray(of: NavidromeSong.self, forKey: .songs)
    }
}

struct SubsonicServerError: Decodable {
    let message: String
}

extension KeyedDecodingContainer {
    /// Subsonic servers write a list with a single element as that element, and
    /// leave an empty list out; both decode to an array here.
    func decodeFlexibleArray<Element: Decodable>(of type: Element.Type, forKey key: Key) -> FlexibleArray<Element> {
        (try? decode(FlexibleArray<Element>.self, forKey: key)) ?? FlexibleArray(values: [])
    }
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
