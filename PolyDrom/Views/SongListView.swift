//
//  SongListView.swift
//  PolyDrom
//
//  Created by zikasak on 07/07/2026.
//

import Combine
import SwiftUI

struct SongListView: View {
    let title: String
    let songs: [NavidromeSong]
    @ObservedObject var viewModel: AppCoordinator
    let emptyMessage: String
    let openRoute: (LibraryRoute) -> Void
    var currentAlbumID: String?
    var editablePlaylist: NavidromePlaylist?

    @State private var isSelecting = false
    @State private var selectedIndices = IndexSet()
    @State private var currentSongID: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title)
                    .font(.headline)

                Spacer()

                if !songs.isEmpty {
                    selectionControls
                }
            }

            if songs.isEmpty {
                ContentUnavailableView(emptyMessage, systemImage: "music.note")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                LazyLibraryList(indexedSongs) { item in
                    SongRowView(
                        song: item.song,
                        queue: songs,
                        queueIndex: item.index,
                        viewModel: viewModel,
                        isCurrentSong: item.song.id == currentSongID,
                        openRoute: openRoute,
                        currentAlbumID: currentAlbumID,
                        selection: isSelecting ? selectionBinding(for: item.index) : nil,
                        removeFromPlaylist: editablePlaylist.map { playlist in
                            {
                                Task {
                                    _ = await viewModel.removeSongs(
                                        at: IndexSet(integer: item.index),
                                        from: playlist
                                    )
                                }
                            }
                        }
                    )
                    .equatable()
                }
            }
        }
        // Only the playing song's identity matters to rows; observing the whole
        // player would re-render every visible row on each playback-time tick.
        .onReceive(viewModel.audioPlayer.$currentSong.map { $0?.id }.removeDuplicates()) { id in
            currentSongID = id
        }
        .onChange(of: songs.count) { _, count in
            selectedIndices = IndexSet(selectedIndices.filter { $0 < count })
            if count == 0 { exitSelection() }
        }
    }

    private var indexedSongs: [IndexedSong] {
        songs.indices.map { IndexedSong(index: $0, song: songs[$0]) }
    }

    @ViewBuilder
    private var selectionControls: some View {
        if isSelecting {
            AddToPlaylistMenu(viewModel: viewModel, songs: selectedSongs) {
                exitSelection()
            }
            .disabled(selectedIndices.isEmpty)

            if let editablePlaylist {
                Button(role: .destructive) {
                    Task {
                        if await viewModel.removeSongs(at: selectedIndices, from: editablePlaylist) {
                            exitSelection()
                        }
                    }
                } label: {
                    Label("Remove Selected", systemImage: "trash")
                        .labelStyle(.iconOnly)
                }
                .disabled(selectedIndices.isEmpty || viewModel.isPlaylistMutating)
                .help("Remove selected songs from playlist")
            }

            Button("Done") {
                exitSelection()
            }
        } else {
            Button("Select") {
                isSelecting = true
            }
        }
    }

    private var selectedSongs: [NavidromeSong] {
        selectedIndices.compactMap { songs.indices.contains($0) ? songs[$0] : nil }
    }

    private func selectionBinding(for index: Int) -> Binding<Bool> {
        Binding(
            get: { selectedIndices.contains(index) },
            set: { isSelected in
                if isSelected {
                    selectedIndices.insert(index)
                } else {
                    selectedIndices.remove(index)
                }
            }
        )
    }

    private func exitSelection() {
        selectedIndices = []
        isSelecting = false
    }
}

/// Rows are compared by value so scrolling and unrelated coordinator updates do
/// not re-evaluate every visible row. `viewModel` is intentionally not observed;
/// it is only used to perform actions, and display state is passed in.
struct SongRowView: View, Equatable {
    let song: NavidromeSong
    let queue: [NavidromeSong]
    let queueIndex: Int
    let viewModel: AppCoordinator
    let isCurrentSong: Bool
    let isFavorite: Bool
    let isOnline: Bool
    let isPlaylistMutating: Bool
    let coverArtResource: CoverArtResource?
    let openRoute: (LibraryRoute) -> Void
    let currentAlbumID: String?
    var selection: Binding<Bool>?
    var removeFromPlaylist: (() -> Void)?

