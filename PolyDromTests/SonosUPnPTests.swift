import AVFoundation
import Foundation
import Synchronization
import Testing
@testable import PolyDrom

@Suite(.serialized)
@MainActor
struct SonosUPnPTests {
    @Test func ssdpAcceptsOnlySonosDescriptionFromReplyingHost() {
        let reply = """
        HTTP/1.1 200 OK\r
        ST: urn:schemas-upnp-org:device:ZonePlayer:1\r
        LOCATION: http://192.168.1.20:1400/xml/device_description.xml\r
        \r
        """
        let address = SonosSSDP.parseResponse(reply, from: "192.168.1.20")
        #expect(address?.host == "192.168.1.20")
        #expect(address?.location.path == "/xml/device_description.xml")
        #expect(SonosSSDP.parseResponse(reply, from: "192.168.1.21") == nil)
        #expect(SonosSSDP.parseResponse(reply.replacingOccurrences(of: "ZonePlayer:1", with: "MediaRenderer:1"), from: "192.168.1.20") == nil)
    }

    @Test func deviceDescriptionAndGroupTopologyIdentifyCoordinator() async throws {
        let session = StubURLProtocol.session { _ in
            StubURLProtocol.Response(data: Data(Self.description.utf8))
        }
        let upnp = SonosUPnP(session: session)
        let url = try #require(URL(string: "http://192.168.1.20:1400/xml/device_description.xml"))
        let device = try await upnp.describe(url, expectedHost: "192.168.1.20")
        #expect(device.id == "RINCON-1")
        #expect(device.name == "Living Room")
        #expect(device.services["AVTransport"]?.url.path == "/MediaRenderer/AVTransport/Control")
        #expect(device.services["GroupRenderingControl"] != nil)
        let topology = try SonosXML.parse(Data(Self.topology.utf8))
        let groups = SonosUPnP.groups(from: topology, devices: [device.id: device])
        #expect(groups.count == 1)
        #expect(groups.first?.name == "Living Room + Kitchen")
        #expect(groups.first?.memberIDs == ["RINCON-1", "RINCON-2"])
        #expect(groups.first?.coordinator.id == "RINCON-1")
        await #expect(throws: SonosError.self) {
            try await upnp.describe(url, expectedHost: "192.168.1.99")
        }
    }

    @Test func soapFaultAndEscapedMetadataAreParsed() async throws {
        let bodies = Mutex<[Data]>([])
        let session = StubURLProtocol.session { request in
            if let body = Self.bodyData(request) { bodies.withLock { $0.append(body) } }
            if Self.actionName(request) == "Play" {
                return StubURLProtocol.Response(statusCode: 500, data: Data(Self.fault.utf8))
            }
            return Self.response(for: request)
        }
        let upnp = SonosUPnP(session: session)
        let device = Self.device()
        let song = makeSong(title: "A & <B>", artist: "O'Neil", album: "A \"Record\"", coverArt: "cover")
        let stream = try #require(URL(string: "https://music.example.com/rest/stream?id=track&token=example"))
        let artwork = try #require(URL(string: "https://music.example.com/rest/getCoverArt?id=cover&token=example"))
        let first = SonosQueueItem(entryID: UUID(), song: song, streamURL: stream, artworkURL: artwork)
        let second = SonosQueueItem(entryID: UUID(), song: song, streamURL: stream, artworkURL: artwork)
        try await upnp.addQueueItems([first, second], to: device)
        let body = try #require(bodies.withLock { $0.first })
        let root = try SonosXML.parse(body)
        let action = try #require(root.firstDescendant(named: "AddMultipleURIsToQueue"))
        #expect(action.child(named: "NumberOfURIs")?.text == "2")
        #expect(action.child(named: "EnqueuedURIs")?.text == "\(stream.absoluteString) \(stream.absoluteString)")
        let metadata = try #require(action.child(named: "EnqueuedURIsMetaData")?.text)
        #expect(metadata.contains(first.entryID.uuidString))
        #expect(metadata.contains(second.entryID.uuidString))
        #expect(metadata.contains("A &amp; &lt;B&gt;"))
        #expect(metadata.contains("O&apos;Neil"))
        #expect(metadata.contains("audio/mpeg"))
        #expect(metadata.contains("albumArtURI"))
        do {
            try await upnp.transport("Play", on: device)
            Issue.record("Expected a SOAP fault")
        } catch SonosError.soapFault(let code) {
            #expect(code == "701")
        }
    }

    @Test func positionQueueVersionAndGroupVolumeReadSoapFields() async throws {
        let bodies = Mutex<[Data]>([])
        let upnp = SonosUPnP(session: StubURLProtocol.session { request in
            if let body = Self.bodyData(request) { bodies.withLock { $0.append(body) } }
            return Self.response(for: request)
        })
        let device = Self.device()
        let position = try await upnp.position(on: device)
        #expect(position.track == 2)
        #expect(position.seconds == 37)
        #expect(position.duration == 185)
        #expect(position.transportState == "PLAYING")
        #expect(position.sourceURI == SonosUPnP.queueURI(for: device))
        #expect(try await upnp.queueVersion(on: device) == "42")
        #expect(try await upnp.groupVolume(on: device) == 23)
        try await upnp.setGroupVolume(150, on: device)
        let root = try SonosXML.parse(try #require(bodies.withLock { $0.last }))
        #expect(root.firstDescendant(named: "DesiredVolume")?.text == "100")
    }

    @Test func routeCopiesDuplicateTracksThenClearsOwnedQueueOnExit() async throws {
        let requests = Mutex<[URLRequest]>([])
        let session = StubURLProtocol.session { request in
            requests.withLock { $0.append(request) }
            return Self.response(for: request)
        }
        let (model, _, _) = makeViewModel(sonosUPnP: SonosUPnP(session: session))
        let profile = makeProfile()
        model.activeServer = profile
        model.client = NavidromeClient(profile: profile, session: session)
        model.isOnline = true
        let song = makeSong(id: "duplicate", duration: 185)
        let queue = (0..<20).map { _ in PlaybackQueueEntry(song: song) }
        model.playbackQueue = queue
        model.currentPlaybackQueueEntryID = queue[0].id
        model.audioPlayer.restore(song: song, at: 37)
        model.selectSonosGroup(Self.group())

        #expect(await eventually(timeout: .seconds(3)) {
            model.audioPlayer.route == .sonos("group-1") && model.sonosQueueSynced == 20
        })
        #expect(model.audioPlayer.currentTime == 37)
        #expect(model.audioPlayer.volume == 0.23)
        #expect(model.playbackQueue.map(\.id) == queue.map(\.id))
        #expect(requests.withLock { $0.filter { Self.actionName($0) == "AddMultipleURIsToQueue" }.count } == 3)
        let currentIndex = try #require(model.playbackQueue.firstIndex {
            $0.id == model.currentPlaybackQueueEntryID
        })
        model.playNext([makeSong(id: "new-next")])
        #expect(await eventually { model.playbackQueue.count == 21 })
        #expect(model.playbackQueue[currentIndex + 1].song.id == "new-next")
        model.addToQueue([makeSong(id: "new-last")])
        #expect(await eventually { model.playbackQueue.count == 22 })
        #expect(model.playbackQueue.last?.song.id == "new-last")
        #expect(requests.withLock { $0.filter { Self.actionName($0) == "AddURIToQueue" }.count } == 2)
        model.switchToLocalOutput()
        #expect(await eventually(timeout: .seconds(3)) { model.audioPlayer.route == .local })
        #expect(model.audioPlayer.currentTime == 37)
        #expect(requests.withLock { $0.contains { Self.actionName($0) == "RemoveAllTracksFromQueue" } })
    }

    @Test func quittingStopsAndClearsSonosWithoutDeletingSavedQueue() async throws {
        let requests = Mutex<[String]>([])
        let session = StubURLProtocol.session { request in
            requests.withLock { $0.append(Self.actionName(request)) }
            return Self.response(for: request, track: 1)
        }
        let (model, _, _) = makeViewModel(sonosUPnP: SonosUPnP(session: session))
        let profile = makeProfile()
        model.activeServer = profile
        model.client = NavidromeClient(profile: profile, session: session)
        model.isOnline = true
        let entry = PlaybackQueueEntry(song: makeSong())
        model.playbackQueue = [entry]
        model.currentPlaybackQueueEntryID = entry.id
        model.audioPlayer.restore(song: entry.song, at: 25)
        model.selectSonosGroup(Self.group())
        #expect(await eventually { model.sonosSession?.expectedQueueVersion == "42" })
        let positionBeforeQuit = model.audioPlayer.currentTime
        let initialClears = requests.withLock { $0.filter { $0 == "RemoveAllTracksFromQueue" }.count }

        await model.stopSonosForTermination()

        #expect(requests.withLock { $0.filter { $0 == "RemoveAllTracksFromQueue" }.count } == initialClears + 1)
        #expect(requests.withLock { $0.filter { $0 == "Stop" }.count } >= 2)
        #expect(model.playbackQueue.map(\.id) == [entry.id])
        #expect(model.audioPlayer.currentSong == entry.song)
        #expect(model.audioPlayer.currentTime == positionBeforeQuit)
        #expect(!model.audioPlayer.isPlaying)
    }

    @Test func failedHandoffKeepsLocalSongAndPosition() async throws {
        let session = StubURLProtocol.session { request in
            if Self.actionName(request) == "SetAVTransportURI" {
                return StubURLProtocol.Response(statusCode: 500, data: Data(Self.fault.utf8))
            }
            return Self.response(for: request)
        }
        let (model, _, _) = makeViewModel(sonosUPnP: SonosUPnP(session: session))
        let profile = makeProfile()
        model.activeServer = profile
        model.client = NavidromeClient(profile: profile, session: session)
        model.isOnline = true
        let song = makeSong()
        let entry = PlaybackQueueEntry(song: song)
        model.playbackQueue = [entry]
        model.currentPlaybackQueueEntryID = entry.id
        model.audioPlayer.restore(song: song, at: 29)
        model.selectSonosGroup(Self.group())

        #expect(await eventually(timeout: .seconds(3)) { model.sonosMessage?.contains("701") == true })
        #expect(model.audioPlayer.route == .local)
        #expect(model.audioPlayer.currentSong == song)
        #expect(model.audioPlayer.currentTime == 29)
    }

    @Test func failedSonosPlayResumesLocalAudio() async throws {
        let localAudio = try Self.silentWAV()
        defer { try? FileManager.default.removeItem(at: localAudio) }
        let session = StubURLProtocol.session { request in
            if Self.actionName(request) == "Play" {
                return StubURLProtocol.Response(statusCode: 500, data: Data(Self.fault.utf8))
            }
            return Self.response(for: request, track: 1)
        }
        let (model, _, _) = makeViewModel(sonosUPnP: SonosUPnP(session: session))
        let profile = makeProfile()
        model.activeServer = profile
        model.client = NavidromeClient(profile: profile, session: session)
        model.isOnline = true
        let song = makeSong(duration: 10)
        let entry = PlaybackQueueEntry(song: song)
        model.playbackQueue = [entry]
        model.currentPlaybackQueueEntryID = entry.id
        model.audioPlayer.play(song: song, url: localAudio, startingAt: 1)
        #expect(await eventually(timeout: .seconds(3)) { model.audioPlayer.player.rate > 0 })

        model.selectSonosGroup(Self.group())

        #expect(await eventually(timeout: .seconds(3)) { model.sonosMessage?.contains("701") == true })
        #expect(model.audioPlayer.route == .local)
        #expect(model.audioPlayer.currentSong == song)
        #expect(model.audioPlayer.isPlaying)
        #expect(await eventually(timeout: .seconds(3)) { model.audioPlayer.player.rate > 0 })
    }

    @Test func externalNavigationVolumeAndQueueConflictUpdateSharedState() async throws {
        let speaker = Mutex((track: 1, volume: 23, version: "42"))
        let session = StubURLProtocol.session { request in
            let state = speaker.withLock { $0 }
            return Self.response(
                for: request, track: state.track, volume: state.volume, version: state.version
            )
        }
        let (model, _, _) = makeViewModel(sonosUPnP: SonosUPnP(session: session))
        let profile = makeProfile()
        model.activeServer = profile
        model.client = NavidromeClient(profile: profile, session: session)
        model.isOnline = true
        let first = PlaybackQueueEntry(song: makeSong(id: "first"))
        let second = PlaybackQueueEntry(song: makeSong(id: "second"))
        model.playbackQueue = [first, second]
        model.currentPlaybackQueueEntryID = first.id
        model.audioPlayer.restore(song: first.song, at: 12)
        var events: [AudioPlaybackEvent.Trigger] = []
        model.audioPlayer.onPlaybackEvent = { events.append($0.trigger) }
        model.selectSonosGroup(Self.group())
        #expect(await eventually(timeout: .seconds(3)) {
            model.sonosSession?.expectedQueueVersion == "42"
        })

        speaker.withLock { $0.track = 2; $0.volume = 55 }
        await model.pollSonosOnce(generation: model.sonosGeneration, tick: 5)
        #expect(model.currentPlaybackQueueEntryID == second.id)
        #expect(model.audioPlayer.currentSong == second.song)
        #expect(model.audioPlayer.volume == 0.55)
        speaker.withLock { $0.track = 1 }
        await model.pollSonosOnce(generation: model.sonosGeneration, tick: 0)
        #expect(model.currentPlaybackQueueEntryID == first.id)
        #expect(model.audioPlayer.currentSong == first.song)
        #expect(events.filter { $0 == .started }.count == 2)
        #expect(events.filter { $0 == .stopped }.count == 2)

        speaker.withLock { $0.version = "43" }
        await model.pollSonosOnce(generation: model.sonosGeneration, tick: 5)
        #expect(model.audioPlayer.route == .local)
        #expect(model.sonosMessage == SonosError.queueChanged.localizedDescription)
    }

    nonisolated private static func actionName(_ request: URLRequest) -> String {
        request.value(forHTTPHeaderField: "SOAPACTION")?
            .split(separator: "#").last?.trimmingCharacters(in: CharacterSet(charactersIn: "\"")) ?? ""
    }

    nonisolated private static func bodyData(_ request: URLRequest) -> Data? {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }
            data.append(contentsOf: buffer.prefix(count))
        }
        return data
    }

    private static func silentWAV() throws -> URL {
        let samples = 441_000
        let pcmBytes = samples * 2
        var data = Data("RIFF".utf8)
        appendLittleEndian(UInt32(36 + pcmBytes), to: &data)
        data.append(contentsOf: Data("WAVEfmt ".utf8))
        appendLittleEndian(UInt32(16), to: &data)
        appendLittleEndian(UInt16(1), to: &data)
        appendLittleEndian(UInt16(1), to: &data)
        appendLittleEndian(UInt32(44_100), to: &data)
        appendLittleEndian(UInt32(88_200), to: &data)
        appendLittleEndian(UInt16(2), to: &data)
        appendLittleEndian(UInt16(16), to: &data)
        data.append(contentsOf: Data("data".utf8))
        appendLittleEndian(UInt32(pcmBytes), to: &data)
        data.append(Data(repeating: 0, count: pcmBytes))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).wav")
        try data.write(to: url)
        return url
    }

    private static func appendLittleEndian<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
        var encoded = value.littleEndian
        withUnsafeBytes(of: &encoded) { data.append(contentsOf: $0) }
    }

    nonisolated private static func response(
        for request: URLRequest, track: Int = 2, volume: Int = 23, version: String = "42"
    ) -> StubURLProtocol.Response {
        let action = actionName(request)
        let fields: String
        switch action {
        case "GetGroupVolume": fields = "<CurrentVolume>\(volume)</CurrentVolume>"
        case "GetTransportInfo": fields = "<CurrentTransportState>PLAYING</CurrentTransportState><CurrentTransportStatus>OK</CurrentTransportStatus>"
        case "GetPositionInfo": fields = "<Track>\(track)</Track><TrackDuration>00:03:05</TrackDuration><RelTime>00:00:37</RelTime>"
        case "GetMediaInfo": fields = "<CurrentURI>x-rincon-queue:RINCON-1#0</CurrentURI>"
        case "Browse": fields = "<UpdateID>\(version)</UpdateID>"
        default: fields = ""
        }
        return StubURLProtocol.Response(data: Data("<s:Envelope xmlns:s=\"http://schemas.xmlsoap.org/soap/envelope/\"><s:Body><u:\(action)Response xmlns:u=\"urn:schemas-upnp-org:service:AVTransport:1\">\(fields)</u:\(action)Response></s:Body></s:Envelope>".utf8))
    }

    private static func device() -> SonosDevice {
        let host = "http://192.168.1.20:1400"
        let serviceNames = ["AVTransport", "ZoneGroupTopology", "ContentDirectory", "GroupRenderingControl"]
        let services = Dictionary(uniqueKeysWithValues: serviceNames.map { name in
            (name, SonosServiceEndpoint(
                type: "urn:schemas-upnp-org:service:\(name):1",
                url: URL(string: "\(host)/\(name)/Control")!
            ))
        })
        return SonosDevice(
            id: "RINCON-1", name: "Living Room",
            descriptionURL: URL(string: "\(host)/xml/device_description.xml")!,
            services: services
        )
    }

    private static func group() -> SonosGroup {
        SonosGroup(id: "group-1", name: "Living Room", coordinator: device(), memberIDs: ["RINCON-1"])
    }

    nonisolated private static let description = """
    <root><device><manufacturer>Sonos, Inc.</manufacturer><UDN>uuid:RINCON-1</UDN>
    <roomName>Living Room</roomName><serviceList>
    <service><serviceType>urn:schemas-upnp-org:service:AVTransport:1</serviceType><controlURL>/MediaRenderer/AVTransport/Control</controlURL></service>
    <service><serviceType>urn:schemas-upnp-org:service:GroupRenderingControl:1</serviceType><controlURL>/GroupRenderingControl/Control</controlURL></service>
    </serviceList></device></root>
    """

    nonisolated private static let topology = """
    <ZoneGroups><ZoneGroup Coordinator="RINCON-1" ID="group-1">
    <ZoneGroupMember UUID="RINCON-1" ZoneName="Living Room" />
    <ZoneGroupMember UUID="RINCON-2" ZoneName="Kitchen" />
    <ZoneGroupMember UUID="satellite" ZoneName="Satellite" Invisible="1" />
    </ZoneGroup></ZoneGroups>
    """

    nonisolated private static let fault = """
    <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/"><s:Body><s:Fault>
    <faultcode>s:Client</faultcode><detail><UPnPError><errorCode>701</errorCode></UPnPError></detail>
    </s:Fault></s:Body></s:Envelope>
    """
}
