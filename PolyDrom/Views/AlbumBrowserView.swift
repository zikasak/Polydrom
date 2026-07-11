//
//  AlbumBrowserView.swift
//  PolyDrom
//
//  Created by zikasak on 07/07/2026.
//

import SwiftUI

struct AlbumBrowserView: View {
    @ObservedObject var viewModel: AppViewModel
    let albums: [NavidromeAlbum]

    var body: some View {
        AlbumBrowserGrid(
            albums: albums,
            selectedAlbumID: viewModel.selectedAlbum?.id,
            serverKey: viewModel.serverKey,
            coverArtResource: { album in
                viewModel.coverArtResource(for: album, size: 220)
            }
        )
        .equatable()
    }
}

private struct AlbumBrowserGrid: View, Equatable {
    let albums: [NavidromeAlbum]
    let selectedAlbumID: String?
    let serverKey: String?
    let coverArtResource: (NavidromeAlbum) -> CoverArtResource?

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.albums == rhs.albums
            && lhs.selectedAlbumID == rhs.selectedAlbumID
            && lhs.serverKey == rhs.serverKey
    }

    var body: some View {
        LazyLibraryCardGrid(albums, minimumCardWidth: 150) { album in
            NavigationLink(value: LibraryRoute.album(album)) {
                AlbumCardView(
                    album: album,
                    coverArtResource: coverArtResource(album),
                    isSelected: selectedAlbumID == album.id
                )
            }
            .buttonStyle(.plain)
        }
    }
}

struct AlbumDetailView: View {
    @ObservedObject var viewModel: AppViewModel
    let album: NavidromeAlbum

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(album.name)
                    .font(.title2)
                    .fontWeight(.semibold)

                Text(album.subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            SongListView(
                title: "Songs",
                songs: viewModel.selectedAlbum == album ? viewModel.albumSongs : [],
                viewModel: viewModel,
                emptyMessage: viewModel.isBusy ? "Loading songs..." : "No songs for this album."
            )
        }
        .padding(18)
        .navigationTitle(album.name)
        .task(id: album.id) {
            await viewModel.loadSongs(for: album)
        }
    }
}

private struct AlbumCardView: View {
    let album: NavidromeAlbum
    let coverArtResource: CoverArtResource?
    let isSelected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            CoverArtView(resource: coverArtResource, size: 128)
                .frame(maxWidth: .infinity)

            VStack(alignment: .leading, spacing: 3) {
                Text(album.name)
                    .font(.headline)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)

                Text(album.subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background {
            RoundedRectangle(cornerRadius: 8)
                .fill(isSelected ? Color.accentColor.opacity(0.16) : Color.secondary.opacity(0.08))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(isSelected ? Color.accentColor.opacity(0.65) : Color.secondary.opacity(0.14), lineWidth: 1)
        }
        .contentShape(RoundedRectangle(cornerRadius: 8))
    }
}
