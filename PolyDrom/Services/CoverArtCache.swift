//
//  CoverArtCache.swift
//  PolyDrom
//
//  Created by zikasak on 08/07/2026.
//

import CryptoKit
import Foundation
import ImageIO
import OSLog

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

/// When the disk cache should next learn about covers served from memory.
private enum AccessFlush {
    case notNeeded
    /// The first access since the last drain; a small set of covers viewed over
    /// and over never reaches the backlog size, so it is flushed on a delay.
    case soon
    case now
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
    /// Keys served since the last drain. Views read decoded images without
    /// reaching the disk cache, which still has to learn that they are in use.
    private var accessedKeys = Set<String>()
    private let accessedKeyFlushThreshold = 64

    /// A hit records `backingKeys`, the keys whose stored bytes can stand in for
    /// this image, since the image may have been decoded from any of them.
    /// `accessFlush` tells the owner when to drain the recorded keys.
    func image(forKey key: String, backingKeys: [String], accessFlush: inout AccessFlush) -> CGImage? {
        lock.lock()
        defer { lock.unlock() }

        guard var entry = entries[key] else { return nil }
        accessCounter &+= 1
        entry.lastAccess = accessCounter
        entries[key] = entry
        let previousCount = accessedKeys.count
        accessedKeys.formUnion(backingKeys)
        if previousCount < accessedKeyFlushThreshold, accessedKeys.count >= accessedKeyFlushThreshold {
            accessFlush = .now
        } else if previousCount == 0 {
            accessFlush = .soon
        }
        return entry.image
    }

    func drainAccessedKeys() -> Set<String> {
        lock.lock()
        defer { lock.unlock() }

        let keys = accessedKeys
        accessedKeys.removeAll(keepingCapacity: true)
        return keys
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

        guard entries.count > countLimit || totalCost > costLimit else { return }

        // Evict in one batch down to 90% of the limits. Scanning for a single
        // least-recently-used entry on every insert holds the lock that rows read
        // from on the main thread while scrolling.
        let targetCount = countLimit * 9 / 10
        let targetCost = costLimit / 10 * 9
        for (key, entry) in entries.sorted(by: { $0.value.lastAccess < $1.value.lastAccess }) {
            guard entries.count > targetCount || totalCost > targetCost else { break }
            totalCost -= entry.cost
            entries[key] = nil
        }
    }

