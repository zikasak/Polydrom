//
//  HomeView.swift
//  PolyDrom
//
//  Created by Codex on 18/07/2026.
//

import AppKit
import SwiftUI

private enum HomeLayout {
    /// Room around the content so card shadows and hover lifts are not clipped.
    static let inset: CGFloat = 6
    static let maxContentWidth: CGFloat = 2200
    static let sectionSpacing: CGFloat = 34
    static let shelfSpacing: CGFloat = 18
    static let minimumShelfCardWidth: CGFloat = 168
    static let heroPanelMinimumWidth: CGFloat = 900
}

struct HomeView: View {
    @ObservedObject var viewModel: AppCoordinator
    let openAlbum: (NavidromeAlbum) -> Void

    @State private var scrollWidth: CGFloat = 960

    private var contentWidth: CGFloat {
        min(scrollWidth - HomeLayout.inset * 2, HomeLayout.maxContentWidth)
    }

    /// Sizes shelf cards so a whole number of them exactly fills the row.
    private var shelfCardWidth: CGFloat {
        let spacing = HomeLayout.shelfSpacing
        let count = max(2, Int((contentWidth + spacing) / (HomeLayout.minimumShelfCardWidth + spacing)))
        return floor((contentWidth + spacing) / CGFloat(count) - spacing)
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: HomeLayout.sectionSpacing) {
                featuredSection
                randomPlaySection
                shelf(
                    title: "Recently Added",
                    subtitle: "New arrivals in your library",
                    emptyMessage: "No recently added albums.",
                    albums: viewModel.recentlyAddedAlbums
                )
                shelf(
                    title: "Recently Played",
                    subtitle: "Pick up where you left off",
                    emptyMessage: "No recently played albums.",
                    albums: viewModel.recentlyPlayedAlbums
                )
                shelf(
                    title: "Random Albums",
                    subtitle: "Something you might have forgotten",
                    emptyMessage: "No random albums available.",
                    albums: viewModel.homeRandomAlbums
                )
            }
            .frame(maxWidth: HomeLayout.maxContentWidth, alignment: .leading)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, HomeLayout.inset)
            .padding(.vertical, 4)
        }
        .padding(.horizontal, -HomeLayout.inset)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { scrollWidth = $0 }
    }

    @ViewBuilder
    private var featuredSection: some View {
        if viewModel.featuredAlbums.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                HomeSectionHeader(title: "Featured", subtitle: "Handpicked from your library")
                HomeEmptySection(message: viewModel.isBusy ? "Loading featured albums…" : "No featured albums available.")
            }
        } else {
            FeaturedHero(
                albums: viewModel.featuredAlbums,
                viewModel: viewModel,
                openAlbum: openAlbum,
                width: contentWidth
            )
        }
    }

    private var randomPlaySection: some View {
        let columnCount = contentWidth >= 760 ? 5 : 3
        let columns = Array(repeating: GridItem(.flexible(), spacing: 14), count: columnCount)

        return VStack(alignment: .leading, spacing: 14) {
            HomeSectionHeader(title: "Start Something Random", subtitle: "Jump into a shuffled mix of your library")

            LazyVGrid(columns: columns, spacing: 14) {
                MixTile(
                    title: "Quick Mix",
                    subtitle: "10 songs",
                    systemImage: "bolt.fill",
                    colors: [Color(red: 0.98, green: 0.55, blue: 0.16), Color(red: 0.92, green: 0.22, blue: 0.36)]
                ) {
                    await viewModel.playRandomSongs(count: 10)
                }
                MixTile(
                    title: "Shuffle 25",
                    subtitle: "A longer mix",
                    systemImage: "shuffle",
                    colors: [Color(red: 0.42, green: 0.36, blue: 0.95), Color(red: 0.66, green: 0.25, blue: 0.85)]
                ) {
                    await viewModel.playRandomSongs(count: 25)
                }
                MixTile(
                    title: "Surprise Me",
                    subtitle: "50 songs",
                    systemImage: "sparkles",
                    colors: [Color(red: 0.13, green: 0.62, blue: 0.86), Color(red: 0.20, green: 0.36, blue: 0.90)]
                ) {
                    await viewModel.playRandomSongs(count: 50)
                }
                MixTile(
                    title: "Shuffle All",
                    subtitle: "Entire library",
                    systemImage: "music.note.list",
                    colors: [Color(red: 0.10, green: 0.62, blue: 0.48), Color(red: 0.10, green: 0.44, blue: 0.62)]
                ) {
                    await viewModel.playRandomSongs()
                }
                MixTile(
                    title: "Shuffle Albums",
                    subtitle: "By album",
                    systemImage: "rectangle.stack.fill",
                    colors: [Color(red: 0.90, green: 0.28, blue: 0.55), Color(red: 0.62, green: 0.18, blue: 0.62)]
                ) {
                    await viewModel.playSongsShuffledByAlbum()
                }
            }
            .disabled(viewModel.isBusy || !viewModel.isOnline)
        }
    }

    private func shelf(
        title: String,
        subtitle: String,
        emptyMessage: String,
        albums: [NavidromeAlbum]
    ) -> some View {
        AlbumShelf(
            title: title,
            subtitle: subtitle,
            emptyMessage: emptyMessage,
            albums: albums,
            cardWidth: shelfCardWidth,
            viewModel: viewModel,
            openAlbum: openAlbum
        )
    }
}

