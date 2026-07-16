//
//  CoverArtCache.swift
//  PolyDrom
//
//  Created by zikasak on 08/07/2026.
//

import CryptoKit
import Foundation
import ImageIO

private actor AsyncPermitPool {
    private let limit: Int
    private var availablePermits: Int
    private var waiterOrder: [UUID] = []
    private var nextWaiterIndex = 0
    private var waiters: [UUID: CheckedContinuation<Void, Error>] = [:]

    init(limit: Int) {
        self.limit = max(1, limit)
        availablePermits = self.limit
    }

    func acquire() async throws {
        try Task.checkCancellation()

        if availablePermits > 0 {
            availablePermits -= 1
            return
        }

        let waiterID = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else {
                    waiterOrder.append(waiterID)
                    waiters[waiterID] = continuation
                }
            }
        } onCancel: {
            Task {
                await self.cancelWaiter(waiterID)
            }
        }
    }

    func release() {
        while nextWaiterIndex < waiterOrder.count {
            let waiterID = waiterOrder[nextWaiterIndex]
            nextWaiterIndex += 1

            if let continuation = waiters.removeValue(forKey: waiterID) {
                compactWaiterOrderIfNeeded()
                continuation.resume()
                return
            }
        }

        waiterOrder.removeAll(keepingCapacity: true)
        nextWaiterIndex = 0
        availablePermits = min(limit, availablePermits + 1)
    }

    private func cancelWaiter(_ waiterID: UUID) {
        guard let continuation = waiters.removeValue(forKey: waiterID) else { return }
        continuation.resume(throwing: CancellationError())
    }

    private func compactWaiterOrderIfNeeded() {
        guard nextWaiterIndex > 128, nextWaiterIndex * 2 > waiterOrder.count else { return }
        waiterOrder.removeFirst(nextWaiterIndex)
        nextWaiterIndex = 0
    }
}

private nonisolated final class DecodedCoverArtCache: @unchecked Sendable {
    private struct Entry {
        let image: CGImage
        let cost: Int
        var lastAccess: UInt64
    }

    private let lock = NSLock()
    private let countLimit = 1_400
    private let costLimit = 256 * 1024 * 1024
    private var entries: [String: Entry] = [:]
    private var totalCost = 0
    private var accessCounter: UInt64 = 0

    func image(forKey key: String) -> CGImage? {
        lock.lock()
        defer { lock.unlock() }

        guard var entry = entries[key] else { return nil }
        accessCounter &+= 1
        entry.lastAccess = accessCounter
        entries[key] = entry
        return entry.image
    }

    func insert(_ image: CGImage, forKey key: String) {
        lock.lock()
        defer { lock.unlock() }

        let cost = image.bytesPerRow * image.height
        if let previousEntry = entries[key] {
            totalCost -= previousEntry.cost
        }

        accessCounter &+= 1
        entries[key] = Entry(image: image, cost: cost, lastAccess: accessCounter)
        totalCost += cost

        while entries.count > countLimit || totalCost > costLimit {
            guard let leastRecentlyUsed = entries.min(by: { $0.value.lastAccess < $1.value.lastAccess }) else {
                break
            }
            totalCost -= leastRecentlyUsed.value.cost
            entries[leastRecentlyUsed.key] = nil
        }
    }
}

struct CoverArtResource: Hashable {
    let cacheKey: String
    let url: URL
    /// Equivalent small-thumbnail cache entries from earlier or adjacent views.
    /// They are deliberately limited to thumbnail-sized art so large artwork is
    /// never replaced with a visibly soft image.
    let fallbackCacheKeys: [String]

    init(cacheKey: String, url: URL, fallbackCacheKeys: [String] = []) {
        self.cacheKey = cacheKey
        self.url = url
        self.fallbackCacheKeys = fallbackCacheKeys
    }

    static func == (lhs: CoverArtResource, rhs: CoverArtResource) -> Bool {
        lhs.cacheKey == rhs.cacheKey
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(cacheKey)
    }

    nonisolated var allCacheKeys: [String] {
        [cacheKey] + fallbackCacheKeys
    }
}

