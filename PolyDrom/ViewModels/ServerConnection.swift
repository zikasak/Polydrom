//
//  ServerConnection.swift
//  PolyDrom
//

import Foundation
import OSLog

extension AppCoordinator {
    func loadServers() {
        do {
            try serverRegistry.importLegacyServersIfNeeded(from: store)
            servers = try serverRegistry.servers()
            if let latest = servers.first, activeServer == nil {
                serverAddress = latest.address
                username = latest.username
                password = latest.password
            }
            AppLog.app.info("Loaded \(self.servers.count, privacy: .public) server profiles")
        } catch {
            AppLog.app.error("Failed to load server profiles: \(error.localizedDescription, privacy: .private)")
            statusMessage = error.localizedDescription
        }
    }

    func connectFromForm() async {
        do {
            let profile = try serverRegistry.save(address: serverAddress, username: username, password: password)
            AppLog.app.info("Connecting using the server profile saved from settings")
            await connect(profile)
        } catch {
            AppLog.app.error("Could not save server profile: \(error.localizedDescription, privacy: .private)")
            statusMessage = error.localizedDescription
        }
    }

    func connectToLatestServer() async {
        guard !didAttemptInitialConnection, !isConnected, !isBusy else { return }
        didAttemptInitialConnection = true

        if servers.isEmpty {
            loadServers()
        }

        guard let latest = servers.first else { return }
        AppLog.app.info("Attempting automatic connection to the latest server")
        statusMessage = "Connecting to \(latest.displayName)..."
        await connect(latest)
    }

    func takeFirstRunSettingsPresentationRequest() -> Bool {
        guard servers.isEmpty, !didRequestFirstRunSettings else { return false }
        didRequestFirstRunSettings = true
        return true
    }

    func deleteServer(_ profile: ServerProfile) {
        AppLog.app.info("Deleting server profile \(profile.id.uuidString, privacy: .public)")
        let refreshToDrain: Task<MetadataSyncOutcome, Error>?
        if activeServer?.id == profile.id {
            sessionGeneration &+= 1
            refreshToDrain = metadataSyncTask
            metadataMonitorTask?.cancel()
            cancelMetadataRefresh()
            scanRetryTask?.cancel()
        } else {
            refreshToDrain = nil
        }

        do {
            try serverRegistry.delete(profile)
            try store.purgeLibrary(serverKey: profile.serverKey)
            if activeServer?.id == profile.id {
                clearPlaybackState()
                playbackReporter.disconnect()
                activeServer = nil
                client = nil
                isOnline = false
                hasCachedLibrary = false
                clearRemoteLibraryState()
            }
            loadServers()
            if let refreshToDrain {
                Task { [weak self] in
                    _ = try? await refreshToDrain.value
                    guard let self else { return }
                    // A background reconciliation that was already committing
                    // when cancellation arrived must not recreate this profile's cache.
                    try? self.store.purgeLibrary(serverKey: profile.serverKey)
                    self.loadServers()
                }
            }
        } catch {
            AppLog.app.error("Failed to delete server profile: \(error.localizedDescription, privacy: .private)")
            statusMessage = error.localizedDescription
        }
    }

    func connect(_ profile: ServerProfile) async {
        guard let nextClient = clientFactory(profile) else {
            AppLog.app.error("Could not create a client for the configured server")
            statusMessage = "Enter a valid server address."
            return
        }

        sessionGeneration &+= 1
        let session = SessionIdentity(generation: sessionGeneration, serverKey: profile.serverKey)
        AppLog.app.info(
            "Connecting to server \(profile.serverKey, privacy: .private(mask: .hash)) (session \(session.generation, privacy: .public))"
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
        await reloadCachedLibrary(for: session.generation)

        isBusy = true
        defer { isBusy = false }

        do {
            try await nextClient.ping()
            guard isCurrentSession(session) else { return }
            let extensions = await openSubsonicExtensions(using: nextClient)
            guard isCurrentSession(session) else { return }
            playbackReporter.connect(
                client: nextClient,
                serverKey: profile.serverKey,
                mode: extensions.supports("playbackReport") ? .modern : .legacy
            )
            supportsSonicSimilarity = extensions.supports("sonicSimilarity")
            supportsTranscodeDecisions = extensions.supports("transcoding")
            isOnline = true
            AppLog.app.info("Connected to server (session \(session.generation, privacy: .public))")
            try serverRegistry.touch(profile)
            loadServers()
            await restorePersistedPlaybackIfNeeded(for: session)
            await refreshMetadata(for: session.generation)
        } catch {
            guard isCurrentSession(session) else { return }
            isOnline = false
            AppLog.app.error(
                "Connection failed for server \(profile.serverKey, privacy: .private(mask: .hash)): \(error.localizedDescription, privacy: .private)"
            )
            statusMessage = hasCachedLibrary
                ? "Offline — showing cached library. \(error.localizedDescription)"
                : error.localizedDescription
        }
    }

    private func openSubsonicExtensions(using client: NavidromeClient) async -> [OpenSubsonicExtension] {
        do {
            return try await client.openSubsonicExtensions()
        } catch {
            AppLog.app.debug(
                "Capability discovery failed; assuming no OpenSubsonic extensions: \(error.localizedDescription, privacy: .private)"
            )
            return []
        }
    }
}
