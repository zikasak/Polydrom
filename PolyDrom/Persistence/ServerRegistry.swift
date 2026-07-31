import Foundation

/// Stores server metadata separately from the disposable music cache. Passwords
/// are deliberately never encoded here; their Keychain identifiers are retained
/// so credentials survive cache recovery and schema changes.
@MainActor
final class ServerRegistry {
    private struct StoredServer: Codable {
        let id: UUID
        var name: String
        var address: String
        var username: String
        var credentialID: String
        var createdAt: Date
        var lastConnectedAt: Date?

        init(
            id: UUID,
            name: String,
            address: String,
            username: String,
            credentialID: String,
            createdAt: Date,
            lastConnectedAt: Date?
        ) {
            self.id = id
            self.name = name
            self.address = address
            self.username = username
            self.credentialID = credentialID
            self.createdAt = createdAt
            self.lastConnectedAt = lastConnectedAt
        }

        init(_ profile: ServerProfile) {
            id = profile.id
            name = profile.name
            address = profile.address
            username = profile.username
            credentialID = profile.credentialID
            createdAt = profile.createdAt
            lastConnectedAt = profile.lastConnectedAt
        }
    }

    private let fileURL: URL?
    private let keychain: any CredentialStoring
    private var storedServers: [StoredServer]

    convenience init() {
        self.init(fileURL: Self.defaultFileURL(), keychain: KeychainStore())
    }

    init(fileURL: URL?, keychain: any CredentialStoring) {
        self.fileURL = fileURL
        self.keychain = keychain
        self.storedServers = (try? Self.read(from: fileURL)) ?? []
    }

    func servers() throws -> [ServerProfile] {
        try storedServers
            .sorted { lhs, rhs in
                switch (lhs.lastConnectedAt, rhs.lastConnectedAt) {
                case let (left?, right?):
                    left > right
                case (_?, nil):
                    true
                case (nil, _?):
                    false
                default:
                    lhs.createdAt > rhs.createdAt
                }
            }
            .map(profile(from:))
    }

    func save(address: String, username: String, password: String, name: String = "") throws -> ServerProfile {
        let trimmedAddress = address.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedUsername = username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedAddress.isEmpty, !trimmedUsername.isEmpty else {
            throw ServerRegistryError.missingRequiredFields
        }

        let now = Date()
        let index = storedServers.firstIndex {
            $0.address.caseInsensitiveCompare(trimmedAddress) == .orderedSame
                && $0.username.caseInsensitiveCompare(trimmedUsername) == .orderedSame
        }
        let existing = index.map { storedServers[$0] }
        let credentialID = existing?.credentialID ?? UUID().uuidString
        try keychain.save(password: password, credentialID: credentialID)

        let stored = StoredServer(
            id: existing?.id ?? UUID(),
            name: name,
            address: trimmedAddress,
            username: trimmedUsername,
            credentialID: credentialID,
            createdAt: existing?.createdAt ?? now,
            lastConnectedAt: now
        )
        if let index {
            storedServers[index] = stored
        } else {
            storedServers.append(stored)
        }
        try persist()
        return try profile(from: stored)
    }

    func touch(_ profile: ServerProfile) throws {
        guard let index = storedServers.firstIndex(where: { $0.id == profile.id }) else { return }
        storedServers[index].lastConnectedAt = Date()
        try persist()
    }

    func delete(_ profile: ServerProfile) throws {
        guard let index = storedServers.firstIndex(where: { $0.id == profile.id }) else { return }
        let removed = storedServers.remove(at: index)
        do {
            try keychain.delete(credentialID: removed.credentialID)
            try persist()
        } catch {
            storedServers.insert(removed, at: index)
            throw error
        }
    }

    /// Imports once from the legacy combined store. A successful write is the
    /// migration marker; the legacy cache is intentionally left untouched until
    /// the new cache has been opened successfully.
    func importLegacyServersIfNeeded(from legacyStore: LibraryStore) throws {
        guard storedServers.isEmpty else { return }
        let legacyProfiles = try legacyStore.servers()
        guard !legacyProfiles.isEmpty else { return }
        storedServers = legacyProfiles.map(StoredServer.init)
        try persist()
    }

    private func profile(from stored: StoredServer) throws -> ServerProfile {
        ServerProfile(
            id: stored.id,
            name: stored.name,
            address: stored.address,
            username: stored.username,
            credentialID: stored.credentialID,
            password: try keychain.password(for: stored.credentialID) ?? "",
            createdAt: stored.createdAt,
            lastConnectedAt: stored.lastConnectedAt
        )
    }

    private func persist() throws {
        guard let fileURL else { return }
        let data = try JSONEncoder().encode(storedServers)
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: fileURL, options: .atomic)
    }

    private static func read(from fileURL: URL?) throws -> [StoredServer] {
        guard let fileURL, FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        return try JSONDecoder().decode([StoredServer].self, from: Data(contentsOf: fileURL))
    }

    private static func defaultFileURL() -> URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("PolyDrom", isDirectory: true)
            .appendingPathComponent("servers.json")
    }
}

enum ServerRegistryError: LocalizedError {
    case missingRequiredFields

    var errorDescription: String? {
        switch self {
        case .missingRequiredFields:
            "Enter both a server address and username."
        }
    }
}
