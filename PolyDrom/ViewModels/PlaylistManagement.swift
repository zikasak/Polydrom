import Foundation

struct PlaylistCreationRequest: Identifiable {
    let id = UUID()
    let songs: [NavidromeSong]
    let onSuccess: @MainActor () -> Void
}

/// A playlist change the server accepted, with the state to show if the
/// follow-up refresh fails.
private struct CommittedPlaylistChange {
    /// The playlist whose songs changed, if it still exists.
    let focusID: String?
    let fallbackPlaylists: [NavidromePlaylist]
    let fallbackSongs: [NavidromeSong]?
    let successMessage: String
}

extension AppCoordinator {
    func canEdit(_ playlist: NavidromePlaylist) -> Bool {
        guard isOnline, !isPlaylistMutating, !playlist.isReadOnly else { return false }
        guard let owner = playlist.owner, !owner.isEmpty else { return true }
        return owner == activeServer?.username
    }

    func requestPlaylistCreation(
        with songs: [NavidromeSong] = [],
        onSuccess: @escaping @MainActor () -> Void = {}
    ) {
        guard canCreatePlaylist else {
            statusMessage = "Connect to the server to create playlists."
            return
        }
        playlistCreationRequest = PlaylistCreationRequest(songs: songs, onSuccess: onSuccess)
    }

    func createPlaylist(name: String, songs: [NavidromeSong]) async -> Bool {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            statusMessage = "Enter a playlist name."
            return false
        }
        guard canCreatePlaylist, let client, let session = currentSession else {
            statusMessage = "Connect to the server to create playlists."
            return false
        }

