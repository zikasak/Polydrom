//
//  ArtistBrowserView.swift
//  PolyDrom
//
//  Created by zikasak on 07/07/2026.
//

import SwiftUI

struct ArtistBrowserView: View {
    @ObservedObject var viewModel: AppViewModel

    var body: some View {
        LazyLibraryCardGrid(viewModel.artists, minimumCardWidth: 140) { artist in
            NavigationLink(value: LibraryRoute.artist(artist)) {
                ArtistCardView(
                    artist: artist,
                    coverArtResource: viewModel.coverArtResource(for: artist, size: 220),
                    isSelected: viewModel.selectedArtist == artist
                )
            }
            .buttonStyle(.plain)
        }
    }
}

struct ArtistDetailView: View {
    @ObservedObject var viewModel: AppViewModel
    let artist: NavidromeArtist

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(artist.name)
                    .font(.title2)
                    .fontWeight(.semibold)

                Text(artist.subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            if viewModel.selectedArtist == artist && !viewModel.artistAlbums.isEmpty {
                AlbumBrowserView(viewModel: viewModel, albums: viewModel.artistAlbums)
            } else {
                ContentUnavailableView(
                    viewModel.isBusy ? "Loading albums..." : "No albums for this artist.",
                    systemImage: "rectangle.stack"
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding(18)
        .navigationTitle(artist.name)
        .task(id: artist.id) {
            await viewModel.loadAlbums(for: artist)
        }
    }
}

private struct ArtistCardView: View {
    let artist: NavidromeArtist
    let coverArtResource: CoverArtResource?
    let isSelected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            CoverArtView(resource: coverArtResource, size: 128, fallbackSystemImage: "music.mic")
                .frame(maxWidth: .infinity)

            VStack(alignment: .leading, spacing: 3) {
                Text(artist.name)
                    .font(.headline)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)

                Text(artist.subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
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
