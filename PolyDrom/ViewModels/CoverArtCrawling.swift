import Foundation
import OSLog

extension AppCoordinator {
    /// Downloads grid-size album and artist covers in the background so the
    /// browsers never wait on the network. Larger artwork stays on demand.
    func startCoverArtCrawl(restart: Bool) {
        if restart {
            cancelCoverArtCrawl()
            // Only the restarted crawl's own result may mark the server done.
            // This holds even when no crawl can start right now, so turning the
            // setting back on later picks up what changed in the meantime.
            coverArtCrawledServerKey = nil
        }
        guard coverArtCrawlEnabled, isOnline, let session = currentSession else { return }
        if !restart, coverArtCrawl != nil || coverArtCrawledServerKey == session.serverKey {
            return
        }

        let id = UUID()
        let task = Task(priority: .background) { [weak self] in
            guard let self else { return }
            await self.crawlCoverArt(id: id, session: session, retryingRejectedCovers: restart)
        }
        coverArtCrawl = (id, task)
    }

    func cancelCoverArtCrawl() {
        coverArtCrawl?.task.cancel()
        coverArtCrawl = nil
    }

    func coverArtCrawlSettingDidChange() {
        if coverArtCrawlEnabled {
            startCoverArtCrawl(restart: false)
        } else {
            cancelCoverArtCrawl()
        }
    }

    func applyCoverArtCacheLimit() {
        Task {
            // Quick successive changes each start a task, and their calls may
            // land in any order; whichever lands last re-applies the current value.
            var applied: CoverArtCacheLimit
            repeat {
                applied = coverArtCacheLimit
                await coverArtCache.setDiskLimit(applied.bytes)
            } while applied != coverArtCacheLimit
            await refreshCoverArtCacheSize()
            // A crawl that stopped at the old limit may have room to continue. One
            // still running may be about to stop for that limit, so it starts over.
            startCoverArtCrawl(restart: true)
        }
    }

    func refreshCoverArtCacheSize() async {
        let size = await coverArtCache.diskUsageBytes()
        if coverArtCacheSize != size {
            coverArtCacheSize = size
        }
    }

    private func crawlCoverArt(id: UUID, session: SessionIdentity, retryingRejectedCovers: Bool) async {
        let serverKey = session.serverKey
        defer {
            if coverArtCrawl?.id == id {
                coverArtCrawl = nil
            }
        }
        if retryingRejectedCovers {
            await coverArtCache.forgetCrawlFailures()
        }
        guard let albums = try? await store.albums(serverKey: serverKey),
              let allArtists = try? await store.artists(serverKey: serverKey) else { return }
        let artists = sortedVisibleArtists(allArtists)
        let total = albums.count + artists.count
        AppLog.cache.info("Cover art crawl started for \(total, privacy: .public) albums and artists")

        // Resources are built in small batches: each one signs a URL, and doing
        // that for a whole library at once would stall the main thread.
        let batchSize = 100
        var outcome = CoverArtCrawlOutcome.finished
        var isIncomplete = false
        for start in stride(from: 0, to: total, by: batchSize) {
            guard !Task.isCancelled, isCurrentSession(session) else { return }
            let resources = (start..<min(start + batchSize, total)).compactMap { index in
                index < albums.count
                    ? coverArtResource(for: albums[index], size: gridCoverSize)
                    : coverArtResource(for: artists[index - albums.count], size: gridCoverSize)
            }
            outcome = await coverArtCache.crawl(resources)
            if outcome == .incomplete {
                isIncomplete = true
                outcome = .finished
            }
            guard outcome == .finished else { break }
        }

        // A crawl that was canceled or replaced while its last batch returned
        // must not restore the marker its successor just cleared.
        guard coverArtCrawl?.id == id, isCurrentSession(session) else { return }
        switch outcome {
        case .finished where isIncomplete, .incomplete:
            // Left unmarked so the next library refresh retries what is missing.
            AppLog.cache.notice("Cover art crawl finished with covers left to retry")
        case .finished:
            AppLog.cache.info("Cover art crawl finished")
            coverArtCrawledServerKey = serverKey
        case .cacheFull:
            AppLog.cache.notice("Cover art crawl stopped because the disk cache is full")
            coverArtCrawledServerKey = serverKey
        case .failing:
            AppLog.cache.notice("Cover art crawl stopped after repeated download failures")
        case .cancelled:
            break
        }
    }
}