        return await commitPlaylistChange(client: client, session: session) {
            try await client.createPlaylist(name: trimmedName, songIDs: songs.map(\.id))
        } describe: { created in
            CommittedPlaylistChange(
                focusID: created.id,
                fallbackPlaylists: playlists + [created],
                fallbackSongs: songs,
                successMessage: "Created \(trimmedName)"
            )
        }
    }

    func renamePlaylist(_ playlist: NavidromePlaylist, to name: String) async -> Bool {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            statusMessage = "Enter a playlist name."
            return false
        }
        guard canEdit(playlist), let client, let session = currentSession else {
            statusMessage = "This playlist cannot be edited."
            return false
        }

        return await commitPlaylistChange(client: client, session: session) {
            try await client.updatePlaylist(playlistID: playlist.id, name: trimmedName)
        } describe: { _ in
            let fallbackPlaylists = replacing(playlist, name: trimmedName)
            return CommittedPlaylistChange(
                focusID: playlist.id,
                fallbackPlaylists: fallbackPlaylists,
                fallbackSongs: try? await store.songs(serverKey: session.serverKey, playlistID: playlist.id),
                successMessage: "Renamed playlist"
            )
        }
    }

    func addSongs(_ songs: [NavidromeSong], to playlist: NavidromePlaylist) async -> Bool {
        guard !songs.isEmpty else { return false }
        guard canEdit(playlist), let client, let session = currentSession else {
            statusMessage = "This playlist cannot be edited."
            return false
        }

        return await commitPlaylistChange(client: client, session: session) {
            try await client.updatePlaylist(playlistID: playlist.id, songIDsToAdd: songs.map(\.id))
        } describe: { _ in
            let existingSongs = (try? await store.songs(
                serverKey: session.serverKey,
                playlistID: playlist.id
            )) ?? []
            return CommittedPlaylistChange(
                focusID: playlist.id,
                fallbackPlaylists: replacing(
                    playlist,
                    songCount: (playlist.songCount ?? existingSongs.count) + songs.count
                ),
                fallbackSongs: existingSongs + songs,
                successMessage: songs.count == 1
                    ? "Added to \(playlist.name)"
                    : "Added \(songs.count) songs to \(playlist.name)"
            )
        }
    }

    func removeSongs(
        at indices: IndexSet,
        from playlist: NavidromePlaylist,
        expectedSnapshotRevision: UUID? = nil
    ) async -> Bool {
        if let expectedSnapshotRevision, expectedSnapshotRevision != playlistSongsSnapshot.revision {
            statusMessage = "Playlist changed. Select the songs again."
            return false
        }
        let validIndices = IndexSet(indices.filter { playlistSongs.indices.contains($0) })
        guard !validIndices.isEmpty else { return false }
        guard canEdit(playlist), selectedPlaylist?.id == playlist.id, let client, let session = currentSession else {
            statusMessage = "This playlist cannot be edited."
            return false
        }

        return await commitPlaylistChange(client: client, session: session) {
            try await client.updatePlaylist(
                playlistID: playlist.id,
                indicesToRemove: Array(validIndices)
            )
        } describe: { _ in
            let remainingSongs = playlistSongs.enumerated().compactMap { index, song in
                validIndices.contains(index) ? nil : song
            }
            return CommittedPlaylistChange(
                focusID: playlist.id,
                fallbackPlaylists: replacing(playlist, songCount: remainingSongs.count),
                fallbackSongs: remainingSongs,
                successMessage: validIndices.count == 1
                    ? "Removed song from \(playlist.name)"
                    : "Removed \(validIndices.count) songs from \(playlist.name)"
            )
        }
    }

    func deletePlaylist(_ playlist: NavidromePlaylist) async -> Bool {
        guard canEdit(playlist), let client, let session = currentSession else {
            statusMessage = "This playlist cannot be deleted."
            return false
        }

        return await commitPlaylistChange(client: client, session: session) {
            try await client.deletePlaylist(id: playlist.id)
        } describe: { _ in
            CommittedPlaylistChange(
                focusID: nil,
                fallbackPlaylists: playlists.filter { $0.id != playlist.id },
                fallbackSongs: nil,
                successMessage: "Deleted \(playlist.name)"
            )
        }
    }

    /// Sends a playlist change to the server, then brings the cache and the UI in
    /// line with it. Returns whether the server accepted the change; a session
    /// that ended in the meantime still counts, as the change was made.
    private func commitPlaylistChange<Response>(
        client: NavidromeClient,
        session: SessionIdentity,
        send: () async throws -> Response,
        describe: (Response) async -> CommittedPlaylistChange
    ) async -> Bool {
        isPlaylistMutating = true
        defer { isPlaylistMutating = false }

        do {
            let response = try await send()
            guard isCurrentSession(session) else { return true }
            await finishCommittedPlaylistChange(await describe(response), session: session, client: client)
            return true
        } catch {
            guard isCurrentSession(session) else { return false }
            statusMessage = error.localizedDescription
            return false
        }
    }

    private func finishCommittedPlaylistChange(
        _ change: CommittedPlaylistChange,
        session: SessionIdentity,
        client: NavidromeClient
    ) async {
        do {
            try await reconcilePlaylistState(focusID: change.focusID, session: session, client: client)
            guard isCurrentSession(session) else { return }
            statusMessage = change.successMessage
        } catch {
            guard isCurrentSession(session) else { return }
            await applyPlaylistFallback(change, session: session)
            statusMessage = "Playlist saved, but refresh failed. \(error.localizedDescription)"
            schedulePlaylistReconciliation(for: session)
        }
    }

    private func reconcilePlaylistState(
        focusID: String?,
        session: SessionIdentity,
        client: NavidromeClient
    ) async throws {
        let remotePlaylists = try await client.playlists()
        var refreshed: [PlaylistMetadataSnapshot] = []
        if let focusID, let playlist = remotePlaylists.first(where: { $0.id == focusID }) {
            refreshed = [
                PlaylistMetadataSnapshot(
                    playlist: playlist,
                    songs: try await client.songs(for: playlist)
                )
            ]
        }
        try Task.checkCancellation()
        guard isCurrentSession(session) else { return }
        try await store.applyPlaylistMetadata(
            playlists: remotePlaylists,
            refreshedPlaylists: refreshed,
            serverKey: session.serverKey
        )
        try await loadReconciledPlaylistState(
            focusID: focusID,
            focusSongs: refreshed.first?.songs,
            session: session
        )
    }

    private func applyPlaylistFallback(_ change: CommittedPlaylistChange, session: SessionIdentity) async {
        let refreshed: PlaylistMetadataSnapshot?
        if let focusID = change.focusID,
           let playlist = change.fallbackPlaylists.first(where: { $0.id == focusID }),
           let songs = change.fallbackSongs {
            refreshed = PlaylistMetadataSnapshot(playlist: playlist, songs: songs)
        } else {
            refreshed = nil
        }
        try? await store.applyPlaylistMetadata(
            playlists: change.fallbackPlaylists,
            refreshedPlaylists: refreshed.map { [$0] } ?? [],
            serverKey: session.serverKey
        )
        try? await loadReconciledPlaylistState(
            focusID: change.focusID,
            focusSongs: change.fallbackSongs,
            session: session
        )
    }

    private func loadReconciledPlaylistState(
        focusID: String?,
        focusSongs: [NavidromeSong]?,
        session: SessionIdentity
    ) async throws {
        let loadedPlaylists = try await store.playlists(serverKey: session.serverKey)
        guard isCurrentSession(session) else { return }
        playlists = loadedPlaylists

        if let selectedID = selectedPlaylist?.id {
            selectedPlaylist = loadedPlaylists.first(where: { $0.id == selectedID })
            if selectedPlaylist == nil {
                playlistSongs = []
                loadedPlaylistSongsID = nil
            } else if focusID == selectedID, let focusSongs {
                await warmCachedSongCovers(focusSongs)
                guard isCurrentSession(session) else { return }
                playlistSongs = focusSongs
                loadedPlaylistSongsID = selectedID
                prefetchSongCovers(focusSongs)
            }
        }
    }

    private func schedulePlaylistReconciliation(for session: SessionIdentity) {
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard let self, self.isCurrentSession(session) else { return }
            await self.refreshMetadata(for: session.generation)
        }
    }

    /// The loaded playlists with `playlist` updated as the server is expected to
    /// have changed it.
    private func replacing(
        _ playlist: NavidromePlaylist,
        name: String? = nil,
        songCount: Int? = nil
    ) -> [NavidromePlaylist] {
        let updated = NavidromePlaylist(
            id: playlist.id,
            name: name ?? playlist.name,
            songCount: songCount ?? playlist.songCount,
            owner: playlist.owner,
            changed: Date(),
            isReadOnly: playlist.isReadOnly
        )
        return playlists.map { $0.id == playlist.id ? updated : $0 }
    }
}
