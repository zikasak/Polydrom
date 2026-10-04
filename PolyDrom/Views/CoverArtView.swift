//
//  CoverArtView.swift
//  PolyDrom
//

import SwiftUI

struct CoverArtView: View {
    let resource: CoverArtResource?
    let size: CGFloat
    let cornerRadius: CGFloat

    @Environment(LibraryScrollActivity.self) private var scrollActivity: LibraryScrollActivity?
    @State private var image: CGImage?
    @State private var loadedCacheKey: String?

    init(
        resource: CoverArtResource?,
        size: CGFloat,
        cornerRadius: CGFloat = 6
    ) {
        self.resource = resource
        self.size = size
        self.cornerRadius = cornerRadius

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
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
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
        displayedImage == nil && scrollActivity?.isScrolling == true
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

        let loadedImage = await CoverArtCache.shared.imageRetrying(for: resource) { $0.isTransientNetworkFailure }
        guard let loadedImage, !Task.isCancelled else { return }

        image = loadedImage
        loadedCacheKey = resource.cacheKey
    }
}

private extension Error {
    var isTransientNetworkFailure: Bool {
        let nsError = self as NSError
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
