//
//  AlbumBrowserView.swift
//  PolyDrom
//
//  Created by zikasak on 07/07/2026.
//

import SwiftUI

struct AlbumBrowserView: View {
    @ObservedObject var viewModel: AppViewModel
    @Environment(\.openLibraryRoute) private var openLibraryRoute
    let albums: [NavidromeAlbum]
    var openAlbum: ((NavidromeAlbum) -> Void)?

    init(
        viewModel: AppViewModel,
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
            selectedAlbumID: viewModel.selectedAlbum?.id,
            favoriteAlbumIDs: viewModel.favoriteAlbumIDs,
            serverKey: viewModel.serverKey,
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
    let selectedAlbumID: String?
    let favoriteAlbumIDs: Set<String>
    let serverKey: String?
    let coverArtResource: (NavidromeAlbum) -> CoverArtResource?
    let play: (NavidromeAlbum) -> Void
    let playNext: (NavidromeAlbum) -> Void
    let addToQueue: (NavidromeAlbum) -> Void
    let toggleFavorite: (NavidromeAlbum) -> Void
    let openAlbum: (NavidromeAlbum) -> Void

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.albums == rhs.albums
            && lhs.selectedAlbumID == rhs.selectedAlbumID
            && lhs.favoriteAlbumIDs == rhs.favoriteAlbumIDs
            && lhs.serverKey == rhs.serverKey
    }

    var body: some View {
        LazyLibraryCardGrid(albums, minimumCardWidth: 150) { album in
            ZStack(alignment: .topTrailing) {
                NavigationLink(value: LibraryRoute.album(album)) {
                    AlbumCardView(
                        album: album,
                        coverArtResource: coverArtResource(album),
                        isSelected: selectedAlbumID == album.id
                    )
                }
                .buttonStyle(.plain)

                Button {
                    toggleFavorite(album)
                } label: {
                    Label(
                        favoriteAlbumIDs.contains(album.id) ? "Unfavorite" : "Favorite",
                        systemImage: favoriteAlbumIDs.contains(album.id) ? "heart.fill" : "heart"
                    )
                    .labelStyle(.iconOnly)
                    .padding(7)
                    .background(.regularMaterial, in: Circle())
                }
                .buttonStyle(.borderless)
                .padding(15)
                .help(favoriteAlbumIDs.contains(album.id) ? "Remove album from favorites" : "Add album to favorites")
            }
            .contextMenu {
                Button {
                    play(album)
                } label: {
                    Label("Play", systemImage: "play.fill")
                }

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
                        favoriteAlbumIDs.contains(album.id) ? "Remove from Favorites" : "Add to Favorites",
                        systemImage: favoriteAlbumIDs.contains(album.id) ? "heart.slash" : "heart"
                    )
                }

                Divider()

                Button {
                    openAlbum(album)
                } label: {
                    Label("Open Album", systemImage: "rectangle.stack")
                }
            }
        }
    }
}

struct AlbumDetailView: View {
    @ObservedObject var viewModel: AppViewModel
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

                Button {
                    viewModel.toggleFavorite(album)
                } label: {
                    Label(
                        viewModel.isFavorite(album) ? "Unfavorite" : "Favorite",
                        systemImage: viewModel.isFavorite(album) ? "heart.fill" : "heart"
                    )
                }
                .help(viewModel.isFavorite(album) ? "Remove album from favorites" : "Add album to favorites")
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
