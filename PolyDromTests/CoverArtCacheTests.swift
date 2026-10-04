import CoreGraphics
import Foundation
import Synchronization
import Testing
@testable import PolyDrom

@Suite(.serialized)
struct CoverArtCacheTests {
    @Test func resourceEqualityHashingAndFallbackOrderUseCacheKey() {
        let first = CoverArtResource(cacheKey: "key", url: URL(string: "https://one.example/art")!, fallbackCacheKeys: ["small", "tiny"])
        let same = CoverArtResource(cacheKey: "key", url: URL(string: "https://two.example/art")!)
        let different = CoverArtResource(cacheKey: "other", url: first.url)

        #expect(first == same)
        #expect(first != different)
        #expect(Set([first, same, different]).count == 2)
        #expect(first.allCacheKeys == ["key", "small", "tiny"])
    }

    @Test func dataDownloadsOnceThenUsesMemoryFallbackAndDiskCaches() async throws {
        let directory = try temporaryDirectory()
        let lock = NSLock()
        nonisolated(unsafe) var requests = 0
        let handler: StubURLProtocol.Handler = { _ in
            lock.lock()
            requests += 1
            lock.unlock()
            return StubURLProtocol.Response(headers: ["Content-Type": "image/png"], data: onePixelPNG)
        }
        let session = StubURLProtocol.session(handler: handler)
        let cache = CoverArtCache(session: session, diskDirectory: directory)
        let resource = CoverArtResource(cacheKey: "original", url: URL(string: "https://art.example/image")!)

        #expect(try await cache.data(for: resource) == onePixelPNG)
        #expect(try await cache.data(for: resource) == onePixelPNG)
        let fallback = CoverArtResource(cacheKey: "large", url: URL(string: "https://art.example/large")!, fallbackCacheKeys: ["original"])
        #expect(try await cache.data(for: fallback) == onePixelPNG)

        let diskCache = CoverArtCache(session: session, diskDirectory: directory)
        #expect(try await diskCache.data(for: resource) == onePixelPNG)
        let requestCount = lock.withLock { requests }
        #expect(requestCount == 1)
    }

    @Test func clearRemovesMemoryAndDiskCoverArtAndAllowsFreshDownloads() async throws {
        let directory = try temporaryDirectory()
        let lock = NSLock()
        nonisolated(unsafe) var requests = 0
        let handler: StubURLProtocol.Handler = { _ in
            lock.lock()
            requests += 1
            lock.unlock()
            return StubURLProtocol.Response(headers: ["Content-Type": "image/png"], data: onePixelPNG)
        }
        let cache = CoverArtCache(
            session: StubURLProtocol.session(handler: handler),
            diskDirectory: directory
        )
        let resource = CoverArtResource(cacheKey: "clearable", url: URL(string: "https://art.example/clearable")!)

        _ = try await cache.image(for: resource)
        #expect(cache.cachedImage(for: resource) != nil)
        #expect(try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).isEmpty == false)

        try await cache.clear()

        #expect(cache.cachedImage(for: resource) == nil)
        #expect(try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).isEmpty)
        _ = try await cache.data(for: resource)
        #expect(lock.withLock { requests } == 2)
    }

    @Test func concurrentConsumersShareDownloadAndDecodedImage() async throws {
        let lock = NSLock()
        nonisolated(unsafe) var requests = 0
        let handler: StubURLProtocol.Handler = { _ in
            lock.lock()
            requests += 1
            lock.unlock()
            return StubURLProtocol.Response(headers: ["Content-Type": "image/png"], data: onePixelPNG)
        }
        let session = StubURLProtocol.session(handler: handler)
        let cache = CoverArtCache(session: session, diskDirectory: try temporaryDirectory())
        let resource = CoverArtResource(cacheKey: UUID().uuidString, url: URL(string: "https://art.example/shared")!)

        async let first = cache.data(for: resource)
        async let second = cache.data(for: resource)
        let values = try await [first, second]
        #expect(values == [onePixelPNG, onePixelPNG])

        async let imageOne = cache.image(for: resource)
        async let imageTwo = cache.image(for: resource)
        let images = try await [imageOne, imageTwo]
        #expect(images.allSatisfy { $0.width == 1 && $0.height == 1 })
        #expect(cache.cachedImage(for: resource) != nil)
        let requestCount = lock.withLock { requests }
        #expect(requestCount == 1)
    }

