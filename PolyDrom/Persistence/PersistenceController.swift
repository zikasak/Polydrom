//
//  PersistenceController.swift
//  PolyDrom
//
//  Created by zikasak on 07/07/2026.
//

import CoreData
import Foundation
import OSLog

@MainActor
final class PersistenceController {
    static let shared = PersistenceController(storeURL: PersistenceController.libraryCacheURL)

    let container: NSPersistentContainer
    private(set) var loadFailure: PersistenceError?

    init(inMemory: Bool = false, storeURL: URL? = nil, recoverDisposableCache: Bool = true) {
        container = NSPersistentContainer(name: "PolyDrom", managedObjectModel: Self.makeModel())
        let description = container.persistentStoreDescriptions[0]
        let resolvedStoreURL: URL?

        if inMemory {
            description.type = NSInMemoryStoreType
            resolvedStoreURL = nil
        } else {
            description.type = NSSQLiteStoreType
            resolvedStoreURL = storeURL
        }
        if let storeURL = resolvedStoreURL {
            try? FileManager.default.createDirectory(
                at: storeURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            description.url = storeURL
        }

        description.setOption(true as NSNumber, forKey: NSMigratePersistentStoresAutomaticallyOption)
        description.setOption(true as NSNumber, forKey: NSInferMappingModelAutomaticallyOption)
        AppLog.persistence.info(
            "Opening Core Data store (in-memory: \(inMemory, privacy: .public), recovery enabled: \(recoverDisposableCache, privacy: .public))"
        )
        openStore(
            description: description,
            cacheURL: recoverDisposableCache ? resolvedStoreURL : nil
        )

        container.viewContext.mergePolicy = NSMergePolicy(merge: .mergeByPropertyObjectTrumpMergePolicyType)
        container.viewContext.automaticallyMergesChangesFromParent = true
    }

    static var libraryCacheURL: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("PolyDrom", isDirectory: true)
            .appendingPathComponent("LibraryCache.sqlite")
    }

