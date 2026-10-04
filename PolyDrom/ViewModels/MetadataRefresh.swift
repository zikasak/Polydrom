import Foundation
import OSLog

extension AppCoordinator {
    func refreshMetadata(for requestedGeneration: UInt? = nil) async {
        let generation = requestedGeneration ?? sessionGeneration
        guard generation == sessionGeneration, metadataRefreshID == nil, let client, let serverKey else { return }
        let session = SessionIdentity(generation: generation, serverKey: serverKey)
        let wasOnline = isOnline
        let refreshID = UUID()
        AppLog.sync.info(
            "Metadata refresh requested (session \(generation, privacy: .public), cached library: \(self.hasCachedLibrary, privacy: .public))"
        )
        metadataRefreshID = refreshID
        isRefreshingMetadata = true
        defer {
            if metadataRefreshID == refreshID {
                metadataRefreshID = nil
                metadataSyncTask = nil
                isRefreshingMetadata = false
            }
        }

        do {
            if !isOnline {
                try await client.ping()
                guard isCurrentSession(session) else { return }
                isOnline = true
            }

            statusMessage = hasCachedLibrary
                ? "Checking library metadata…"
                : "Building local metadata cache…"
            let syncTask = Task {
                try await syncCoordinator.synchronize(client: client, serverKey: serverKey)
            }
            metadataSyncTask = syncTask
            let hadUnloadedChanges = hasUnloadedMetadataChanges
            hasUnloadedMetadataChanges = true
            let outcome = try await syncTask.value
            guard isCurrentSession(session) else { return }
            try await finishMetadataRefresh(outcome, hadUnloadedChanges: hadUnloadedChanges, session: session)
        } catch is CancellationError {
            AppLog.sync.debug("Metadata refresh canceled")
        } catch {
            guard isCurrentSession(session) else { return }
            await handleMetadataRefreshFailure(error, client: client, wasOnline: wasOnline, session: session)
        }
    }

    func setApplicationActive(_ isActive: Bool) {
        isApplicationActive = isActive
        metadataMonitorTask?.cancel()
        metadataMonitorTask = nil
        if !isActive {
            persistPlaybackState()
            scanRetryTask?.cancel()
            cancelMetadataRefresh()
            return
        }

        restartMetadataMonitor(refreshImmediately: true)
    }

    func restartMetadataMonitor(refreshImmediately: Bool) {
        metadataMonitorTask?.cancel()
        metadataMonitorTask = nil
        guard isApplicationActive, let refreshIntervalSeconds = metadataRefreshInterval.seconds else { return }

        metadataMonitorTask = Task { [weak self] in
            guard let self else { return }
            if refreshImmediately {
                await refreshMetadata()
            }
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(refreshIntervalSeconds))
                } catch {
                    return
                }
                await refreshMetadata()
            }
        }
    }

    func cancelMetadataRefresh() {
        metadataSyncTask?.cancel()
        metadataSyncTask = nil
        metadataRefreshID = nil
        isRefreshingMetadata = false
    }

    /// Shows what a completed sync changed, or schedules a retry when the server
    /// was scanning.
    private func finishMetadataRefresh(
        _ outcome: MetadataSyncOutcome,
        hadUnloadedChanges: Bool,
        session: SessionIdentity
    ) async throws {
        switch outcome {
        case .full:
            AppLog.sync.info("Metadata refresh completed with a full catalog sync")
            await reloadCachedLibrary(for: session.generation)
        case .metadataOnly:
            AppLog.sync.info("Metadata refresh completed with a metadata-only sync")
            await reloadCachedLibrary(for: session.generation)
        case .unchanged:
            AppLog.sync.info("Metadata refresh found no changes")
            if hadUnloadedChanges {
                await reloadCachedLibrary(for: session.generation)
            } else {
                // Nothing was written, so the loaded library is still current.
                let syncState = try await store.metadataSyncState(serverKey: session.serverKey)
                guard isCurrentSession(session) else { return }
                lastMetadataCheckAt = syncState.lastCheckedAt
            }
        case .deferredForScan:
            hasUnloadedMetadataChanges = hadUnloadedChanges
            AppLog.sync.info("Metadata refresh deferred because Navidrome is scanning")
            statusMessage = "Navidrome is scanning. Refresh will retry shortly."
            scheduleScanRetry(for: session)
            return
        }

        hasUnloadedMetadataChanges = false
        let didUpdateCatalog = outcome == .full
        statusMessage = metadataCompletionMessage(
            prefix: didUpdateCatalog ? "Library metadata updated" : "Library metadata is up to date"
        )
        startCoverArtCrawl(restart: didUpdateCatalog)
    }

    private func handleMetadataRefreshFailure(
        _ error: Error,
        client: NavidromeClient,
        wasOnline: Bool,
        session: SessionIdentity
    ) async {
        // Navidrome can stall or reject catalog requests while it rescans the
        // library, so confirm the server is really unreachable before going offline.
        if let changeState = try? await client.catalogChangeState(timeoutInterval: 10) {
            guard isCurrentSession(session) else { return }
            isOnline = true
            if changeState.isScanning || error is LibrarySyncError {
                AppLog.sync.info("Metadata refresh interrupted by a Navidrome scan; retrying later")
                statusMessage = "Navidrome is scanning. Refresh will retry shortly."
                scheduleScanRetry(for: session)
                return
            }
        } else {
            guard isCurrentSession(session) else { return }
            if !wasOnline || error is URLError {
                isOnline = false
            }
        }
        AppLog.sync.error("Metadata refresh failed: \(error.localizedDescription, privacy: .private)")
        statusMessage = hasCachedLibrary
            ? "Refresh failed — showing cached library. \(error.localizedDescription)"
            : error.localizedDescription
    }

    private func scheduleScanRetry(for session: SessionIdentity) {
        guard isApplicationActive else { return }
        scanRetryTask?.cancel()
        scanRetryTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(30))
            } catch {
                return
            }
            guard let self,
                  self.isCurrentSession(session),
                  self.isApplicationActive else { return }
            await self.refreshMetadata(for: session.generation)
        }
    }

    private func metadataCompletionMessage(prefix: String) -> String {
        let completedAt = lastMetadataCheckAt ?? Date()
        return "\(prefix) at \(completedAt.formatted(date: .omitted, time: .shortened))"
    }
}
