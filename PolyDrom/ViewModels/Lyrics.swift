import Foundation
import OSLog

extension AppCoordinator {
    func loadLyrics(for song: NavidromeSong, force: Bool = false) async {
        guard isOnline, let client, let session = currentSession else {
            currentLyrics = nil
            lyricsMessage = "Connect to a server to load lyrics."
            return
        }

        if !force, lyricsSongID == song.id {
            return
        }

        lyricsSongID = song.id
        currentLyrics = nil
        lyricsMessage = "Loading lyrics..."
        isLoadingLyrics = true
        defer { isLoadingLyrics = false }

        do {
            let availableLyrics = try await client.lyrics(for: song)
            guard lyricsSongID == song.id, isCurrentSession(session) else { return }
            let mainLyrics = availableLyrics.filter(\.isMainLayer)
            let candidates = mainLyrics.isEmpty ? availableLyrics : mainLyrics
            currentLyrics = candidates.first(where: \.synced) ?? candidates.first
            lyricsMessage = currentLyrics == nil ? "No lyrics are available for this song." : ""
            AppLog.network.debug(
                "Loaded \(availableLyrics.count, privacy: .public) lyric entries for song \(song.id, privacy: .private(mask: .hash))"
            )
        } catch {
            guard lyricsSongID == song.id, isCurrentSession(session) else { return }
            currentLyrics = nil
            lyricsMessage = "Lyrics could not be loaded: \(error.localizedDescription)"
            AppLog.network.error("Could not load lyrics: \(error.localizedDescription, privacy: .private)")
        }
    }
}