    @Test func storedImageDoesNotFetchMissingDataButDecodesDiskData() async throws {
        nonisolated(unsafe) var requests = 0
        let handler: StubURLProtocol.Handler = { _ in
            requests += 1
            return StubURLProtocol.Response(headers: ["Content-Type": "image/png"], data: onePixelPNG)
        }
        let session = StubURLProtocol.session(handler: handler)
        let directory = try temporaryDirectory()
        let cache = CoverArtCache(session: session, diskDirectory: directory)
        let missing = CoverArtResource(cacheKey: "missing", url: URL(string: "https://art.example/missing")!)
        #expect(await cache.storedImage(for: missing) == nil)
        #expect(requests == 0)

        _ = try await cache.data(for: missing)
        let secondCache = CoverArtCache(session: session, diskDirectory: directory)
        #expect(await secondCache.storedImage(for: missing)?.width == 1)
        #expect(requests == 1)
    }

    @Test func serverErrorBodyIsNotCached() async throws {
        let errorBody = Data(
            #"<subsonic-response status="failed"><error code="40" message="Wrong username or password"/></subsonic-response>"#.utf8
        )
        let lock = NSLock()
        nonisolated(unsafe) var body = errorBody
        let handler: StubURLProtocol.Handler = { _ in
            StubURLProtocol.Response(headers: ["Content-Type": "application/xml"], data: lock.withLock { body })
        }
        let session = StubURLProtocol.session(handler: handler)
        let directory = try temporaryDirectory()
        let cache = CoverArtCache(session: session, diskDirectory: directory)
        let resource = CoverArtResource(cacheKey: "rejected", url: URL(string: "https://art.example/rejected")!)

        await #expect(throws: CoverArtError.invalidImage) { try await cache.data(for: resource) }
        #expect(try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).isEmpty)

        // Once the server accepts the request, the same cover loads normally.
        lock.withLock { body = onePixelPNG }
        #expect(try await cache.image(for: resource).width == 1)
    }

    @Test func invalidImageAndHTTPFailuresSurfaceUsefulErrors() async throws {
        let invalid = CoverArtResource(cacheKey: "invalid", url: URL(string: "https://art.example/invalid")!)

        let invalidCache = CoverArtCache(
            session: StubURLProtocol.session { _ in StubURLProtocol.Response(data: Data("invalid".utf8)) },
            diskDirectory: try temporaryDirectory()
        )
        do {
            _ = try await invalidCache.image(for: invalid)
            Issue.record("Expected invalid image")
        } catch {
            #expect(error.localizedDescription == "The cover art is not a valid image.")
        }

        let httpCache = CoverArtCache(
            session: StubURLProtocol.session { _ in StubURLProtocol.Response(statusCode: 404, data: Data()) },
            diskDirectory: try temporaryDirectory()
        )
        do {
            _ = try await httpCache.data(for: CoverArtResource(cacheKey: "404", url: invalid.url))
            Issue.record("Expected HTTP error")
        } catch {
            #expect(error.localizedDescription == "HTTP 404")
        }
    }

