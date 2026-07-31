//
//  ArtistBrowserView.swift
//  PolyDrom
//
//  Created by zikasak on 07/07/2026.
//

import SwiftUI

struct ArtistBrowserView: View {
    @ObservedObject var viewModel: AppCoordinator

    var body: some View {
        ArtistBrowserGrid(
            artists: viewModel.artists,
            selectedArtistID: viewModel.selectedArtist?.id,
            favoriteArtistIDs: viewModel.favoriteArtistIDs,
            serverKey: viewModel.serverKey,
            isOnline: viewModel.isOnline,
            coverArtResource: { viewModel.coverArtResource(for: $0, size: 220) },
            play: viewModel.play,
            playNext: viewModel.playNext,
            addToQueue: viewModel.addToQueue,
            toggleFavorite: viewModel.toggleFavorite
        )
        .equatable()
    }
}

struct FavoriteArtistBrowserView: View {
    @ObservedObject var viewModel: AppCoordinator

    var body: some View {
        ArtistBrowserGrid(
            artists: viewModel.favoriteArtists,
            selectedArtistID: viewModel.selectedArtist?.id,
            favoriteArtistIDs: viewModel.favoriteArtistIDs,
            serverKey: viewModel.serverKey,
            isOnline: viewModel.isOnline,
            coverArtResource: { viewModel.coverArtResource(for: $0, size: 220) },
            play: viewModel.play,
            playNext: viewModel.playNext,
            addToQueue: viewModel.addToQueue,
            toggleFavorite: viewModel.toggleFavorite
        )
        .equatable()
    }
}

private struct ArtistBrowserGrid: View, Equatable {
    let artists: [NavidromeArtist]
    let selectedArtistID: String?
    let favoriteArtistIDs: Set<String>
    let serverKey: String?
    let isOnline: Bool
    let coverArtResource: (NavidromeArtist) -> CoverArtResource?
    let play: (NavidromeArtist) -> Void
    let playNext: (NavidromeArtist) -> Void
    let addToQueue: (NavidromeArtist) -> Void
    let toggleFavorite: (NavidromeArtist) -> Void
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
            ZStack(alignment: .topTrailing) {
                NavigationLink(value: LibraryRoute.artist(artist)) {
                    ArtistCardView(
                        artist: artist,
                        coverArtResource: coverArtResource(artist),
                        isSelected: selectedArtistID == artist.id
                    )
                }
                .buttonStyle(.plain)

                Button {
                    toggleFavorite(artist)
                } label: {
                    Label(
                        favoriteArtistIDs.contains(artist.id) ? "Unfavorite" : "Favorite",
                        systemImage: favoriteArtistIDs.contains(artist.id) ? "heart.fill" : "heart"
                    )
                    .labelStyle(.iconOnly)
                    .padding(7)
                    .background(.regularMaterial, in: Circle())
                }
                .buttonStyle(.borderless)
                .disabled(!isOnline)
                .padding(15)
                .help(favoriteArtistIDs.contains(artist.id) ? "Remove artist from favorites" : "Add artist to favorites")
            }
            .contextMenu {
                Button {
                    play(artist)
                } label: {
                    Label("Play", systemImage: "play.fill")
                }
                .disabled(!isOnline)

                Button {
                    playNext(artist)
                } label: {
                    Label("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward")
                }

                Button {
                    addToQueue(artist)
                } label: {
                    Label("Add to Queue", systemImage: "text.badge.plus")
                }

                Button {
                    toggleFavorite(artist)
                } label: {
                    Label(
                        favoriteArtistIDs.contains(artist.id) ? "Remove from Favorites" : "Add to Favorites",
                        systemImage: favoriteArtistIDs.contains(artist.id) ? "heart.slash" : "heart"
                    )
                }
                .disabled(!isOnline)

                Divider()

                Button {
                    openLibraryRoute(.artist(artist))
                } label: {
                    Label("Open Artist", systemImage: "music.mic")
                }

                OpenInSpotifyLink(artist: artist)
            }
        }
    }
}

struct ArtistDetailView: View {
    @ObservedObject var viewModel: AppCoordinator
    let artist: NavidromeArtist
    let openAlbum: (NavidromeAlbum) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(artist.name)
                        .font(.title2)
                        .fontWeight(.semibold)

                    Text(artist.subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                OpenInSpotifyLink(artist: artist)

                Button {
                    viewModel.toggleFavorite(artist)
                } label: {
                    Label(
                        viewModel.isFavorite(artist) ? "Unfavorite" : "Favorite",
                        systemImage: viewModel.isFavorite(artist) ? "heart.fill" : "heart"
                    )
                }
                .disabled(!viewModel.isOnline)
                .help(viewModel.isFavorite(artist) ? "Remove artist from favorites" : "Add artist to favorites")
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

private struct ArtistCardView: View {
    let artist: NavidromeArtist
    let coverArtResource: CoverArtResource?
    let isSelected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            CoverArtView(resource: coverArtResource, size: 128)
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
