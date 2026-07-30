import CoreGraphics
import Foundation
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
        lock.lock()
        let requestCount = requests
        lock.unlock()
        #expect(requestCount == 1)
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
        lock.lock()
        let requestCount = requests
        lock.unlock()
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
