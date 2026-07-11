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
    @ObservedObject var viewModel: AppViewModel
    let emptyMessage: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.headline)

            if songs.isEmpty {
                ContentUnavailableView(emptyMessage, systemImage: "music.note")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                LazyLibraryList(songs) { song in
                    SongRowView(song: song, queue: songs, viewModel: viewModel)
                }
            }
        }
    }
}

struct SongRowView: View {
    let song: NavidromeSong
    let queue: [NavidromeSong]
    @ObservedObject var viewModel: AppViewModel

    var body: some View {
        HStack(spacing: 12) {
            Button {
                viewModel.play(song, in: queue)
            } label: {
                Label("Play", systemImage: "play.fill")
                    .labelStyle(.iconOnly)
            }
            .buttonStyle(.borderless)
            .help("Play")

            CoverArtView(resource: viewModel.coverArtResource(for: song, size: 72), size: 38)

            VStack(alignment: .leading, spacing: 3) {
                Text(song.title)
                    .font(.headline)
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

            Button {
                viewModel.toggleFavorite(song)
            } label: {
                Label(viewModel.isFavorite(song) ? "Unfavorite" : "Favorite", systemImage: viewModel.isFavorite(song) ? "heart.fill" : "heart")
                    .labelStyle(.iconOnly)
            }
            .buttonStyle(.borderless)
            .help(viewModel.isFavorite(song) ? "Remove from favorites" : "Add to favorites")
        }
        .padding(.vertical, 4)
    }
}

struct CoverArtView: View {
    let resource: CoverArtResource?
    let size: CGFloat
    let fallbackSystemImage: String

    @Environment(\.libraryGridIsScrolling) private var libraryGridIsScrolling
    @State private var image: CGImage?
    @State private var loadedCacheKey: String?

    init(
        resource: CoverArtResource?,
        size: CGFloat,
        fallbackSystemImage: String = "music.note"
    ) {
        self.resource = resource
        self.size = size
        self.fallbackSystemImage = fallbackSystemImage

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
        .task(id: CoverArtLoadID(cacheKey: resource?.cacheKey, isPaused: shouldPauseLoading)) {
            if restoreCachedImage() { return }
            guard !shouldPauseLoading else { return }
            await loadImage()
        }
    }

    private var displayedImage: CGImage? {
        image ?? resource.flatMap { CoverArtCache.shared.cachedImage(for: $0) }
    }

    private var shouldPauseLoading: Bool {
        displayedImage == nil && libraryGridIsScrolling
    }

    private var fallback: some View {
        ZStack {
            Rectangle()
                .fill(.secondary.opacity(0.12))
            Image(systemName: fallbackSystemImage)
                .foregroundStyle(.secondary)
        }
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

private struct CoverArtLoadID: Hashable {
    let cacheKey: String?
    let isPaused: Bool
}
