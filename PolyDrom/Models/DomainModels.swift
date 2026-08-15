//
//  DomainModels.swift
//  PolyDrom
//
//  Created by zikasak on 07/07/2026.
//

import Foundation

struct ServerProfile: Identifiable, Hashable, Sendable {
    let id: UUID
    var name: String
    var address: String
    var username: String
    var credentialID: String
    var password: String
    var createdAt: Date
    var lastConnectedAt: Date?

    var serverKey: String {
        "\(address.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())|\(username.lowercased())"
    }

    var displayName: String {
        if !name.isEmpty { return name }
        return "\(username) @ \(address)"
    }
}

struct NavidromeSong: Codable, Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    let artist: String?
    let album: String?
    let duration: Int?
    let coverArt: String?
    let albumId: String?
    let artistId: String?
    let track: Int?
    let discNumber: Int?
    let created: Date?
    let played: Date?

    init(
        id: String,
        title: String,
        artist: String? = nil,
        album: String? = nil,
        duration: Int? = nil,
        coverArt: String? = nil,
        albumId: String? = nil,
        artistId: String? = nil,
        track: Int? = nil,
        discNumber: Int? = nil,
        created: Date? = nil,
        played: Date? = nil
    ) {
        self.id = id
        self.title = title
        self.artist = artist
        self.album = album
        self.duration = duration
        self.coverArt = coverArt
        self.albumId = albumId
        self.artistId = artistId
        self.track = track
        self.discNumber = discNumber
        self.created = created
        self.played = played
    }

    enum CodingKeys: String, CodingKey {
        case id, title, artist, album, duration, coverArt, albumId, artistId
        case track
        case discNumber
        case created
        case played
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeString(forKey: .id)
        title = container.decodeStringIfPresent(forKey: .title) ?? "Untitled"
        artist = container.decodeStringIfPresent(forKey: .artist)
        album = container.decodeStringIfPresent(forKey: .album)
        duration = container.decodeIntIfPresent(forKey: .duration)
        coverArt = container.decodeStringIfPresent(forKey: .coverArt)
        albumId = container.decodeStringIfPresent(forKey: .albumId)
        artistId = container.decodeStringIfPresent(forKey: .artistId)
        track = container.decodeIntIfPresent(forKey: .track)
        discNumber = container.decodeIntIfPresent(forKey: .discNumber)
        created = container.decodeDateIfPresent(forKey: .created)
        played = container.decodeDateIfPresent(forKey: .played)
    }

    var subtitle: String {
        [artist, album].compactMap { value in
            guard let value, !value.isEmpty else { return nil }
            return value
        }
        .joined(separator: " - ")
    }

    var durationText: String {
        guard let duration else { return "--:--" }
        return "\(duration / 60):\(String(format: "%02d", duration % 60))"
    }
}

struct PlaybackQueueEntry: Codable, Identifiable, Hashable, Sendable {
    let id: UUID
    var song: NavidromeSong

    init(id: UUID = UUID(), song: NavidromeSong) {
        self.id = id
        self.song = song
    }
}

struct PlaybackSessionIdentity: Sendable {
    let generation: UInt
    let serverKey: String
}

