//
//  PolyDromTests.swift
//  PolyDromTests
//
//  Created by zikasak on 07/07/2026.
//

import Foundation
import Testing
@testable import PolyDrom

@MainActor
struct PolyDromTests {

    @Test func streamURLUsesAVFoundationFriendlyQuery() throws {
        let profile = ServerProfile(
            id: UUID(),
            name: "Test",
            address: "https://music.example.com",
            username: "user",
            credentialID: UUID().uuidString,
            password: "password",
            createdAt: Date(),
            lastConnectedAt: nil
        )
        let song = makeSong()
        let client = try #require(NavidromeClient(profile: profile))

        let url = try client.streamURL(for: song)
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let queryItems = components.queryItems ?? []

        #expect(components.path == "/rest/stream.view")
        #expect(queryItems.contains(URLQueryItem(name: "id", value: "song-1")))
        #expect(queryItems.contains(URLQueryItem(name: "format", value: "mp3")))
        #expect(!queryItems.contains { $0.name == "estimateContentLength" })
        #expect(!queryItems.contains { $0.name == "f" })
    }

    @Test func structuredLyricsDecodeTimedAndPlainLines() throws {
        let json = #"""
        {
          "subsonic-response": {
            "status": "ok",
            "lyricsList": {
              "structuredLyrics": [
                {
                  "displayArtist": "Test Artist",
                  "displayTitle": "Test Song",
                  "lang": "eng",
                  "offset": 125,
                  "synced": true,
                  "line": [
                    { "start": 1200, "value": "First line" },
                    { "start": "3500", "value": "Second line" }
                  ]
                }
              ]
            }
          }
        }
        """#

        let envelope = try JSONDecoder().decode(LyricsEnvelope.self, from: Data(json.utf8))
        let lyrics = try #require(envelope.subsonicResponse.lyricsList?.structuredLyrics.values.first)

        #expect(lyrics.synced)
        #expect(lyrics.language == "eng")
        #expect(lyrics.displayLanguage == "ENG")
        #expect(lyrics.offset == 125)
        #expect(lyrics.lines.map(\.start) == [1200, 3500])
        #expect(lyrics.lines.map(\.value) == ["First line", "Second line"])
    }

    @Test func unspecifiedLyricsLanguageHasNoDisplayLabel() throws {
        let json = #"""
        {
          "displayArtist": "Test Artist",
          "displayTitle": "Test Song",
          "lang": "xxx",
          "synced": false,
          "line": [{ "value": "A lyric" }]
        }
        """#

        let lyrics = try JSONDecoder().decode(SongLyrics.self, from: Data(json.utf8))

        #expect(lyrics.displayLanguage == nil)
    }

    @Test func failedSubsonicResponsePreservesServerMessage() throws {
        let json = #"""
        {
          "subsonic-response": {
            "status": "failed",
            "error": { "message": "Bad credentials" }
          }
        }
        """#

        let envelope = try JSONDecoder().decode(PingEnvelope.self, from: Data(json.utf8))
        var thrownMessage: String?

        do {
            try envelope.subsonicResponse.throwIfNeeded()
        } catch {
            thrownMessage = error.localizedDescription
        }

        #expect(thrownMessage == "Bad credentials")
    }

    @Test func starredResponseDecodesArtistsAlbumsAndSongs() throws {
        let json = #"""
        {
          "subsonic-response": {
            "status": "ok",
            "starred2": {
              "artist": [{ "id": "artist-1", "name": "Favorite Artist" }],
              "album": [{ "id": "album-1", "name": "Favorite Album" }],
              "song": [{ "id": "song-1", "title": "Favorite Song" }]
            }
          }
        }
        """#

        let envelope = try JSONDecoder().decode(StarredEnvelope.self, from: Data(json.utf8))
        let artists = envelope.subsonicResponse.starred2?.artists.values ?? []
        let albums = envelope.subsonicResponse.starred2?.albums.values ?? []
        let songs = envelope.subsonicResponse.starred2?.songs.values ?? []

        #expect(artists.map(\.id) == ["artist-1"])
        #expect(artists.map(\.name) == ["Favorite Artist"])
        #expect(albums.map(\.id) == ["album-1"])
        #expect(albums.map(\.name) == ["Favorite Album"])
        #expect(songs.map(\.id) == ["song-1"])
        #expect(songs.map(\.title) == ["Favorite Song"])
    }

    @Test func libraryStorePersistsRecentSongs() throws {
        let store = LibraryStore(
            persistence: PersistenceController(inMemory: true),
            keychain: KeychainStore()
        )
        let song = makeSong()
        let serverKey = "https://music.example.com|user"

        try store.upsertSongs([song], serverKey: serverKey)
        try store.markPlayed(song, serverKey: serverKey)
        #expect(try store.recentSongs(serverKey: serverKey) == [song])
    }

    @Test func playNextInsertsAfterCurrentSongAndQueueAppends() {
        let store = LibraryStore(
            persistence: PersistenceController(inMemory: true),
            keychain: KeychainStore()
        )
        let audioPlayer = AudioPlayer()
        let viewModel = AppViewModel(store: store, audioPlayer: audioPlayer)
        let current = makeSong(id: "current", title: "Current")
        let later = makeSong(id: "later", title: "Later")
        let next = makeSong(id: "next", title: "Next")
        let end = makeSong(id: "end", title: "End")
        let currentEntry = PlaybackQueueEntry(song: current)

        viewModel.playbackQueue = [currentEntry, PlaybackQueueEntry(song: later)]
        viewModel.currentPlaybackQueueEntryID = currentEntry.id
        audioPlayer.currentSong = current
        viewModel.playNext([next])
        viewModel.addToQueue([end])

        #expect(viewModel.playbackQueue.map(\.song.id) == ["current", "next", "later", "end"])
    }

    @Test func duplicateQueueEntriesKeepIndependentIdentity() {
        let store = LibraryStore(
            persistence: PersistenceController(inMemory: true),
            keychain: KeychainStore()
        )
        let audioPlayer = AudioPlayer()
        let viewModel = AppViewModel(store: store, audioPlayer: audioPlayer)
        let duplicate = makeSong(id: "duplicate", title: "Duplicate")
        let later = makeSong(id: "later", title: "Later")
        let first = PlaybackQueueEntry(id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!, song: duplicate)
        let second = PlaybackQueueEntry(id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!, song: duplicate)
        let laterEntry = PlaybackQueueEntry(id: UUID(uuidString: "00000000-0000-0000-0000-000000000003")!, song: later)

        viewModel.playbackQueue = [first, second, laterEntry]
        viewModel.currentPlaybackQueueEntryID = second.id
        audioPlayer.currentSong = duplicate

        #expect(first.id != second.id)
        #expect(viewModel.currentPlaybackQueueEntryID != first.id)
        #expect(viewModel.currentPlaybackQueueEntryID == second.id)
        #expect(viewModel.canPlayPreviousTrack())
        #expect(viewModel.canPlayNextTrack())

        viewModel.playNext([duplicate])
        viewModel.addToQueue([duplicate])

        #expect(viewModel.playbackQueue.map(\.song.id) == ["duplicate", "duplicate", "duplicate", "later", "duplicate"])
        #expect(viewModel.playbackQueue[0].id == first.id)
        #expect(viewModel.playbackQueue[1].id == second.id)
        #expect(viewModel.playbackQueue[3].id == laterEntry.id)
        #expect(Set(viewModel.playbackQueue.map(\.id)).count == viewModel.playbackQueue.count)

        audioPlayer.stop()
        #expect(!viewModel.canPlayPreviousTrack())
        #expect(!viewModel.canPlayNextTrack())
    }

    @Test func songMetadataCreatesNavigableAlbumAndArtist() throws {
        let song = makeSong(
            artist: "Artist",
            album: "Album",
            albumId: "album-1",
            artistId: "artist-1"
        )
        let album = try #require(NavidromeAlbum(song: song))
        let artist = try #require(NavidromeArtist(song: song))

        #expect(album.id == "album-1")
        #expect(album.name == "Album")
        #expect(album.artistId == "artist-1")
        #expect(artist.id == "artist-1")
        #expect(artist.name == "Artist")
    }

    @Test func songNavigationReusesLoadedAlbumAndArtistMetadata() throws {
        let store = LibraryStore(
            persistence: PersistenceController(inMemory: true),
            keychain: KeychainStore()
        )
        let viewModel = AppViewModel(store: store, audioPlayer: AudioPlayer())
        let song = makeSong(
            artist: "Artist",
            album: "Album",
            albumId: "album-1",
            artistId: "artist-1"
        )
        let album = try JSONDecoder().decode(
            NavidromeAlbum.self,
            from: Data(#"{"id":"album-1","name":"Album","artist":"Artist","artistId":"artist-1","songCount":42,"year":2026}"#.utf8)
        )
        let artist = try JSONDecoder().decode(
            NavidromeArtist.self,
            from: Data(#"{"id":"artist-1","name":"Artist","albumCount":7}"#.utf8)
        )

        viewModel.selectedAlbum = album
        viewModel.selectedArtist = artist

        #expect(viewModel.albumForNavigation(from: song) == album)
        #expect(viewModel.artistForNavigation(from: song) == artist)
        #expect(viewModel.albumForNavigation(from: song)?.songCount == 42)
        #expect(viewModel.artistForNavigation(from: song)?.albumCount == 7)
    }

    private func makeSong(
        id: String = "song-1",
        title: String = "Song",
        artist: String? = nil,
        album: String? = nil,
        albumId: String? = nil,
        artistId: String? = nil
    ) -> NavidromeSong {
        NavidromeSong(
            id: id,
            title: title,
            artist: artist,
            album: album,
            duration: nil,
            suffix: nil,
            coverArt: nil,
            albumId: albumId,
            artistId: artistId
        )
    }

}