    @Test func prefetchAndWarmDeduplicateAndHandleEmptyInputs() async throws {
        let handler: StubURLProtocol.Handler = { _ in
            StubURLProtocol.Response(headers: ["Content-Type": "image/png"], data: onePixelPNG)
        }
        let session = StubURLProtocol.session(handler: handler)
        let directory = try temporaryDirectory()
        let cache = CoverArtCache(session: session, diskDirectory: directory)
        let one = CoverArtResource(cacheKey: "one", url: URL(string: "https://art.example/one")!)
        let two = CoverArtResource(cacheKey: "two", url: URL(string: "https://art.example/two")!)

        await cache.prefetch([], maxConcurrentRequests: 0)
        await cache.prefetch([one, one, two], maxConcurrentRequests: 0)
        #expect(cache.cachedImage(for: one) != nil)
        #expect(cache.cachedImage(for: two) != nil)

        let diskCache = CoverArtCache(session: session, diskDirectory: directory)
        await diskCache.warmCachedImages([], maxConcurrentDecodes: 0)
        await diskCache.warmCachedImages([one, one, two], maxConcurrentDecodes: 1)
        #expect(diskCache.cachedImage(for: one) != nil)
        #expect(diskCache.cachedImage(for: two) != nil)
    }

    @Test func crawlStoresMissingCoversOnDiskWithoutDecodingAndSkipsStoredOnes() async throws {
        let requestedPaths = Mutex<[String]>([])
        let session = StubURLProtocol.session { request in
            requestedPaths.withLock { $0.append(request.url?.lastPathComponent ?? "") }
            return StubURLProtocol.Response(headers: ["Content-Type": "image/png"], data: onePixelPNG)
        }
        let directory = try temporaryDirectory()
        let cache = CoverArtCache(session: session, diskDirectory: directory)
        let stored = CoverArtResource(cacheKey: "stored", url: URL(string: "https://art.example/stored")!)
        let missing = CoverArtResource(cacheKey: "missing", url: URL(string: "https://art.example/missing")!)
        _ = try await cache.data(for: stored)

        #expect(await cache.crawl([stored, missing, missing]) == .finished)

        #expect(requestedPaths.withLock { $0 } == ["stored", "missing"])
        #expect(cache.cachedImage(for: missing) == nil)
        #expect(await cache.diskUsageBytes() == onePixelPNG.count * 2)
        // A relaunched cache serves the crawled cover without the network.
        let relaunched = CoverArtCache(session: session, diskDirectory: directory)
        #expect(await relaunched.storedImage(for: missing)?.width == 1)
        #expect(requestedPaths.withLock { $0.count } == 2)
    }

    @Test func diskLimitEvictsLeastRecentlyUsedCovers() async throws {
        let session = StubURLProtocol.session { _ in
            StubURLProtocol.Response(headers: ["Content-Type": "image/png"], data: onePixelPNG)
        }
        let directory = try temporaryDirectory()
        let resources = (0..<4).map {
            CoverArtResource(cacheKey: "cover-\($0)", url: URL(string: "https://art.example/\($0)")!)
        }
        let writer = CoverArtCache(session: session, diskDirectory: directory)
        for resource in resources.prefix(3) {
            _ = try await writer.data(for: resource)
            try await Task.sleep(for: .milliseconds(20))
        }

        // A fresh instance has nothing in memory, so reads below hit the disk.
        let cache = CoverArtCache(session: session, diskDirectory: directory, diskLimit: onePixelPNG.count * 3)
        #expect(await cache.diskUsageBytes() == onePixelPNG.count * 3)
        _ = try await cache.data(for: resources[0])
        _ = try await cache.data(for: resources[3])

        // The oldest untouched cover goes; the one just read stays.
        #expect(await cache.diskUsageBytes() <= onePixelPNG.count * 3)
        let reader = CoverArtCache(session: session, diskDirectory: directory)
        #expect(await reader.storedImage(for: resources[1]) == nil)
        #expect(await reader.storedImage(for: resources[0]) != nil)
        #expect(await reader.storedImage(for: resources[3]) != nil)

        await reader.setDiskLimit(onePixelPNG.count)
        #expect(await reader.diskUsageBytes() <= onePixelPNG.count)
    }