struct NavidromeAlbum: Decodable, Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let artist: String?
    let artistId: String?
    let songCount: Int?
    let year: Int?
    let coverArt: String?
    let created: Date?
    let played: Date?

    init(
        id: String,
        name: String,
        artist: String? = nil,
        artistId: String? = nil,
        songCount: Int? = nil,
        year: Int? = nil,
        coverArt: String? = nil,
        created: Date? = nil,
        played: Date? = nil
    ) {
        self.id = id
        self.name = name
        self.artist = artist
        self.artistId = artistId
        self.songCount = songCount
        self.year = year
        self.coverArt = coverArt
        self.created = created
        self.played = played
    }

    init?(song: NavidromeSong) {
        guard let id = song.albumId,
              let name = song.album,
              !name.isEmpty else {
            return nil
        }

        self.id = id
        self.name = name
        self.artist = song.artist
        self.artistId = song.artistId
        self.songCount = nil
        self.year = nil
        self.coverArt = song.coverArt
        self.created = song.created
        self.played = song.played
    }

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case title
        case artist
        case artistId
        case songCount
        case year
        case coverArt
        case created
        case played
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeString(forKey: .id)
        name = container.decodeStringIfPresent(forKey: .name)
            ?? container.decodeStringIfPresent(forKey: .title)
            ?? "Untitled Album"
        artist = container.decodeStringIfPresent(forKey: .artist)
        artistId = container.decodeStringIfPresent(forKey: .artistId)
        songCount = container.decodeIntIfPresent(forKey: .songCount)
        year = container.decodeIntIfPresent(forKey: .year)
        coverArt = container.decodeStringIfPresent(forKey: .coverArt)
        created = container.decodeDateIfPresent(forKey: .created)
        played = container.decodeDateIfPresent(forKey: .played)
    }

    var subtitle: String {
        var parts: [String] = []
        if let artist, !artist.isEmpty { parts.append(artist) }
        if let year { parts.append(String(year)) }
        if let songCount { parts.append("\(songCount) songs") }
        return parts.joined(separator: " - ")
    }
}

struct NavidromeArtist: Decodable, Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let albumCount: Int?
    let coverArt: String?
    let artistImageURL: String?

    init(
        id: String,
        name: String,
        albumCount: Int? = nil,
        coverArt: String? = nil,
        artistImageURL: String? = nil
    ) {
        self.id = id
        self.name = name
        self.albumCount = albumCount
        self.coverArt = coverArt
        self.artistImageURL = artistImageURL
    }

    init?(song: NavidromeSong) {
        guard let id = song.artistId,
              let name = song.artist,
              !name.isEmpty else {
            return nil
        }

        self.id = id
        self.name = name
        self.albumCount = nil
        self.coverArt = nil
        self.artistImageURL = nil
    }

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case albumCount
        case coverArt
        case artistImageURL = "artistImageUrl"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeString(forKey: .id)
        name = try container.decodeString(forKey: .name)
        albumCount = container.decodeIntIfPresent(forKey: .albumCount)
        coverArt = container.decodeStringIfPresent(forKey: .coverArt)
        artistImageURL = container.decodeStringIfPresent(forKey: .artistImageURL)
    }

    var subtitle: String {
        guard let albumCount else { return "" }
        return "\(albumCount) albums"
    }
}

struct NavidromePlaylist: Decodable, Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let songCount: Int?
    let owner: String?
    let changed: Date?
    let isReadOnly: Bool

    init(
        id: String,
        name: String,
        songCount: Int? = nil,
        owner: String? = nil,
        changed: Date? = nil,
        isReadOnly: Bool = false
    ) {
        self.id = id
        self.name = name
        self.songCount = songCount
        self.owner = owner
        self.changed = changed
        self.isReadOnly = isReadOnly
    }

    enum CodingKeys: String, CodingKey {
        case id, name, songCount, owner, changed
        case isReadOnly = "readonly"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeString(forKey: .id)
        name = container.decodeStringIfPresent(forKey: .name) ?? "Untitled Playlist"
        songCount = container.decodeIntIfPresent(forKey: .songCount)
        owner = container.decodeStringIfPresent(forKey: .owner)
        changed = container.decodeDateIfPresent(forKey: .changed)
        isReadOnly = (try? container.decode(Bool.self, forKey: .isReadOnly)) ?? false
    }

    var subtitle: String {
        var parts: [String] = []
        if let owner, !owner.isEmpty { parts.append(owner) }
        if let songCount { parts.append("\(songCount) songs") }
        return parts.joined(separator: " - ")
    }
}

struct SongLyrics: Decodable, Identifiable, Hashable, Sendable {
    let displayArtist: String?
    let displayTitle: String?
    let language: String?
    let offset: Int?
    let synced: Bool
    let lines: [SongLyricsLine]

