//
//  LibraryDetailView.swift
//  PolyDrom
//
//  Created by zikasak on 07/07/2026.
//

import SwiftUI

struct LibraryDetailView: View {
    @ObservedObject var viewModel: AppViewModel
    let openRoute: (LibraryRoute) -> Void

    var body: some View {
        if !viewModel.isConnected {
            disconnectedContent
        } else {
            connectedContent
        }
    }

    private var connectedContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            content
        }
        .padding(18)
    }

    private var disconnectedContent: some View {
        ContentUnavailableView(
            "Connect to Navidrome",
            systemImage: "music.note.house",
            description: Text("Enter a server address and credentials, or select a saved server from the sidebar.")
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        .padding(18)
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(viewModel.selectedSection.rawValue)
                    .font(.title2)
                    .fontWeight(.semibold)

                Text(viewModel.activeServer?.displayName ?? "Disconnected")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button {
                Task { await viewModel.refreshSelectedSection(force: true) }
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
                    .labelStyle(.iconOnly)
            }
            .disabled(!viewModel.isConnected || viewModel.isBusy)
            .help("Refresh")
        }
    }

    @ViewBuilder
    private var content: some View {
        switch viewModel.selectedSection {
        case .search:
            SearchView(viewModel: viewModel, openRoute: openRoute)
        case .random:
            SongListView(
                title: "Random songs",
                songs: viewModel.randomSongs,
                viewModel: viewModel,
                emptyMessage: "No random songs loaded.",
                openRoute: openRoute
            )
        case .albums:
            AlbumBrowserView(viewModel: viewModel, albums: viewModel.albums)
        case .artists:
            ArtistBrowserView(viewModel: viewModel)
        case .playlists:
            PlaylistBrowserView(viewModel: viewModel)
        case .favorites:
            FavoriteLibraryView(viewModel: viewModel, openRoute: openRoute)
        case .recent:
            SongListView(
                title: "Recently played",
                songs: viewModel.recentSongs,
                viewModel: viewModel,
                emptyMessage: "No playback history yet.",
                openRoute: openRoute
            )
        }
    }
}

private struct FavoriteLibraryView: View {
    @ObservedObject var viewModel: AppViewModel
    let openRoute: (LibraryRoute) -> Void
    @State private var selection: FavoriteContent = .songs

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("Favorite content", selection: $selection) {
                Label("Songs", systemImage: "music.note")
                    .tag(FavoriteContent.songs)
                Label("Albums", systemImage: "rectangle.stack")
                    .tag(FavoriteContent.albums)
                Label("Artists", systemImage: "music.mic")
                    .tag(FavoriteContent.artists)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()

            switch selection {
            case .artists:
                if viewModel.favoriteArtists.isEmpty {
                    ContentUnavailableView("No favorite artists yet.", systemImage: "music.mic")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    FavoriteArtistBrowserView(viewModel: viewModel)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            case .albums:
                if viewModel.favoriteAlbums.isEmpty {
                    ContentUnavailableView("No favorite albums yet.", systemImage: "rectangle.stack")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    AlbumBrowserView(viewModel: viewModel, albums: viewModel.favoriteAlbums)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            case .songs:
                if viewModel.favoriteSongs.isEmpty {
                    ContentUnavailableView("No favorite songs yet.", systemImage: "music.note")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    SongListView(
                        title: "Favorite songs",
                        songs: viewModel.favoriteSongs,
                        viewModel: viewModel,
                        emptyMessage: "No favorite songs yet.",
                        openRoute: openRoute
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear {
            selection = .songs
        }
    }

    private enum FavoriteContent: Hashable {
        case artists
        case albums
        case songs
    }
}

enum LibraryRoute: Hashable {
    case album(NavidromeAlbum)
    case artist(NavidromeArtist)
    case playlist(NavidromePlaylist)
}
