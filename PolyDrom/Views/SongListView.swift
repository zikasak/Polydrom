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
    let snapshot: SongListSnapshot
    private var songs: [NavidromeSong] { snapshot.songs }
    @ObservedObject var viewModel: AppCoordinator
    let emptyMessage: String
    let openRoute: (LibraryRoute) -> Void
    var currentAlbumID: String?
    var editablePlaylist: NavidromePlaylist?

    @State private var isSelecting = false
    @State private var selectedEntryIDs: Set<UUID> = []
    @State private var selectionRevision: UUID?
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
                LazyLibraryList(snapshot.entries) { item in
                    SongRowView(
                        snapshot: snapshot,
                        queueIndex: item.index,
                        viewModel: viewModel,
                        isCurrentSong: item.song.id == currentSongID,
                        openRoute: openRoute,
                        currentAlbumID: currentAlbumID,
                        selection: isSelecting ? selectionBinding(for: item.id) : nil,
                        removeFromPlaylist: editablePlaylist.map { playlist in
                            {
                                Task {
                                    _ = await viewModel.removeSongs(
                                        at: IndexSet(integer: item.index),
                                        from: playlist,
                                        expectedSnapshotRevision: snapshot.revision
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
        .onChange(of: snapshot.revision) { _, _ in
            exitSelection()
        }
    }

    // Gate stale selection immediately, before onChange clears stored state.
    private var hasSelection: Bool {
        selectionRevision == snapshot.revision && !selectedEntryIDs.isEmpty
    }

    private var selectedIndices: IndexSet {
        guard selectionRevision == snapshot.revision else { return [] }
        return IndexSet(selectedEntryIDs.compactMap { snapshot.indicesByID[$0] })
    }

    @ViewBuilder
    private var selectionControls: some View {
        if isSelecting {
            AddToPlaylistMenu(viewModel: viewModel, songs: selectedSongs) {
                exitSelection()
            }
            .disabled(!hasSelection)

            if let editablePlaylist {
                Button(role: .destructive) {
                    Task {
                        if await viewModel.removeSongs(
                            at: selectedIndices,
                            from: editablePlaylist,
                            expectedSnapshotRevision: snapshot.revision
                        ) {
                            exitSelection()
                        }
                    }
                } label: {
                    Label("Remove Selected", systemImage: "trash")
                        .labelStyle(.iconOnly)
                }
                .disabled(!hasSelection || viewModel.isPlaylistMutating)
                .help("Remove selected songs from playlist")
            }

            Button("Done") {
                exitSelection()
            }
        } else {
            Button("Select") {
                selectionRevision = snapshot.revision
                isSelecting = true
            }
        }
    }

    private var selectedSongs: [NavidromeSong] {
        guard selectionRevision == snapshot.revision else { return [] }
        return selectedIndices.map { songs[$0] }
    }

    private func selectionBinding(for id: UUID) -> Binding<Bool> {
        Binding(
            get: { selectionRevision == snapshot.revision && selectedEntryIDs.contains(id) },
            set: { isSelected in
                if isSelected {
                    selectedEntryIDs.insert(id)
                } else {
                    selectedEntryIDs.remove(id)
                }
            }
        )
    }

    private func exitSelection() {
        selectedEntryIDs = []
        selectionRevision = nil
        isSelecting = false
    }
}

/// Rows are compared by value so scrolling and unrelated coordinator updates do
/// not re-evaluate every visible row. `viewModel` is intentionally not observed;
/// it is only used to perform actions, and display state is passed in.
struct SongRowView: View, Equatable {
    let snapshot: SongListSnapshot
    private var song: NavidromeSong { snapshot.songs[queueIndex] }
    private var queue: [NavidromeSong] { snapshot.songs }
    let queueIndex: Int
    let viewModel: AppCoordinator
    let isCurrentSong: Bool
    let isFavorite: Bool
    let isOnline: Bool
    let isPlaylistMutating: Bool
    let coverArtResource: CoverArtResource?
    let openRoute: (LibraryRoute) -> Void
    let currentAlbumID: String?
    let isSelected: Bool?
    var selection: Binding<Bool>?
    var removeFromPlaylist: (() -> Void)?

    init(
        snapshot: SongListSnapshot,
        queueIndex: Int,
        viewModel: AppCoordinator,
        isCurrentSong: Bool,
        openRoute: @escaping (LibraryRoute) -> Void,
        currentAlbumID: String?,
        selection: Binding<Bool>? = nil,
        removeFromPlaylist: (() -> Void)? = nil
    ) {
        self.snapshot = snapshot
        let song = snapshot.songs[queueIndex]
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
        self.isSelected = selection?.wrappedValue
        self.removeFromPlaylist = removeFromPlaylist
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        // A revision covers every song value and the queue used by actions.
        lhs.snapshot.revision == rhs.snapshot.revision
            && lhs.queueIndex == rhs.queueIndex
            && lhs.isCurrentSong == rhs.isCurrentSong
            && lhs.isFavorite == rhs.isFavorite
            && lhs.isOnline == rhs.isOnline
            && lhs.isPlaylistMutating == rhs.isPlaylistMutating
            && lhs.coverArtResource == rhs.coverArtResource
            && lhs.currentAlbumID == rhs.currentAlbumID
            && lhs.isSelected == rhs.isSelected
            && (lhs.removeFromPlaylist == nil) == (rhs.removeFromPlaylist == nil)
            && lhs.viewModel === rhs.viewModel
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
