import Foundation

struct CachedFavorites: Sendable {
    let artists: [NavidromeArtist]
    let albums: [NavidromeAlbum]
    let songs: [NavidromeSong]
}

/// What differs between favoriting a song, an album, and an artist.
@MainActor
private struct FavoriteCollection<Item: Identifiable & Sendable> where Item.ID == String {
    let record: LibraryRecord
    let items: ReferenceWritableKeyPath<AppCoordinator, [Item]>
    let ids: ReferenceWritableKeyPath<AppCoordinator, Set<String>>
    let sortName: KeyPath<Item, String>
    let addedMessage: String
    let removedMessage: String
}

extension AppCoordinator {
    func isFavorite(_ song: NavidromeSong) -> Bool {
        favoriteIDs.contains(song.id)
    }

    func isFavorite(_ album: NavidromeAlbum) -> Bool {
        favoriteAlbumIDs.contains(album.id)
    }

    func isFavorite(_ artist: NavidromeArtist) -> Bool {
        favoriteArtistIDs.contains(artist.id)
    }

    func toggleFavorite(_ song: NavidromeSong) {
        toggleFavorite(song, in: FavoriteCollection(
            record: .song,
            items: \.favoriteSongs,
            ids: \.favoriteIDs,
            sortName: \.title,
            addedMessage: "Added to favorites",
            removedMessage: "Removed from favorites"
        ))
    }

    func toggleFavorite(_ album: NavidromeAlbum) {
        toggleFavorite(album, in: FavoriteCollection(
            record: .album,
            items: \.favoriteAlbums,
            ids: \.favoriteAlbumIDs,
            sortName: \.name,
            addedMessage: "Added album to favorites",
            removedMessage: "Removed album from favorites"
        ))
    }

    func toggleFavorite(_ artist: NavidromeArtist) {
        toggleFavorite(artist, in: FavoriteCollection(
            record: .artist,
            items: \.favoriteArtists,
            ids: \.favoriteArtistIDs,
            sortName: \.name,
            addedMessage: "Added artist to favorites",
            removedMessage: "Removed artist from favorites"
        ))
    }

    func loadCachedFavorites() async throws {
        guard let session = currentSession else { return }
        let favorites = try await cachedFavorites(serverKey: session.serverKey)
        await warmCachedArtistCovers(favorites.artists)
        await warmCachedAlbumCovers(favorites.albums)
        await warmCachedSongCovers(favorites.songs)
        guard isCurrentSession(session) else { return }
        showFavorites(favorites)
        prefetchArtistCovers(favorites.artists)
        prefetchAlbumCovers(favorites.albums)
        prefetchSongCovers(favorites.songs)
    }

    func cachedFavorites(serverKey: String) async throws -> CachedFavorites {
        async let artists = store.favoriteArtists(serverKey: serverKey)
        async let albums = store.favoriteAlbums(serverKey: serverKey)
        async let songs = store.favoriteSongs(serverKey: serverKey)
        return try await CachedFavorites(artists: artists, albums: albums, songs: songs)
    }

    func showFavorites(_ favorites: CachedFavorites) {
        favoriteArtists = favorites.artists
        favoriteArtistIDs = Set(favorites.artists.map(\.id))
        favoriteAlbums = favorites.albums
        favoriteAlbumIDs = Set(favorites.albums.map(\.id))
        favoriteSongs = favorites.songs
        favoriteIDs = Set(favorites.songs.map(\.id))
    }

    /// Shows the change right away, then sends it to the server and the cache,
    /// undoing it if the server refuses.
    private func toggleFavorite<Item>(_ item: Item, in collection: FavoriteCollection<Item>) {
        let record = collection.record
        guard isOnline, let client, let session = currentSession,
              favoriteUpdatesInFlight[record, default: []].insert(item.id).inserted else {
            if !isOnline { statusMessage = "Connect to the server to update favorites." }
            return
        }

        let wasFavorite = self[keyPath: collection.ids].contains(item.id)
        let isFavorite = !wasFavorite
        setFavoriteState(isFavorite, for: item, in: collection)

        Task { [weak self] in
            do {
                try await client.setStarred(isFavorite, itemID: item.id)
            } catch {
                guard let self, self.isCurrentSession(session) else { return }
                self.favoriteUpdatesInFlight[record]?.remove(item.id)
                self.setFavoriteState(wasFavorite, for: item, in: collection)
                self.statusMessage = error.localizedDescription
                return
            }

            guard let self, self.isCurrentSession(session) else { return }
            do {
                try await self.store.setFavorite(isFavorite, record, id: item.id, serverKey: session.serverKey)
                try await self.loadCachedFavorites()
                self.statusMessage = isFavorite ? collection.addedMessage : collection.removedMessage
            } catch {
                self.statusMessage = "Favorite updated in Navidrome, but could not cache it: \(error.localizedDescription)"
            }
            self.favoriteUpdatesInFlight[record]?.remove(item.id)
        }
    }

    private func setFavoriteState<Item>(_ isFavorite: Bool, for item: Item, in collection: FavoriteCollection<Item>) {
        if isFavorite {
            self[keyPath: collection.ids].insert(item.id)
            if !self[keyPath: collection.items].contains(where: { $0.id == item.id }) {
                let sortName = collection.sortName
                self[keyPath: collection.items].append(item)
                self[keyPath: collection.items].sort {
                    $0[keyPath: sortName].localizedCaseInsensitiveCompare($1[keyPath: sortName]) == .orderedAscending
                }
            }
        } else {
            self[keyPath: collection.ids].remove(item.id)
            self[keyPath: collection.items].removeAll { $0.id == item.id }
        }
    }
}
