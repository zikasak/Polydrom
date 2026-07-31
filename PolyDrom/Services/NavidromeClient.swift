//
//  NavidromeClient.swift
//  PolyDrom
//
//  Created by zikasak on 07/07/2026.
//

import CryptoKit
import Foundation

struct NavidromeClient: Sendable {
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

    func catalogChangeState() async throws -> CatalogChangeState {
        let response: ScanStatusEnvelope = try await request("getScanStatus")
        try response.subsonicResponse.throwIfNeeded()
        let status = response.subsonicResponse.scanStatus
        return CatalogChangeState(
            isScanning: status?.scanning ?? false,
            token: status?.lastScan
        )
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

    func albumMetadataPage(size: Int, offset: Int) async throws -> [NavidromeAlbum] {
        let response: SearchEnvelope = try await request(
            "search3",
            queryItems: [
                URLQueryItem(name: "query", value: ""),
                URLQueryItem(name: "artistCount", value: "0"),
                URLQueryItem(name: "albumCount", value: String(size)),
                URLQueryItem(name: "albumOffset", value: String(offset)),
                URLQueryItem(name: "songCount", value: "0")
            ]
        )
        try response.subsonicResponse.throwIfNeeded()
        return response.subsonicResponse.searchResult3?.albums.values ?? []
    }

    func songMetadataPage(size: Int, offset: Int) async throws -> [NavidromeSong] {
        let response: SearchEnvelope = try await request(
            "search3",
            queryItems: [
                URLQueryItem(name: "query", value: ""),
                URLQueryItem(name: "artistCount", value: "0"),
                URLQueryItem(name: "albumCount", value: "0"),
                URLQueryItem(name: "songCount", value: String(size)),
                URLQueryItem(name: "songOffset", value: String(offset))
            ]
        )
        try response.subsonicResponse.throwIfNeeded()
        return response.subsonicResponse.searchResult3?.songs.values ?? []
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

    func createPlaylist(name: String, songIDs: [String] = []) async throws -> NavidromePlaylist {
        let response: PlaylistEnvelope = try await request(
            "createPlaylist",
            queryItems: [URLQueryItem(name: "name", value: name)]
                + songIDs.map { URLQueryItem(name: "songId", value: $0) }
        )
        try response.subsonicResponse.throwIfNeeded()
        guard let playlist = response.subsonicResponse.playlist?.summary else {
            throw NavidromeError.server(message: "Navidrome did not return the created playlist.")
        }
        return playlist
    }

    func updatePlaylist(
        playlistID: String,
        name: String? = nil,
        songIDsToAdd: [String] = [],
        indicesToRemove: [Int] = []
    ) async throws {
        var queryItems = [URLQueryItem(name: "playlistId", value: playlistID)]
        if let name {
            queryItems.append(URLQueryItem(name: "name", value: name))
        }
        queryItems += songIDsToAdd.map { URLQueryItem(name: "songIdToAdd", value: $0) }
        queryItems += indicesToRemove.map { URLQueryItem(name: "songIndexToRemove", value: String($0)) }
        let response: PingEnvelope = try await request("updatePlaylist", queryItems: queryItems)
        try response.subsonicResponse.throwIfNeeded()
    }

    func deletePlaylist(id: String) async throws {
        let response: PingEnvelope = try await request(
            "deletePlaylist",
            queryItems: [URLQueryItem(name: "id", value: id)]
        )
        try response.subsonicResponse.throwIfNeeded()
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
