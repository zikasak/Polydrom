import Foundation
import Testing
@testable import PolyDrom

@Suite(.serialized)
@MainActor
struct AppViewModelTests {
    @Test func disconnectedActionsReturnUsefulMessagesAndIgnoreUnavailableWork() async {
        let (viewModel, _, _) = makeViewModel()
        #expect(!viewModel.isConnected)
        #expect(viewModel.selectedSection == .home)
        #expect(viewModel.serverKey == nil)

        await viewModel.search()
        #expect(viewModel.statusMessage == "Select a library first.")
        await viewModel.loadLyrics(for: makeSong())
        #expect(viewModel.currentLyrics == nil)
        #expect(viewModel.lyricsMessage == "Connect to a server to load lyrics.")

        await viewModel.refreshSelectedSection(force: true)
        await viewModel.loadRandomSongs()
        await viewModel.loadHome()
        await viewModel.playRandomSongs(count: 10)
        await viewModel.loadAlbums()
        await viewModel.loadArtists()
        await viewModel.loadPlaylists()
        #expect(viewModel.randomSongs.isEmpty)

        viewModel.playNext([])
        viewModel.addToQueue([])
        viewModel.playPreviousTrack()
        viewModel.playNextTrack()
        #expect(!viewModel.canPlayPreviousTrack())
        #expect(!viewModel.canPlayNextTrack())
        #expect(viewModel.coverArtResource(for: makeSong()) == nil)
        #expect(viewModel.coverArtResource(for: try! JSONDecoder().decode(NavidromeAlbum.self, from: Data(#"{"id":"a","name":"A"}"#.utf8))) == nil)
    }