// MARK: - Featured

private struct FeaturedHero: View {
    let albums: [NavidromeAlbum]
    @ObservedObject var viewModel: AppCoordinator
    let openAlbum: (NavidromeAlbum) -> Void
    let width: CGFloat

    @State private var selectedID: String?

    private var selected: NavidromeAlbum? {
        albums.first { $0.id == selectedID } ?? albums.first
    }

    private var showsPanel: Bool {
        albums.count > 1 && width >= HomeLayout.heroPanelMinimumWidth
    }

    private var height: CGFloat {
        min(400, max(330, width * 0.2))
    }

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            if let selected {
                HeroCard(
                    album: selected,
                    coverArtResource: viewModel.coverArtResource(for: selected, size: 500),
                    isOnline: viewModel.isOnline,
                    height: height,
                    open: { openAlbum(selected) },
                    play: { viewModel.play(selected) }
                )
                .id(selected.id)
                .transition(.opacity)
                .contextMenu {
                    AlbumContextMenu(viewModel: viewModel, album: selected) { openAlbum(selected) }
                }
            }

            if showsPanel {
                panel
                    .frame(width: min(400, max(300, width * 0.24)), height: height)
            }
        }
        .animation(.smooth(duration: 0.35), value: selected?.id)
    }

    private var panel: some View {
        VStack(spacing: 0) {
            ForEach(albums.prefix(5)) { album in
                HeroPanelRow(
                    album: album,
                    coverArtResource: viewModel.coverArtResource(for: album, size: 96),
                    isSelected: album.id == selected?.id
                ) {
                    selectedID = album.id
                }
                .frame(maxHeight: .infinity)
            }
        }
        .padding(8)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(.primary.opacity(0.08), lineWidth: 1)
        }
    }
}

private struct HeroCard: View {
    let album: NavidromeAlbum
    let coverArtResource: CoverArtResource?
    let isOnline: Bool
    let height: CGFloat
    let open: () -> Void
    let play: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    private let padding: CGFloat = 28

    private var coverSize: CGFloat { height - padding * 2 }

