//
//  LibraryContextMenus.swift
//  PolyDrom
//

import SwiftUI

/// What an album or an artist can be asked to do from a menu.
struct LibraryItemActions<Item> {
    let play: @MainActor (Item) -> Void
    let playNext: @MainActor (Item) -> Void
    let addToQueue: @MainActor (Item) -> Void
    let toggleFavorite: @MainActor (Item) -> Void
}

extension LibraryItemActions where Item == NavidromeAlbum {
    @MainActor
    init(_ viewModel: AppCoordinator) {
        self.init(
            play: viewModel.play,
            playNext: viewModel.playNext,
            addToQueue: viewModel.addToQueue,
            toggleFavorite: viewModel.toggleFavorite
        )
    }
}

extension LibraryItemActions where Item == NavidromeArtist {
    @MainActor
    init(_ viewModel: AppCoordinator) {
        self.init(
            play: viewModel.play,
            playNext: viewModel.playNext,
            addToQueue: viewModel.addToQueue,
            toggleFavorite: viewModel.toggleFavorite
        )
    }
}

/// "Play", "Play Next", and "Add to Queue". `play` is left out where the item
/// is already playing.
struct QueueMenuButtons: View {
    let isOnline: Bool
    var play: (() -> Void)?
    let playNext: () -> Void
    let addToQueue: () -> Void

    var body: some View {
        if let play {
            Button(action: play) {
                Label("Play", systemImage: "play.fill")
            }
            .disabled(!isOnline)
        }

        Button(action: playNext) {
            Label("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward")
        }

        Button(action: addToQueue) {
            Label("Add to Queue", systemImage: "text.badge.plus")
        }
    }
}

struct FavoriteMenuButton: View {
    let isFavorite: Bool
    let isOnline: Bool
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            Label(
                isFavorite ? "Remove from Favorites" : "Add to Favorites",
                systemImage: isFavorite ? "heart.slash" : "heart"
            )
        }
        .disabled(!isOnline)
    }
}

/// The menu shared by albums and artists. It takes plain values rather than
/// observing the coordinator, so the grids can build one per card cheaply.
struct LibraryItemContextMenu<Item>: View {
    let item: Item
    let isFavorite: Bool
    let isOnline: Bool
    let actions: LibraryItemActions<Item>
    let open: () -> Void
    private let openTitle: String
    private let openSystemImage: String
    private let spotifyLink: OpenInSpotifyLink

    var body: some View {
        QueueMenuButtons(
            isOnline: isOnline,
            play: { actions.play(item) },
            playNext: { actions.playNext(item) },
            addToQueue: { actions.addToQueue(item) }
        )

        FavoriteMenuButton(isFavorite: isFavorite, isOnline: isOnline) {
            actions.toggleFavorite(item)
        }

        Divider()

        Button(action: open) {
            Label(openTitle, systemImage: openSystemImage)
        }

        spotifyLink
    }
}

extension LibraryItemContextMenu where Item == NavidromeAlbum {
    init(
        album: NavidromeAlbum,
        isFavorite: Bool,
        isOnline: Bool,
        actions: LibraryItemActions<NavidromeAlbum>,
        open: @escaping () -> Void
    ) {
        item = album
        self.isFavorite = isFavorite
        self.isOnline = isOnline
        self.actions = actions
        self.open = open
        openTitle = "Open Album"
        openSystemImage = "rectangle.stack"
        spotifyLink = OpenInSpotifyLink(album: album)
    }
}

extension LibraryItemContextMenu where Item == NavidromeArtist {
    init(
        artist: NavidromeArtist,
        isFavorite: Bool,
        isOnline: Bool,
        actions: LibraryItemActions<NavidromeArtist>,
        open: @escaping () -> Void
    ) {
        item = artist
        self.isFavorite = isFavorite
        self.isOnline = isOnline
        self.actions = actions
        self.open = open
        openTitle = "Open Artist"
        openSystemImage = "music.mic"
        spotifyLink = OpenInSpotifyLink(artist: artist)
    }
}

/// An album's menu wherever a view already follows the coordinator.
struct AlbumContextMenu: View {
    @ObservedObject var viewModel: AppCoordinator
    let album: NavidromeAlbum
    let open: () -> Void

    var body: some View {
        LibraryItemContextMenu(
            album: album,
            isFavorite: viewModel.isFavorite(album),
            isOnline: viewModel.isOnline,
            actions: LibraryItemActions(viewModel),
            open: open
        )
    }
}

/// An artist's menu wherever a view already follows the coordinator.
struct ArtistContextMenu: View {
    @ObservedObject var viewModel: AppCoordinator
    let artist: NavidromeArtist
    let open: () -> Void

    var body: some View {
        LibraryItemContextMenu(
            artist: artist,
            isFavorite: viewModel.isFavorite(artist),
            isOnline: viewModel.isOnline,
            actions: LibraryItemActions(viewModel),
            open: open
        )
    }
}

/// The menu of the song that is playing, which therefore has no "Play".
struct PlayerSongContextMenu: View {
    @ObservedObject var viewModel: AppCoordinator
    let song: NavidromeSong

    var body: some View {
        QueueMenuButtons(
            isOnline: viewModel.isOnline,
            playNext: { viewModel.playNext([song]) },
            addToQueue: { viewModel.addToQueue([song]) }
        )

        Divider()

        FavoriteMenuButton(isFavorite: viewModel.isFavorite(song), isOnline: viewModel.isOnline) {
            viewModel.toggleFavorite(song)
        }

        AddToPlaylistMenu(viewModel: viewModel, songs: [song])
    }
}

struct AddToPlaylistMenu: View {
    @ObservedObject var viewModel: AppCoordinator
    let songs: [NavidromeSong]
    var onSuccess: @MainActor () -> Void = {}

    var body: some View {
        Menu {
            ForEach(viewModel.editablePlaylists) { playlist in
                Button(playlist.name) {
                    Task {
                        if await viewModel.addSongs(songs, to: playlist) {
                            onSuccess()
                        }
                    }
                }
            }

            if !viewModel.editablePlaylists.isEmpty {
                Divider()
            }

            Button {
                viewModel.requestPlaylistCreation(with: songs, onSuccess: onSuccess)
            } label: {
                Label("New Playlist…", systemImage: "plus")
            }
        } label: {
            Label("Add to Playlist", systemImage: "text.badge.plus")
        }
        .disabled(songs.isEmpty || !viewModel.canCreatePlaylist)
    }
}