    @Test func invalidClientFactoryAndFailedPingCoverConnectionFailures() async throws {
        let store = LibraryStore(persistence: PersistenceController(inMemory: true), keychain: MemoryCredentialStore())
        let invalid = AppViewModel(store: store, audioPlayer: AudioPlayer(), clientFactory: { _ in nil })
        await invalid.connect(makeProfile())
        #expect(invalid.statusMessage == "Enter a valid server address.")

        let failedSession = StubURLProtocol.session { _ in
            envelope(#"{"status":"failed","error":{"message":"Bad login"}}"#)
        }
        let (failed, _, _) = makeViewModel(session: failedSession)
        await failed.connect(makeProfile())
        #expect(!failed.isConnected)
        #expect(failed.statusMessage == "Bad login")
        #expect(!failed.isBusy)
    }

    @Test func connectionLoadingSearchDetailsLyricsFavoritesAndDeletionWorkTogether() async throws {
        let lock = NSLock()
        nonisolated(unsafe) var starredSongIDs: Set<String> = ["favorite-song"]
        nonisolated(unsafe) var starredAlbumIDs: Set<String> = ["favorite-album"]
        nonisolated(unsafe) var starredArtistIDs: Set<String> = ["favorite-artist"]
        let handler: StubURLProtocol.Handler = { request in
            let method = apiMethod(in: request)
            if method == "getCoverArt" {
                return StubURLProtocol.Response(headers: ["Content-Type": "image/png"], data: onePixelPNG)
            }
            if method == "star" || method == "unstar" {
                let id = queryValue("id", in: request) ?? ""
                lock.lock()
                if id.contains("album") {
                    if method == "star" { starredAlbumIDs.insert(id) } else { starredAlbumIDs.remove(id) }
                } else if id.contains("artist") {
                    if method == "star" { starredArtistIDs.insert(id) } else { starredArtistIDs.remove(id) }
                } else {
                    if method == "star" { starredSongIDs.insert(id) } else { starredSongIDs.remove(id) }
                }
                lock.unlock()
                return envelope(#"{"status":"ok"}"#)
            }
            if method == "getStarred2" {
                lock.lock()
                let songs = starredSongIDs.sorted().map { #"{"id":"\#($0)","title":"\#($0)"}"# }.joined(separator: ",")
                let albums = starredAlbumIDs.sorted().map { #"{"id":"\#($0)","name":"\#($0)"}"# }.joined(separator: ",")
                let artists = starredArtistIDs.sorted().map { #"{"id":"\#($0)","name":"\#($0)","albumCount":1}"# }.joined(separator: ",")
                lock.unlock()
                return envelope(#"{"status":"ok","starred2":{"artist":[\#(artists)],"album":[\#(albums)],"song":[\#(songs)]}}"#)
            }

            switch method {
            case "ping":
                return envelope(#"{"status":"ok"}"#)
            case "getScanStatus":
                return envelope(#"{"status":"ok","scanStatus":{"scanning":false,"lastScan":"scan-1"}}"#)
            case "getRandomSongs":
                return envelope(#"{"status":"ok","randomSongs":{"song":[{"id":"random","title":"Random","albumId":"album"}]}}"#)
            case "search3":
                if queryValue("artistCount", in: request) != "0" {
                    return envelope(#"{"status":"ok","searchResult3":{"artist":[{"id":"hidden","name":"Hidden","albumCount":0},{"id":"artist","name":"Artist","albumCount":2}]}}"#)
                }
                if queryValue("albumCount", in: request) != "0" {
                    return envelope(#"{"status":"ok","searchResult3":{"album":[{"id":"album","name":"Album","artist":"Artist","artistId":"artist","songCount":2,"created":"2026-07-30T10:00:00Z","played":"2026-07-30T11:00:00Z"}]}}"#)
                }
                return envelope(#"{"status":"ok","searchResult3":{"song":[{"id":"random","title":"Random"},{"id":"search","title":"Search query"},{"id":"album-song","title":"Album Song","albumId":"album","artistId":"artist"}]}}"#)
            case "getAlbumList2":
                return envelope(#"{"status":"ok","albumList2":{"album":[{"id":"album","name":"Album","artist":"Artist","artistId":"artist","songCount":1}]}}"#)
            case "getPlaylists":
                return envelope(#"{"status":"ok","playlists":{"playlist":[{"id":"playlist","name":"Playlist","songCount":1,"changed":"2026-07-30T12:00:00Z"}]}}"#)
            case "getArtist":
                return envelope(#"{"status":"ok","artist":{"album":[{"id":"album","name":"Album","artistId":"artist"}]}}"#)
            case "getAlbum":
                return envelope(#"{"status":"ok","album":{"song":[{"id":"album-song","title":"Album Song","albumId":"album","artistId":"artist"}]}}"#)
            case "getPlaylist":
                return envelope(#"{"status":"ok","playlist":{"entry":[{"id":"playlist-song","title":"Playlist Song"}]}}"#)
            case "getLyricsBySongId":
                return envelope(#"{"status":"ok","lyricsList":{"structuredLyrics":[{"lang":"en","synced":false,"line":{"value":"Plain"}},{"lang":"en","synced":true,"line":{"start":0,"value":"Timed"}}]}}"#)
            case "getSong":
                return envelope(#"{"status":"ok","song":{"id":"random","title":"Hydrated Random","duration":10}}"#)
            default:
                return StubURLProtocol.Response(statusCode: 404, json: "{}")
            }
        }

        let (viewModel, store, _) = makeViewModel(
            session: StubURLProtocol.session(handler: handler)
        )
        let profile = try store.saveServer(address: "https://music.example.com", username: "user", password: "pw")
        viewModel.loadServers()
        #expect(viewModel.serverAddress == profile.address)
        #expect(viewModel.username == profile.username)
        #expect(viewModel.password == "pw")

        await viewModel.connectToLatestServer()
        #expect(viewModel.isConnected)
        #expect(viewModel.activeServer?.id == profile.id)
        #expect(viewModel.recentlyAddedAlbums.map(\.id) == ["album"])
        #expect(viewModel.recentlyPlayedAlbums.map(\.id) == ["album"])
        #expect(Set(viewModel.homeRandomAlbums.map(\.id)) == ["album", "favorite-album"])
        #expect(Set(viewModel.featuredAlbums.map(\.id)) == ["album", "favorite-album"])
        #expect(viewModel.favoriteSongs.map(\.id) == ["favorite-song"])
        await viewModel.connectToLatestServer()

        await viewModel.playRandomSongs(count: 10)
        #expect(await eventually { viewModel.audioPlayer.currentSong != nil })
        #expect(!viewModel.playbackQueue.isEmpty)
        #expect(viewModel.audioPlayer.currentSong?.id == viewModel.playbackQueue.first?.song.id)

        viewModel.searchText = "  "
        await viewModel.search()
        #expect(viewModel.searchResults.isEmpty)
        #expect(viewModel.statusMessage == "Enter a search term.")
        viewModel.searchText = " query "
        await viewModel.search()
        #expect(viewModel.searchResults.map(\.id) == ["search"])

        viewModel.selectedSection = .albums
        await viewModel.refreshSelectedSection(force: true)
        viewModel.selectedSection = .artists
        await viewModel.refreshSelectedSection(force: true)
        viewModel.selectedSection = .playlists
        await viewModel.refreshSelectedSection(force: true)
        viewModel.selectedSection = .favorites
        await viewModel.refreshSelectedSection(force: true)
        viewModel.selectedSection = .recent
        await viewModel.refreshSelectedSection(force: true)
        viewModel.selectedSection = .random
        await viewModel.refreshSelectedSection(force: true)
        #expect(viewModel.albums.map(\.id) == ["album", "favorite-album"])
        #expect(viewModel.artists.map(\.id) == ["artist", "favorite-artist"])
        #expect(viewModel.playlists.map(\.id) == ["playlist"])

        let artist = try #require(viewModel.artists.first)
        await viewModel.loadAlbums(for: artist)
        await viewModel.loadAlbums(for: artist)
        let album = try #require(viewModel.artistAlbums.first)
        await viewModel.loadSongs(for: album)
        await viewModel.loadSongs(for: album)
        let playlist = try #require(viewModel.playlists.first)
        await viewModel.loadSongs(for: playlist)
        await viewModel.loadSongs(for: playlist)
        #expect(viewModel.albumSongs.map(\.id) == ["album-song"])
        #expect(viewModel.playlistSongs.map(\.id) == ["playlist-song"])

        let song = try #require(viewModel.albumSongs.first)
        await viewModel.loadLyrics(for: song)
        await viewModel.loadLyrics(for: song)
        #expect(viewModel.currentLyrics?.synced == true)
        #expect(viewModel.currentLyrics?.lines.first?.value == "Timed")
        #expect(viewModel.lyricsMessage == "")

        #expect(viewModel.coverArtResource(for: song)?.fallbackCacheKeys.count == 2)
        #expect(viewModel.coverArtResource(for: album, size: 512)?.fallbackCacheKeys.isEmpty == true)
        let remoteArtist = try JSONDecoder().decode(NavidromeArtist.self, from: Data(#"{"id":"remote-artist","name":"Remote","artistImageUrl":"https://images.example/artist.jpg"}"#.utf8))
        #expect(viewModel.coverArtResource(for: remoteArtist)?.url.host == "images.example")

        viewModel.toggleFavorite(song)
        #expect(await eventually { viewModel.statusMessage == "Added to favorites" })
        #expect(viewModel.isFavorite(song))
        viewModel.toggleFavorite(song)
        #expect(await eventually { viewModel.statusMessage == "Removed from favorites" })
        #expect(!viewModel.isFavorite(song))

        viewModel.toggleFavorite(album)
        #expect(await eventually { viewModel.statusMessage == "Added album to favorites" })
        #expect(viewModel.isFavorite(album))
        viewModel.toggleFavorite(album)
        #expect(await eventually { viewModel.statusMessage == "Removed album from favorites" })

        viewModel.toggleFavorite(artist)
        #expect(await eventually { viewModel.statusMessage == "Added artist to favorites" })
        #expect(viewModel.isFavorite(artist))
        viewModel.toggleFavorite(artist)
        #expect(await eventually { viewModel.statusMessage == "Removed artist from favorites" })

        let currentEntry = PlaybackQueueEntry(song: song)
        viewModel.playbackQueue = [currentEntry]
        viewModel.currentPlaybackQueueEntryID = currentEntry.id
        viewModel.audioPlayer.currentSong = song
        viewModel.playNext([makeSong(id: "next"), makeSong(id: "later")])
        viewModel.addToQueue([makeSong(id: "end")])
        #expect(viewModel.playbackQueue.map(\.song.id) == ["album-song", "next", "later", "end"])
        #expect(viewModel.statusMessage == "Added to queue")

        viewModel.deleteServer(profile)
        #expect(!viewModel.isConnected)
        #expect(viewModel.servers.isEmpty)
        #expect(viewModel.audioPlayer.currentSong == nil)
    }

    @Test func navigationPrefersEachLoadedSourceThenFallsBack() throws {
        let (viewModel, _, _) = makeViewModel()
        let song = makeSong(albumId: "album", artistId: "artist")
        let richAlbum = try JSONDecoder().decode(NavidromeAlbum.self, from: Data(#"{"id":"album","name":"Rich","songCount":9}"#.utf8))
        let richArtist = try JSONDecoder().decode(NavidromeArtist.self, from: Data(#"{"id":"artist","name":"Rich Artist","albumCount":9}"#.utf8))

        viewModel.artistAlbums = [richAlbum]
        #expect(viewModel.albumForNavigation(from: song)?.songCount == 9)
        viewModel.artistAlbums = []
        viewModel.albums = [richAlbum]
        #expect(viewModel.albumForNavigation(from: song)?.name == "Rich")
        viewModel.albums = []
        viewModel.favoriteAlbums = [richAlbum]
        #expect(viewModel.albumForNavigation(from: song)?.name == "Rich")
        viewModel.favoriteAlbums = []
        #expect(viewModel.albumForNavigation(from: song)?.name == "Album")
        #expect(viewModel.albumForNavigation(from: makeSong(album: nil)) == nil)

        viewModel.artists = [richArtist]
        #expect(viewModel.artistForNavigation(from: song)?.albumCount == 9)
        viewModel.artists = []
        viewModel.favoriteArtists = [richArtist]
        #expect(viewModel.artistForNavigation(from: song)?.name == "Rich Artist")
        viewModel.favoriteArtists = []
        #expect(viewModel.artistForNavigation(from: song)?.name == "Artist")
        #expect(viewModel.artistForNavigation(from: makeSong(artist: nil)) == nil)
    }

    @Test func cachedLibraryLoadsBeforeFailedNetworkingAndRemainsBrowsableOffline() async throws {
        let handler: StubURLProtocol.Handler = { _ in
            envelope(#"{"status":"failed","error":{"message":"Server unavailable"}}"#)
        }
        let (viewModel, store, _) = makeViewModel(
            session: StubURLProtocol.session(handler: handler)
        )
        let profile = makeProfile()
        let artist = NavidromeArtist(id: "artist", name: "Cached Artist", albumCount: 1)
        let album = NavidromeAlbum(id: "album", name: "Cached Album", artist: artist.name, artistId: artist.id)
        let song = NavidromeSong(
            id: "song",
            title: "Cached Song",
            artist: artist.name,
            album: album.name,
            albumId: album.id,
            artistId: artist.id,
            track: 1
        )
        try await store.apply(
            LibrarySnapshot(
                artists: [artist],
                albums: [album],
                songs: [song],
                playlists: [],
                favorites: FavoriteMetadata(songIDs: [song.id]),
                catalogToken: "scan",
                checkedAt: Date()
            ),
            serverKey: profile.serverKey
        )

        await viewModel.connect(profile)

        #expect(!viewModel.isOnline)
        #expect(viewModel.hasCachedLibrary)
        #expect(viewModel.canBrowseLibrary)
        #expect(viewModel.albums.map(\.id) == [album.id])
        #expect(viewModel.artists.map(\.id) == [artist.id])
        #expect(viewModel.favoriteSongs.map(\.id) == [song.id])

        viewModel.searchText = "cached"
        await viewModel.search()
        #expect(viewModel.searchResults.map(\.id) == [song.id])
        await viewModel.loadSongs(for: album)
        #expect(viewModel.albumSongs.map(\.id) == [song.id])

        viewModel.toggleFavorite(song)
        #expect(viewModel.isFavorite(song))
        #expect(viewModel.statusMessage == "Connect to the server to update favorites.")
    }
}
