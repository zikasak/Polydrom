//
//  SongListView.swift
//  PolyDrom
//
//  Created by zikasak on 07/07/2026.
//

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
                        audioPlayer: viewModel.audioPlayer,
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
                }
            }
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

struct SongRowView: View {
    let song: NavidromeSong
    let queue: [NavidromeSong]
    let queueIndex: Int
    @ObservedObject var viewModel: AppCoordinator
    @ObservedObject var audioPlayer: AudioPlayer
    let openRoute: (LibraryRoute) -> Void
    let currentAlbumID: String?
    var selection: Binding<Bool>?
    var removeFromPlaylist: (() -> Void)?

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
                .disabled(!viewModel.isOnline)
                .help("Play")
            }

            CoverArtView(resource: viewModel.coverArtResource(for: song, size: 96), size: 38)

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
                    .disabled(viewModel.isPlaylistMutating)
                    .help("Remove from playlist")
                }

                Button {
                    viewModel.toggleFavorite(song)
                } label: {
                    Label(viewModel.isFavorite(song) ? "Unfavorite" : "Favorite", systemImage: viewModel.isFavorite(song) ? "heart.fill" : "heart")
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(.borderless)
                .disabled(!viewModel.isOnline)
                .help(viewModel.isFavorite(song) ? "Remove from favorites" : "Add to favorites")
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
            if selection == nil, viewModel.isOnline {
                viewModel.play(queue, startingAt: queueIndex)
            }
        }
        .contextMenu {
            if selection == nil {
                Button {
                    viewModel.play(queue, startingAt: queueIndex)
                } label: {
                    Label("Play", systemImage: "play.fill")
                }
                .disabled(!viewModel.isOnline)

                Button {
                    viewModel.playNext([song])
                } label: {
                    Label("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward")
                }

                Button {
                    viewModel.addToQueue([song])
                } label: {
                    Label("Add to Queue", systemImage: "text.badge.plus")
                }

                Divider()

                Button {
                    viewModel.toggleFavorite(song)
                } label: {
                    Label(
                        viewModel.isFavorite(song) ? "Remove from Favorites" : "Add to Favorites",
                        systemImage: viewModel.isFavorite(song) ? "heart.slash" : "heart"
                    )
                }
                .disabled(!viewModel.isOnline)

                AddToPlaylistMenu(viewModel: viewModel, songs: [song])

                if let removeFromPlaylist {
                    Button(role: .destructive, action: removeFromPlaylist) {
                        Label("Remove from Playlist", systemImage: "trash")
                    }
                    .disabled(viewModel.isPlaylistMutating)
                }

                if navigationAlbum != nil || navigationArtist != nil {
                    Divider()
                }

                if let album = navigationAlbum {
                    Button {
                        openRoute(.album(album))
                    } label: {
                        Label("Open Album", systemImage: "rectangle.stack")
                    }
                }

                if let artist = navigationArtist {
                    Button {
                        openRoute(.artist(artist))
                    } label: {
                        Label("Open Artist", systemImage: "music.mic")
                    }
                }
            }
        }
    }

    private var navigationAlbum: NavidromeAlbum? {
        guard let album = viewModel.albumForNavigation(from: song),
              album.id != currentAlbumID else {
            return nil
        }
        return album
    }

    private var navigationArtist: NavidromeArtist? {
        viewModel.artistForNavigation(from: song)
    }

    private var isCurrentSong: Bool {
        audioPlayer.currentSong?.id == song.id
    }
}

struct AddToPlaylistMenu: View {
    @ObservedObject var viewModel: AppCoordinator
    let songs: [NavidromeSong]
    var onSuccess: @MainActor () -> Void = {}

    var body: some View {
        Menu {
            ForEach(viewModel.editablePlaylists) { playlist in
                Button(playlist.name) {
                    Task {
                        if await viewModel.addSongs(songs, to: playlist) {
                            onSuccess()
                        }
                    }
                }
            }

            if !viewModel.editablePlaylists.isEmpty {
                Divider()
            }

            Button {
                viewModel.requestPlaylistCreation(with: songs, onSuccess: onSuccess)
            } label: {
                Label("New Playlist…", systemImage: "plus")
            }
        } label: {
            Label("Add to Playlist", systemImage: "text.badge.plus")
        }
        .disabled(songs.isEmpty || !viewModel.canCreatePlaylist)
    }
}