    func removeAll() {
        lock.lock()
        defer { lock.unlock() }

        entries.removeAll(keepingCapacity: true)
        accessedKeys.removeAll(keepingCapacity: true)
        totalCost = 0
        accessCounter = 0
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

enum CoverArtError: LocalizedError, Equatable {
    case http(statusCode: Int)
    /// The server answered with a Subsonic error document instead of artwork,
    /// e.g. because it rejected the credentials.
    case subsonic(code: Int?)
    case invalidImage

    var errorDescription: String? {
        switch self {
        case .http(let statusCode):
            "HTTP \(statusCode)"
        case .subsonic:
            "The server rejected the cover art request."
        case .invalidImage:
            "The cover art is not a valid image."
        }
    }

    /// Whether asking again for this particular cover would get the same answer.
    var isPermanent: Bool {
        switch self {
        case .http(let statusCode):
            // Only "not found" is about this cover. Other statuses, including
            // rejected credentials, affect every request until they are resolved.
            statusCode == 404 || statusCode == 410
        case .subsonic(let code):
            // Only "data not found" is about this cover; authentication and
            // protocol errors affect every request until they are resolved.
            code == 70
        case .invalidImage:
            true
        }
    }
}

enum CoverArtCrawlOutcome: Equatable, Sendable {
    case finished
    /// Some covers could not be downloaded or stored and are worth retrying.
    case incomplete
    /// The disk cache reached its limit; crawling further would only evict art.
    case cacheFull
    /// Too many downloads failed in a row, e.g. because the server went offline.
    case failing
    case cancelled
}

enum CoverArtCacheLimit: Int, CaseIterable, Identifiable, Sendable {
    case megabytes100 = 100
    case megabytes250 = 250
    case megabytes500 = 500
    case gigabytes1 = 1_024
    case gigabytes2 = 2_048
    case gigabytes5 = 5_120

    static let `default` = CoverArtCacheLimit.megabytes500

    var id: Self { self }

    var bytes: Int {
        rawValue * 1024 * 1024
    }

    var title: String {
        rawValue < 1_024 ? "\(rawValue) MB" : "\(rawValue / 1_024) GB"
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

    private struct DiskEntry {
        var size: Int
        var lastAccess: Date
    }

    private struct DiskCacheFullError: Error {}

    private enum CrawlItemResult {
        case stored
        case retryableFailure
        case permanentFailure
        case cacheFull
        case cancelled
        /// Dropped by a cache clear, which says nothing about the server.
        case dropped
    }

    private let memoryCache = NSCache<NSString, NSData>()
    nonisolated private let decodedImageCache = DecodedCoverArtCache()
    private let diskDirectory: URL
    private let session: URLSession
    private let requestPermits = AsyncPermitPool(limit: 5)
    private let decodePermits = AsyncPermitPool(limit: 2)
    private var inFlightRequests: [String: InFlightRequest] = [:]
    private var inFlightImageRequests: [String: InFlightImageRequest] = [:]
    private var cacheGeneration: UInt = 0
    /// Files in the disk directory by name, loaded on first use. The last access
    /// is mirrored to each file's modification date so it survives relaunches.
    private var diskEntries: [String: DiskEntry]?
    private var diskUsage = 0
    private var diskLimit: Int
    /// On-screen and prefetch downloads that have not finished yet. The crawl
    /// starts nothing new while this is above zero.
    private var foregroundRequestCount = 0
    private var crawlFailedKeys = Set<String>()
    /// Keys served from the data memory cache since their disk entries were
    /// last marked as used.
    private var memoryAccessedKeys = Set<String>()
    private let crawlFailureLimit = 8

    init(session: URLSession? = nil, diskDirectory: URL? = nil, diskLimit: Int = CoverArtCacheLimit.default.bytes) {
        self.diskLimit = max(0, diskLimit)
        memoryCache.countLimit = 4_000
        memoryCache.totalCostLimit = 100 * 1024 * 1024
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.default
            configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
            configuration.httpMaximumConnectionsPerHost = 5
            configuration.timeoutIntervalForRequest = 30
            configuration.timeoutIntervalForResource = 60
            self.session = URLSession(configuration: configuration)
        }

        let defaultDirectory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        self.diskDirectory = diskDirectory
            ?? defaultDirectory
                .appendingPathComponent("PolyDrom", isDirectory: true)
                .appendingPathComponent("CoverArt", isDirectory: true)
        try? FileManager.default.createDirectory(at: self.diskDirectory, withIntermediateDirectories: true)
    }

    func data(for resource: CoverArtResource) async throws -> Data {
        try await data(for: resource, isCrawl: false)
    }

    private func data(for resource: CoverArtResource, isCrawl: Bool) async throws -> Data {
        try Task.checkCancellation()

        let key = resource.cacheKey as NSString
        let destinationURL = fileURL(for: resource.cacheKey)

        if let cachedData = cachedData(for: resource) {
            if isCrawl {
                // The bytes may only be in memory, e.g. after a failed write or
                // an eviction; the crawl's job is to have them on disk.
                if !hasDiskData(forKey: resource.cacheKey) {
                    guard try storeOnDisk(cachedData, at: destinationURL, evicting: false) else {
                        throw DiskCacheFullError()
                    }
                }
                return cachedData
            }
            memoryCache.setObject(cachedData as NSData, forKey: key, cost: cachedData.count)
            return cachedData
        }

        if !isCrawl {
            foregroundRequestCount += 1
        }
        defer {
            if !isCrawl {
                foregroundRequestCount -= 1
            }
        }

        let consumerID = UUID()
        let requestGeneration = cacheGeneration
        let task: Task<Data, Error>

        if var request = inFlightRequests[resource.cacheKey] {
            request.consumers.insert(consumerID)
            inFlightRequests[resource.cacheKey] = request
            task = request.task
        } else {
            let session = session
            let requestPermits = requestPermits
            task = Task<Data, Error> {
                try await Self.download(resource, session: session, requestPermits: requestPermits, isCrawl: isCrawl)
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
                if requestGeneration == cacheGeneration {
                    if isCrawl {
                        // Crawled art stays on disk only, and never pushes out
                        // covers the user has actually looked at.
                        guard try storeOnDisk(data, at: destinationURL, evicting: false) else {
                            throw DiskCacheFullError()
                        }
                    } else {
                        _ = try? storeOnDisk(data, at: destinationURL, evicting: true)
                        memoryCache.setObject(data as NSData, forKey: key, cost: data.count)
                    }
                }
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
        var accessFlush = AccessFlush.notNeeded
        defer {
            switch accessFlush {
            case .notNeeded:
                break
            case .soon:
                Task(priority: .utility) { await self.applyRecordedAccessesAfterDelay() }
            case .now:
                Task(priority: .utility) { await self.applyRecordedAccesses() }
            }
        }

        let cacheKeys = resource.allCacheKeys
        for cacheKey in cacheKeys {
            if let image = decodedImageCache.image(
                forKey: cacheKey,
                backingKeys: cacheKeys,
                accessFlush: &accessFlush
            ) {
                return image
            }
        }
        return nil
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
        let requestGeneration = cacheGeneration
        let task: Task<CGImage, Error>

        if var request = inFlightImageRequests[resource.cacheKey] {
            request.consumers.insert(consumerID)
            inFlightImageRequests[resource.cacheKey] = request
            task = request.task
        } else {
            task = Task { [self] in
                try await decodeImage(for: resource, generation: requestGeneration)
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

    /// Removes downloaded and decoded cover art. Requests that were in flight
    /// before the clear are canceled and cannot repopulate the cache afterward.
    func clear() throws {
        cacheGeneration &+= 1
        inFlightRequests.values.forEach { $0.task.cancel() }
        inFlightImageRequests.values.forEach { $0.task.cancel() }
        inFlightRequests.removeAll()
        inFlightImageRequests.removeAll()
        memoryCache.removeAllObjects()
        decodedImageCache.removeAll()
        crawlFailedKeys.removeAll()
        memoryAccessedKeys.removeAll()
        // Reloaded from the directory on next use, so a clear that fails part
        // way still accounts for whatever is left on disk.
        diskEntries = nil
        diskUsage = 0

        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: diskDirectory.path) {
            try fileManager.removeItem(at: diskDirectory)
        }
        try fileManager.createDirectory(at: diskDirectory, withIntermediateDirectories: true)
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

    private func decodeImage(for resource: CoverArtResource, generation: UInt) async throws -> CGImage {
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

        guard generation == cacheGeneration else { throw CancellationError() }
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

    /// Downloads the given covers to disk without decoding them, skipping any
    /// that are already stored. New downloads wait while on-screen requests are
    /// pending, so the crawl only uses the connection when nothing else needs it.
    func crawl(_ resources: [CoverArtResource], maxConcurrentRequests: Int = 2) async -> CoverArtCrawlOutcome {
        var seenKeys = Set<String>()
        let missingResources = resources.filter {
            seenKeys.insert($0.cacheKey).inserted
                && !crawlFailedKeys.contains($0.cacheKey)
                && !hasDiskData(forKey: $0.cacheKey)
        }
        let limit = max(1, maxConcurrentRequests)

        return await withTaskGroup(of: CrawlItemResult.self) { group in
            var iterator = missingResources.makeIterator()
            var consecutiveFailures = 0
            var hasRetryableFailures = false

            for _ in 0..<limit {
                guard let resource = iterator.next() else { break }
                group.addTask { await self.crawlDownload(resource) }
            }

            while let result = await group.next() {
                if Task.isCancelled {
                    group.cancelAll()
                    return .cancelled
                }

                switch result {
                case .stored:
                    consecutiveFailures = 0
                case .permanentFailure:
                    // A cover the server refuses says nothing about an outage,
                    // so a run of missing art must not end the crawl.
                    break
                case .retryableFailure:
                    hasRetryableFailures = true
                    consecutiveFailures += 1
                    if consecutiveFailures >= crawlFailureLimit {
                        group.cancelAll()
                        return .failing
                    }
                case .cacheFull:
                    group.cancelAll()
                    return .cacheFull
                case .dropped:
                    hasRetryableFailures = true
                case .cancelled:
                    break
                }

                guard let resource = iterator.next() else { continue }
                group.addTask { await self.crawlDownload(resource) }
            }

            if Task.isCancelled { return .cancelled }
            return hasRetryableFailures ? .incomplete : .finished
        }
    }

    /// Lets the next crawl ask again for covers the server rejected earlier, in
    /// case the artwork was repaired without its ID changing.
    func forgetCrawlFailures() {
        crawlFailedKeys.removeAll()
    }

    /// The size of the cover art stored on disk, in bytes.
    func diskUsageBytes() -> Int {
        loadDiskEntriesIfNeeded()
        return diskUsage
    }

    func setDiskLimit(_ bytes: Int) {
        diskLimit = max(0, bytes)
        loadDiskEntriesIfNeeded()
        applyRecordedAccesses()
        evictDiskEntriesIfNeeded()
    }

    private func crawlDownload(_ resource: CoverArtResource) async -> CrawlItemResult {
        while foregroundRequestCount > 0, !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(150))
        }
        guard !Task.isCancelled else { return .cancelled }

        loadDiskEntriesIfNeeded()
        guard diskUsage < diskLimit else { return .cacheFull }

        do {
            _ = try await data(for: resource, isCrawl: true)
            return .stored
        } catch is DiskCacheFullError {
            return .cacheFull
        } catch is CancellationError {
            return Task.isCancelled ? .cancelled : .dropped
        } catch {
            if Task.isCancelled { return .cancelled }
            // Rejected or broken art is not retried until the app restarts.
            // Transport, server, and disk errors are, since they can clear up.
            guard let coverArtError = error as? CoverArtError, coverArtError.isPermanent else {
                return .retryableFailure
            }
            crawlFailedKeys.insert(resource.cacheKey)
            return .permanentFailure
        }
    }

    private func loadDiskEntriesIfNeeded() {
        guard diskEntries == nil else { return }

        var entries: [String: DiskEntry] = [:]
        var usage = 0
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey]
        let files = (try? FileManager.default.contentsOfDirectory(
            at: diskDirectory,
            includingPropertiesForKeys: keys
        )) ?? []
        for file in files {
            guard let values = try? file.resourceValues(forKeys: Set(keys)), let size = values.fileSize else { continue }
            entries[file.lastPathComponent] = DiskEntry(
                size: size,
                lastAccess: values.contentModificationDate ?? .distantPast
            )
            usage += size
        }
        diskEntries = entries
        diskUsage = usage
    }

    /// Returns `false` when storing without evicting would exceed the limit.
    private func storeOnDisk(_ data: Data, at fileURL: URL, evicting: Bool) throws -> Bool {
        loadDiskEntriesIfNeeded()
        let name = fileURL.lastPathComponent
        let previousSize = diskEntries?[name]?.size ?? 0
        if !evicting, diskUsage - previousSize + data.count > diskLimit {
            return false
        }

        try data.write(to: fileURL, options: .atomic)
        diskUsage += data.count - previousSize
        diskEntries?[name] = DiskEntry(size: data.count, lastAccess: Date())
        applyRecordedAccesses()
        if evicting {
            evictDiskEntriesIfNeeded()
        }
        return true
    }

    private func noteDiskAccess(at fileURL: URL, size: Int) {
        loadDiskEntriesIfNeeded()
        let name = fileURL.lastPathComponent
        let now = Date()
        diskUsage += size - (diskEntries?[name]?.size ?? 0)
        diskEntries?[name] = DiskEntry(size: size, lastAccess: now)
        try? FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: fileURL.path)
    }

    /// Marks the stored files behind covers served from memory as recently
    /// used. Memory hits never read the disk, so without this a cover that is on
    /// screen every day would look untouched and be evicted first.
    private func applyRecordedAccesses() {
        let keys = decodedImageCache.drainAccessedKeys().union(memoryAccessedKeys)
        memoryAccessedKeys.removeAll(keepingCapacity: true)
        guard !keys.isEmpty else { return }

        loadDiskEntriesIfNeeded()
        let now = Date()
        for key in keys {
            let fileURL = fileURL(for: key)
            let name = fileURL.lastPathComponent
            guard diskEntries?[name] != nil else { continue }
            diskEntries?[name]?.lastAccess = now
            try? FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: fileURL.path)
        }
    }

    private func applyRecordedAccessesAfterDelay() async {
        try? await Task.sleep(for: .seconds(30))
        applyRecordedAccesses()
    }

    /// Removes the least recently used files once the limit is exceeded. Like the
    /// decoded cache, it evicts down to 90% so a full cache is not rescanned on
    /// every download.
    private func evictDiskEntriesIfNeeded() {
        guard diskUsage > diskLimit, let entries = diskEntries else { return }

        let targetUsage = diskLimit / 10 * 9
        var evictedCount = 0
        for (name, entry) in entries.sorted(by: { $0.value.lastAccess < $1.value.lastAccess }) {
            guard diskUsage > targetUsage else { break }
            do {
                try FileManager.default.removeItem(at: diskDirectory.appendingPathComponent(name))
            } catch CocoaError.fileNoSuchFile {
                // Already gone, so its space is free either way.
            } catch {
                // The file is still there and still counts toward the limit.
                continue
            }
            diskEntries?[name] = nil
            diskUsage -= entry.size
            evictedCount += 1
        }
        AppLog.cache.info("Evicted \(evictedCount, privacy: .public) covers to stay within the disk cache limit")
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

    private func hasDiskData(forKey key: String) -> Bool {
        FileManager.default.fileExists(atPath: fileURL(for: key).path)
    }

    private func hasCachedData(for resource: CoverArtResource) -> Bool {
        resource.allCacheKeys.contains {
            memoryCache.object(forKey: $0 as NSString) != nil || hasDiskData(forKey: $0)
        }
    }

    private func cachedData(for resource: CoverArtResource) -> Data? {
        for cacheKey in resource.allCacheKeys {
            let key = cacheKey as NSString
            if let cachedData = memoryCache.object(forKey: key) {
                // Bytes read through a fallback are also held under the requested
                // key, so the file that supplied them may be any of these.
                if memoryAccessedKeys.isEmpty {
                    Task(priority: .utility) { await self.applyRecordedAccessesAfterDelay() }
                }
                memoryAccessedKeys.formUnion(resource.allCacheKeys)
                return Data(referencing: cachedData)
            }

            let fileURL = fileURL(for: cacheKey)
            if let diskData = try? Data(contentsOf: fileURL) {
                noteDiskAccess(at: fileURL, size: diskData.count)
                memoryCache.setObject(diskData as NSData, forKey: key, cost: diskData.count)
                return diskData
            }
        }

        return nil
    }

    /// Checks the container header only, so it is cheap enough to run on every
    /// download.
    private static func isImageData(_ data: Data) -> Bool {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return false }
        return CGImageSourceGetType(source) != nil
    }

    private static func download(
        _ resource: CoverArtResource,
        session: URLSession,
        requestPermits: AsyncPermitPool,
        isCrawl: Bool
    ) async throws -> Data {
        // The crawl is already limited by its own concurrency and must
        // not hold permits that on-screen loads are waiting for.
        if !isCrawl {
            try await requestPermits.acquire()
        }

        let result: (Data, URLResponse)
        do {
            try Task.checkCancellation()
            var request = URLRequest(url: resource.url)
            request.cachePolicy = .reloadIgnoringLocalCacheData
            request.timeoutInterval = 30
            if isCrawl {
                request.networkServiceType = .background
            }

            result = try await session.data(for: request)
            if !isCrawl {
                await requestPermits.release()
            }
        } catch {
            if !isCrawl {
                await requestPermits.release()
            }
            throw error
        }

        let (data, response) = result
        if let httpResponse = response as? HTTPURLResponse, !(200...299).contains(httpResponse.statusCode) {
            throw CoverArtError.http(statusCode: httpResponse.statusCode)
        }

        // Subsonic reports failures such as rejected credentials as an
        // HTTP 200 error document, which must never be cached as art.
        guard Self.isImageData(data) else {
            throw Self.subsonicError(in: data) ?? CoverArtError.invalidImage
        }

        return data
    }

    /// Recognizes a Subsonic error document, which arrives as XML or JSON
    /// depending on the request, without fully parsing either.
    private static func subsonicError(in data: Data) -> CoverArtError? {
        // Error documents are tiny, so anything larger is not worth inspecting.
        guard data.count <= 4_096,
              let text = String(bytes: data, encoding: .utf8),
              text.contains("subsonic-response") else { return nil }
        let code = text.firstMatch(of: /code"?\s*[=:]\s*"?(\d+)/).flatMap { Int($0.1) }
        return .subsonic(code: code)
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
                    throw CoverArtError.invalidImage
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
