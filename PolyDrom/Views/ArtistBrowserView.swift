//
//  ArtistBrowserView.swift
//  PolyDrom
//
//  Created by zikasak on 07/07/2026.
//

import SwiftUI

struct ArtistBrowserView: View {
    @ObservedObject var viewModel: AppCoordinator
    let artists: [NavidromeArtist]

    var body: some View {
        ArtistBrowserGrid(
            artists: artists,
            selectedArtistID: viewModel.selectedArtist?.id,
            favoriteArtistIDs: viewModel.favoriteArtistIDs,
            serverKey: viewModel.serverKey,
            isOnline: viewModel.isOnline,
            coverArtResource: { viewModel.coverArtResource(for: $0, size: viewModel.gridCoverSize) },
            actions: LibraryItemActions(viewModel)
        )
        .equatable()
    }
}

/// Compared by the values it shows, so coordinator updates that do not affect
/// the grid leave it alone while it scrolls.
private struct ArtistBrowserGrid: View, Equatable {
    let artists: [NavidromeArtist]
    let selectedArtistID: String?
    let favoriteArtistIDs: Set<String>
    let serverKey: String?
    let isOnline: Bool
    let coverArtResource: (NavidromeArtist) -> CoverArtResource?
    let actions: LibraryItemActions<NavidromeArtist>
    @Environment(\.openLibraryRoute) private var openLibraryRoute

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.artists == rhs.artists
            && lhs.selectedArtistID == rhs.selectedArtistID
            && lhs.favoriteArtistIDs == rhs.favoriteArtistIDs
            && lhs.serverKey == rhs.serverKey
            && lhs.isOnline == rhs.isOnline
    }

    var body: some View {
        LazyLibraryCardGrid(artists, minimumCardWidth: 140) { artist in
            let isFavorite = favoriteArtistIDs.contains(artist.id)

            LibraryCardView(
                title: artist.name,
                subtitle: artist.subtitle,
                coverArtResource: coverArtResource(artist),
                spacing: 10,
                subtitleLineLimit: 1,
                isSelected: selectedArtistID == artist.id
            )
            .libraryCardActions(
                isFavorite: isFavorite,
                isOnline: isOnline,
                favoriteHelp: isFavorite ? "Remove artist from favorites" : "Add artist to favorites",
                open: { openLibraryRoute(.artist(artist)) },
                toggleFavorite: { actions.toggleFavorite(artist) }
            )
            .contextMenu {
                LibraryItemContextMenu(
                    artist: artist,
                    isFavorite: isFavorite,
                    isOnline: isOnline,
                    actions: actions,
                    open: { openLibraryRoute(.artist(artist)) }
                )
            }
        }
    }
}

struct ArtistDetailView: View {
    @ObservedObject var viewModel: AppCoordinator
    let artist: NavidromeArtist
    let openAlbum: (NavidromeAlbum) -> Void

    var body: some View {
        let isFavorite = viewModel.isFavorite(artist)

        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                LibraryDetailHeader(title: artist.name, subtitle: artist.subtitle)

                Spacer()

                OpenInSpotifyLink(artist: artist)

                Button {
                    viewModel.toggleFavorite(artist)
                } label: {
                    FavoriteLabel(isFavorite: isFavorite)
                }
                .disabled(!viewModel.isOnline)
                .help(isFavorite ? "Remove artist from favorites" : "Add artist to favorites")
            }

            if viewModel.selectedArtist?.id == artist.id && !viewModel.artistAlbums.isEmpty {
                AlbumBrowserView(
                    viewModel: viewModel,
                    albums: viewModel.artistAlbums,
                    openAlbum: openAlbum
                )
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
