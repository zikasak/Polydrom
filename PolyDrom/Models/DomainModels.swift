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

struct NavidromeGenre: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let songCount: Int

    init(name: String, songCount: Int) {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        self.id = Self.normalizedID(for: trimmedName)
        self.name = trimmedName
        self.songCount = songCount
    }

    static func normalizedID(for name: String) -> String {
        name
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .precomposedStringWithCanonicalMapping
            .lowercased(with: Locale(identifier: "en_US_POSIX"))
    }

    var subtitle: String {
        "\(songCount) \(songCount == 1 ? "song" : "songs")"
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
    let suffix: String?
    let genres: [String]

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
        played: Date? = nil,
        suffix: String? = nil,
        genres: [String] = []
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
        self.suffix = suffix
        self.genres = Self.normalizedGenres(genres)
    }

    enum CodingKeys: String, CodingKey {
        case id, title, artist, album, duration, coverArt, albumId, artistId
        case track
        case discNumber
        case created
        case played
        case suffix
        case genre
        case genres
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
        suffix = container.decodeStringIfPresent(forKey: .suffix)
        let modernGenres = try? container.decode([SongGenreValue].self, forKey: .genres)
        var singleModernGenre: SongGenreValue?
        if modernGenres == nil, container.contains(.genres) {
            singleModernGenre = try? container.decode(SongGenreValue.self, forKey: .genres)
        }
        let legacyGenre = container.decodeStringIfPresent(forKey: .genre)
        genres = Self.normalizedGenres(
            (modernGenres ?? []).map(\.name) + [singleModernGenre?.name, legacyGenre].compactMap { $0 }
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(title, forKey: .title)
        try container.encodeIfPresent(artist, forKey: .artist)
        try container.encodeIfPresent(album, forKey: .album)
        try container.encodeIfPresent(duration, forKey: .duration)
        try container.encodeIfPresent(coverArt, forKey: .coverArt)
        try container.encodeIfPresent(albumId, forKey: .albumId)
        try container.encodeIfPresent(artistId, forKey: .artistId)
        try container.encodeIfPresent(track, forKey: .track)
        try container.encodeIfPresent(discNumber, forKey: .discNumber)
        try container.encodeIfPresent(created, forKey: .created)
        try container.encodeIfPresent(played, forKey: .played)
        try container.encodeIfPresent(suffix, forKey: .suffix)
        if !genres.isEmpty {
            try container.encode(genres.map(SongGenreValue.init(name:)), forKey: .genres)
        }
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

    private static func normalizedGenres(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.compactMap { value in
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            let id = NavidromeGenre.normalizedID(for: trimmed)
            guard seen.insert(id).inserted else { return nil }
            return trimmed
        }
    }
}

private struct SongGenreValue: Codable {
    let name: String
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
    let kind: String?
    let lines: [SongLyricsLine]
    /// Main and background vocal runs for each entry in `lines`, in display order.
    let lineSegments: [[SongLyricsSegment]]

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

    /// Enhanced responses also carry translation and pronunciation layers.
    var isMainLayer: Bool {
        guard let kind, !kind.isEmpty else { return true }
        return kind.caseInsensitiveCompare("main") == .orderedSame
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
        case kind
        case lines = "line"
        case agents
        case cueLines = "cueLine"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        displayArtist = try? container.decode(String.self, forKey: .displayArtist)
        displayTitle = try? container.decode(String.self, forKey: .displayTitle)
        language = try? container.decode(String.self, forKey: .language)
        offset = container.decodeFlexibleInt(forKey: .offset)
        synced = (try? container.decode(Bool.self, forKey: .synced)) ?? false
        kind = try? container.decode(String.self, forKey: .kind)
        let lines = ((try? container.decode(FlexibleArray<SongLyricsLine>.self, forKey: .lines)) ?? FlexibleArray(values: [])).values
        self.lines = lines

        let agents = ((try? container.decode(FlexibleArray<SongLyricsAgent>.self, forKey: .agents)) ?? FlexibleArray(values: [])).values
        let cueLines = ((try? container.decode(FlexibleArray<SongLyricsCueLine>.self, forKey: .cueLines)) ?? FlexibleArray(values: [])).values
        let backgroundAgentIDs = Set(agents.filter { $0.role.caseInsensitiveCompare("bg") == .orderedSame }.map(\.id))
        let backgroundValuesByIndex = Dictionary(
            grouping: cueLines.filter { $0.agentId.map(backgroundAgentIDs.contains) ?? false },
            by: \.index
        ).mapValues { $0.map(\.value) }

        lineSegments = lines.enumerated().map { index, line in
            // Servers without vocal attribution only mark background vocals with parentheses.
            SongLyricsSegment.marking(backgroundValues: backgroundValuesByIndex[index] ?? [], in: line.value)
                ?? SongLyricsSegment.splittingParentheses(in: line.value)
        }
    }
}

struct SongLyricsSegment: Hashable, Sendable {
    let text: String
    let isBackground: Bool

    /// Marks where each background vocal sits inside the combined line, keeping the line's own
    /// ordering and spacing. Returns nil when none of them can be located in `value`.
    static func marking(backgroundValues: [String], in value: String) -> [SongLyricsSegment]? {
        var backgroundRanges: [Range<String.Index>] = []

        for backgroundValue in backgroundValues {
            let needle = backgroundValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !needle.isEmpty else { continue }

            var plainMatch: Range<String.Index>?
            var parenthesizedMatch: Range<String.Index>?
            var searchStart = value.startIndex
            while parenthesizedMatch == nil,
                  let match = value.range(of: needle, range: searchStart..<value.endIndex) {
                searchStart = match.upperBound
                guard !backgroundRanges.contains(where: { $0.overlaps(match) }) else { continue }

                // The lead can sing the same words, so prefer the occurrence set off in parentheses.
                if match.lowerBound > value.startIndex, match.upperBound < value.endIndex {
                    let opening = value.index(before: match.lowerBound)
                    if "(（".contains(value[opening]), ")）".contains(value[match.upperBound]),
                       !backgroundRanges.contains(where: { $0.contains(opening) || $0.contains(match.upperBound) }) {
                        parenthesizedMatch = opening..<value.index(after: match.upperBound)
                    }
                }
                plainMatch = plainMatch ?? match
            }

            if let range = parenthesizedMatch ?? plainMatch {
                backgroundRanges.append(range)
            }
        }

        guard !backgroundRanges.isEmpty else { return nil }

        var segments: [SongLyricsSegment] = []
        var position = value.startIndex
        for range in backgroundRanges.sorted(by: { $0.lowerBound < $1.lowerBound }) {
            if position < range.lowerBound {
                segments.append(SongLyricsSegment(text: String(value[position..<range.lowerBound]), isBackground: false))
            }
            segments.append(SongLyricsSegment(text: String(value[range]), isBackground: true))
            position = range.upperBound
        }
        if position < value.endIndex {
            segments.append(SongLyricsSegment(text: String(value[position...]), isBackground: false))
        }
        return segments
    }

    /// Treats parenthesized runs as background vocals; the segments concatenate back to `value`.
    static func splittingParentheses(in value: String) -> [SongLyricsSegment] {
        var segments: [SongLyricsSegment] = []
        var current = ""
        var depth = 0

        func flush(isBackground: Bool) {
            guard !current.isEmpty else { return }
            segments.append(SongLyricsSegment(text: current, isBackground: isBackground))
            current = ""
        }

        for character in value {
            if character == "(" || character == "（" {
                if depth == 0 { flush(isBackground: false) }
                depth += 1
                current.append(character)
            } else if (character == ")" || character == "）"), depth > 0 {
                current.append(character)
                depth -= 1
                if depth == 0 { flush(isBackground: true) }
            } else {
                current.append(character)
            }
        }
        flush(isBackground: false)
        return segments
    }
}

private struct SongLyricsAgent: Decodable {
    let id: String
    let role: String
}

private struct SongLyricsCueLine: Decodable {
    let index: Int
    let value: String
    let agentId: String?
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
        guard contains(key) else { return nil }

        if let value = try? decode(String.self, forKey: key) {
            return value
        }

        if let value = try? decode(Int.self, forKey: key) {
            return String(value)
        }

        return nil
    }

    func decodeIntIfPresent(forKey key: Key) -> Int? {
        guard contains(key) else { return nil }

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
        guard contains(key) else { return nil }

        // Navidrome sends ISO 8601 strings, so try that first: a failed decode
        // builds an error, which adds up over a whole catalog.
        if let value = try? decode(String.self, forKey: key) {
            return FlexibleISO8601.date(from: value)
        }

        if let date = try? decode(Date.self, forKey: key) {
            return date
        }

        if let milliseconds = try? decode(Double.self, forKey: key) {
            return Date(timeIntervalSince1970: milliseconds / 1_000)
        }

        return nil
    }
}

private enum FlexibleISO8601 {
    // ISO8601DateFormatter is thread-safe, and building one per date dominated
    // the cost of decoding large catalog pages.
    nonisolated(unsafe) private static let fractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    nonisolated(unsafe) private static let wholeSeconds = ISO8601DateFormatter()

    static func date(from value: String) -> Date? {
        fractional.date(from: value) ?? wholeSeconds.date(from: value)
    }
}

enum LibrarySection: String, CaseIterable, Identifiable, Sendable {
    case home = "Home"
    case search = "Search"
    case random = "Random"
    case albums = "Albums"
    case artists = "Artists"
    case genres = "Genres"
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
        case .genres: "guitars"
        case .playlists: "music.note.list"
        case .favorites: "heart"
        case .recent: "clock"
        }
    }
}
