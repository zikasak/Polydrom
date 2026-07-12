//
//  LibraryStore.swift
//  PolyDrom
//
//  Created by zikasak on 07/07/2026.
//

import CoreData
import Foundation

@MainActor
final class LibraryStore {
    private let context: NSManagedObjectContext
    private let keychain: KeychainStore

    init(persistence: PersistenceController, keychain: KeychainStore) {
        context = persistence.container.viewContext
        self.keychain = keychain
    }

    convenience init() {
        self.init(persistence: .shared, keychain: KeychainStore())
    }

    func servers() throws -> [ServerProfile] {
        let request = NSFetchRequest<NSManagedObject>(entityName: "VDServer")
        request.sortDescriptors = [
            NSSortDescriptor(key: "lastConnectedAt", ascending: false),
            NSSortDescriptor(key: "createdAt", ascending: false)
        ]
        return try context.fetch(request).map(serverProfile(from:))
    }

    func saveServer(address: String, username: String, password: String, name: String = "") throws -> ServerProfile {
        let trimmedAddress = address.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedUsername = username.trimmingCharacters(in: .whitespacesAndNewlines)
        let existing = try serverObject(address: trimmedAddress, username: trimmedUsername)
        let object = existing ?? NSEntityDescription.insertNewObject(forEntityName: "VDServer", into: context)
        let now = Date()

        if existing == nil {
            object.setValue(UUID(), forKey: "uuid")
            object.setValue(now, forKey: "createdAt")
        }
        let credentialID = object.value(forKey: "credentialID") as? String ?? UUID().uuidString
        try keychain.save(password: password, credentialID: credentialID)

        object.setValue(name, forKey: "name")
        object.setValue(trimmedAddress, forKey: "address")
        object.setValue(trimmedUsername, forKey: "username")
        object.setValue(credentialID, forKey: "credentialID")
        object.setValue(nil, forKey: "password")
        object.setValue(now, forKey: "lastConnectedAt")
        try save()
        return serverProfile(from: object)
    }

    func deleteServer(_ profile: ServerProfile) throws {
        if let object = try serverObject(address: profile.address, username: profile.username) {
            context.delete(object)
            try keychain.delete(credentialID: profile.credentialID)
            try save()
        }
    }

    func touchServer(_ profile: ServerProfile) throws {
        guard let object = try serverObject(address: profile.address, username: profile.username) else { return }
        object.setValue(Date(), forKey: "lastConnectedAt")
        try save()
    }

    func upsertSongs(_ songs: [NavidromeSong], serverKey: String) throws {
        for song in songs {
            _ = try upsertSong(song, serverKey: serverKey)
        }
        try save()
    }

    func favoriteSongs(serverKey: String) throws -> [NavidromeSong] {
        let request = songFetchRequest()
        request.predicate = NSPredicate(format: "serverKey == %@ AND isFavorite == YES", serverKey)
        request.sortDescriptors = [NSSortDescriptor(key: "title", ascending: true)]
        return try context.fetch(request).map(song(from:))
    }

    func recentSongs(serverKey: String, limit: Int = 50) throws -> [NavidromeSong] {
        let request = songFetchRequest()
        request.predicate = NSPredicate(format: "serverKey == %@ AND lastPlayedAt != nil", serverKey)
        request.sortDescriptors = [NSSortDescriptor(key: "lastPlayedAt", ascending: false)]
        request.fetchLimit = limit
        return try context.fetch(request).map(song(from:))
    }

    func favoriteIDs(serverKey: String) throws -> Set<String> {
        let request = songFetchRequest()
        request.predicate = NSPredicate(format: "serverKey == %@ AND isFavorite == YES", serverKey)
        return Set(try context.fetch(request).compactMap { $0.value(forKey: "songID") as? String })
    }

