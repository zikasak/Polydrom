//
//  ServerConnection.swift
//  PolyDrom
//

import Foundation
import OSLog

extension AppCoordinator {
    func connect(_ profile: ServerProfile) async {
        guard let nextClient = clientFactory(profile) else {
            AppLog.app.error("Could not create a client for the configured server")
            statusMessage = "Enter a valid server address."
            return
        }

        sessionGeneration &+= 1
        let generation = sessionGeneration
        AppLog.app.info(
            "Connecting to server \(profile.serverKey, privacy: .private(mask: .hash)) (session \(generation, privacy: .public))"
        )
        let previousServerKey = activeServer?.serverKey
        cancelMetadataRefresh()
        scanRetryTask?.cancel()
        if previousServerKey != profile.serverKey {
            clearRemoteLibraryState()
            if previousServerKey != nil
                || (pendingPlaybackRestore?.serverKey != nil
                    && pendingPlaybackRestore?.serverKey != profile.serverKey) {
                clearPlaybackState()
            }
            playbackReporter.disconnect()
        }
        activeServer = profile
        client = nextClient
        isOnline = false
        serverAddress = profile.address
        username = profile.username
        password = profile.password
        await reloadCachedLibrary(for: generation)

        isBusy = true
        defer { isBusy = false }

        do {
            try await nextClient.ping()
            guard isCurrentSession(generation, serverKey: profile.serverKey) else { return }
            let reportingMode = await playbackReportingMode(using: nextClient)
            guard isCurrentSession(generation, serverKey: profile.serverKey) else { return }
            playbackReporter.connect(client: nextClient, serverKey: profile.serverKey, mode: reportingMode)
            isOnline = true
            AppLog.app.info("Connected to server (session \(generation, privacy: .public))")
            try serverRegistry.touch(profile)
            loadServers()
            await restorePersistedPlaybackIfNeeded(for: generation)
            await refreshMetadata(for: generation)
        } catch {
            guard isCurrentSession(generation, serverKey: profile.serverKey) else { return }
            isOnline = false
            AppLog.app.error(
                "Connection failed for server \(profile.serverKey, privacy: .private(mask: .hash)): \(error.localizedDescription, privacy: .private)"
            )
            statusMessage = hasCachedLibrary
                ? "Offline — showing cached library. \(error.localizedDescription)"
                : error.localizedDescription
        }
    }

    private func playbackReportingMode(using client: NavidromeClient) async -> PlaybackReportingMode {
        do {
            let extensions = try await client.openSubsonicExtensions()
            let supportsPlaybackReport = extensions.contains {
                $0.name.caseInsensitiveCompare("playbackReport") == .orderedSame
                    && $0.supports(version: 1)
            }
            return supportsPlaybackReport ? .modern : .legacy
        } catch {
            AppLog.playback.debug(
                "Playback-report capability discovery failed; using legacy reporting: \(error.localizedDescription, privacy: .private)"
            )
            return .legacy
        }
    }
}
