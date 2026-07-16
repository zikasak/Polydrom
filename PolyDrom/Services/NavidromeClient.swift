//
//  NavidromeClient.swift
//  PolyDrom
//
//  Created by zikasak on 07/07/2026.
//

import CryptoKit
import Foundation

struct NavidromeClient {
    let profile: ServerProfile

    private let baseURL: URL
    private let session: URLSession

    init?(profile: ServerProfile, session: URLSession = .shared) {
        guard let baseURL = Self.normalizedServerURL(from: profile.address) else {
            return nil
        }

        self.profile = profile
        self.baseURL = baseURL
        self.session = session
    }

    func ping() async throws {
        let response: PingEnvelope = try await request("ping")
        try response.subsonicResponse.throwIfNeeded()
    }

    func randomSongs(size: Int = 50) async throws -> [NavidromeSong] {
        let response: RandomSongsEnvelope = try await request(
            "getRandomSongs",
            queryItems: [URLQueryItem(name: "size", value: String(size))]
        )
        try response.subsonicResponse.throwIfNeeded()
        return response.subsonicResponse.randomSongs?.songs.values ?? []
    }

    func song(id: String) async throws -> NavidromeSong? {
        let response: SongEnvelope = try await request(
            "getSong",
            queryItems: [URLQueryItem(name: "id", value: id)],
            timeoutInterval: 2
        )
        try response.subsonicResponse.throwIfNeeded()
        return response.subsonicResponse.song
    }

    func searchSongs(matching query: String) async throws -> [NavidromeSong] {
        let response: SearchEnvelope = try await request(
            "search3",
            queryItems: [
                URLQueryItem(name: "query", value: query),
                URLQueryItem(name: "artistCount", value: "0"),
                URLQueryItem(name: "albumCount", value: "0"),
                URLQueryItem(name: "songCount", value: "100")
            ]
        )
        try response.subsonicResponse.throwIfNeeded()
        return response.subsonicResponse.searchResult3?.songs.values ?? []
    }

    private func allAlbums(type: AlbumListType, pageSize: Int = 500) async throws -> [NavidromeAlbum] {
        let pageSize = max(1, pageSize)
        var albums: [NavidromeAlbum] = []
        var seenAlbumIDs = Set<String>()
        var offset = 0

        while true {
            let page = try await albumPage(type: type, size: pageSize, offset: offset)
            let newAlbums = page.filter { seenAlbumIDs.insert($0.id).inserted }
            albums.append(contentsOf: newAlbums)

            if page.count < pageSize || newAlbums.isEmpty {
                return albums
            }

            offset += pageSize
        }
    }

    func albumPage(type: AlbumListType, size: Int, offset: Int) async throws -> [NavidromeAlbum] {
        let response: AlbumListEnvelope = try await request(
            "getAlbumList2",
            queryItems: [
                URLQueryItem(name: "type", value: type.rawValue),
                URLQueryItem(name: "size", value: String(size)),
                URLQueryItem(name: "offset", value: String(offset))
            ]
        )
        try response.subsonicResponse.throwIfNeeded()
        return response.subsonicResponse.albumList2?.albums.values ?? []
    }

    func artistPage(size: Int, offset: Int) async throws -> [NavidromeArtist] {
        let response: SearchEnvelope = try await request(
            "search3",
            queryItems: [
                URLQueryItem(name: "query", value: ""),
                URLQueryItem(name: "artistCount", value: String(size)),
                URLQueryItem(name: "artistOffset", value: String(offset)),
                URLQueryItem(name: "albumCount", value: "0"),
                URLQueryItem(name: "songCount", value: "0")
            ]
        )
        try response.subsonicResponse.throwIfNeeded()
        return response.subsonicResponse.searchResult3?.artists.values ?? []
    }

    func albums(for artist: NavidromeArtist) async throws -> [NavidromeAlbum] {
        let response: ArtistEnvelope = try await request(
            "getArtist",
            queryItems: [URLQueryItem(name: "id", value: artist.id)]
        )
        try response.subsonicResponse.throwIfNeeded()
        let artistAlbums = response.subsonicResponse.artist?.albums.values ?? []
        if !artistAlbums.isEmpty {
            return artistAlbums
        }

        let libraryAlbums = try await allAlbums(type: .alphabeticalByName)
        return libraryAlbums
            .filter { album in
                album.artistId == artist.id || album.artist?.localizedCaseInsensitiveCompare(artist.name) == .orderedSame
            }
            .sorted {
                switch ($0.year, $1.year) {
                case let (lhs?, rhs?) where lhs != rhs:
                    return lhs < rhs
                case (_?, nil):
                    return true
                case (nil, _?):
                    return false
                default:
                    return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
                }
            }
    }

    func songs(for album: NavidromeAlbum) async throws -> [NavidromeSong] {
        let response: AlbumEnvelope = try await request(
            "getAlbum",
            queryItems: [URLQueryItem(name: "id", value: album.id)]
        )
        try response.subsonicResponse.throwIfNeeded()
        return response.subsonicResponse.album?.songs.values ?? []
    }

