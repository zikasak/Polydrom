import Foundation
import Synchronization
import Testing
@testable import PolyDrom

@Suite(.serialized)
@MainActor
struct LibrarySyncCoordinatorTests {
    @Test func firstChangedAndUnchangedChecksUseTheExpectedSyncDepth() async throws {
        struct RequestState: Sendable {
            var scanToken = "scan-1"
            var searchRequests = 0
            var playlistDetailRequests = 0
        }
        let state = Mutex(RequestState())

        let handler: StubURLProtocol.Handler = { request in
            switch apiMethod(in: request) {
            case "getScanStatus":
                let token = state.withLock { $0.scanToken }
                return envelope(#"{"status":"ok","scanStatus":{"scanning":false,"lastScan":"\#(token)"}}"#)
            case "search3":
                state.withLock { $0.searchRequests += 1 }
                if queryValue("artistCount", in: request) != "0" {
                    return envelope(#"{"status":"ok","searchResult3":{"artist":[{"id":"artist","name":"Artist","albumCount":1}]}}"#)
                }
                if queryValue("albumCount", in: request) != "0" {
                    return envelope(#"{"status":"ok","searchResult3":{"album":[{"id":"album","name":"Album","artistId":"artist"}]}}"#)
                }
                return envelope(#"{"status":"ok","searchResult3":{"song":[{"id":"song","title":"Song","albumId":"album","artistId":"artist"}]}}"#)
            case "getPlaylists":
                return envelope(#"{"status":"ok","playlists":{"playlist":[{"id":"playlist","name":"Mix","songCount":1,"changed":"2026-07-30T12:00:00Z"}]}}"#)
            case "getPlaylist":
                state.withLock { $0.playlistDetailRequests += 1 }
                return envelope(#"{"status":"ok","playlist":{"entry":[{"id":"song","title":"Song","albumId":"album","artistId":"artist"}]}}"#)
            case "getStarred2":
                return envelope(#"{"status":"ok","starred2":{"song":[{"id":"song","title":"Song"}]}}"#)
            default:
                return StubURLProtocol.Response(statusCode: 404, json: "{}")
            }
        }

        let store = LibraryStore(
            persistence: PersistenceController(inMemory: true),
            keychain: MemoryCredentialStore()
        )
        let coordinator = LibrarySyncCoordinator(store: store, pageSize: 10)
        let client = try #require(
            NavidromeClient(profile: makeProfile(), session: StubURLProtocol.session(handler: handler))
        )

        #expect(try await coordinator.synchronize(client: client, serverKey: "server") == .full)
        #expect(state.withLock { $0.searchRequests } == 3)
        #expect(state.withLock { $0.playlistDetailRequests } == 1)
        #expect(try await store.favoriteSongs(serverKey: "server").map(\.id) == ["song"])

        #expect(try await coordinator.synchronize(client: client, serverKey: "server") == .metadataOnly)
        #expect(state.withLock { $0.searchRequests } == 3)
        #expect(state.withLock { $0.playlistDetailRequests } == 1)

        state.withLock { $0.scanToken = "scan-2" }
        #expect(try await coordinator.synchronize(client: client, serverKey: "server") == .full)
        #expect(state.withLock { $0.searchRequests } == 6)
        #expect(state.withLock { $0.playlistDetailRequests } == 2)
        #expect(try await store.metadataSyncState(serverKey: "server").catalogToken == "scan-2")
    }

    @Test func scanInProgressDefersWithoutMutatingTheExistingSnapshot() async throws {
        let handler: StubURLProtocol.Handler = { request in
            if apiMethod(in: request) == "getScanStatus" {
                return envelope(#"{"status":"ok","scanStatus":{"scanning":true,"lastScan":"scan-2"}}"#)
            }
            return StubURLProtocol.Response(statusCode: 500, json: "{}")
        }
        let store = LibraryStore(
            persistence: PersistenceController(inMemory: true),
            keychain: MemoryCredentialStore()
        )
        let coordinator = LibrarySyncCoordinator(store: store)
        let client = try #require(
            NavidromeClient(profile: makeProfile(), session: StubURLProtocol.session(handler: handler))
        )

        #expect(try await coordinator.synchronize(client: client, serverKey: "server") == .deferredForScan)
        #expect(!(try await store.metadataSyncState(serverKey: "server").isComplete))
    }

    @Test func metadataOnlyCheckReconcilesFavoritesAndDeletedPlaylists() async throws {
        let store = LibraryStore(
            persistence: PersistenceController(inMemory: true),
            keychain: MemoryCredentialStore()
        )
        let song = makeSong(id: "song")
        try await store.apply(
            LibrarySnapshot(
                artists: [],
                albums: [],
                songs: [song],
                playlists: [
                    PlaylistMetadataSnapshot(
                        playlist: NavidromePlaylist(id: "deleted", name: "Deleted", songCount: 1),
                        songs: [song]
                    )
                ],
                favorites: FavoriteMetadata(songIDs: [song.id]),
                catalogToken: "scan",
                checkedAt: Date()
            ),
            serverKey: "server"
        )
        let handler: StubURLProtocol.Handler = { request in
            switch apiMethod(in: request) {
            case "getScanStatus":
                return envelope(#"{"status":"ok","scanStatus":{"scanning":false,"lastScan":"scan"}}"#)
            case "getPlaylists":
                return envelope(#"{"status":"ok","playlists":{"playlist":[]}}"#)
            case "getStarred2":
                return envelope(#"{"status":"ok","starred2":{}}"#)
            default:
                return StubURLProtocol.Response(statusCode: 500, json: "{}")
            }
        }
        let client = try #require(
            NavidromeClient(profile: makeProfile(), session: StubURLProtocol.session(handler: handler))
        )
        let coordinator = LibrarySyncCoordinator(store: store)

        #expect(try await coordinator.synchronize(client: client, serverKey: "server") == .metadataOnly)
        #expect(try await store.playlists(serverKey: "server").isEmpty)
        #expect(try await store.favoriteSongs(serverKey: "server").isEmpty)
        #expect(try await store.songs(serverKey: "server", albumID: "album-1").map(\.id) == ["song"])
    }

    @Test func failedChangedCatalogDownloadLeavesPreviousSnapshotIntact() async throws {
        let store = LibraryStore(
            persistence: PersistenceController(inMemory: true),
            keychain: MemoryCredentialStore()
        )
        let original = makeSong(id: "original")
        try await store.apply(
            LibrarySnapshot(
                artists: [],
                albums: [],
                songs: [original],
                playlists: [],
                favorites: FavoriteMetadata(),
                catalogToken: "scan-1",
                checkedAt: Date()
            ),
            serverKey: "server"
        )
        let handler: StubURLProtocol.Handler = { request in
            switch apiMethod(in: request) {
            case "getScanStatus":
                return envelope(#"{"status":"ok","scanStatus":{"scanning":false,"lastScan":"scan-2"}}"#)
            case "search3":
                if queryValue("albumCount", in: request) != "0" {
                    return StubURLProtocol.Response(statusCode: 503, json: "{}")
                }
                return envelope(#"{"status":"ok","searchResult3":{}}"#)
            case "getPlaylists":
                return envelope(#"{"status":"ok","playlists":{"playlist":[]}}"#)
            case "getStarred2":
                return envelope(#"{"status":"ok","starred2":{}}"#)
            default:
                return StubURLProtocol.Response(statusCode: 500, json: "{}")
            }
        }
        let client = try #require(
            NavidromeClient(profile: makeProfile(), session: StubURLProtocol.session(handler: handler))
        )
        let coordinator = LibrarySyncCoordinator(store: store)

        do {
            _ = try await coordinator.synchronize(client: client, serverKey: "server")
            Issue.record("Expected the catalog download to fail")
        } catch {
            #expect(error.localizedDescription == "HTTP 503")
        }

        #expect(try await store.metadataSyncState(serverKey: "server").catalogToken == "scan-1")
        #expect(try await store.randomSongs(serverKey: "server", count: 10).map(\.id) == ["original"])
    }

    @Test func concurrentChecksShareOneSynchronization() async throws {
        let store = LibraryStore(
            persistence: PersistenceController(inMemory: true),
            keychain: MemoryCredentialStore()
        )
        try await store.apply(
            LibrarySnapshot(
                artists: [],
                albums: [],
                songs: [],
                playlists: [],
                favorites: FavoriteMetadata(),
                catalogToken: "scan",
                checkedAt: Date()
            ),
            serverKey: "server"
        )
        let lock = NSLock()
        nonisolated(unsafe) var scanRequests = 0
        let handler: StubURLProtocol.Handler = { request in
            switch apiMethod(in: request) {
            case "getScanStatus":
                lock.withLock { scanRequests += 1 }
                Thread.sleep(forTimeInterval: 0.05)
                return envelope(#"{"status":"ok","scanStatus":{"scanning":false,"lastScan":"scan"}}"#)
            case "getPlaylists":
                return envelope(#"{"status":"ok","playlists":{"playlist":[]}}"#)
            case "getStarred2":
                return envelope(#"{"status":"ok","starred2":{}}"#)
            default:
                return StubURLProtocol.Response(statusCode: 500, json: "{}")
            }
        }
        let client = try #require(
            NavidromeClient(profile: makeProfile(), session: StubURLProtocol.session(handler: handler))
        )
        let coordinator = LibrarySyncCoordinator(store: store)

        async let first = coordinator.synchronize(client: client, serverKey: "server")
        async let second = coordinator.synchronize(client: client, serverKey: "server")
        let outcomes = try await (first, second)

        #expect(outcomes.0 == .metadataOnly)
        #expect(outcomes.1 == .metadataOnly)
        #expect(lock.withLock { scanRequests } == 1)
    }
}
