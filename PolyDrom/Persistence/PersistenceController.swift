//
//  PersistenceController.swift
//  PolyDrom
//
//  Created by zikasak on 07/07/2026.
//

import CoreData
import Foundation

final class PersistenceController {
    static let shared = PersistenceController()

    let container: NSPersistentContainer

    init(inMemory: Bool = false, storeURL: URL? = nil) {
        container = NSPersistentContainer(name: "PolyDrom", managedObjectModel: Self.makeModel())

        if inMemory {
            container.persistentStoreDescriptions.first?.url = URL(fileURLWithPath: "/dev/null")
        } else if let storeURL {
            container.persistentStoreDescriptions.first?.url = storeURL
        }

        container.persistentStoreDescriptions.first?.setOption(true as NSNumber, forKey: NSMigratePersistentStoresAutomaticallyOption)
        container.persistentStoreDescriptions.first?.setOption(true as NSNumber, forKey: NSInferMappingModelAutomaticallyOption)

        container.loadPersistentStores { _, error in
            if let error {
                fatalError("Unable to load Core Data store: \(error)")
            }
        }

        container.viewContext.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy
        container.viewContext.automaticallyMergesChangesFromParent = true
    }

    private static func makeModel() -> NSManagedObjectModel {
        let model = NSManagedObjectModel()
        let server = serverEntity()
        let song = songEntity()
        let artist = artistEntity()
        let album = albumEntity()
        let playlist = playlistEntity()
        let playlistEntry = playlistEntryEntity()
        let syncState = syncStateEntity()
        model.entities = [server, song, artist, album, playlist, playlistEntry, syncState]
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
            attribute("password", .stringAttributeType),
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
            attribute("uuid", .UUIDAttributeType, isOptional: false),
            attribute("songID", .stringAttributeType, isOptional: false),
            attribute("serverKey", .stringAttributeType, isOptional: false),
            attribute("title", .stringAttributeType, isOptional: false),
            attribute("artist", .stringAttributeType),
            attribute("album", .stringAttributeType),
            attribute("duration", .integer64AttributeType),
            attribute("suffix", .stringAttributeType),
            attribute("coverArt", .stringAttributeType),
            attribute("albumId", .stringAttributeType),
            attribute("artistId", .stringAttributeType),
            attribute("track", .integer64AttributeType),
            attribute("discNumber", .integer64AttributeType),
            attribute("created", .dateAttributeType),
            attribute("serverPlayedAt", .dateAttributeType),
            attribute("isFavorite", .booleanAttributeType, isOptional: false, defaultValue: false),
            attribute("playCount", .integer64AttributeType, isOptional: false, defaultValue: 0),
            attribute("cachedAt", .dateAttributeType, isOptional: false),
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
            attribute("uuid", .UUIDAttributeType, isOptional: false),
            attribute("artistID", .stringAttributeType, isOptional: false),
            attribute("serverKey", .stringAttributeType, isOptional: false),
            attribute("name", .stringAttributeType, isOptional: false),
            attribute("albumCount", .integer64AttributeType),
            attribute("coverArt", .stringAttributeType),
            attribute("artistImageURL", .stringAttributeType),
            attribute("isFavorite", .booleanAttributeType, isOptional: false, defaultValue: false),
            attribute("cachedAt", .dateAttributeType, isOptional: false)
        ]
        entity.uniquenessConstraints = [["serverKey", "artistID"]]
        return entity
    }

    private static func albumEntity() -> NSEntityDescription {
        let entity = NSEntityDescription()
        entity.name = "VDAlbum"
        entity.managedObjectClassName = NSStringFromClass(NSManagedObject.self)
        entity.properties = [
            attribute("uuid", .UUIDAttributeType, isOptional: false),
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
            attribute("isFavorite", .booleanAttributeType, isOptional: false, defaultValue: false),
            attribute("cachedAt", .dateAttributeType, isOptional: false)
        ]
        entity.uniquenessConstraints = [["serverKey", "albumID"]]
        return entity
    }

    private static func playlistEntity() -> NSEntityDescription {
        let entity = NSEntityDescription()
        entity.name = "VDPlaylist"
        entity.managedObjectClassName = NSStringFromClass(NSManagedObject.self)
        entity.properties = [
            attribute("uuid", .UUIDAttributeType, isOptional: false),
            attribute("playlistID", .stringAttributeType, isOptional: false),
            attribute("serverKey", .stringAttributeType, isOptional: false),
            attribute("name", .stringAttributeType, isOptional: false),
            attribute("songCount", .integer64AttributeType),
            attribute("owner", .stringAttributeType),
            attribute("changedAt", .dateAttributeType),
            attribute("cachedAt", .dateAttributeType, isOptional: false)
        ]
        entity.uniquenessConstraints = [["serverKey", "playlistID"]]
        return entity
    }

    private static func playlistEntryEntity() -> NSEntityDescription {
        let entity = NSEntityDescription()
        entity.name = "VDPlaylistEntry"
        entity.managedObjectClassName = NSStringFromClass(NSManagedObject.self)
        entity.properties = [
            attribute("uuid", .UUIDAttributeType, isOptional: false),
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
            attribute("uuid", .UUIDAttributeType, isOptional: false),
            attribute("serverKey", .stringAttributeType, isOptional: false),
            attribute("catalogToken", .stringAttributeType),
            attribute("lastCheckedAt", .dateAttributeType),
            attribute("lastFullSyncAt", .dateAttributeType),
            attribute("isComplete", .booleanAttributeType, isOptional: false, defaultValue: false)
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