    func playlists() async throws -> [NavidromePlaylist] {
        let response: PlaylistsEnvelope = try await request("getPlaylists")
        try response.subsonicResponse.throwIfNeeded()
        return response.subsonicResponse.playlists?.playlists.values ?? []
    }

    func songs(for playlist: NavidromePlaylist) async throws -> [NavidromeSong] {
        let response: PlaylistEnvelope = try await request(
            "getPlaylist",
            queryItems: [URLQueryItem(name: "id", value: playlist.id)]
        )
        try response.subsonicResponse.throwIfNeeded()
        return response.subsonicResponse.playlist?.songs.values ?? []
    }

    func lyrics(for song: NavidromeSong) async throws -> [SongLyrics] {
        let response: LyricsEnvelope = try await request(
            "getLyricsBySongId",
            queryItems: [URLQueryItem(name: "id", value: song.id)]
        )
        try response.subsonicResponse.throwIfNeeded()
        return response.subsonicResponse.lyricsList?.structuredLyrics.values ?? []
    }

    func starredItems() async throws -> (artists: [NavidromeArtist], albums: [NavidromeAlbum], songs: [NavidromeSong]) {
        let response: StarredEnvelope = try await request("getStarred2")
        try response.subsonicResponse.throwIfNeeded()
        return (
            artists: response.subsonicResponse.starred2?.artists.values ?? [],
            albums: response.subsonicResponse.starred2?.albums.values ?? [],
            songs: response.subsonicResponse.starred2?.songs.values ?? []
        )
    }

    func setStarred(_ isStarred: Bool, itemID: String) async throws {
        let response: PingEnvelope = try await request(
            isStarred ? "star" : "unstar",
            queryItems: [URLQueryItem(name: "id", value: itemID)]
        )
        try response.subsonicResponse.throwIfNeeded()
    }

    func streamURL(for song: NavidromeSong) throws -> URL {
        try apiURL(
            "stream",
            includeResponseFormat: false,
            queryItems: [
                URLQueryItem(name: "id", value: song.id),
                URLQueryItem(name: "format", value: "mp3")
            ]
        )
    }

    func coverArtURL(id: String, size: Int = 160) throws -> URL {
        try apiURL(
            "getCoverArt",
            includeResponseFormat: false,
            queryItems: [
                URLQueryItem(name: "id", value: id),
                URLQueryItem(name: "size", value: String(size))
            ]
        )
    }

    private func request<Response: Decodable>(
        _ method: String,
        queryItems: [URLQueryItem] = [],
        timeoutInterval: TimeInterval? = nil
    ) async throws -> Response {
        let url = try apiURL(method, queryItems: queryItems)
        let data: Data
        let response: URLResponse

        if let timeoutInterval {
            var request = URLRequest(url: url)
            request.timeoutInterval = timeoutInterval
            (data, response) = try await session.data(for: request)
        } else {
            (data, response) = try await session.data(from: url)
        }

        if let httpResponse = response as? HTTPURLResponse, !(200...299).contains(httpResponse.statusCode) {
            throw NavidromeError.server(message: "HTTP \(httpResponse.statusCode)")
        }

        return try JSONDecoder().decode(Response.self, from: data)
    }

    private func apiURL(_ method: String, includeResponseFormat: Bool = true, queryItems: [URLQueryItem] = []) throws -> URL {
        let endpoint = baseURL
            .appendingPathComponent("rest")
            .appendingPathComponent("\(method).view")
        var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)
        components?.queryItems = authenticationQueryItems(includeResponseFormat: includeResponseFormat) + queryItems

        guard let url = components?.url else {
            throw NavidromeError.invalidURL
        }

        return url
    }

    private func authenticationQueryItems(includeResponseFormat: Bool) -> [URLQueryItem] {
        let salt = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        var items = [
            URLQueryItem(name: "u", value: profile.username),
            URLQueryItem(name: "t", value: md5(profile.password + salt)),
            URLQueryItem(name: "s", value: salt),
            URLQueryItem(name: "v", value: "1.16.1"),
            URLQueryItem(name: "c", value: "PolyDrom")
        ]

        if includeResponseFormat {
            items.append(URLQueryItem(name: "f", value: "json"))
        }

        return items
    }

    private func md5(_ value: String) -> String {
        Insecure.MD5.hash(data: Data(value.utf8))
            .map { String(format: "%02hhx", $0) }
            .joined()
    }

    private static func normalizedServerURL(from address: String) -> URL? {
        let trimmedAddress = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedAddress.isEmpty else { return nil }

        if let url = URL(string: trimmedAddress), url.scheme != nil {
            return url
        }

        return URL(string: "http://\(trimmedAddress)")
    }
}

enum NavidromeError: LocalizedError {
    case invalidURL
    case server(message: String)

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            "The server address is not a valid URL."
        case .server(let message):
            message
        }
    }
}
