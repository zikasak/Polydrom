import Combine
import Foundation
import SwiftUI
import Testing
@testable import PolyDrom

struct ViewSnapshotTests {
    @Test func songIdentitiesSurviveReorderAndMetadataChanges() {
        let first = SongListSnapshot([makeSong(id: "a"), makeSong(id: "b")])
        let reordered = SongListSnapshot(
            [makeSong(id: "b", title: "Updated"), makeSong(id: "a")],
            previous: first
        )
        #expect(reordered.revision != first.revision)
        #expect(reordered.entries[0].id == first.entries[1].id)
        #expect(reordered.entries[1].id == first.entries[0].id)
        #expect(reordered.indicesByID[first.entries[0].id] == 1)
        #expect(reordered.entries[0].song.title == "Updated")
    }

    @Test func duplicateSongsHaveDistinctStableIdentities() {
        let song = makeSong()
        let first = SongListSnapshot([song, song])
        let refreshed = SongListSnapshot([song, song], previous: first)
        #expect(first.entries[0].id != first.entries[1].id)
        #expect(refreshed.entries.map(\.id) == first.entries.map(\.id))
    }

    @Test func ambiguousDuplicateRemovalDoesNotReuseAnotherOccurrencesState() {
        let song = makeSong(id: "duplicate")
        let other = makeSong(id: "other")
        let first = SongListSnapshot([song, other, song])
        let removed = SongListSnapshot([other, song], previous: first)
        #expect(removed.entries[0].id == first.entries[1].id)
        #expect(!first.entries.map(\.id).contains(removed.entries[1].id))
        #expect(removed.indicesByID[first.entries[0].id] == nil)
        #expect(removed.indicesByID[first.entries[2].id] == nil)
    }

    @Test func lyricsTimelineMatchesLineOrderingAndOffsets() throws {
        for offset in [-1_000, 0, 1_000] {
            let json = """
            {"synced":true,"offset":\(offset),"line":[
                {"start":0,"value":"First"},
                {"start":5000,"value":"Later"},
                {"value":"Untimed"},
                {"start":2000,"value":"Out of order"},
                {"start":5000,"value":"Same time"}
            ]}
            """
            let lyrics = try JSONDecoder().decode(SongLyrics.self, from: Data(json.utf8))
            let timeline = LyricsTimeline(lyrics)
            for index in lyrics.lines.indices {
                #expect(timeline.playbackTime(at: index) == lyrics.playbackTime(for: lyrics.lines[index]))
            }
            // Include backward seeks, boundaries, duplicate and unsorted cues.
            for time in [0.0, 0.999, 1, 2, 4.999, 5, 6, 100, 2, -1, .infinity, -.infinity, .nan] {
                #expect(timeline.lineIndex(at: time) == lyrics.lineIndex(at: time))
            }
        }
    }

    @Test func plainAndEmptyLyricsHaveNoActiveLine() throws {
        let plain = try JSONDecoder().decode(
            SongLyrics.self,
            from: Data(#"{"synced":false,"line":[{"start":0,"value":"Plain"}]}"#.utf8)
        )
        #expect(LyricsTimeline(plain).lineIndex(at: 10) == nil)
        #expect(LyricsTimeline().lineIndex(at: 10) == nil)
    }
}

@Suite(.serialized)
@MainActor
struct ViewSnapshotIntegrationTests {
    @Test func rowUpdatesWhenItsPlaybackQueueChanges() {
        let (viewModel, _, _) = makeViewModel()
        let first = SongListSnapshot([makeSong(id: "a"), makeSong(id: "b")])
        let changedQueue = SongListSnapshot([makeSong(id: "a"), makeSong(id: "c")], previous: first)
        func row(_ snapshot: SongListSnapshot) -> SongRowView {
            SongRowView(
                snapshot: snapshot, queueIndex: 0, viewModel: viewModel,
                isCurrentSong: false, openRoute: { _ in }, currentAlbumID: nil
            )
        }
        #expect(row(first) == row(first))
        #expect(row(first) != row(changedQueue))
    }

    @Test func rowComparisonCapturesSelectionInsteadOfReadingLiveBindings() {
        let (viewModel, _, _) = makeViewModel()
        let snapshot = SongListSnapshot([makeSong()])
        var selected = false
        let binding = Binding(get: { selected }, set: { selected = $0 })
        func row() -> SongRowView {
            SongRowView(
                snapshot: snapshot, queueIndex: 0, viewModel: viewModel,
                isCurrentSong: false, openRoute: { _ in }, currentAlbumID: nil,
                selection: binding
            )
        }
        let before = row()
        selected = true
        #expect(before != row())
    }