    @Test func crawlStopsAtTheDiskLimitWithoutEvictingStoredCovers() async throws {
        let session = StubURLProtocol.session { _ in
            StubURLProtocol.Response(headers: ["Content-Type": "image/png"], data: onePixelPNG)
        }
        let cache = CoverArtCache(
            session: session,
            diskDirectory: try temporaryDirectory(),
            diskLimit: onePixelPNG.count * 2
        )
        let viewed = CoverArtResource(cacheKey: "viewed", url: URL(string: "https://art.example/viewed")!)
        _ = try await cache.data(for: viewed)
        let crawled = (0..<5).map {
            CoverArtResource(cacheKey: "crawl-\($0)", url: URL(string: "https://art.example/crawl-\($0)")!)
        }

        #expect(await cache.crawl(crawled, maxConcurrentRequests: 1) == .cacheFull)

        #expect(await cache.diskUsageBytes() == onePixelPNG.count * 2)
        try await cache.clear()
        #expect(await cache.diskUsageBytes() == 0)
    }

    @Test func crawlRetriesTransientFailuresButNotRejectedArt() async throws {
        let isHealthy = Mutex(false)
        let requestedPaths = Mutex<[String]>([])
        let session = StubURLProtocol.session { request in
            let path = request.url?.lastPathComponent ?? ""
            requestedPaths.withLock { $0.append(path) }
            if path == "broken" {
                return StubURLProtocol.Response(data: Data("not an image".utf8))
            }
            guard isHealthy.withLock({ $0 }) else {
                return StubURLProtocol.Response(statusCode: 503, data: Data())
            }
            return StubURLProtocol.Response(headers: ["Content-Type": "image/png"], data: onePixelPNG)
        }
        let cache = CoverArtCache(session: session, diskDirectory: try temporaryDirectory())
        let flaky = CoverArtResource(cacheKey: "flaky", url: URL(string: "https://art.example/flaky")!)
        let broken = CoverArtResource(cacheKey: "broken", url: URL(string: "https://art.example/broken")!)

        #expect(await cache.crawl([flaky, broken], maxConcurrentRequests: 1) == .incomplete)

        isHealthy.withLock { $0 = true }
        #expect(await cache.crawl([flaky, broken], maxConcurrentRequests: 1) == .finished)
        #expect(requestedPaths.withLock { $0 } == ["flaky", "broken", "flaky"])
        #expect(await cache.diskUsageBytes() == onePixelPNG.count)
    }

    @Test func crawlReportsCoversItCouldNotWriteToDisk() async throws {
        let session = StubURLProtocol.session { _ in
            StubURLProtocol.Response(headers: ["Content-Type": "image/png"], data: onePixelPNG)
        }
        let directory = try temporaryDirectory()
        let cache = CoverArtCache(session: session, diskDirectory: directory)
        let resource = CoverArtResource(cacheKey: "unwritable", url: URL(string: "https://art.example/unwritable")!)
        try FileManager.default.removeItem(at: directory)

        #expect(await cache.crawl([resource]) == .incomplete)
        #expect(await cache.diskUsageBytes() == 0)

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        #expect(await cache.crawl([resource]) == .finished)
        #expect(await cache.diskUsageBytes() == onePixelPNG.count)
    }

    @Test func crawlGivesUpAfterRepeatedFailures() async throws {
        let requests = Mutex(0)
        let session = StubURLProtocol.session { _ in
            requests.withLock { $0 += 1 }
            throw URLError(.notConnectedToInternet)
        }
        let cache = CoverArtCache(session: session, diskDirectory: try temporaryDirectory())
        let resources = (0..<50).map {
            CoverArtResource(cacheKey: "offline-\($0)", url: URL(string: "https://art.example/offline-\($0)")!)
        }

        #expect(await cache.crawl(resources, maxConcurrentRequests: 1) == .failing)
        #expect(requests.withLock { $0 } < resources.count)
    }

    @Test func cancelledRequestFailsWithoutStartingWork() async throws {
        let cache = CoverArtCache(session: StubURLProtocol.session(), diskDirectory: try temporaryDirectory())
        let resource = CoverArtResource(cacheKey: "cancelled", url: URL(string: "https://art.example/cancelled")!)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await cache.data(for: resource)
        }
        await #expect(throws: CancellationError.self) { try await task.value }
    }
}
