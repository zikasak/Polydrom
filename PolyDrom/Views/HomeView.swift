//
//  HomeView.swift
//  PolyDrom
//
//  Created by Codex on 18/07/2026.
//

import SwiftUI

struct HomeView: View {
    @ObservedObject var viewModel: AppCoordinator
    let openAlbum: (NavidromeAlbum) -> Void

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 26) {
                featuredSection
                randomPlaySection
                AlbumShelf(
                    title: "Recently Added",
                    emptyMessage: "No recently added albums.",
                    albums: viewModel.recentlyAddedAlbums,
                    viewModel: viewModel,
                    openAlbum: openAlbum
                )
                AlbumShelf(
                    title: "Recently Played",
                    emptyMessage: "No recently played albums.",
                    albums: viewModel.recentlyPlayedAlbums,
                    viewModel: viewModel,
                    openAlbum: openAlbum
                )
                AlbumShelf(
                    title: "Random Albums",
                    emptyMessage: "No random albums available.",
                    albums: viewModel.homeRandomAlbums,
                    viewModel: viewModel,
                    openAlbum: openAlbum
                )
            }
            .padding(.vertical, 4)
        }
    }

    private var featuredSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HomeSectionHeader(title: "Featured", systemImage: "sparkles")

            if viewModel.featuredAlbums.isEmpty {
                HomeEmptySection(message: viewModel.isBusy ? "Loading featured albums…" : "No featured albums available.")
            } else {
                ScrollView(.horizontal) {
                    LazyHStack(spacing: 14) {
                        ForEach(viewModel.featuredAlbums) { album in
                            FeaturedAlbumCard(
                                album: album,
                                coverArtResource: viewModel.coverArtResource(for: album, size: 220),
                                isOnline: viewModel.isOnline,
                                open: { openAlbum(album) },
                                play: { viewModel.play(album) }
                            )
                            .contextMenu {
                                AlbumContextMenu(viewModel: viewModel, album: album, openAlbum: openAlbum)
                            }
                        }
                    }
                    .padding(.horizontal, 1)
                }
                .scrollIndicators(.hidden)
            }
        }
    }

    private var randomPlaySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HomeSectionHeader(title: "Start Something Random", systemImage: "shuffle")

            HStack(spacing: 12) {
                RandomPlayButton(title: "Quick Mix", subtitle: "10 songs", systemImage: "bolt.fill") {
                    await viewModel.playRandomSongs(count: 10)
                }
                RandomPlayButton(title: "Shuffle 25", subtitle: "A longer mix", systemImage: "shuffle") {
                    await viewModel.playRandomSongs(count: 25)
                }
                RandomPlayButton(title: "Surprise Me", subtitle: "50 songs", systemImage: "sparkles") {
                    await viewModel.playRandomSongs(count: 50)
                }
                RandomPlayButton(title: "Shuffle All", subtitle: "Entire library", systemImage: "music.note.list") {
                    await viewModel.playRandomSongs()
                }
            }
            .disabled(viewModel.isBusy || !viewModel.isOnline)
        }
    }
}

private struct AlbumShelf: View {
    let title: String
    let emptyMessage: String
    let albums: [NavidromeAlbum]
    @ObservedObject var viewModel: AppCoordinator
    let openAlbum: (NavidromeAlbum) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HomeSectionHeader(title: title, systemImage: nil)

            if albums.isEmpty {
                HomeEmptySection(message: viewModel.isBusy ? "Loading albums…" : emptyMessage)
            } else {
                ScrollView(.horizontal) {
                    LazyHStack(alignment: .top, spacing: 14) {
                        ForEach(albums) { album in
                            HomeAlbumCard(
                                album: album,
                                coverArtResource: viewModel.coverArtResource(for: album, size: 220),
                                isOnline: viewModel.isOnline,
                                open: { openAlbum(album) },
                                play: { viewModel.play(album) }
                            )
                            .contextMenu {
                                AlbumContextMenu(viewModel: viewModel, album: album, openAlbum: openAlbum)
                            }
                        }
                    }
                    .padding(.horizontal, 1)
                }
                .scrollIndicators(.hidden)
            }
        }
    }
}