    /// The location used by the pre-registry release. It is read only for the
    /// one-time server migration; music metadata may be rebuilt.
    static var legacyStoreURL: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("PolyDrom.sqlite")
    }

    private func openStore(description: NSPersistentStoreDescription, cacheURL: URL?) {
        do {
            try container.persistentStoreCoordinator.addPersistentStore(
                ofType: description.type,
                configurationName: description.configuration,
                at: description.url,
                options: description.options
            )
            AppLog.persistence.info("Core Data store opened")
        } catch {
            AppLog.persistence.error(
                "Core Data store failed to open: \(error.localizedDescription, privacy: .private)"
            )
            guard let cacheURL else {
                loadFailure = .unavailable(error.localizedDescription)
                return
            }

            do {
                try Self.removeDisposableCache(at: cacheURL)
                try container.persistentStoreCoordinator.addPersistentStore(
                    ofType: description.type,
                    configurationName: description.configuration,
                    at: cacheURL,
                    options: description.options
                )
                AppLog.persistence.warning("Disposable Core Data cache was removed and recreated")
            } catch {
                AppLog.persistence.fault(
                    "Core Data cache recovery failed: \(error.localizedDescription, privacy: .private)"
                )
                loadFailure = .unavailable(error.localizedDescription)
            }
        }
    }

    private static func removeDisposableCache(at url: URL) throws {
        let fileManager = FileManager.default
        for suffix in ["", "-shm", "-wal"] {
            let cacheFile = URL(fileURLWithPath: url.path + suffix)
            guard fileManager.fileExists(atPath: cacheFile.path) else { continue }
            try fileManager.removeItem(at: cacheFile)
        }
    }

    private static func makeModel() -> NSManagedObjectModel {
        let model = NSManagedObjectModel()
        let server = serverEntity()
        let song = songEntity()
        let artist = artistEntity()
        let album = albumEntity()
        let genre = genreEntity()
        let genreSong = genreSongEntity()
        let playlist = playlistEntity()
        let playlistEntry = playlistEntryEntity()
        let syncState = syncStateEntity()
        model.entities = [server, song, artist, album, genre, genreSong, playlist, playlistEntry, syncState]
        return model
    }

    private static func serverEntity() -> NSEntityDescription {
        let entity = NSEntityDescription()
        entity.name = "VDServer"
        entity.managedObjectClassName = NSStringFromClass(NSManagedObject.self)
        entity.properties = [
            attribute("uuid", .UUIDAttributeType, isOptional: false),
            attribute("name", .stringAttributeType),
            attribute("address", .stringAttributeType, isOptional: false),
            attribute("username", .stringAttributeType, isOptional: false),
            attribute("credentialID", .stringAttributeType),
            attribute("createdAt", .dateAttributeType, isOptional: false),
            attribute("lastConnectedAt", .dateAttributeType)
        ]
        entity.uniquenessConstraints = [["address", "username"]]
        return entity
    }

    private static func songEntity() -> NSEntityDescription {
        let entity = NSEntityDescription()
        entity.name = "VDSong"
        entity.managedObjectClassName = NSStringFromClass(NSManagedObject.self)
        entity.properties = [
            attribute("songID", .stringAttributeType, isOptional: false),
            attribute("serverKey", .stringAttributeType, isOptional: false),
            attribute("title", .stringAttributeType, isOptional: false),
            attribute("artist", .stringAttributeType),
            attribute("album", .stringAttributeType),
            attribute("duration", .integer64AttributeType),
            attribute("coverArt", .stringAttributeType),
            attribute("albumId", .stringAttributeType),
            attribute("artistId", .stringAttributeType),
            attribute("track", .integer64AttributeType),
            attribute("discNumber", .integer64AttributeType),
            attribute("created", .dateAttributeType),
            attribute("serverPlayedAt", .dateAttributeType),
            attribute("genresData", .binaryDataAttributeType),
            attribute("isFavorite", .booleanAttributeType, isOptional: false, defaultValue: false),
            attribute("lastPlayedAt", .dateAttributeType)
        ]
        entity.uniquenessConstraints = [["serverKey", "songID"]]
        return entity
    }

    private static func artistEntity() -> NSEntityDescription {
        let entity = NSEntityDescription()
        entity.name = "VDArtist"
        entity.managedObjectClassName = NSStringFromClass(NSManagedObject.self)
        entity.properties = [
            attribute("artistID", .stringAttributeType, isOptional: false),
            attribute("serverKey", .stringAttributeType, isOptional: false),
            attribute("name", .stringAttributeType, isOptional: false),
            attribute("albumCount", .integer64AttributeType),
            attribute("coverArt", .stringAttributeType),
            attribute("artistImageURL", .stringAttributeType),
            attribute("isFavorite", .booleanAttributeType, isOptional: false, defaultValue: false)
        ]
        entity.uniquenessConstraints = [["serverKey", "artistID"]]
        return entity
    }

    private static func albumEntity() -> NSEntityDescription {
        let entity = NSEntityDescription()
        entity.name = "VDAlbum"
        entity.managedObjectClassName = NSStringFromClass(NSManagedObject.self)
        entity.properties = [
            attribute("albumID", .stringAttributeType, isOptional: false),
            attribute("serverKey", .stringAttributeType, isOptional: false),
            attribute("name", .stringAttributeType, isOptional: false),
            attribute("artist", .stringAttributeType),
            attribute("artistID", .stringAttributeType),
            attribute("songCount", .integer64AttributeType),
            attribute("year", .integer64AttributeType),
            attribute("coverArt", .stringAttributeType),
            attribute("created", .dateAttributeType),
            attribute("serverPlayedAt", .dateAttributeType),
            attribute("lastPlayedAt", .dateAttributeType),
            attribute("isFavorite", .booleanAttributeType, isOptional: false, defaultValue: false)
        ]
        entity.uniquenessConstraints = [["serverKey", "albumID"]]
        return entity
    }

    private static func genreEntity() -> NSEntityDescription {
        let entity = NSEntityDescription()
        entity.name = "VDGenre"
        entity.managedObjectClassName = NSStringFromClass(NSManagedObject.self)
        entity.properties = [
            attribute("genreID", .stringAttributeType, isOptional: false),
            attribute("serverKey", .stringAttributeType, isOptional: false),
            attribute("name", .stringAttributeType, isOptional: false),
            attribute("songCount", .integer64AttributeType, isOptional: false)
        ]
        entity.uniquenessConstraints = [["serverKey", "genreID"]]
        return entity
    }

    private static func genreSongEntity() -> NSEntityDescription {
        let entity = NSEntityDescription()
        entity.name = "VDGenreSong"
        entity.managedObjectClassName = NSStringFromClass(NSManagedObject.self)
        entity.properties = [
            attribute("serverKey", .stringAttributeType, isOptional: false),
            attribute("genreID", .stringAttributeType, isOptional: false),
            attribute("songID", .stringAttributeType, isOptional: false)
        ]
        entity.uniquenessConstraints = [["serverKey", "genreID", "songID"]]
        return entity
    }

    private static func playlistEntity() -> NSEntityDescription {
        let entity = NSEntityDescription()
        entity.name = "VDPlaylist"
        entity.managedObjectClassName = NSStringFromClass(NSManagedObject.self)
        entity.properties = [
            attribute("playlistID", .stringAttributeType, isOptional: false),
            attribute("serverKey", .stringAttributeType, isOptional: false),
            attribute("name", .stringAttributeType, isOptional: false),
            attribute("songCount", .integer64AttributeType),
            attribute("owner", .stringAttributeType),
            attribute("changedAt", .dateAttributeType),
            attribute("isReadOnly", .booleanAttributeType, isOptional: false, defaultValue: false)
        ]
        entity.uniquenessConstraints = [["serverKey", "playlistID"]]
        return entity
    }

    private static func playlistEntryEntity() -> NSEntityDescription {
        let entity = NSEntityDescription()
        entity.name = "VDPlaylistEntry"
        entity.managedObjectClassName = NSStringFromClass(NSManagedObject.self)
        entity.properties = [
            attribute("serverKey", .stringAttributeType, isOptional: false),
            attribute("playlistID", .stringAttributeType, isOptional: false),
            attribute("songID", .stringAttributeType, isOptional: false),
            attribute("position", .integer64AttributeType, isOptional: false)
        ]
        entity.uniquenessConstraints = [["serverKey", "playlistID", "position"]]
        return entity
    }

    private static func syncStateEntity() -> NSEntityDescription {
        let entity = NSEntityDescription()
        entity.name = "VDMetadataSyncState"
        entity.managedObjectClassName = NSStringFromClass(NSManagedObject.self)
        entity.properties = [
            attribute("serverKey", .stringAttributeType, isOptional: false),
            attribute("catalogToken", .stringAttributeType),
            attribute("lastCheckedAt", .dateAttributeType),
            attribute("isComplete", .booleanAttributeType, isOptional: false, defaultValue: false),
            attribute("catalogVersion", .integer64AttributeType, isOptional: false, defaultValue: 0)
        ]
        entity.uniquenessConstraints = [["serverKey"]]
        return entity
    }

    private static func attribute(
        _ name: String,
        _ type: NSAttributeType,
        isOptional: Bool = true,
        defaultValue: Any? = nil
    ) -> NSAttributeDescription {
        let attribute = NSAttributeDescription()
        attribute.name = name
        attribute.attributeType = type
        attribute.isOptional = isOptional
        attribute.defaultValue = defaultValue
        return attribute
    }
}

enum PersistenceError: LocalizedError {
    case unavailable(String)

    var errorDescription: String? {
        switch self {
        case .unavailable(let description):
            "The local music cache is unavailable: \(description)"
        }
    }
}
