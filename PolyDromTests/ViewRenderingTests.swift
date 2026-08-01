import AppKit
import SwiftUI
import Testing
@testable import PolyDrom

@Suite(.serialized)
@MainActor
struct ViewRenderingTests {
    @Test func libraryViewsRenderEmptyAndPopulatedStates() async throws {
        let (viewModel, _, _) = makeViewModel()
        let song = makeSong(albumId: nil, artistId: nil)
        let album = try JSONDecoder().decode(NavidromeAlbum.self, from: Data(#"{"id":"album","name":"Album","artist":"Artist","songCount":1,"year":2025}"#.utf8))
        let artist = try JSONDecoder().decode(NavidromeArtist.self, from: Data(#"{"id":"artist","name":"Artist","albumCount":1}"#.utf8))
        let playlist = try JSONDecoder().decode(NavidromePlaylist.self, from: Data(#"{"id":"playlist","name":"Playlist","songCount":1,"owner":"Owner"}"#.utf8))
        viewModel.searchResults = [song]
        viewModel.randomSongs = [song]
        viewModel.recentSongs = [song]
        viewModel.albums = [album]
        viewModel.recentlyAddedAlbums = [album]
        viewModel.recentlyPlayedAlbums = [album]
        viewModel.homeRandomAlbums = [album]
        viewModel.featuredAlbums = [album]
        viewModel.artists = [artist]
        viewModel.playlists = [playlist]
        viewModel.favoriteSongs = [song]
        viewModel.favoriteAlbums = [album]
        viewModel.favoriteArtists = [artist]
        viewModel.favoriteIDs = [song.id]
        viewModel.favoriteAlbumIDs = [album.id]
        viewModel.favoriteArtistIDs = [artist.id]

        await render(SongListView(title: "Empty", songs: [], viewModel: viewModel, emptyMessage: "Empty", openRoute: { _ in }))
        await render(SongListView(title: "Songs", songs: [song], viewModel: viewModel, emptyMessage: "Empty", openRoute: { _ in }))
        await render(SongRowView(song: song, queue: [song], queueIndex: 0, viewModel: viewModel, audioPlayer: viewModel.audioPlayer, openRoute: { _ in }, currentAlbumID: nil))
        viewModel.audioPlayer.currentSong = song
        await render(SongRowView(song: song, queue: [song], queueIndex: 0, viewModel: viewModel, audioPlayer: viewModel.audioPlayer, openRoute: { _ in }, currentAlbumID: nil))
        await render(SearchView(viewModel: viewModel, openRoute: { _ in }))
        await render(HomeView(viewModel: viewModel, openAlbum: { _ in }))
        await render(AlbumBrowserView(viewModel: viewModel, albums: [album]))
        await render(ArtistBrowserView(viewModel: viewModel))
        await render(FavoriteArtistBrowserView(viewModel: viewModel))
        await render(PlaylistBrowserView(viewModel: viewModel))
        await render(
            PlaylistCreationSheet(
                viewModel: viewModel,
                request: PlaylistCreationRequest(songs: [song], onSuccess: {})
            ),
            size: CGSize(width: 460, height: 240)
        )
        await render(AlbumDetailView(viewModel: viewModel, album: album, openRoute: { _ in }))
        await render(ArtistDetailView(viewModel: viewModel, artist: artist, openAlbum: { _ in }))
        await render(OpenInSpotifyLink(album: album))
        await render(OpenInSpotifyLink(album: album, presentation: .iconOnly))
        await render(OpenInSpotifyLink(artist: artist))
        await render(PlaylistDetailView(viewModel: viewModel, playlist: playlist, openRoute: { _ in }))
        let readOnlyPlaylist = NavidromePlaylist(
            id: "smart",
            name: "Smart Playlist",
            songCount: 1,
            owner: "Owner",
            isReadOnly: true
        )
        await render(
            PlaylistDetailView(
                viewModel: viewModel,
                playlist: readOnlyPlaylist,
                openRoute: { _ in }
            )
        )
        await render(CoverArtView(resource: nil, size: 48))
    }

    @Test func connectedLibraryDetailRendersEverySection() async throws {
        let handler: StubURLProtocol.Handler = { request in
            if apiMethod(in: request) == "getCoverArt" {
                return StubURLProtocol.Response(headers: ["Content-Type": "image/png"], data: onePixelPNG)
            }
            switch apiMethod(in: request) {
            case "ping": return envelope(#"{"status":"ok"}"#)
            case "getScanStatus": return envelope(#"{"status":"ok","scanStatus":{"scanning":false,"lastScan":"scan"}}"#)
            case "getStarred2": return envelope(#"{"status":"ok","starred2":{}}"#)
            case "getRandomSongs": return envelope(#"{"status":"ok","randomSongs":{"song":[]}}"#)
            case "getPlaylists": return envelope(#"{"status":"ok","playlists":{"playlist":[]}}"#)
            case "search3": return envelope(#"{"status":"ok","searchResult3":{}}"#)
            default: return envelope(#"{"status":"ok"}"#)
            }
        }
        let (viewModel, _, _) = makeViewModel(session: StubURLProtocol.session(handler: handler))
        let server = makeProfile()
        await viewModel.connect(server)
        viewModel.servers = [
            server,
            makeProfile(name: "Backup Server", address: "https://backup.example.com")
        ]
        let song = makeSong(albumId: nil, artistId: nil)
        let album = try JSONDecoder().decode(NavidromeAlbum.self, from: Data(#"{"id":"album","name":"Album"}"#.utf8))
        let artist = try JSONDecoder().decode(NavidromeArtist.self, from: Data(#"{"id":"artist","name":"Artist","albumCount":1}"#.utf8))
        let playlist = try JSONDecoder().decode(NavidromePlaylist.self, from: Data(#"{"id":"playlist","name":"Playlist"}"#.utf8))
        viewModel.searchResults = [song]
        viewModel.randomSongs = [song]
        viewModel.recentSongs = [song]
        viewModel.albums = [album]
        viewModel.artists = [artist]
        viewModel.playlists = [playlist]
        viewModel.favoriteSongs = [song]

        for section in LibrarySection.allCases {
            viewModel.selectedSection = section
            await render(LibraryDetailView(viewModel: viewModel, openRoute: { _ in }))
        }
        await render(ContentView(viewModel: viewModel), size: CGSize(width: 1200, height: 800))
        await render(SidebarView(viewModel: viewModel, onSectionSelected: {}), size: CGSize(width: 260, height: 700))
    }

    @Test func settingsRendersEmptySavedConnectedBusyAndErrorStates() async {
        let (viewModel, _, _) = makeViewModel()
        await render(SettingsView(viewModel: viewModel), size: CGSize(width: 540, height: 640))

        let server = makeProfile()
        viewModel.servers = [server]
        await render(SettingsView(viewModel: viewModel), size: CGSize(width: 540, height: 640))

        viewModel.activeServer = server
        viewModel.isOnline = true
        viewModel.statusMessage = "Connected"
        viewModel.metadataRefreshInterval = .oneHour
        await render(SettingsView(viewModel: viewModel), size: CGSize(width: 540, height: 640))

        viewModel.isBusy = true
        await render(SettingsView(viewModel: viewModel), size: CGSize(width: 540, height: 640))

        viewModel.isBusy = false
        viewModel.isOnline = false
        viewModel.statusMessage = "Connection failed"
        await render(SettingsView(viewModel: viewModel), size: CGSize(width: 540, height: 640))
    }

    @Test func playerViewsRenderPlaybackQueueAndEveryLyricsState() async throws {
        let (viewModel, _, _) = makeViewModel()
        let song = makeSong(albumId: nil, artistId: nil)
        let currentEntry = PlaybackQueueEntry(song: song)
        viewModel.playbackQueue = [
            currentEntry,
            PlaybackQueueEntry(song: makeSong(id: "second", artist: nil, album: nil, albumId: nil, artistId: nil))
        ]
        viewModel.currentPlaybackQueueEntryID = currentEntry.id
        viewModel.audioPlayer.currentSong = song
        viewModel.audioPlayer.currentTime = 2
        viewModel.audioPlayer.duration = 10

        await render(PlayerBarView(viewModel: viewModel, onOpenFullPlayer: {}), size: CGSize(width: 900, height: 100))
        await render(FullPlayerView(viewModel: viewModel, onClose: {}), size: CGSize(width: 1100, height: 820))
        await render(FullPlayerView(viewModel: viewModel, onClose: {}), size: CGSize(width: 800, height: 650))
        await render(PlayerQueueView(viewModel: viewModel), size: CGSize(width: 360, height: 600))
        viewModel.playbackQueue = []
        await render(PlayerQueueView(viewModel: viewModel), size: CGSize(width: 360, height: 600))

        viewModel.isLoadingLyrics = true
        await render(PlayerLyricsView(viewModel: viewModel), size: CGSize(width: 360, height: 600))
        viewModel.isLoadingLyrics = false
        viewModel.currentLyrics = nil
        viewModel.lyricsMessage = "Unavailable"
        await render(PlayerLyricsView(viewModel: viewModel), size: CGSize(width: 360, height: 600))
        viewModel.currentLyrics = try JSONDecoder().decode(SongLyrics.self, from: Data(#"{"lang":"en","synced":true,"offset":10,"line":[{"start":0,"value":"First"},{"start":5000,"value":"Second"}]}"#.utf8))
        await render(PlayerLyricsView(viewModel: viewModel), size: CGSize(width: 360, height: 600))

        #expect(PlayerDetailPanel.queue.title == "Queue")
        #expect(PlayerDetailPanel.queue.systemImage == "text.line.last.and.arrowtriangle.forward")
        #expect(PlayerDetailPanel.lyrics.title == "Lyrics")
        #expect(PlayerDetailPanel.lyrics.systemImage == "quote.bubble")
    }

    @Test func lazyContainersAndEnvironmentValuesBuild() async {
        let songs = [makeSong(albumId: nil, artistId: nil)]
        await render(LazyLibraryList(songs) { song in Text(song.title) })
        await render(LazyLibraryCardGrid(songs, minimumCardWidth: 100, spacing: 4) { song in Text(song.title) })
        var values = EnvironmentValues()
        #expect(values.libraryGridIsScrolling == false)
        values.libraryGridIsScrolling = true
        #expect(values.libraryGridIsScrolling == true)
    }

    private func render<V: View>(_ rootView: V, size: CGSize = CGSize(width: 800, height: 600)) async {
        let host = NSHostingView(rootView: rootView)
        host.frame = NSRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()
        host.displayIfNeeded()
        await Task.yield()
        host.layoutSubtreeIfNeeded()
        host.displayIfNeeded()
    }
}
