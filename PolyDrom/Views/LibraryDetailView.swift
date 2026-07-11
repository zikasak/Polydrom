//
//  LibraryDetailView.swift
//  PolyDrom
//
//  Created by zikasak on 07/07/2026.
//

import SwiftUI

struct LibraryDetailView: View {
    @ObservedObject var viewModel: AppViewModel

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
            SearchView(viewModel: viewModel)
        case .random:
            SongListView(
                title: "Random songs",
                songs: viewModel.randomSongs,
                viewModel: viewModel,
                emptyMessage: "No random songs loaded."
            )
        case .albums:
            AlbumBrowserView(viewModel: viewModel, albums: viewModel.albums)
        case .artists:
            ArtistBrowserView(viewModel: viewModel)
        case .playlists:
            PlaylistBrowserView(viewModel: viewModel)
        case .favorites:
            SongListView(
                title: "Favorite songs",
                songs: viewModel.favoriteSongs,
                viewModel: viewModel,
                emptyMessage: "No favorites yet."
            )
        case .recent:
            SongListView(
                title: "Recently played",
                songs: viewModel.recentSongs,
                viewModel: viewModel,
                emptyMessage: "No playback history yet."
            )
        }
    }
}

enum LibraryRoute: Hashable {
    case album(NavidromeAlbum)
    case artist(NavidromeArtist)
    case playlist(NavidromePlaylist)
}