    init(
        song: NavidromeSong,
        queue: [NavidromeSong],
        queueIndex: Int,
        viewModel: AppCoordinator,
        isCurrentSong: Bool,
        openRoute: @escaping (LibraryRoute) -> Void,
        currentAlbumID: String?,
        selection: Binding<Bool>? = nil,
        removeFromPlaylist: (() -> Void)? = nil
    ) {
        self.song = song
        self.queue = queue
        self.queueIndex = queueIndex
        self.viewModel = viewModel
        self.isCurrentSong = isCurrentSong
        self.isFavorite = viewModel.isFavorite(song)
        self.isOnline = viewModel.isOnline
        self.isPlaylistMutating = viewModel.isPlaylistMutating
        self.coverArtResource = viewModel.coverArtResource(for: song, size: 96)
        self.openRoute = openRoute
        self.currentAlbumID = currentAlbumID
        self.selection = selection
        self.removeFromPlaylist = removeFromPlaylist
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        // Array equality short-circuits when both sides share storage, which is
        // the common case when the parent re-renders with an unchanged list.
        lhs.song == rhs.song
            && lhs.queueIndex == rhs.queueIndex
            && lhs.isCurrentSong == rhs.isCurrentSong
            && lhs.isFavorite == rhs.isFavorite
            && lhs.isOnline == rhs.isOnline
            && lhs.isPlaylistMutating == rhs.isPlaylistMutating
            && lhs.coverArtResource == rhs.coverArtResource
            && lhs.currentAlbumID == rhs.currentAlbumID
            && lhs.selection?.wrappedValue == rhs.selection?.wrappedValue
            && (lhs.removeFromPlaylist == nil) == (rhs.removeFromPlaylist == nil)
            && lhs.viewModel === rhs.viewModel
            && lhs.queue == rhs.queue
    }

    var body: some View {
        HStack(spacing: 12) {
            if let selection {
                Toggle("Select \(song.title)", isOn: selection)
                    .labelsHidden()
                    .toggleStyle(.checkbox)
            } else {
                Button {
                    viewModel.play(queue, startingAt: queueIndex)
                } label: {
                    Label("Play", systemImage: "play.fill")
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(.borderless)
                .disabled(!isOnline)
                .help("Play")
            }

            CoverArtView(resource: coverArtResource, size: 38)

            VStack(alignment: .leading, spacing: 3) {
                Text(song.title)
                    .font(.headline)
                    .fontWeight(isCurrentSong ? .semibold : .regular)
                    .lineLimit(1)

                Text(song.subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            Text(song.durationText)
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 52, alignment: .trailing)

            if selection == nil {
                if let removeFromPlaylist {
                    Button(role: .destructive, action: removeFromPlaylist) {
                        Label("Remove from Playlist", systemImage: "trash")
                            .labelStyle(.iconOnly)
                    }
                    .buttonStyle(.borderless)
                    .disabled(isPlaylistMutating)
                    .help("Remove from playlist")
                }

                Button {
                    viewModel.toggleFavorite(song)
                } label: {
                    FavoriteLabel(isFavorite: isFavorite)
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(.borderless)
                .disabled(!isOnline)
                .help(isFavorite ? "Remove from favorites" : "Add to favorites")
            }
        }
        .padding(.vertical, 4)
        .background {
            RoundedRectangle(cornerRadius: 8)
                .fill(isCurrentSong ? Color.accentColor.opacity(0.13) : .clear)
                .padding(.horizontal, -40)
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            if selection == nil, isOnline {
                viewModel.play(queue, startingAt: queueIndex)
            }
        }
        .contextMenu {
            if selection == nil {
                QueueMenuButtons(
                    isOnline: isOnline,
                    play: { viewModel.play(queue, startingAt: queueIndex) },
                    playNext: { viewModel.playNext([song]) },
                    addToQueue: { viewModel.addToQueue([song]) }
                )

                Divider()

                FavoriteMenuButton(isFavorite: isFavorite, isOnline: isOnline) {
                    viewModel.toggleFavorite(song)
                }

                AddToPlaylistMenu(viewModel: viewModel, songs: [song])

                if let removeFromPlaylist {
                    Button(role: .destructive, action: removeFromPlaylist) {
                        Label("Remove from Playlist", systemImage: "trash")
                    }
                    .disabled(isPlaylistMutating)
                }

                if hasNavigationAlbum || hasNavigationArtist {
                    Divider()
                }

                if hasNavigationAlbum {
                    Button {
                        if let album = viewModel.albumForNavigation(from: song) {
                            openRoute(.album(album))
                        }
                    } label: {
                        Label("Open Album", systemImage: "rectangle.stack")
                    }
                }

                if hasNavigationArtist {
                    Button {
                        if let artist = viewModel.artistForNavigation(from: song) {
                            openRoute(.artist(artist))
                        }
                    } label: {
                        Label("Open Artist", systemImage: "music.mic")
                    }
                }
            }
        }
    }

    // The full library lookups behind navigation are deferred to the click so
    // the eagerly built context menu stays cheap while rows scroll into view.
    private var hasNavigationAlbum: Bool {
        guard let album = NavidromeAlbum(song: song) else { return false }
        return album.id != currentAlbumID
    }

    private var hasNavigationArtist: Bool {
        NavidromeArtist(song: song) != nil
    }
}

private struct IndexedSong: Identifiable {
    let index: Int
    let song: NavidromeSong

    var id: Int { index }
}
