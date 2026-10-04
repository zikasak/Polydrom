import Foundation

extension AppCoordinator {
    // MARK: - Sections

    func loadHome() async {
        await loadFromCache { session in
            let home = try await store.homeMetadata(serverKey: session.serverKey)
            let allAlbums = home.recentlyAdded + home.recentlyPlayed + home.random + home.featured
            await warmCachedAlbumCovers(allAlbums)
            guard !Task.isCancelled, isCurrentSession(session) else { return }

            showHome(home)
            prefetchAlbumCovers(allAlbums)
            if allAlbums.isEmpty {
                statusMessage = "No cached albums for Home."
            }
        }
    }

    func search() async {
        guard serverKey != nil else {
            statusMessage = "Select a library first."
            return
        }

        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            searchResults = []
            statusMessage = "Enter a search term."
            return
        }

        await loadFromCache { session in
            let results = try await store.searchSongs(query, serverKey: session.serverKey)
            await warmCachedSongCovers(results)
            guard isCurrentSession(session) else { return }
            searchResults = results
            prefetchSongCovers(results)
            statusMessage = results.isEmpty ? "No songs found." : "\(results.count) songs found"
        }
    }

    func loadRandomSongs() async {
        await loadFromCache { session in
            let songs = try await store.randomSongs(serverKey: session.serverKey, count: 50)
            await warmCachedSongCovers(songs)
            guard isCurrentSession(session) else { return }
            randomSongs = songs
            prefetchSongCovers(songs)
            statusMessage = songs.isEmpty ? "No random songs returned." : "Loaded random songs"
        }
    }

    func loadAlbums() async {
        await loadFromCache { session in
            let loadedAlbums = try await store.albums(serverKey: session.serverKey)
            await warmCachedAlbumCovers(loadedAlbums)
            guard isCurrentSession(session) else { return }
            albums = loadedAlbums
            prefetchAlbumCovers(loadedAlbums)
            statusMessage = loadedAlbums.isEmpty ? "No cached albums." : "Loaded \(loadedAlbums.count) albums"
        }
    }

    func loadArtists() async {
        await loadFromCache { session in
            let loadedArtists = try await store.artists(serverKey: session.serverKey)
            await warmCachedArtistCovers(loadedArtists)
            guard isCurrentSession(session) else { return }
            artists = sortedVisibleArtists(loadedArtists)
            prefetchArtistCovers(loadedArtists)
            statusMessage = artists.isEmpty ? "No cached artists." : "Loaded \(artists.count) artists"
        }
    }

    func loadGenres() async {
        await loadFromCache { session in
            let loadedGenres = try await store.genres(serverKey: session.serverKey)
            guard isCurrentSession(session) else { return }
            genres = loadedGenres
            statusMessage = loadedGenres.isEmpty ? "No genres in this library." : "Loaded \(loadedGenres.count) genres"
        }
    }

    func loadPlaylists() async {
        await loadFromCache { session in
            let loadedPlaylists = try await store.playlists(serverKey: session.serverKey)
            guard isCurrentSession(session) else { return }
            playlists = loadedPlaylists
            statusMessage = loadedPlaylists.isEmpty ? "No cached playlists." : "Loaded playlists"
        }
    }

    func refreshRecentSongs() async throws {
        guard let session = currentSession else { return }
        let loadedRecentSongs = try await store.recentSongs(serverKey: session.serverKey)
        await warmCachedSongCovers(loadedRecentSongs)
        guard isCurrentSession(session) else { return }
        recentSongs = loadedRecentSongs
        prefetchSongCovers(loadedRecentSongs)
    }

    // MARK: - Detail pages

    func loadAlbums(for artist: NavidromeArtist, force: Bool = false) async {
        guard serverKey != nil else { return }
        if !force, loadedArtistAlbumsID == artist.id {
            if selectedArtist?.id != artist.id {
                selectedArtist = artist
            }
            return
        }

        selectedArtist = artist
        selectedAlbum = nil
        artistAlbums = []
        albumSongs = []
        loadedArtistAlbumsID = nil
        loadedAlbumSongsID = nil

        await loadFromCache { session in
            let albums = try await store.albums(serverKey: session.serverKey, artistID: artist.id)
            await warmCachedAlbumCovers(albums)
            artistAlbums = albums
            guard !Task.isCancelled, isCurrentSession(session) else { return }
            loadedArtistAlbumsID = artist.id
            prefetchAlbumCovers(albums)
            statusMessage = albums.isEmpty ? "No albums for \(artist.name)." : "Loaded \(artist.name)"
        }
    }

    func loadSongs(for album: NavidromeAlbum, force: Bool = false) async {
        guard serverKey != nil else { return }
        if !force, loadedAlbumSongsID == album.id {
            if selectedAlbum?.id != album.id {
                selectedAlbum = album
            }
            return
        }

        selectedAlbum = album
        albumSongs = []
        loadedAlbumSongsID = nil

        await loadFromCache { session in
            let songs = try await store.songs(serverKey: session.serverKey, albumID: album.id)
            await warmCachedSongCovers(songs)
            albumSongs = songs
            guard !Task.isCancelled, isCurrentSession(session) else { return }
            loadedAlbumSongsID = album.id
            prefetchSongCovers(songs)
            statusMessage = songs.isEmpty ? "No songs for \(album.name)." : "Loaded \(album.name)"
        }
    }

    func loadSongs(for playlist: NavidromePlaylist, force: Bool = false) async {
        guard serverKey != nil else { return }
        if !force, loadedPlaylistSongsID == playlist.id {
            selectedPlaylist = playlist
            return
        }

        selectedPlaylist = playlist
        playlistSongs = []
        loadedPlaylistSongsID = nil

        await loadFromCache { session in
            let songs = try await store.songs(serverKey: session.serverKey, playlistID: playlist.id)
            await warmCachedSongCovers(songs)
            playlistSongs = songs
            guard !Task.isCancelled, isCurrentSession(session) else { return }
            loadedPlaylistSongsID = playlist.id
            prefetchSongCovers(songs)
            statusMessage = songs.isEmpty ? "No songs for \(playlist.name)." : "Loaded \(playlist.name)"
        }
    }

    func loadSongs(for genre: NavidromeGenre, force: Bool = false) async {
        guard serverKey != nil else { return }
        if !force, loadedGenreSongsID == genre.id {
            selectedGenre = genre
            return
        }

        selectedGenre = genre
        genreSongs = []
        loadedGenreSongsID = nil

        await loadFromCache { session in
            let songs = try await store.songs(serverKey: session.serverKey, genreID: genre.id)
            await warmCachedSongCovers(songs)
            guard !Task.isCancelled, isCurrentSession(session) else { return }
            genreSongs = songs
            loadedGenreSongsID = genre.id
            prefetchSongCovers(songs)
            statusMessage = songs.isEmpty ? "No songs for \(genre.name)." : "Loaded \(genre.name)"
        }
    }

    // MARK: - Whole library

    func reloadCachedLibrary(for requestedGeneration: UInt? = nil) async {
        guard let serverKey else { return }
        let session = SessionIdentity(generation: requestedGeneration ?? sessionGeneration, serverKey: serverKey)
        do {
            let syncState = try await store.metadataSyncState(serverKey: serverKey)
            guard isCurrentSession(session) else { return }
            hasCachedLibrary = syncState.isComplete
            lastMetadataCheckAt = syncState.lastCheckedAt
            guard syncState.isComplete else { return }

            async let artistsRequest = store.artists(serverKey: serverKey)
            async let albumsRequest = store.albums(serverKey: serverKey)
            async let genresRequest = store.genres(serverKey: serverKey)
            async let playlistsRequest = store.playlists(serverKey: serverKey)
            async let homeRequest = store.homeMetadata(serverKey: serverKey)
            async let favoritesRequest = cachedFavorites(serverKey: serverKey)
            async let recentRequest = store.recentSongs(serverKey: serverKey)

            let (loadedArtists, loadedAlbums, loadedGenres, loadedPlaylists, home, favorites, loadedRecentSongs) = try await (
                artistsRequest,
                albumsRequest,
                genresRequest,
                playlistsRequest,
                homeRequest,
                favoritesRequest,
                recentRequest
            )
            guard isCurrentSession(session) else { return }
            artists = sortedVisibleArtists(loadedArtists)
            albums = loadedAlbums
            genres = loadedGenres
            playlists = loadedPlaylists
            showHome(home)
            showFavorites(favorites)
            recentSongs = loadedRecentSongs

            if let selectedArtist {
                artistAlbums = try await store.albums(serverKey: serverKey, artistID: selectedArtist.id)
                loadedArtistAlbumsID = selectedArtist.id
            }
            if let selectedAlbum {
                albumSongs = try await store.songs(serverKey: serverKey, albumID: selectedAlbum.id)
                loadedAlbumSongsID = selectedAlbum.id
            }
            if let selectedPlaylist {
                playlistSongs = try await store.songs(serverKey: serverKey, playlistID: selectedPlaylist.id)
                loadedPlaylistSongsID = selectedPlaylist.id
            }
            if let selectedGenre {
                genreSongs = try await store.songs(serverKey: serverKey, genreID: selectedGenre.id)
                loadedGenreSongsID = selectedGenre.id
            }
        } catch {
            guard isCurrentSession(session) else { return }
            statusMessage = error.localizedDescription
        }
    }

    // MARK: - Navigation

    /// The fullest known version of the album a song belongs to, falling back
    /// to what the song itself says about it.
    func albumForNavigation(from song: NavidromeSong) -> NavidromeAlbum? {
        guard let fallback = NavidromeAlbum(song: song) else { return nil }

        if let selectedAlbum, selectedAlbum.id == fallback.id {
            return selectedAlbum
        }

        let loadedAlbums = [
            artistAlbums, albums, recentlyAddedAlbums, recentlyPlayedAlbums, homeRandomAlbums, featuredAlbums, favoriteAlbums
        ]
        return loadedAlbums.lazy.compactMap { $0.first { $0.id == fallback.id } }.first ?? fallback
    }

    func artistForNavigation(from song: NavidromeSong) -> NavidromeArtist? {
        guard let fallback = NavidromeArtist(song: song) else { return nil }

        if let selectedArtist, selectedArtist.id == fallback.id {
            return selectedArtist
        }

        return artists.first { $0.id == fallback.id }
            ?? favoriteArtists.first { $0.id == fallback.id }
            ?? fallback
    }

    func sortedVisibleArtists(_ artists: [NavidromeArtist]) -> [NavidromeArtist] {
        artists
            .filter { ($0.albumCount ?? 0) > 0 }
            .sorted {
                $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
    }

    // MARK: - Helpers

    /// Runs a cache read for the active library behind the busy indicator and
    /// reports a failure in the status line.
    private func loadFromCache(_ load: (SessionIdentity) async throws -> Void) async {
        guard let session = currentSession else { return }
        isBusy = true
        defer { isBusy = false }

        do {
            try await load(session)
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    private func showHome(_ home: CachedHomeMetadata) {
        recentlyAddedAlbums = home.recentlyAdded
        recentlyPlayedAlbums = home.recentlyPlayed
        homeRandomAlbums = home.random
        featuredAlbums = home.featured
        hasLoadedHome = true
    }
}