actor CoverArtCache {
    static let shared = CoverArtCache()

    private struct InFlightRequest {
        let task: Task<Data, Error>
        var consumers: Set<UUID>
    }

    private struct InFlightImageRequest {
        let task: Task<CGImage, Error>
        var consumers: Set<UUID>
    }

    private let memoryCache = NSCache<NSString, NSData>()
    nonisolated private let decodedImageCache = DecodedCoverArtCache()
    private let diskDirectory: URL
    private let session: URLSession
    private let requestPermits = AsyncPermitPool(limit: 5)
    private let decodePermits = AsyncPermitPool(limit: 2)
    private var inFlightRequests: [String: InFlightRequest] = [:]
    private var inFlightImageRequests: [String: InFlightImageRequest] = [:]

    private init() {
        memoryCache.countLimit = 4_000
        memoryCache.totalCostLimit = 100 * 1024 * 1024
        let configuration = URLSessionConfiguration.default
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpMaximumConnectionsPerHost = 5
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 60
        session = URLSession(configuration: configuration)

        let cachesDirectory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        diskDirectory = cachesDirectory
            .appendingPathComponent("PolyDrom", isDirectory: true)
            .appendingPathComponent("CoverArt", isDirectory: true)

        try? FileManager.default.createDirectory(at: diskDirectory, withIntermediateDirectories: true)
    }

    init(session: URLSession, diskDirectory: URL) {
        memoryCache.countLimit = 4_000
        memoryCache.totalCostLimit = 100 * 1024 * 1024
        self.session = session
        self.diskDirectory = diskDirectory
        try? FileManager.default.createDirectory(at: diskDirectory, withIntermediateDirectories: true)
    }

    func data(for resource: CoverArtResource) async throws -> Data {
        try Task.checkCancellation()

        let key = resource.cacheKey as NSString
        let destinationURL = fileURL(for: resource.cacheKey)

        if let cachedData = cachedData(for: resource) {
            memoryCache.setObject(cachedData as NSData, forKey: key, cost: cachedData.count)
            return cachedData
        }

        let consumerID = UUID()
        let task: Task<Data, Error>

        if var request = inFlightRequests[resource.cacheKey] {
            request.consumers.insert(consumerID)
            inFlightRequests[resource.cacheKey] = request
            task = request.task
        } else {
            let session = session
            let requestPermits = requestPermits
            task = Task<Data, Error> {
                try await requestPermits.acquire()

                let result: (Data, URLResponse)
                do {
                    try Task.checkCancellation()
                    var request = URLRequest(url: resource.url)
                    request.cachePolicy = .reloadIgnoringLocalCacheData
                    request.timeoutInterval = 30

                    result = try await session.data(for: request)
                    await requestPermits.release()
                } catch {
                    await requestPermits.release()
                    throw error
                }

                let (data, response) = result
                if let httpResponse = response as? HTTPURLResponse, !(200...299).contains(httpResponse.statusCode) {
                    throw NavidromeError.server(message: "HTTP \(httpResponse.statusCode)")
                }

                try? data.write(to: destinationURL, options: .atomic)
                return data
            }
            inFlightRequests[resource.cacheKey] = InFlightRequest(
                task: task,
                consumers: [consumerID]
            )
        }

        return try await withTaskCancellationHandler {
            do {
                let data = try await task.value
                try Task.checkCancellation()
                releaseConsumer(consumerID, forKey: resource.cacheKey, cancelIfUnused: false)
                memoryCache.setObject(data as NSData, forKey: key, cost: data.count)
                return data
            } catch {
                releaseConsumer(
                    consumerID,
                    forKey: resource.cacheKey,
                    cancelIfUnused: Task.isCancelled
                )
                throw error
            }
        } onCancel: {
            Task {
                await self.releaseConsumer(
                    consumerID,
                    forKey: resource.cacheKey,
                    cancelIfUnused: true
                )
            }
        }
    }

    nonisolated func cachedImage(for resource: CoverArtResource) -> CGImage? {
        resource.allCacheKeys.lazy.compactMap { self.decodedImageCache.image(forKey: $0) }.first
    }

    /// Returns an image only when its bytes are already cached locally. This is
    /// safe to call for a row that appears during scrolling because it never starts
    /// a network request and decoding is handled by the bounded utility queue.
    func storedImage(for resource: CoverArtResource) async -> CGImage? {
        if let image = cachedImage(for: resource) {
            return image
        }

        guard hasCachedData(for: resource) else { return nil }
        return try? await image(for: resource)
    }

    func image(for resource: CoverArtResource) async throws -> CGImage {
        try Task.checkCancellation()

        if let cachedImage = cachedImage(for: resource) {
            return cachedImage
        }

        let consumerID = UUID()
        let task: Task<CGImage, Error>

        if var request = inFlightImageRequests[resource.cacheKey] {
            request.consumers.insert(consumerID)
            inFlightImageRequests[resource.cacheKey] = request
            task = request.task
        } else {
            task = Task { [self] in
                try await decodeImage(for: resource)
            }
            inFlightImageRequests[resource.cacheKey] = InFlightImageRequest(
                task: task,
                consumers: [consumerID]
            )
        }

        return try await withTaskCancellationHandler {
            do {
                let image = try await task.value
                try Task.checkCancellation()
                releaseImageConsumer(consumerID, forKey: resource.cacheKey, cancelIfUnused: false)
                return image
            } catch {
                releaseImageConsumer(
                    consumerID,
                    forKey: resource.cacheKey,
                    cancelIfUnused: Task.isCancelled
                )
                throw error
            }
        } onCancel: {
            Task {
                await self.releaseImageConsumer(
                    consumerID,
                    forKey: resource.cacheKey,
                    cancelIfUnused: true
                )
            }
        }
    }

    /// Decodes images that are already stored locally without issuing requests.
    /// This makes cached covers available synchronously when their views are made.
    func warmCachedImages(
        _ resources: [CoverArtResource],
        maxConcurrentDecodes: Int = 4
    ) async {
        var seenKeys = Set<String>()
        let cachedResources = resources.filter {
            seenKeys.insert($0.cacheKey).inserted && hasCachedData(for: $0)
        }
        let limit = max(1, maxConcurrentDecodes)

        await withTaskGroup(of: Void.self) { group in
            var iterator = cachedResources.makeIterator()

            for _ in 0..<limit {
                guard let resource = iterator.next() else { break }
                group.addTask { _ = try? await self.image(for: resource) }
            }

            while await group.next() != nil {
                if Task.isCancelled {
                    group.cancelAll()
                    return
                }

                guard let resource = iterator.next() else { continue }
                group.addTask { _ = try? await self.image(for: resource) }
            }
        }
    }

    private func decodeImage(for resource: CoverArtResource) async throws -> CGImage {
        if let cachedImage = cachedImage(for: resource) {
            return cachedImage
        }

        let data = try await data(for: resource)

        // Another consumer may have decoded the same in-flight download while this
        // task was suspended waiting for its data.
        if let cachedImage = cachedImage(for: resource) {
            return cachedImage
        }

        let image = try await decode(data)

        decodedImageCache.insert(image, forKey: resource.cacheKey)
        return image
    }

    func prefetch(_ resources: [CoverArtResource], maxConcurrentRequests: Int = 2) async {
        var seenKeys = Set<String>()
        let uniqueResources = resources.filter { seenKeys.insert($0.cacheKey).inserted }
        let limit = max(1, maxConcurrentRequests)

        await withTaskGroup(of: Void.self) { group in
            var iterator = uniqueResources.makeIterator()

            for _ in 0..<limit {
                guard let resource = iterator.next() else { break }
                group.addTask { _ = try? await self.image(for: resource) }
            }

            while await group.next() != nil {
                if Task.isCancelled {
                    group.cancelAll()
                    return
                }

                guard let resource = iterator.next() else { continue }
                group.addTask { _ = try? await self.image(for: resource) }
            }
        }
    }

    private func releaseConsumer(_ consumerID: UUID, forKey key: String, cancelIfUnused: Bool) {
        guard var request = inFlightRequests[key] else { return }

        request.consumers.remove(consumerID)
        if request.consumers.isEmpty {
            if cancelIfUnused {
                request.task.cancel()
            }
            inFlightRequests[key] = nil
        } else {
            inFlightRequests[key] = request
        }
    }

    private func releaseImageConsumer(_ consumerID: UUID, forKey key: String, cancelIfUnused: Bool) {
        guard var request = inFlightImageRequests[key] else { return }

        request.consumers.remove(consumerID)
        if request.consumers.isEmpty {
            if cancelIfUnused {
                request.task.cancel()
            }
            inFlightImageRequests[key] = nil
        } else {
            inFlightImageRequests[key] = request
        }
    }

    private func fileURL(for key: String) -> URL {
        let digest = SHA256.hash(data: Data(key.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        return diskDirectory.appendingPathComponent("\(digest).image")
    }

    private func hasCachedData(for resource: CoverArtResource) -> Bool {
        resource.allCacheKeys.contains {
            memoryCache.object(forKey: $0 as NSString) != nil
                || FileManager.default.fileExists(atPath: fileURL(for: $0).path)
        }
    }

    private func cachedData(for resource: CoverArtResource) -> Data? {
        for cacheKey in resource.allCacheKeys {
            let key = cacheKey as NSString
            if let cachedData = memoryCache.object(forKey: key) {
                return Data(referencing: cachedData)
            }

            let fileURL = fileURL(for: cacheKey)
            if let diskData = try? Data(contentsOf: fileURL) {
                memoryCache.setObject(diskData as NSData, forKey: key, cost: diskData.count)
                return diskData
            }
        }

        return nil
    }

    private func decode(_ data: Data) async throws -> CGImage {
        try await decodePermits.acquire()

        do {
            let image = try await Task.detached(priority: .utility) {
                guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                      let image = CGImageSourceCreateImageAtIndex(
                          source,
                          0,
                          [kCGImageSourceShouldCacheImmediately: true] as CFDictionary
                      ) else {
                    throw NavidromeError.server(message: "The cover art is not a valid image.")
                }
                return image
            }.value
            await decodePermits.release()
            return image
        } catch {
            await decodePermits.release()
            throw error
        }
    }
}
