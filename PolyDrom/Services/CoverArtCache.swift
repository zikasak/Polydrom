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

    static func == (lhs: CoverArtResource, rhs: CoverArtResource) -> Bool {
        lhs.cacheKey == rhs.cacheKey
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(cacheKey)
    }
}

actor CoverArtCache {
    static let shared = CoverArtCache()

    private struct InFlightRequest {
        let task: Task<Data, Error>
        var consumers: Set<UUID>
    }

    private let memoryCache = NSCache<NSString, NSData>()
    nonisolated private let decodedImageCache = DecodedCoverArtCache()
    private let diskDirectory: URL
    private let session: URLSession
    private let requestPermits = AsyncPermitPool(limit: 5)
    private var inFlightRequests: [String: InFlightRequest] = [:]

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

    func data(for resource: CoverArtResource) async throws -> Data {
        try Task.checkCancellation()

        let key = resource.cacheKey as NSString

        if let cachedData = memoryCache.object(forKey: key) {
            return Data(referencing: cachedData)
        }

        let fileURL = fileURL(for: resource.cacheKey)
        if let diskData = try? Data(contentsOf: fileURL) {
            memoryCache.setObject(diskData as NSData, forKey: key, cost: diskData.count)
            return diskData
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

                try? data.write(to: fileURL, options: .atomic)
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
        decodedImageCache.image(forKey: resource.cacheKey)
    }

    func image(for resource: CoverArtResource) async throws -> CGImage {
        try Task.checkCancellation()

        if let cachedImage = cachedImage(for: resource) {
            return cachedImage
        }

        let data = try await data(for: resource)
        try Task.checkCancellation()

        // Another consumer may have decoded the same in-flight download while this
        // task was suspended waiting for its data.
        if let cachedImage = cachedImage(for: resource) {
            return cachedImage
        }

        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(
                  source,
                  0,
                  [kCGImageSourceShouldCacheImmediately: true] as CFDictionary
              ) else {
            throw NavidromeError.server(message: "The cover art is not a valid image.")
        }

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

    private func fileURL(for key: String) -> URL {
        let digest = SHA256.hash(data: Data(key.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        return diskDirectory.appendingPathComponent("\(digest).image")
    }
}
