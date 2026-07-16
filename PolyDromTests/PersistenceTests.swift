import Foundation
import Testing
@testable import PolyDrom

@Suite(.serialized)
@MainActor
struct PersistenceTests {
    @Test func serverLifecycleTrimsUpdatesSortsTouchesAndDeletes() throws {
        let credentials = MemoryCredentialStore()
        let store = LibraryStore(persistence: PersistenceController(inMemory: true), keychain: credentials)

        let first = try store.saveServer(address: "  host.local  ", username: " user ", password: "one")
        Thread.sleep(forTimeInterval: 0.002)
        let second = try store.saveServer(address: "https://two.example", username: "two", password: "two", name: "Second")

        #expect(first.address == "host.local")
        #expect(first.username == "user")
        #expect(first.password == "one")
        #expect(try store.servers().map(\.id) == [second.id, first.id])
        #expect(credentials.savedCredentialIDs.count == 2)

        Thread.sleep(forTimeInterval: 0.002)
        try store.touchServer(first)
        #expect(try store.servers().first?.id == first.id)

        let updated = try store.saveServer(address: "host.local", username: "user", password: "changed", name: "Updated")
        #expect(updated.id == first.id)
        #expect(updated.name == "Updated")
        #expect(updated.password == "changed")
        #expect(credentials.passwords[first.credentialID] == "changed")

        try store.deleteServer(updated)
        #expect(try store.servers().map(\.id) == [second.id])
        #expect(credentials.deletedCredentialIDs == [first.credentialID])

        try store.deleteServer(updated)
        try store.touchServer(updated)
        #expect(try store.servers().count == 1)
    }

    @Test func credentialFailuresPropagateFromSave() {
        let credentials = MemoryCredentialStore()
        credentials.error = TestFailure.intentional
        let store = LibraryStore(persistence: PersistenceController(inMemory: true), keychain: credentials)

        #expect(throws: TestFailure.self) {
            try store.saveServer(address: "host", username: "user", password: "secret")
        }
    }

    @Test func songsUpsertUpdateRemainServerScopedAndRespectLimit() throws {
        let store = LibraryStore(
            persistence: PersistenceController(inMemory: true),
            keychain: MemoryCredentialStore()
        )
        let original = makeSong(id: "one", title: "Original", duration: nil, coverArt: "cover")
        let other = makeSong(id: "two", title: "Other", artist: nil, album: nil)

        try store.upsertSongs([original, other], serverKey: "server-a")
        #expect(try store.recentSongs(serverKey: "server-a").isEmpty)

        try store.markPlayed(original, serverKey: "server-a")
        Thread.sleep(forTimeInterval: 0.002)
        try store.markPlayed(other, serverKey: "server-a")
        try store.markPlayed(makeSong(id: "one", title: "Updated", duration: 42), serverKey: "server-a")
        try store.markPlayed(makeSong(id: "one", title: "Other Server"), serverKey: "server-b")

        let recent = try store.recentSongs(serverKey: "server-a")
        #expect(recent.count == 2)
        #expect(recent.first?.id == "one")
        #expect(recent.first?.title == "Updated")
        #expect(recent.first?.duration == 42)
        #expect(try store.recentSongs(serverKey: "server-a", limit: 1).count == 1)
        #expect(try store.recentSongs(serverKey: "server-b").map(\.title) == ["Other Server"])
    }

    @Test func keychainErrorsExposeStatusCode() {
        #expect(KeychainError.unexpectedStatus(-50).localizedDescription == "Keychain error -50")
        #expect(NavidromeError.invalidURL.localizedDescription == "The server address is not a valid URL.")
        #expect(NavidromeError.server(message: "Nope").localizedDescription == "Nope")
    }
}
