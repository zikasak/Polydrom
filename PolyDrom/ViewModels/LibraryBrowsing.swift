import Foundation

extension AppCoordinator {
    func loadArtists() async {
        let generation = sessionGeneration
        guard let serverKey else { return }
        isBusy = true
        defer { isBusy = false }

        do {
            let loadedArtists = try await store.artists(serverKey: serverKey)
            await warmCachedArtistCovers(loadedArtists)
            guard isCurrentSession(generation, serverKey: serverKey) else { return }
            artists = sortedVisibleArtists(loadedArtists)
            prefetchArtistCovers(loadedArtists)
            statusMessage = artists.isEmpty ? "No cached artists." : "Loaded \(artists.count) artists"
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func loadGenres() async {
        let generation = sessionGeneration
        guard let serverKey else { return }
        isBusy = true
        defer { isBusy = false }

        do {
            let loadedGenres = try await store.genres(serverKey: serverKey)
            guard isCurrentSession(generation, serverKey: serverKey) else { return }
            genres = loadedGenres
            statusMessage = loadedGenres.isEmpty ? "No genres in this library." : "Loaded \(loadedGenres.count) genres"
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func loadPlaylists() async {
        let generation = sessionGeneration
        guard let serverKey else { return }
        isBusy = true
        defer { isBusy = false }

        do {
            let loadedPlaylists = try await store.playlists(serverKey: serverKey)
            guard isCurrentSession(generation, serverKey: serverKey) else { return }
            playlists = loadedPlaylists
            statusMessage = playlists.isEmpty ? "No cached playlists." : "Loaded playlists"
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func loadSongs(for genre: NavidromeGenre, force: Bool = false) async {
        let generation = sessionGeneration
        guard let serverKey else { return }
        if !force, loadedGenreSongsID == genre.id {
            selectedGenre = genre
            return
        }

        selectedGenre = genre
        genreSongs = []
        loadedGenreSongsID = nil
        isBusy = true
        defer { isBusy = false }

        do {
            let songs = try await store.songs(serverKey: serverKey, genreID: genre.id)
            await warmCachedSongCovers(songs)
            guard !Task.isCancelled, isCurrentSession(generation, serverKey: serverKey) else { return }
            genreSongs = songs
            loadedGenreSongsID = genre.id
            prefetchSongCovers(songs)
            statusMessage = songs.isEmpty ? "No songs for \(genre.name)." : "Loaded \(genre.name)"
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func sortedVisibleArtists(_ artists: [NavidromeArtist]) -> [NavidromeArtist] {
        artists
            .filter { ($0.albumCount ?? 0) > 0 }
            .sorted {
                $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
    }
}
