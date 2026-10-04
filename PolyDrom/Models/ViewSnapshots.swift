import Foundation
import Observation

/// Created at the data source, so views compare revisions without walking arrays.
struct ViewCollectionSnapshot<Element> {
    let revision = UUID()
    let items: [Element]

    init(_ items: [Element] = []) {
        self.items = items
    }
}

struct SongListEntry: Identifiable, Sendable {
    let id: UUID
    let index: Int
    let song: NavidromeSong
}

struct SongListSnapshot: Sendable {
    static let empty = SongListSnapshot()

    let revision = UUID()
    let songs: [NavidromeSong]
    let entries: [SongListEntry]
    let indicesByID: [UUID: Int]

    init(_ songs: [NavidromeSong] = [], previous: SongListSnapshot? = nil) {
        self.songs = songs
        var previousIDs: [String: [UUID]] = [:]
        for entry in previous?.entries ?? [] {
            previousIDs[entry.song.id, default: []].append(entry.id)
        }
        var counts: [String: Int] = [:]
        for song in songs { counts[song.id, default: 0] += 1 }
        var occurrences: [String: Int] = [:]
        entries = songs.enumerated().map { index, song in
            let occurrence = occurrences[song.id, default: 0]
            occurrences[song.id] = occurrence + 1
            let oldIDs = previousIDs[song.id] ?? []
            // The server provides song IDs, not playlist-entry IDs. If the
            // number of duplicates changes, their surviving identities are
            // ambiguous; remount that group rather than reuse the wrong state.
            let id = oldIDs.count == counts[song.id] ? oldIDs[occurrence] : UUID()
            return SongListEntry(id: id, index: index, song: song)
        }
        indicesByID = Dictionary(uniqueKeysWithValues: entries.map { ($0.id, $0.index) })
    }
}

/// A timeline sorted once when lyrics arrive. Equal times prefer the last line
/// in display order, matching the server's line ordering.
struct LyricsTimeline {
    private struct Cue {
        let time: Double
        let lineIndex: Int
    }

    private let cues: [Cue]
    private let playbackTimes: [Double?]

    init(_ lyrics: SongLyrics? = nil) {
        let times = lyrics.map { lyrics in
            lyrics.lines.map { lyrics.playbackTime(for: $0) }
        } ?? []
        playbackTimes = times
        let timedLines = times.enumerated().compactMap { index, time -> Cue? in
            guard let time else { return nil }
            return Cue(time: time, lineIndex: index)
        }
        let sorted = timedLines.sorted {
            $0.time == $1.time ? $0.lineIndex < $1.lineIndex : $0.time < $1.time
        }
        // Preserve lastIndex(where:) semantics even for out-of-order times.
        var lastIndex = -1
        cues = sorted.map { cue in
            lastIndex = max(lastIndex, cue.lineIndex)
            return Cue(time: cue.time, lineIndex: lastIndex)
        }
    }

    func lineIndex(at time: Double) -> Int? {
        guard !time.isNaN else { return nil }
        var lower = 0
        var upper = cues.count
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if cues[middle].time <= time {
                lower = middle + 1
            } else {
                upper = middle
            }
        }
        return lower == 0 ? nil : cues[lower - 1].lineIndex
    }

    func playbackTime(at index: Int) -> Double? {
        guard playbackTimes.indices.contains(index) else { return nil }
        return playbackTimes[index]
    }
}

/// Menus observe only playlist availability, rather than every coordinator event.
@MainActor
@Observable
final class PlaylistMenuState {
    var playlists: [NavidromePlaylist] = []
    var canCreatePlaylist = false
}
