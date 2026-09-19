import Foundation
import Testing
@testable import PolyDrom

@Suite(.serialized)
struct DomainModelTests {
    @Test func serverProfileNormalizesKeyAndChoosesDisplayName() {
        let unnamed = makeProfile(name: "", address: " HTTPS://Music.Example.COM/ \n", username: "USER")
        let named = makeProfile(name: "Living Room")

        #expect(unnamed.serverKey == "https://music.example.com/|user")
        #expect(unnamed.displayName == "USER @  HTTPS://Music.Example.COM/ \n")
        #expect(named.displayName == "Living Room")
    }

    @Test func songFormattingCoversEmptyAndKnownMetadata() {
        #expect(makeSong(artist: nil, album: nil, duration: nil).subtitle == "")
        #expect(makeSong(artist: "", album: "Album").subtitle == "Album")
        #expect(makeSong(artist: "Artist", album: "").subtitle == "Artist")
        #expect(makeSong().subtitle == "Artist - Album")
        #expect(makeSong(duration: nil).durationText == "--:--")
        #expect(makeSong(duration: 5).durationText == "0:05")
        #expect(makeSong(duration: 125).durationText == "2:05")
    }

    @Test func songDecodingSupportsLegacyAndMultipleGenres() throws {
        let legacy = try JSONDecoder().decode(
            NavidromeSong.self,
            from: Data(#"{"id":"legacy","title":"Legacy","genre":" Rock "}"#.utf8)
        )
        let modern = try JSONDecoder().decode(
            NavidromeSong.self,
            from: Data(
                #"{"id":"modern","title":"Modern","genre":"rock","genres":[{"name":"Electronic"},{"name":" ROCK "},{"name":""},{"name":"Electronic"}]}"#.utf8
            )
        )
        let missing = try JSONDecoder().decode(
            NavidromeSong.self,
            from: Data(#"{"id":"missing","title":"Missing"}"#.utf8)
        )

        #expect(legacy.genres == ["Rock"])
        #expect(modern.genres == ["Electronic", "ROCK"])
        #expect(missing.genres.isEmpty)
        #expect(try JSONDecoder().decode(NavidromeSong.self, from: JSONEncoder().encode(modern)) == modern)

        let genre = NavidromeGenre(name: "  Post-Rock  ", songCount: 1)
        #expect(genre.id == "post-rock")
        #expect(genre.name == "Post-Rock")
        #expect(genre.subtitle == "1 song")
        #expect(NavidromeGenre(name: "Ambient", songCount: 2).subtitle == "2 songs")
    }

    @Test func albumDecodingSupportsFlexibleValuesAndFallbacks() throws {
        let album = try JSONDecoder().decode(NavidromeAlbum.self, from: Data(#"{"id":42,"title":7,"artist":9,"artistId":10,"songCount":"3","year":"2024","coverArt":11}"#.utf8))
        let untitled = try JSONDecoder().decode(NavidromeAlbum.self, from: Data(#"{"id":"a"}"#.utf8))

        #expect(album.id == "42")
        #expect(album.name == "7")
        #expect(album.artist == "9")
        #expect(album.artistId == "10")
        #expect(album.songCount == 3)
        #expect(album.year == 2024)
        #expect(album.coverArt == "11")
        #expect(album.subtitle == "9 - 2024 - 3 songs")
        #expect(untitled.name == "Untitled Album")
        #expect(untitled.subtitle == "")
        #expect(NavidromeAlbum(song: makeSong(album: nil)) == nil)
        #expect(NavidromeAlbum(song: makeSong(album: "")) == nil)
        #expect(NavidromeAlbum(song: makeSong(albumId: nil)) == nil)
    }

    @Test func artistPlaylistAndLyricsFormattingCoversBranches() throws {
        let artist = try JSONDecoder().decode(NavidromeArtist.self, from: Data(#"{"id":1,"name":2,"albumCount":"4","coverArt":3,"artistImageUrl":4}"#.utf8))
        let noCount = try JSONDecoder().decode(NavidromeArtist.self, from: Data(#"{"id":"a","name":"A"}"#.utf8))
        let playlistFull = try JSONDecoder().decode(NavidromePlaylist.self, from: Data(#"{"id":"p","name":"Mix","songCount":2,"owner":"DJ","readonly":true}"#.utf8))
        let playlistEmpty = try JSONDecoder().decode(NavidromePlaylist.self, from: Data(#"{"id":"p","name":"Mix","owner":""}"#.utf8))

        #expect(artist.name == "2")
        #expect(artist.albumCount == 4)
        #expect(artist.subtitle == "4 albums")
        #expect(noCount.subtitle == "")
        #expect(playlistFull.subtitle == "DJ - 2 songs")
        #expect(playlistFull.isReadOnly)
        #expect(playlistEmpty.subtitle == "")
        #expect(!playlistEmpty.isReadOnly)
        #expect(NavidromeArtist(song: makeSong(artist: nil)) == nil)
        #expect(NavidromeArtist(song: makeSong(artist: "")) == nil)
        #expect(NavidromeArtist(song: makeSong(artistId: nil)) == nil)

        let lyrics = try JSONDecoder().decode(SongLyrics.self, from: Data(#"{"displayArtist":" A ","displayTitle":"T","lang":" en ","offset":"25","synced":true,"line":{"start":"50","value":"line"}}"#.utf8))
        let defaults = try JSONDecoder().decode(SongLyrics.self, from: Data(#"{"lang":"   ","line":[{"start":{},"value":4}]}"#.utf8))
        #expect(lyrics.id == " en | A |T|synced")
        #expect(lyrics.displayLanguage == "EN")
        #expect(lyrics.offset == 25)
        #expect(lyrics.lines.first?.id == "50|line")
        #expect(defaults.displayLanguage == nil)
        #expect(defaults.synced == false)
        #expect(defaults.lines.first?.id == "-1|")
    }

    @Test(arguments: ["xxx", "XXX", "und", "UND", "", " \n"])
    func unspecifiedLanguageHasNoLabel(_ language: String) throws {
        let data = try JSONSerialization.data(withJSONObject: ["lang": language])
        #expect(try JSONDecoder().decode(SongLyrics.self, from: data).displayLanguage == nil)
    }

    @Test func syncedLyricsConvertLineTimestampsToPlaybackTimes() throws {
        let positiveOffset = try JSONDecoder().decode(
            SongLyrics.self,
            from: Data(#"{"offset":250,"synced":true,"line":[{"start":100,"value":"Before start"},{"start":1250,"value":"Timed"},{"value":"Missing"}]}"#.utf8)
        )
        let negativeOffset = try JSONDecoder().decode(
            SongLyrics.self,
            from: Data(#"{"offset":-500,"synced":true,"line":{"start":1000,"value":"Delayed"}}"#.utf8)
        )
        let missingOffset = try JSONDecoder().decode(
            SongLyrics.self,
            from: Data(#"{"synced":true,"line":{"start":1000,"value":"No offset"}}"#.utf8)
        )
        let plainLyrics = try JSONDecoder().decode(
            SongLyrics.self,
            from: Data(#"{"synced":false,"line":{"start":1000,"value":"Plain"}}"#.utf8)
        )

        #expect(positiveOffset.playbackTime(for: positiveOffset.lines[0]) == 0)
        #expect(positiveOffset.playbackTime(for: positiveOffset.lines[1]) == 1)
        #expect(positiveOffset.playbackTime(for: positiveOffset.lines[2]) == nil)
        #expect(positiveOffset.lineIndex(at: 0) == 0)
        #expect(positiveOffset.lineIndex(at: 1) == 1)
        #expect(negativeOffset.playbackTime(for: negativeOffset.lines[0]) == 1.5)
        #expect(missingOffset.playbackTime(for: missingOffset.lines[0]) == 1)
        #expect(plainLyrics.playbackTime(for: plainLyrics.lines[0]) == nil)
        #expect(plainLyrics.lineIndex(at: 1) == nil)
    }

    @Test func missingRequiredFlexibleStringThrows() {
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(NavidromeArtist.self, from: Data(#"{"name":"Artist"}"#.utf8))
        }
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(NavidromeArtist.self, from: Data(#"{"id":{},"name":"Artist"}"#.utf8))
        }
    }

    @Test func librarySectionsExposeStableSymbols() {
        let expected: [LibrarySection: String] = [
            .home: "house", .search: "magnifyingglass", .random: "shuffle", .albums: "rectangle.stack",
            .artists: "music.mic", .genres: "guitars", .playlists: "music.note.list", .favorites: "heart",
            .recent: "clock"
        ]
        #expect(LibrarySection.allCases.count == expected.count)
        for section in LibrarySection.allCases {
            #expect(section.id == section.rawValue)
            #expect(section.systemImage == expected[section])
        }
    }
}
