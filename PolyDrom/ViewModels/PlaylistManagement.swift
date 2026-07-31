import Foundation

struct PlaylistCreationRequest: Identifiable {
    let id = UUID()
    let songs: [NavidromeSong]
    let onSuccess: @MainActor () -> Void
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
        guard canCreatePlaylist, let client, let serverKey else {
            statusMessage = "Connect to the server to create playlists."
            return false
        }

        let generation = sessionGeneration
        isPlaylistMutating = true
        defer { isPlaylistMutating = false }

        do {
            let created = try await client.createPlaylist(name: trimmedName, songIDs: songs.map(\.id))
            guard isCurrentSession(generation, serverKey: serverKey) else { return true }
            await finishCommittedPlaylistMutation(
                focusID: created.id,
                fallbackPlaylists: playlists + [created],
                fallbackSongs: songs,
                successMessage: "Created \(trimmedName)",
                generation: generation,
                serverKey: serverKey,
                client: client
            )
            return true
        } catch {
            guard isCurrentSession(generation, serverKey: serverKey) else { return false }
            statusMessage = error.localizedDescription
            return false
        }
    }

    func renamePlaylist(_ playlist: NavidromePlaylist, to name: String) async -> Bool {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            statusMessage = "Enter a playlist name."
            return false
        }
        guard canEdit(playlist), let client, let serverKey else {
            statusMessage = "This playlist cannot be edited."
            return false
        }

        let generation = sessionGeneration
        isPlaylistMutating = true
        defer { isPlaylistMutating = false }

        do {
            try await client.updatePlaylist(playlistID: playlist.id, name: trimmedName)
            guard isCurrentSession(generation, serverKey: serverKey) else { return true }
            let updated = replacingPlaylist(playlist, name: trimmedName)
            let fallback = playlists.map { $0.id == playlist.id ? updated : $0 }
            let songs = try? await store.songs(serverKey: serverKey, playlistID: playlist.id)
            await finishCommittedPlaylistMutation(
                focusID: playlist.id,
                fallbackPlaylists: fallback,
                fallbackSongs: songs,
                successMessage: "Renamed playlist",
                generation: generation,
                serverKey: serverKey,
                client: client
            )
            return true
        } catch {
            guard isCurrentSession(generation, serverKey: serverKey) else { return false }
            statusMessage = error.localizedDescription
            return false
        }
    }

    func addSongs(_ songs: [NavidromeSong], to playlist: NavidromePlaylist) async -> Bool {
        guard !songs.isEmpty else { return false }
        guard canEdit(playlist), let client, let serverKey else {
            statusMessage = "This playlist cannot be edited."
            return false
        }

        let generation = sessionGeneration
        isPlaylistMutating = true
        defer { isPlaylistMutating = false }

        do {
            try await client.updatePlaylist(playlistID: playlist.id, songIDsToAdd: songs.map(\.id))
            guard isCurrentSession(generation, serverKey: serverKey) else { return true }
            let existingSongs = (try? await store.songs(
                serverKey: serverKey,
                playlistID: playlist.id
            )) ?? []
            let updated = replacingPlaylist(
                playlist,
                songCount: (playlist.songCount ?? existingSongs.count) + songs.count
            )
            let fallback = playlists.map { $0.id == playlist.id ? updated : $0 }
            let message = songs.count == 1
                ? "Added to \(playlist.name)"
                : "Added \(songs.count) songs to \(playlist.name)"
            await finishCommittedPlaylistMutation(
                focusID: playlist.id,
                fallbackPlaylists: fallback,
                fallbackSongs: existingSongs + songs,
                successMessage: message,
                generation: generation,
                serverKey: serverKey,
                client: client
            )
            return true
        } catch {
            guard isCurrentSession(generation, serverKey: serverKey) else { return false }
            statusMessage = error.localizedDescription
            return false
        }
    }

    func removeSongs(at indices: IndexSet, from playlist: NavidromePlaylist) async -> Bool {
        let validIndices = IndexSet(indices.filter { playlistSongs.indices.contains($0) })
        guard !validIndices.isEmpty else { return false }
        guard canEdit(playlist), selectedPlaylist?.id == playlist.id, let client, let serverKey else {
            statusMessage = "This playlist cannot be edited."
            return false
        }

        let generation = sessionGeneration
        isPlaylistMutating = true
        defer { isPlaylistMutating = false }

        do {
            try await client.updatePlaylist(
                playlistID: playlist.id,
                indicesToRemove: Array(validIndices)
            )
            guard isCurrentSession(generation, serverKey: serverKey) else { return true }
            let remainingSongs = playlistSongs.enumerated().compactMap { index, song in
                validIndices.contains(index) ? nil : song
            }
            let updated = replacingPlaylist(playlist, songCount: remainingSongs.count)
            let fallback = playlists.map { $0.id == playlist.id ? updated : $0 }
            let message = validIndices.count == 1
                ? "Removed song from \(playlist.name)"
                : "Removed \(validIndices.count) songs from \(playlist.name)"
            await finishCommittedPlaylistMutation(
                focusID: playlist.id,
                fallbackPlaylists: fallback,
                fallbackSongs: remainingSongs,
                successMessage: message,
                generation: generation,
                serverKey: serverKey,
                client: client
            )
            return true
        } catch {
            guard isCurrentSession(generation, serverKey: serverKey) else { return false }
            statusMessage = error.localizedDescription
            return false
        }
    }

    func deletePlaylist(_ playlist: NavidromePlaylist) async -> Bool {
        guard canEdit(playlist), let client, let serverKey else {
            statusMessage = "This playlist cannot be deleted."
            return false
        }

        let generation = sessionGeneration
        isPlaylistMutating = true
        defer { isPlaylistMutating = false }

        do {
            try await client.deletePlaylist(id: playlist.id)
            guard isCurrentSession(generation, serverKey: serverKey) else { return true }
            await finishCommittedPlaylistMutation(
                focusID: nil,
                fallbackPlaylists: playlists.filter { $0.id != playlist.id },
                fallbackSongs: nil,
                successMessage: "Deleted \(playlist.name)",
                generation: generation,
                serverKey: serverKey,
                client: client
            )
            return true
        } catch {
            guard isCurrentSession(generation, serverKey: serverKey) else { return false }
            statusMessage = error.localizedDescription
            return false
        }
    }

    private func finishCommittedPlaylistMutation(
        focusID: String?,
        fallbackPlaylists: [NavidromePlaylist],
        fallbackSongs: [NavidromeSong]?,
        successMessage: String,
        generation: UInt,
        serverKey: String,
        client: NavidromeClient
    ) async {
        do {
            try await reconcilePlaylistState(
                focusID: focusID,
                generation: generation,
                serverKey: serverKey,
                client: client
            )
            guard isCurrentSession(generation, serverKey: serverKey) else { return }
            statusMessage = successMessage
        } catch {
            guard isCurrentSession(generation, serverKey: serverKey) else { return }
            await applyPlaylistFallback(
                playlists: fallbackPlaylists,
                focusID: focusID,
                songs: fallbackSongs,
                generation: generation,
                serverKey: serverKey
            )
            statusMessage = "Playlist saved, but refresh failed. \(error.localizedDescription)"
            schedulePlaylistReconciliation(generation: generation, serverKey: serverKey)
        }
    }

    private func reconcilePlaylistState(
        focusID: String?,
        generation: UInt,
        serverKey: String,
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
        guard isCurrentSession(generation, serverKey: serverKey) else { return }
        try await store.applyPlaylistMetadata(
            playlists: remotePlaylists,
            refreshedPlaylists: refreshed,
            serverKey: serverKey
        )
        try await loadReconciledPlaylistState(
            focusID: focusID,
            focusSongs: refreshed.first?.songs,
            generation: generation,
            serverKey: serverKey
        )
    }

    private func applyPlaylistFallback(
        playlists: [NavidromePlaylist],
        focusID: String?,
        songs: [NavidromeSong]?,
        generation: UInt,
        serverKey: String
    ) async {
        let refreshed: PlaylistMetadataSnapshot?
        if let focusID,
           let playlist = playlists.first(where: { $0.id == focusID }),
           let songs {
            refreshed = PlaylistMetadataSnapshot(playlist: playlist, songs: songs)
        } else {
            refreshed = nil
        }
        try? await store.applyPlaylistMetadata(
            playlists: playlists,
            refreshedPlaylists: refreshed.map { [$0] } ?? [],
            serverKey: serverKey
        )
        try? await loadReconciledPlaylistState(
            focusID: focusID,
            focusSongs: songs,
            generation: generation,
            serverKey: serverKey
        )
    }

    private func loadReconciledPlaylistState(
        focusID: String?,
        focusSongs: [NavidromeSong]?,
        generation: UInt,
        serverKey: String
    ) async throws {
        let loadedPlaylists = try await store.playlists(serverKey: serverKey)
        guard isCurrentSession(generation, serverKey: serverKey) else { return }
        playlists = loadedPlaylists

        if let selectedID = selectedPlaylist?.id {
            selectedPlaylist = loadedPlaylists.first(where: { $0.id == selectedID })
            if selectedPlaylist == nil {
                playlistSongs = []
                loadedPlaylistSongsID = nil
            } else if focusID == selectedID, let focusSongs {
                await warmCachedSongCovers(focusSongs)
                guard isCurrentSession(generation, serverKey: serverKey) else { return }
                playlistSongs = focusSongs
                loadedPlaylistSongsID = selectedID
                prefetchSongCovers(focusSongs)
            }
        }
    }

    private func schedulePlaylistReconciliation(generation: UInt, serverKey: String) {
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard let self, self.isCurrentSession(generation, serverKey: serverKey) else { return }
            await self.refreshMetadata(for: generation)
        }
    }

    private func replacingPlaylist(
        _ playlist: NavidromePlaylist,
        name: String? = nil,
        songCount: Int? = nil
    ) -> NavidromePlaylist {
        NavidromePlaylist(
            id: playlist.id,
            name: name ?? playlist.name,
            songCount: songCount ?? playlist.songCount,
            owner: playlist.owner,
            changed: Date(),
            isReadOnly: playlist.isReadOnly
        )
    }
}
