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
    let albums: [NavidromeAlbum]
    var openAlbum: ((NavidromeAlbum) -> Void)?

    init(
        viewModel: AppCoordinator,
        albums: [NavidromeAlbum],
        openAlbum: ((NavidromeAlbum) -> Void)? = nil
    ) {
        self.viewModel = viewModel
        self.albums = albums
        self.openAlbum = openAlbum
    }

    var body: some View {
        AlbumBrowserGrid(
            albums: albums,
            favoriteAlbumIDs: viewModel.favoriteAlbumIDs,
            serverKey: viewModel.serverKey,
            isOnline: viewModel.isOnline,
            coverArtResource: { album in
                viewModel.coverArtResource(for: album, size: 220)
            },
            play: viewModel.play,
            playNext: viewModel.playNext,
            addToQueue: viewModel.addToQueue,
            toggleFavorite: viewModel.toggleFavorite,
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

private struct AlbumBrowserGrid: View, Equatable {
    let albums: [NavidromeAlbum]
    let favoriteAlbumIDs: Set<String>
    let serverKey: String?
    let isOnline: Bool
    let coverArtResource: (NavidromeAlbum) -> CoverArtResource?
    let play: (NavidromeAlbum) -> Void
    let playNext: (NavidromeAlbum) -> Void
    let addToQueue: (NavidromeAlbum) -> Void
    let toggleFavorite: (NavidromeAlbum) -> Void
    let openAlbum: (NavidromeAlbum) -> Void

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.albums == rhs.albums
            && lhs.favoriteAlbumIDs == rhs.favoriteAlbumIDs
            && lhs.serverKey == rhs.serverKey
            && lhs.isOnline == rhs.isOnline
    }

    var body: some View {
        LazyLibraryCardGrid(albums, minimumCardWidth: 150) { album in
            let isFavorite = favoriteAlbumIDs.contains(album.id)

            // Cards scroll into view by the dozen, and a button or navigation
            // link costs several times what a tap gesture does to build, so both
            // the card and its favorite badge are plain views with gestures.
            AlbumCardView(
                album: album,
                coverArtResource: coverArtResource(album)
            )
            .modifier(LibraryCardPressModifier {
                openAlbum(album)
            })
            // Pinned to the cover's corner, which is centered in a card whose
            // width follows the window.
            .overlay(alignment: .top) {
                LibraryFavoriteBadge(
                    isFavorite: isFavorite,
                    isEnabled: isOnline,
                    help: isFavorite ? "Remove album from favorites" : "Add album to favorites"
                ) {
                    toggleFavorite(album)
                }
                .padding(5)
                .frame(width: 128, alignment: .trailing)
                .padding(.top, 10)
            }
            .contextMenu {
                Button {
                    play(album)
                } label: {
                    Label("Play", systemImage: "play.fill")
                }
                .disabled(!isOnline)

                Button {
                    playNext(album)
                } label: {
                    Label("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward")
                }

                Button {
                    addToQueue(album)
                } label: {
                    Label("Add to Queue", systemImage: "text.badge.plus")
                }

                Button {
                    toggleFavorite(album)
                } label: {
                    Label(
                        isFavorite ? "Remove from Favorites" : "Add to Favorites",
                        systemImage: isFavorite ? "heart.slash" : "heart"
                    )
                }
                .disabled(!isOnline)

                Divider()

                Button {
                    openAlbum(album)
                } label: {
                    Label("Open Album", systemImage: "rectangle.stack")
                }

                OpenInSpotifyLink(album: album)
            }
        }
    }
}

struct AlbumDetailView: View {
    @ObservedObject var viewModel: AppCoordinator
    let album: NavidromeAlbum
    let openRoute: (LibraryRoute) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(album.name)
                        .font(.title2)
                        .fontWeight(.semibold)

                    Text(album.subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                HStack(alignment: .center, spacing: 8) {
                    OpenInSpotifyLink(album: album, presentation: .iconOnly)

                    Button {
                        viewModel.toggleFavorite(album)
                    } label: {
                        Label(
                            viewModel.isFavorite(album) ? "Unfavorite" : "Favorite",
                            systemImage: viewModel.isFavorite(album) ? "heart.fill" : "heart"
                        )
                    }
                    .disabled(!viewModel.isOnline)
                    .help(viewModel.isFavorite(album) ? "Remove album from favorites" : "Add album to favorites")
                }
            }

            SongListView(
                title: "Songs",
                songs: viewModel.selectedAlbum?.id == album.id ? viewModel.albumSongs : [],
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

private struct AlbumCardView: View {
    let album: NavidromeAlbum
    let coverArtResource: CoverArtResource?

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
                .fill(Color.secondary.opacity(0.08))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.secondary.opacity(0.14), lineWidth: 1)
        }
        .contentShape(RoundedRectangle(cornerRadius: 8))
    }
}
