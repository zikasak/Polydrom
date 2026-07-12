//
//  DomainModels.swift
//  PolyDrom
//
//  Created by zikasak on 07/07/2026.
//

import Foundation

struct ServerProfile: Identifiable, Hashable {
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

struct NavidromeSong: Decodable, Identifiable, Hashable {
    let id: String
    let title: String
    let artist: String?
    let album: String?
    let duration: Int?
    let suffix: String?
    let coverArt: String?
    let albumId: String?
    let artistId: String?

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

struct NavidromeAlbum: Decodable, Identifiable, Hashable {
    let id: String
    let name: String
    let artist: String?
    let artistId: String?
    let songCount: Int?
    let year: Int?
    let coverArt: String?

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case title
        case artist
        case artistId
        case songCount
        case year
        case coverArt
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
    }

    var subtitle: String {
        var parts: [String] = []
        if let artist, !artist.isEmpty { parts.append(artist) }
        if let year { parts.append(String(year)) }
        if let songCount { parts.append("\(songCount) songs") }
        return parts.joined(separator: " - ")
    }
}

struct NavidromeArtist: Decodable, Identifiable, Hashable {
    let id: String
    let name: String
    let albumCount: Int?
    let coverArt: String?
    let artistImageURL: String?

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

struct NavidromePlaylist: Decodable, Identifiable, Hashable {
    let id: String
    let name: String
    let songCount: Int?
    let owner: String?

    var subtitle: String {
        var parts: [String] = []
        if let owner, !owner.isEmpty { parts.append(owner) }
        if let songCount { parts.append("\(songCount) songs") }
        return parts.joined(separator: " - ")
    }
}

struct SongLyrics: Decodable, Identifiable, Hashable {
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

struct SongLyricsLine: Decodable, Identifiable, Hashable {
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
}

enum AlbumListType: String {
    case newest
    case alphabeticalByName
}

enum LibrarySection: String, CaseIterable, Identifiable {
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
