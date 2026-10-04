//
//  AlbumBrowserView.swift
//  PolyDrom
//
//  Created by zikasak on 07/07/2026.
//

import SwiftUI

struct AlbumBrowserView: View {
    @ObservedObject var viewModel: AppCoordinator
    @Environment(\.openLibraryRoute) private var openLibraryRoute
    let snapshot: ViewCollectionSnapshot<NavidromeAlbum>
    var openAlbum: ((NavidromeAlbum) -> Void)?

    init(
        viewModel: AppCoordinator,
        snapshot: ViewCollectionSnapshot<NavidromeAlbum>,
        openAlbum: ((NavidromeAlbum) -> Void)? = nil
    ) {
        self.viewModel = viewModel
        self.snapshot = snapshot
        self.openAlbum = openAlbum
    }

    var body: some View {
        AlbumBrowserGrid(
            snapshot: snapshot,
            favoriteAlbumIDs: viewModel.favoriteAlbumIDs,
            favoritesRevision: viewModel.favoriteAlbumIDsRevision,
            serverKey: viewModel.serverKey,
            isOnline: viewModel.isOnline,
            coverArtResource: { album in
                viewModel.coverArtResource(for: album, size: viewModel.gridCoverSize)
            },
            actions: LibraryItemActions(viewModel),
            openAlbum: { album in
                if let openAlbum {
                    openAlbum(album)
                } else {
                    openLibraryRoute(.album(album))
                }
            }
        )
        .equatable()
    }
}

/// Compared by the values it shows, so coordinator updates that do not affect
/// the grid leave it alone while it scrolls.
private struct AlbumBrowserGrid: View, Equatable {
    let snapshot: ViewCollectionSnapshot<NavidromeAlbum>
    let favoriteAlbumIDs: Set<String>
    let favoritesRevision: UUID
    let serverKey: String?
    let isOnline: Bool
    let coverArtResource: (NavidromeAlbum) -> CoverArtResource?
    let actions: LibraryItemActions<NavidromeAlbum>
    let openAlbum: (NavidromeAlbum) -> Void

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.snapshot.revision == rhs.snapshot.revision
            && lhs.favoritesRevision == rhs.favoritesRevision
            && lhs.serverKey == rhs.serverKey
            && lhs.isOnline == rhs.isOnline
    }

    var body: some View {
        LazyLibraryCardGrid(snapshot.items, minimumCardWidth: 150) { album in
            let isFavorite = favoriteAlbumIDs.contains(album.id)

            LibraryCardView(
                title: album.name,
                subtitle: album.subtitle,
                coverArtResource: coverArtResource(album)
            )
            .libraryCardActions(
                isFavorite: isFavorite,
                isOnline: isOnline,
                favoriteHelp: isFavorite ? "Remove album from favorites" : "Add album to favorites",
                open: { openAlbum(album) },
                toggleFavorite: { actions.toggleFavorite(album) }
            )
            .contextMenu {
                LibraryItemContextMenu(
                    album: album,
                    isFavorite: isFavorite,
                    isOnline: isOnline,
                    actions: actions,
                    open: { openAlbum(album) }
                )
            }
        }
    }
}

struct AlbumDetailView: View {
    @ObservedObject var viewModel: AppCoordinator
    let album: NavidromeAlbum
    let openRoute: (LibraryRoute) -> Void

    var body: some View {
        let isFavorite = viewModel.isFavorite(album)

        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                LibraryDetailHeader(title: album.name, subtitle: album.subtitle)

                Spacer()

                HStack(alignment: .center, spacing: 8) {
                    OpenInSpotifyLink(album: album, presentation: .iconOnly)

                    Button {
                        viewModel.toggleFavorite(album)
                    } label: {
                        FavoriteLabel(isFavorite: isFavorite)
                    }
                    .disabled(!viewModel.isOnline)
                    .help(isFavorite ? "Remove album from favorites" : "Add album to favorites")
                }
            }

            SongListView(
                title: "Songs",
                snapshot: viewModel.selectedAlbum?.id == album.id ? viewModel.albumSongsSnapshot : .empty,
                viewModel: viewModel,
                emptyMessage: viewModel.isBusy ? "Loading songs..." : "No songs for this album.",
                openRoute: openRoute,
                currentAlbumID: album.id
            )
        }
        .padding(18)
        .navigationTitle(album.name)
        .task(id: album.id) {
            await viewModel.loadSongs(for: album)
        }
    }
}
