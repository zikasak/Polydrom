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

    init(inMemory: Bool = false) {
        container = NSPersistentContainer(name: "PolyDrom", managedObjectModel: Self.makeModel())

        if inMemory {
            container.persistentStoreDescriptions.first?.url = URL(fileURLWithPath: "/dev/null")
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
        model.entities = [server, song]
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
            attribute("isFavorite", .booleanAttributeType, isOptional: false, defaultValue: false),
            attribute("playCount", .integer64AttributeType, isOptional: false, defaultValue: 0),
            attribute("cachedAt", .dateAttributeType, isOptional: false),
            attribute("lastPlayedAt", .dateAttributeType)
        ]
        entity.uniquenessConstraints = [["serverKey", "songID"]]
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