    private var details: String {
        var parts: [String] = []
        if let year = album.year { parts.append(String(year)) }
        if let songCount = album.songCount { parts.append(songCount == 1 ? "1 song" : "\(songCount) songs") }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        HStack(spacing: 32) {
            Button(action: open) {
                CoverArtView(resource: coverArtResource, size: coverSize, cornerRadius: 14)
                    .shadow(color: .black.opacity(0.35), radius: 24, y: 12)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Open \(album.name)")

            VStack(alignment: .leading, spacing: 8) {
                Label("Featured Album", systemImage: "sparkles")
                    .font(.caption.weight(.bold))
                    .textCase(.uppercase)
                    .foregroundStyle(.tint)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(.tint.opacity(0.16), in: Capsule())

                Spacer(minLength: 4)

                Button(action: open) {
                    Text(album.name)
                        .font(.system(size: 34, weight: .bold))
                        .lineLimit(2)
                        .minimumScaleFactor(0.65)
                        .multilineTextAlignment(.leading)
                }
                .buttonStyle(.plain)

                Text(album.artist ?? "Unknown Artist")
                    .font(.title3.weight(.medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                if !details.isEmpty {
                    Text(details)
                        .font(.subheadline)
                        .foregroundStyle(.tertiary)
                }

                Spacer(minLength: 12)

                HStack(spacing: 10) {
                    Button(action: play) {
                        Label("Play", systemImage: "play.fill")
                            .padding(.horizontal, 10)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!isOnline)

                    Button(action: open) {
                        Label("View Album", systemImage: "rectangle.stack")
                    }
                    .buttonStyle(.bordered)
                }
                .controlSize(.large)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(padding)
        .frame(maxWidth: .infinity)
        .frame(height: height)
        .background { backdrop }
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(.primary.opacity(0.1), lineWidth: 1)
        }
    }

    /// The album art, blown up and blurred, tinted so text stays readable in both appearances.
    private var backdrop: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)

            CoverArtView(resource: coverArtResource, size: 120, cornerRadius: 0)
                .scaleEffect(14)
                .blur(radius: 48)
                .saturation(1.35)
                .opacity(colorScheme == .dark ? 0.75 : 0.55)

            Rectangle().fill(.ultraThinMaterial)

            LinearGradient(
                colors: [
                    Color(nsColor: .windowBackgroundColor).opacity(colorScheme == .dark ? 0.1 : 0.3),
                    Color(nsColor: .windowBackgroundColor).opacity(colorScheme == .dark ? 0.5 : 0.65)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
        .clipped()
    }
}

private struct HeroPanelRow: View {
    let album: NavidromeAlbum
    let coverArtResource: CoverArtResource?
    let isSelected: Bool
    let select: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: select) {
            HStack(spacing: 12) {
                CoverArtView(resource: coverArtResource, size: 48, cornerRadius: 8)

                VStack(alignment: .leading, spacing: 2) {
                    Text(album.name)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    Text(album.artist ?? "Unknown Artist")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 0)

                if isSelected {
                    Image(systemName: "waveform")
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(.tint)
                }
            }
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .background(rowBackground, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .animation(.easeOut(duration: 0.15), value: isHovering)
        .accessibilityLabel("Show \(album.name)")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var rowBackground: Color {
        if isSelected { return Color.accentColor.opacity(0.18) }
        return isHovering ? Color.primary.opacity(0.07) : .clear
    }
}

// MARK: - Shuffle tiles

private struct MixTile: View {
    let title: String
    let subtitle: String
    let systemImage: String
    let colors: [Color]
    let action: () async -> Void

    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovering = false

    private var isLifted: Bool { isHovering && isEnabled }

    var body: some View {
        Button {
            Task { await action() }
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Image(systemName: systemImage)
                    .font(.title3.weight(.semibold))
                    .frame(width: 34, height: 34)
                    .background(.white.opacity(0.2), in: Circle())

                Spacer(minLength: 10)

                Text(title)
                    .font(.headline)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.85))
                    .lineLimit(1)
            }
            .foregroundStyle(.white)
            .padding(14)
            .frame(maxWidth: .infinity, minHeight: 112, alignment: .leading)
            .background {
                tileBackground
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .shadow(
                        color: (colors.first ?? .black).opacity(isLifted ? 0.4 : 0.15),
                        radius: isLifted ? 14 : 6,
                        y: isLifted ? 8 : 3
                    )
            }
            .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .buttonStyle(TilePressStyle())
        .scaleEffect(isLifted ? 1.02 : 1)
        .opacity(isEnabled ? 1 : 0.45)
        .onHover { isHovering = $0 }
        .animation(.easeOut(duration: 0.18), value: isLifted)
    }

    private var tileBackground: some View {
        ZStack(alignment: .bottomTrailing) {
            LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing)

            Image(systemName: systemImage)
                .font(.system(size: 84, weight: .bold))
                .foregroundStyle(.white.opacity(0.14))
                .rotationEffect(.degrees(-14))
                .offset(x: 18, y: 20)
        }
    }
}

private struct TilePressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
    }
}

