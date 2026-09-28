//
//  KeychainStore.swift
//  PolyDrom
//
//  Created by zikasak on 07/07/2026.
//

import Foundation
import OSLog
import Security

protocol CredentialStoring {
    func password(for credentialID: String) throws -> String?
    func save(password: String, credentialID: String) throws
    func delete(credentialID: String) throws
}

struct KeychainStore: CredentialStoring {
    private let current: any CredentialStoring
    private let legacy: [any CredentialStoring]

    init() {
        #if DEBUG
        // Tests and local builds must never create items in the release app's
        // Keychain services. Their signatures change between builds.
        current = KeychainServiceStore(service: "uk.zikasak.PolyDrom.Navidrome.debug")
        legacy = []
        #else
        current = KeychainServiceStore(service: "uk.zikasak.PolyDrom.Navidrome.v3")
        legacy = [
            KeychainServiceStore(service: "uk.zikasak.PolyDrom.Navidrome.v2"),
            KeychainServiceStore(service: "uk.zikasak.PolyDrom.Navidrome")
        ]
        #endif
    }

    init(current: any CredentialStoring, legacy: [any CredentialStoring]) {
        self.current = current
        self.legacy = legacy
    }

    func password(for credentialID: String) throws -> String? {
        if let password = try current.password(for: credentialID) {
            return password
        }

        for oldStore in legacy {
            guard let password = try oldStore.password(for: credentialID) else {
                continue
            }

            // Preserve the source item until its replacement is usable.
            do {
                try current.save(password: password, credentialID: credentialID)
            } catch {
                AppLog.registry.error("Could not migrate Keychain credential: \(error.localizedDescription, privacy: .public)")
            }
            return password
        }
        return nil
    }

    func save(password: String, credentialID: String) throws {
        try current.save(password: password, credentialID: credentialID)
    }

    func delete(credentialID: String) throws {
        try current.delete(credentialID: credentialID)
        for oldStore in legacy {
            try oldStore.delete(credentialID: credentialID)
        }
    }
}

private struct KeychainServiceStore: CredentialStoring {
    let service: String

    func password(for credentialID: String) throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: credentialID,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)

        if status == errSecItemNotFound {
            return nil
        }

        guard status == errSecSuccess else {
            throw KeychainError.unexpectedStatus(status)
        }

        guard let data = item as? Data else {
            return nil
        }

        return String(data: data, encoding: .utf8)
    }

    func save(password: String, credentialID: String) throws {
        let data = Data(password.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: credentialID
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: data
        ]

        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess {
            return
        }

        guard updateStatus == errSecItemNotFound else {
            throw KeychainError.unexpectedStatus(updateStatus)
        }

        var insert = query
        insert[kSecValueData as String] = data
        insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock

        let addStatus = SecItemAdd(insert as CFDictionary, nil)
        if addStatus == errSecDuplicateItem {
            let retryStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
            guard retryStatus == errSecSuccess else {
                throw KeychainError.unexpectedStatus(retryStatus)
            }
            return
        }
        guard addStatus == errSecSuccess else {
            throw KeychainError.unexpectedStatus(addStatus)
        }
    }

    func delete(credentialID: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: credentialID
        ]
        let status = SecItemDelete(query as CFDictionary)

        if status == errSecItemNotFound || status == errSecSuccess {
            return
        }

        throw KeychainError.unexpectedStatus(status)
    }
}

enum KeychainError: LocalizedError {
    case unexpectedStatus(OSStatus)

    var errorDescription: String? {
        switch self {
        case .unexpectedStatus(let status):
            "Keychain error \(status)"
        }
    }
}
