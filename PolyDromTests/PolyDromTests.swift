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
        #expect(lyrics.offset == 125)
        #expect(lyrics.lines.map(\.start) == [1200, 3500])
        #expect(lyrics.lines.map(\.value) == ["First line", "Second line"])
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

    @Test func libraryStorePersistsFavoriteAndRecentSongs() throws {
        let store = LibraryStore(
            persistence: PersistenceController(inMemory: true),
            keychain: KeychainStore()
        )
        let song = makeSong()
        let serverKey = "https://music.example.com|user"

        try store.upsertSongs([song], serverKey: serverKey)
        #expect(try store.favoriteSongs(serverKey: serverKey).isEmpty)

        try store.setFavorite(song, serverKey: serverKey, isFavorite: true)
        #expect(try store.favoriteIDs(serverKey: serverKey) == [song.id])
        #expect(try store.favoriteSongs(serverKey: serverKey) == [song])

        try store.markPlayed(song, serverKey: serverKey)
        #expect(try store.recentSongs(serverKey: serverKey) == [song])
    }

    private func makeSong() -> NavidromeSong {
        NavidromeSong(
            id: "song-1",
            title: "Song",
            artist: nil,
            album: nil,
            duration: nil,
            suffix: nil,
            coverArt: nil,
            albumId: nil,
            artistId: nil
        )
    }

}