// MARK: - Shelves

private struct AlbumShelf: View {
    let title: String
    let subtitle: String
    let emptyMessage: String
    let albums: [NavidromeAlbum]
    let cardWidth: CGFloat
    @ObservedObject var viewModel: AppCoordinator
    let openAlbum: (NavidromeAlbum) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HomeSectionHeader(title: title, subtitle: subtitle)

            if albums.isEmpty {
                HomeEmptySection(message: viewModel.isBusy ? "Loading albums…" : emptyMessage)
            } else {
                ScrollView(.horizontal) {
                    LazyHStack(alignment: .top, spacing: HomeLayout.shelfSpacing) {
                        ForEach(albums) { album in
                            HomeAlbumCard(
                                album: album,
                                coverArtResource: viewModel.coverArtResource(for: album, size: viewModel.gridCoverSize),
                                width: cardWidth,
                                isOnline: viewModel.isOnline,
                                open: { openAlbum(album) },
                                play: { viewModel.play(album) }
                            )
                            .contextMenu {
                                AlbumContextMenu(viewModel: viewModel, album: album) { openAlbum(album) }
                            }
                        }
                    }
                    .padding(.horizontal, HomeLayout.inset)
                    .padding(.vertical, 10)
                }
                .scrollIndicators(.hidden)
                .padding(.horizontal, -HomeLayout.inset)
            }
        }
    }
}

private struct HomeAlbumCard: View {
    let album: NavidromeAlbum
    let coverArtResource: CoverArtResource?
    let width: CGFloat
    let isOnline: Bool
    let open: () -> Void
    let play: () -> Void

    @State private var isHovering = false

    private var caption: String {
        let artist = album.artist ?? "Unknown Artist"
        guard let year = album.year else { return artist }
        return "\(artist) · \(year)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ZStack(alignment: .bottomTrailing) {
                Button(action: open) {
                    CoverArtView(resource: coverArtResource, size: width, cornerRadius: 12)
                        .overlay {
                            LinearGradient(
                                colors: [.clear, .black.opacity(isHovering ? 0.35 : 0)],
                                startPoint: .center,
                                endPoint: .bottom
                            )
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                        }
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Open \(album.name)")

                Button(action: play) {
                    Image(systemName: "play.fill")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 40, height: 40)
                        .background(Color.accentColor, in: Circle())
                        .shadow(color: .black.opacity(0.3), radius: 6, y: 3)
                }
                .buttonStyle(.plain)
                .grayscale(isOnline ? 0 : 1)
                .disabled(!isOnline)
                .opacity(isHovering ? 1 : 0)
                .offset(y: isHovering ? 0 : 8)
                .padding(10)
                .accessibilityLabel("Play \(album.name)")
            }
            .shadow(color: .black.opacity(isHovering ? 0.32 : 0.18), radius: isHovering ? 14 : 7, y: isHovering ? 9 : 4)
            .scaleEffect(isHovering ? 1.03 : 1)

            Button(action: open) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(album.name)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    Text(caption)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
        }
        .frame(width: width, alignment: .leading)
        .onHover { isHovering = $0 }
        .animation(.easeOut(duration: 0.18), value: isHovering)
    }
}

// MARK: - Shared pieces

private struct HomeSectionHeader: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.title2.weight(.bold))
            Text(subtitle)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }
}

private struct HomeEmptySection: View {
    let message: String

    var body: some View {
        Text(message)
            .font(.callout)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, minHeight: 96, alignment: .center)
            .background(.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}