    func markPlayed(_ song: NavidromeSong, serverKey: String) throws {
        let object = try upsertSong(song, serverKey: serverKey)
        object.setValue(Date(), forKey: "lastPlayedAt")
        let playCount = object.value(forKey: "playCount") as? Int64 ?? 0
        object.setValue(playCount + 1, forKey: "playCount")
        try save()
    }

    func setFavorite(_ song: NavidromeSong, serverKey: String, isFavorite: Bool) throws {
        let object = try upsertSong(song, serverKey: serverKey)
        object.setValue(isFavorite, forKey: "isFavorite")
        try save()
    }

    private func upsertSong(_ song: NavidromeSong, serverKey: String) throws -> NSManagedObject {
        let object = try songObject(songID: song.id, serverKey: serverKey)
            ?? NSEntityDescription.insertNewObject(forEntityName: "VDSong", into: context)

        if object.value(forKey: "uuid") == nil {
            object.setValue(UUID(), forKey: "uuid")
        }

        object.setValue(serverKey, forKey: "serverKey")
        object.setValue(song.id, forKey: "songID")
        object.setValue(song.title, forKey: "title")
        object.setValue(song.artist, forKey: "artist")
        object.setValue(song.album, forKey: "album")
        object.setValue(song.duration.map { Int64($0) }, forKey: "duration")
        object.setValue(song.suffix, forKey: "suffix")
        object.setValue(song.coverArt, forKey: "coverArt")
        object.setValue(song.albumId, forKey: "albumId")
        object.setValue(song.artistId, forKey: "artistId")
        object.setValue(Date(), forKey: "cachedAt")
        return object
    }

    private func serverObject(address: String, username: String) throws -> NSManagedObject? {
        let request = NSFetchRequest<NSManagedObject>(entityName: "VDServer")
        request.predicate = NSPredicate(format: "address == %@ AND username == %@", address, username)
        request.fetchLimit = 1
        return try context.fetch(request).first
    }

    private func songObject(songID: String, serverKey: String) throws -> NSManagedObject? {
        let request = songFetchRequest()
        request.predicate = NSPredicate(format: "serverKey == %@ AND songID == %@", serverKey, songID)
        request.fetchLimit = 1
        return try context.fetch(request).first
    }

    private func songFetchRequest() -> NSFetchRequest<NSManagedObject> {
        NSFetchRequest<NSManagedObject>(entityName: "VDSong")
    }

    private func serverProfile(from object: NSManagedObject) -> ServerProfile {
        let credentialID = object.value(forKey: "credentialID") as? String ?? UUID().uuidString
        let legacyPassword = object.value(forKey: "password") as? String ?? ""
        let password = (try? keychain.password(for: credentialID)) ?? legacyPassword

        return ServerProfile(
            id: object.value(forKey: "uuid") as? UUID ?? UUID(),
            name: object.value(forKey: "name") as? String ?? "",
            address: object.value(forKey: "address") as? String ?? "",
            username: object.value(forKey: "username") as? String ?? "",
            credentialID: credentialID,
            password: password,
            createdAt: object.value(forKey: "createdAt") as? Date ?? Date(),
            lastConnectedAt: object.value(forKey: "lastConnectedAt") as? Date
        )
    }

    private func song(from object: NSManagedObject) -> NavidromeSong {
        let durationValue = object.value(forKey: "duration") as? Int64
        return NavidromeSong(
            id: object.value(forKey: "songID") as? String ?? "",
            title: object.value(forKey: "title") as? String ?? "Untitled",
            artist: object.value(forKey: "artist") as? String,
            album: object.value(forKey: "album") as? String,
            duration: durationValue.map(Int.init),
            suffix: object.value(forKey: "suffix") as? String,
            coverArt: object.value(forKey: "coverArt") as? String,
            albumId: object.value(forKey: "albumId") as? String,
            artistId: object.value(forKey: "artistId") as? String
        )
    }

    private func save() throws {
        guard context.hasChanges else { return }
        try context.save()
    }
}
