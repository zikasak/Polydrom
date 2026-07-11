//
//  PlaylistBrowserView.swift
//  PolyDrom
//
//  Created by zikasak on 07/07/2026.
//

import SwiftUI

struct PlaylistBrowserView: View {
    @ObservedObject var viewModel: AppViewModel

    var body: some View {
        LazyLibraryList(viewModel.playlists) { playlist in
            NavigationLink(value: LibraryRoute.playlist(playlist)) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(playlist.name)
                        .font(.headline)
                        .lineLimit(1)
                    Text(playlist.subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            .padding(.vertical, 4)
        }
    }
}

struct PlaylistDetailView: View {
    @ObservedObject var viewModel: AppViewModel
    let playlist: NavidromePlaylist

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(playlist.name)
                    .font(.title2)
                    .fontWeight(.semibold)

                Text(playlist.subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            SongListView(
                title: "Songs",
                songs: viewModel.selectedPlaylist == playlist ? viewModel.playlistSongs : [],
                viewModel: viewModel,
                emptyMessage: viewModel.isBusy ? "Loading songs..." : "No songs for this playlist."
            )
        }
        .padding(18)
        .navigationTitle(playlist.name)
        .task(id: playlist.id) {
            await viewModel.loadSongs(for: playlist)
        }
    }
}