private struct FeaturedAlbumCard: View {
    let album: NavidromeAlbum
    let coverArtResource: CoverArtResource?
    let isOnline: Bool
    let open: () -> Void
    let play: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            Button(action: open) {
                CoverArtView(resource: coverArtResource, size: 112)
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 7) {
                Text("FEATURED ALBUM")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.tint)

                Button(action: open) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(album.name)
                            .font(.headline)
                            .lineLimit(2)
                        Text(album.artist ?? "Unknown Artist")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    .multilineTextAlignment(.leading)
                }
                .buttonStyle(.plain)

                Spacer(minLength: 0)

                Button(action: play) {
                    Label("Play", systemImage: "play.fill")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(!isOnline)
            }
            .padding(.vertical, 2)
        }
        .padding(12)
        .frame(width: 310, height: 138, alignment: .leading)
        .background(.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .stroke(.secondary.opacity(0.14), lineWidth: 1)
        }
    }
}

private struct HomeAlbumCard: View {
    let album: NavidromeAlbum
    let coverArtResource: CoverArtResource?
    let isOnline: Bool
    let open: () -> Void
    let play: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .bottomTrailing) {
                Button(action: open) {
                    CoverArtView(resource: coverArtResource, size: 142)
                }
                .buttonStyle(.plain)

                Button(action: play) {
                    Label("Play \(album.name)", systemImage: "play.fill")
                        .labelStyle(.iconOnly)
                        .frame(width: 30, height: 30)
                        .background(.regularMaterial, in: Circle())
                }
                .buttonStyle(.plain)
                .disabled(!isOnline)
                .padding(8)
            }

            Button(action: open) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(album.name)
                        .font(.headline)
                        .lineLimit(1)
                    Text(album.artist ?? "Unknown Artist")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .multilineTextAlignment(.leading)
            }
            .buttonStyle(.plain)
        }
        .frame(width: 142, alignment: .leading)
    }
}

private struct RandomPlayButton: View {
    let title: String
    let subtitle: String
    let systemImage: String
    let action: () async -> Void

    var body: some View {
        Button {
            Task { await action() }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: systemImage)
                    .font(.title3)
                    .frame(width: 28, height: 28)
                    .foregroundStyle(.tint)

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.headline)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 8)
                Image(systemName: "play.fill")
                    .foregroundStyle(.secondary)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .stroke(.secondary.opacity(0.14), lineWidth: 1)
        }
    }
}

private struct HomeSectionHeader: View {
    let title: String
    let systemImage: String?

    var body: some View {
        HStack(spacing: 7) {
            if let systemImage {
                Image(systemName: systemImage)
                    .foregroundStyle(.secondary)
            }
            Text(title)
                .font(.title3.weight(.semibold))
        }
    }
}

private struct HomeEmptySection: View {
    let message: String

    var body: some View {
        Text(message)
            .font(.callout)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, minHeight: 82, alignment: .center)
            .background(.secondary.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
    }
}

private struct AlbumContextMenu: View {
    @ObservedObject var viewModel: AppCoordinator
    let album: NavidromeAlbum
    let openAlbum: (NavidromeAlbum) -> Void

    var body: some View {
        Button { viewModel.play(album) } label: {
            Label("Play", systemImage: "play.fill")
        }
        .disabled(!viewModel.isOnline)
        Button { viewModel.playNext(album) } label: {
            Label("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward")
        }
        Button { viewModel.addToQueue(album) } label: {
            Label("Add to Queue", systemImage: "text.badge.plus")
        }
        Button { viewModel.toggleFavorite(album) } label: {
            Label(
                viewModel.isFavorite(album) ? "Remove from Favorites" : "Add to Favorites",
                systemImage: viewModel.isFavorite(album) ? "heart.slash" : "heart"
            )
        }
        .disabled(!viewModel.isOnline)
        Divider()
        Button { openAlbum(album) } label: {
            Label("Open Album", systemImage: "rectangle.stack")
        }
        OpenInSpotifyLink(album: album)
    }
}