    @Test func sourceMutationsRefreshSnapshotsAndFavoriteRevisions() {
        let (viewModel, _, _) = makeViewModel()
        viewModel.albumSongs = [makeSong()]
        let original = viewModel.albumSongsSnapshot
        viewModel.albumSongs.append(makeSong(id: "second"))
        #expect(viewModel.albumSongsSnapshot.songs.count == 2)
        #expect(viewModel.albumSongsSnapshot.revision != original.revision)
        #expect(viewModel.albumSongsSnapshot.entries[0].id == original.entries[0].id)
        let favoriteRevision = viewModel.favoriteAlbumIDsRevision
        viewModel.favoriteAlbumIDs.insert("album")
        #expect(viewModel.favoriteAlbumIDsRevision != favoriteRevision)
        let revision = viewModel.albumSongsSnapshot.revision
        viewModel.statusMessage = "Unrelated update"
        #expect(viewModel.albumSongsSnapshot.revision == revision)
    }

    @Test func playlistMenuTracksEveryPermissionInput() {
        let (viewModel, _, _) = makeViewModel()
        let server = makeProfile()
        let owned = NavidromePlaylist(id: "owned", name: "Owned", owner: server.username)
        let foreign = NavidromePlaylist(id: "foreign", name: "Foreign", owner: "someone-else")
        let readOnly = NavidromePlaylist(id: "smart", name: "Smart", isReadOnly: true)
        viewModel.playlists = [owned, foreign, readOnly]
        viewModel.activeServer = server
        #expect(viewModel.playlistMenuState.playlists.isEmpty)
        viewModel.isOnline = true
        #expect(viewModel.playlistMenuState.playlists.map(\.id) == ["owned"])
        #expect(viewModel.playlistMenuState.canCreatePlaylist)
        viewModel.isPlaylistMutating = true
        #expect(viewModel.playlistMenuState.playlists.isEmpty)
        #expect(!viewModel.playlistMenuState.canCreatePlaylist)
        viewModel.isPlaylistMutating = false
        #expect(viewModel.playlistMenuState.playlists.map(\.id) == ["owned"])
        viewModel.activeServer?.username = "someone-else"
        #expect(viewModel.playlistMenuState.playlists.map(\.id) == ["foreign"])
        viewModel.playlists.removeAll()
        #expect(viewModel.playlistMenuState.playlists.isEmpty)
        viewModel.isOnline = false
        #expect(!viewModel.playlistMenuState.canCreatePlaylist)
    }

    @Test func explicitPublisherStillReceivesPublishedChanges() {
        let (viewModel, _, _) = makeViewModel()
        var coordinatorEvents = 0
        var playerEvents = 0
        let coordinatorSubscription = viewModel.objectWillChange.sink { coordinatorEvents += 1 }
        let playerSubscription = viewModel.audioPlayer.objectWillChange.sink { playerEvents += 1 }
        viewModel.statusMessage = "Changed"
        viewModel.audioPlayer.currentTime = 5
        #expect(coordinatorEvents == 1)
        #expect(playerEvents == 1)
        withExtendedLifetime((coordinatorSubscription, playerSubscription)) {}
    }

    @Test func stalePlaylistSelectionCannotRemoveAnotherSong() async {
        let (viewModel, _, _) = makeViewModel()
        let playlist = NavidromePlaylist(id: "playlist", name: "Playlist")
        viewModel.playlistSongs = [makeSong(id: "a"), makeSong(id: "b")]
        let selectedRevision = viewModel.playlistSongsSnapshot.revision
        viewModel.playlistSongs = [makeSong(id: "b"), makeSong(id: "c")]
        let removed = await viewModel.removeSongs(
            at: IndexSet(integer: 0), from: playlist,
            expectedSnapshotRevision: selectedRevision
        )
        #expect(!removed)
        #expect(viewModel.playlistSongs.map(\.id) == ["b", "c"])
        #expect(viewModel.statusMessage == "Playlist changed. Select the songs again.")
    }

    @Test func transportAvailabilityTracksQueueReorderAndRemoval() {
        let (viewModel, _, _) = makeViewModel()
        let first = PlaybackQueueEntry(song: makeSong(id: "a"))
        let second = PlaybackQueueEntry(song: makeSong(id: "b"))
        viewModel.isOnline = true
        viewModel.audioPlayer.currentSong = second.song
        viewModel.currentPlaybackQueueEntryID = second.id
        viewModel.playbackQueue = [first, second]
        #expect(viewModel.canPlayPreviousTrack())
        #expect(!viewModel.canPlayNextTrack())
        viewModel.playbackQueue = [second, first]
        #expect(!viewModel.canPlayPreviousTrack())
        #expect(viewModel.canPlayNextTrack())
        viewModel.playbackQueue.removeFirst()
        #expect(!viewModel.canPlayPreviousTrack())
        #expect(!viewModel.canPlayNextTrack())
    }
}