private struct IndexedSong: Identifiable {
    let index: Int
    let song: NavidromeSong

    var id: Int { index }
}

struct CoverArtView: View {
    let resource: CoverArtResource?
    let size: CGFloat

    @Environment(\.libraryGridIsScrolling) private var libraryGridIsScrolling
    @State private var image: CGImage?
    @State private var loadedCacheKey: String?

    init(
        resource: CoverArtResource?,
        size: CGFloat
    ) {
        self.resource = resource
        self.size = size

        let cachedImage = resource.flatMap { CoverArtCache.shared.cachedImage(for: $0) }
        _image = State(initialValue: cachedImage)
        _loadedCacheKey = State(initialValue: cachedImage == nil ? nil : resource?.cacheKey)
    }

    var body: some View {
        Group {
            if let image = displayedImage {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .scaledToFill()
            } else {
                fallback
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .task(id: coverArtTaskID) {
            if restoreCachedImage() { return }
            if shouldPauseLoading {
                await restoreStoredImage()
                return
            }
            await loadImage()
        }
    }

    private var displayedImage: CGImage? {
        guard let resource else { return nil }

        if loadedCacheKey == resource.cacheKey {
            return image
        }

        // A view can be reused for another row before its task gets a chance to
        // reset state. This also lets a pre-warmed cached image render immediately.
        return CoverArtCache.shared.cachedImage(for: resource)
    }

    private var coverArtTaskID: String {
        "\(resource?.cacheKey ?? "missing")|\(shouldPauseLoading)"
    }

    private var shouldPauseLoading: Bool {
        displayedImage == nil && libraryGridIsScrolling
    }

    private var fallback: some View {
        Rectangle()
            .fill(.secondary.opacity(0.12))
    }

    @MainActor
    private func restoreCachedImage() -> Bool {
        guard let resource,
              let cachedImage = CoverArtCache.shared.cachedImage(for: resource) else {
            return false
        }

        image = cachedImage
        loadedCacheKey = resource.cacheKey
        return true
    }

    @MainActor
    private func restoreStoredImage() async {
        guard let resource,
              let storedImage = await CoverArtCache.shared.storedImage(for: resource),
              !Task.isCancelled else {
            return
        }

        image = storedImage
        loadedCacheKey = resource.cacheKey
    }

    @MainActor
    private func loadImage() async {
        guard let resource else {
            image = nil
            loadedCacheKey = nil
            return
        }

        guard loadedCacheKey != resource.cacheKey else { return }

        if let cachedImage = CoverArtCache.shared.cachedImage(for: resource) {
            image = cachedImage
            loadedCacheKey = resource.cacheKey
            return
        }

        image = nil
        loadedCacheKey = nil

        for attempt in 0..<3 {
            do {
                let loadedImage = try await CoverArtCache.shared.image(for: resource)
                guard !Task.isCancelled else { return }

                image = loadedImage
                loadedCacheKey = resource.cacheKey
                return
            } catch {
                guard !Task.isCancelled else { return }
                guard attempt < 2, isTransientNetworkError(error) else {
                    finishLoadingWithoutImage()
                    return
                }

                do {
                    try await Task.sleep(for: .milliseconds(attempt == 0 ? 400 : 900))
                } catch {
                    return
                }
            }
        }
    }

    @MainActor
    private func finishLoadingWithoutImage() {
        image = nil
        loadedCacheKey = nil
    }

    private func isTransientNetworkError(_ error: Error) -> Bool {
        let nsError = error as NSError
        guard nsError.domain == NSURLErrorDomain else { return false }

        return [
            URLError.timedOut,
            .cannotConnectToHost,
            .networkConnectionLost,
            .notConnectedToInternet,
            .dnsLookupFailed
        ].contains(URLError.Code(rawValue: nsError.code))
    }
}