    var id: String {
        [language, displayArtist, displayTitle, synced ? "synced" : "plain"]
            .compactMap { $0 }
            .joined(separator: "|")
    }

    var displayLanguage: String? {
        guard let language = language?.trimmingCharacters(in: .whitespacesAndNewlines),
              !language.isEmpty,
              language.caseInsensitiveCompare("xxx") != .orderedSame,
              language.caseInsensitiveCompare("und") != .orderedSame else {
            return nil
        }
        return language.uppercased()
    }

    func playbackTime(for line: SongLyricsLine) -> Double? {
        guard synced, let start = line.start else { return nil }
        return max((Double(start) - Double(offset ?? 0)) / 1_000, 0)
    }

    func lineIndex(at playbackTime: Double) -> Int? {
        guard synced else { return nil }
        return lines.lastIndex { line in
            guard let lineTime = self.playbackTime(for: line) else { return false }
            return lineTime <= playbackTime
        }
    }

    enum CodingKeys: String, CodingKey {
        case displayArtist
        case displayTitle
        case language = "lang"
        case offset
        case synced
        case lines = "line"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        displayArtist = try? container.decode(String.self, forKey: .displayArtist)
        displayTitle = try? container.decode(String.self, forKey: .displayTitle)
        language = try? container.decode(String.self, forKey: .language)
        offset = container.decodeFlexibleInt(forKey: .offset)
        synced = (try? container.decode(Bool.self, forKey: .synced)) ?? false
        lines = ((try? container.decode(FlexibleArray<SongLyricsLine>.self, forKey: .lines)) ?? FlexibleArray(values: [])).values
    }
}

struct SongLyricsLine: Decodable, Identifiable, Hashable, Sendable {
    let value: String
    let start: Int?

    var id: String { "\(start ?? -1)|\(value)" }

    enum CodingKeys: String, CodingKey {
        case value
        case start
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        value = (try? container.decode(String.self, forKey: .value)) ?? ""
        start = container.decodeFlexibleInt(forKey: .start)
    }
}

private extension KeyedDecodingContainer {
    func decodeString(forKey key: Key) throws -> String {
        if let value = decodeStringIfPresent(forKey: key) {
            return value
        }

        throw DecodingError.keyNotFound(
            key,
            DecodingError.Context(codingPath: codingPath, debugDescription: "Missing string value for \(key.stringValue).")
        )
    }

    func decodeStringIfPresent(forKey key: Key) -> String? {
        if let value = try? decode(String.self, forKey: key) {
            return value
        }

        if let value = try? decode(Int.self, forKey: key) {
            return String(value)
        }

        return nil
    }

    func decodeIntIfPresent(forKey key: Key) -> Int? {
        if let value = try? decode(Int.self, forKey: key) {
            return value
        }

        if let value = try? decode(String.self, forKey: key) {
            return Int(value)
        }

        return nil
    }

    func decodeFlexibleInt(forKey key: Key) -> Int? {
        decodeIntIfPresent(forKey: key)
    }

    func decodeDateIfPresent(forKey key: Key) -> Date? {
        if let date = try? decode(Date.self, forKey: key) {
            return date
        }

        if let value = try? decode(String.self, forKey: key) {
            return FlexibleISO8601.date(from: value)
        }

        if let milliseconds = try? decode(Double.self, forKey: key) {
            return Date(timeIntervalSince1970: milliseconds / 1_000)
        }

        return nil
    }
}

private enum FlexibleISO8601 {
    static func date(from value: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }
}

enum LibrarySection: String, CaseIterable, Identifiable, Sendable {
    case home = "Home"
    case search = "Search"
    case random = "Random"
    case albums = "Albums"
    case artists = "Artists"
    case playlists = "Playlists"
    case favorites = "Favorites"
    case recent = "Recently Played"

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .home: "house"
        case .search: "magnifyingglass"
        case .random: "shuffle"
        case .albums: "rectangle.stack"
        case .artists: "music.mic"
        case .playlists: "music.note.list"
        case .favorites: "heart"
        case .recent: "clock"
        }
    }
}
