import Foundation
import Testing
@testable import PolyDrom

final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    typealias Handler = @Sendable (URLRequest) throws -> Response

    struct Response: Sendable {
        let statusCode: Int
        let headers: [String: String]
        let data: Data

        init(statusCode: Int = 200, headers: [String: String] = ["Content-Type": "application/json"], data: Data) {
            self.statusCode = statusCode
            self.headers = headers
            self.data = data
        }

        init(statusCode: Int = 200, json: String) {
            self.init(statusCode: statusCode, data: Data(json.utf8))
        }
    }

    private static let defaultHandler: Handler = { _ in
        Response(statusCode: 500, json: #"{"error":"No stub configured"}"#)
    }
    nonisolated(unsafe) static var requestObserver: (@Sendable (URLRequest) -> Void)?
    private static let registryLock = NSLock()
    nonisolated(unsafe) private static var handlers: [String: Handler] = [:]
    private static let sessionHeader = "X-PolyDrom-Test-Session"

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        do {
            Self.requestObserver?(request)
            let sessionID = request.value(forHTTPHeaderField: Self.sessionHeader)
            Self.registryLock.lock()
            let sessionHandler = sessionID.flatMap { Self.handlers[$0] }
            Self.registryLock.unlock()
            let stub = try (sessionHandler ?? Self.defaultHandler)(request)
            let response = HTTPURLResponse(
                url: try #require(request.url),
                statusCode: stub.statusCode,
                httpVersion: "HTTP/1.1",
                headerFields: stub.headers
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: stub.data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}

    static func session() -> URLSession {
        session(handler: defaultHandler)
    }

    static func session(handler: @escaping Handler) -> URLSession {
        let sessionID = UUID().uuidString
        registryLock.lock()
        handlers[sessionID] = handler
        registryLock.unlock()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        configuration.httpAdditionalHeaders = [sessionHeader: sessionID]
        return URLSession(configuration: configuration)
    }
}

final class MemoryCredentialStore: CredentialStoring {
    var passwords: [String: String] = [:]
    var savedCredentialIDs: [String] = []
    var deletedCredentialIDs: [String] = []
    var error: Error?

    func password(for credentialID: String) throws -> String? {
        if let error { throw error }
        return passwords[credentialID]
    }

    func save(password: String, credentialID: String) throws {
        if let error { throw error }
        passwords[credentialID] = password
        savedCredentialIDs.append(credentialID)
    }

    func delete(credentialID: String) throws {
        if let error { throw error }
        passwords[credentialID] = nil
        deletedCredentialIDs.append(credentialID)
    }
}

enum TestFailure: Error, LocalizedError {
    case intentional

    var errorDescription: String? { "Intentional test failure" }
}

func makeProfile(
    id: UUID = UUID(),
    name: String = "Test Server",
    address: String = "https://music.example.com",
    username: String = "User",
    credentialID: String = UUID().uuidString,
    password: String = "password",
    createdAt: Date = Date(timeIntervalSince1970: 100),
    lastConnectedAt: Date? = nil
) -> ServerProfile {
    ServerProfile(
        id: id,
        name: name,
        address: address,
        username: username,
        credentialID: credentialID,
        password: password,
        createdAt: createdAt,
        lastConnectedAt: lastConnectedAt
    )
}

func makeSong(
    id: String = "song-1",
    title: String = "Song",
    artist: String? = "Artist",
    album: String? = "Album",
    duration: Int? = 185,
    coverArt: String? = nil,
    albumId: String? = "album-1",
    artistId: String? = "artist-1"
) -> NavidromeSong {
    NavidromeSong(
        id: id,
        title: title,
        artist: artist,
        album: album,
        duration: duration,
        coverArt: coverArt,
        albumId: albumId,
        artistId: artistId
    )
}

func queryValue(_ name: String, in request: URLRequest) -> String? {
    guard let url = request.url,
          let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
    return components.queryItems?.first(where: { $0.name == name })?.value
}

func apiMethod(in request: URLRequest) -> String {
    request.url?.deletingPathExtension().lastPathComponent ?? ""
}

func envelope(_ body: String) -> StubURLProtocol.Response {
    StubURLProtocol.Response(json: #"{"subsonic-response":\#(body)}"#)
}

func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

let onePixelPNG = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=")!

@MainActor
func makeViewModel(
    credentials: MemoryCredentialStore = MemoryCredentialStore(),
    session: URLSession = StubURLProtocol.session(),
    userDefaults: UserDefaults = temporaryUserDefaults()
) -> (AppCoordinator, LibraryStore, MemoryCredentialStore) {
    let store = LibraryStore(persistence: PersistenceController(inMemory: true), keychain: credentials)
    let viewModel = AppCoordinator(
        store: store,
        audioPlayer: AudioPlayer(),
        clientFactory: { NavidromeClient(profile: $0, session: session) },
        coverArtCache: CoverArtCache(
            session: session,
            diskDirectory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        ),
        serverRegistry: ServerRegistry(fileURL: nil, keychain: credentials),
        userDefaults: userDefaults
    )
    return (viewModel, store, credentials)
}

func temporaryUserDefaults() -> UserDefaults {
    let suiteName = "PolyDromTests.\(UUID().uuidString)"
    let userDefaults = UserDefaults(suiteName: suiteName)!
    userDefaults.removePersistentDomain(forName: suiteName)
    return userDefaults
}

func eventually(
    timeout: Duration = .seconds(2),
    condition: @escaping @MainActor () -> Bool
) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while clock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return await condition()
}
