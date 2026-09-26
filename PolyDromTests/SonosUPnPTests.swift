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

    @Test func singleTrackQueueMetadataAndSoapFaultAreParsed() async throws {
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
        let track = SonosTrack(entryID: UUID(), song: song, streamURL: stream, artworkURL: artwork)
        try await upnp.enqueueTrack(track, on: device)
        let body = try #require(bodies.withLock { $0.first })
        let root = try SonosXML.parse(body)
        let action = try #require(root.firstDescendant(named: "AddURIToQueue"))
        #expect(action.child(named: "EnqueuedURI")?.text == stream.absoluteString)
        let metadata = try #require(action.child(named: "EnqueuedURIMetaData")?.text)
        #expect(metadata.contains(track.entryID.uuidString))
        #expect(metadata.contains("A &amp; &lt;B&gt;"))
        #expect(metadata.contains("O&apos;Neil"))
        #expect(metadata.contains("<upnp:album>A &quot;Record&quot;</upnp:album>"))
        #expect(metadata.contains("duration=\"00:03:05\""))
        #expect(metadata.contains("audio/mpeg"))
        #expect(metadata.contains("albumArtURI"))
        try await upnp.useQueue(device)
        try await upnp.seekFirstTrack(on: device)
        let actions = try bodies.withLock { bodies in
            try bodies.compactMap { try SonosXML.parse($0).firstDescendant(named: "SetAVTransportURI") }
        }
        #expect(actions.first?.child(named: "CurrentURI")?.text == SonosUPnP.queueURI(for: device))
        do {
            try await upnp.transport("Play", on: device)
            Issue.record("Expected a SOAP fault")
        } catch SonosError.soapFault(let code) {
            #expect(code == "701")
        }
    }

    @Test func positionAndGroupVolumeReadSoapFields() async throws {
        let bodies = Mutex<[Data]>([])
        let upnp = SonosUPnP(session: StubURLProtocol.session { request in
            if let body = Self.bodyData(request) { bodies.withLock { $0.append(body) } }
            return Self.response(
                for: request, trackURI: "https://music.example.com/rest/stream?id=track"
            )
        })
        let device = Self.device()
        let position = try await upnp.position(on: device)
        #expect(position.track == 1)
        #expect(position.seconds == 37)
        #expect(position.duration == 185)
        #expect(position.transportState == "PLAYING")
        #expect(position.sourceURI == SonosUPnP.queueURI(for: device))
        #expect(position.trackURI == "https://music.example.com/rest/stream?id=track")
        #expect(try await upnp.groupVolume(on: device) == 23)
        try await upnp.setGroupVolume(150, on: device)
        let root = try SonosXML.parse(try #require(bodies.withLock { $0.last }))
        #expect(root.firstDescendant(named: "DesiredVolume")?.text == "100")
    }

    @Test func routeStreamsOneTrackAndKeepsQueueLocal() async throws {
        let speaker = Mutex((requests: [URLRequest](), sourceURI: ""))
        let session = StubURLProtocol.session { request in
            let source = speaker.withLock { state in
                state.requests.append(request)
                if Self.actionName(request) == "SetAVTransportURI" {
                    state.sourceURI = Self.requestField("CurrentURI", in: request) ?? ""
                }
                return state.sourceURI
            }
            return Self.response(for: request, sourceURI: source)
        }
        let (model, _, _) = makeViewModel(sonosUPnP: SonosUPnP(session: session))
        let profile = makeProfile(address: "music.example.com")
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
            model.audioPlayer.route == .sonos("group-1") && model.sonosSession?.sourceURI != nil
        })
        #expect(model.audioPlayer.currentTime == 37)
        #expect(model.audioPlayer.volume == 0.23)
        #expect(model.playbackQueue.map(\.id) == queue.map(\.id))
        #expect(speaker.withLock { $0.requests.filter { Self.actionName($0) == "SetAVTransportURI" }.count } == 1)
        #expect(speaker.withLock { $0.requests.filter { Self.actionName($0) == "AddURIToQueue" }.count } == 1)
        let trackRequest = try #require(speaker.withLock {
            $0.requests.first(where: { Self.actionName($0) == "AddURIToQueue" })
        })
        let trackBody = try #require(Self.bodyData(trackRequest))
        let trackAction = try #require(SonosXML.parse(trackBody).firstDescendant(named: "AddURIToQueue"))
        let trackMetadata = try #require(trackAction.child(named: "EnqueuedURIMetaData")?.text)
        #expect(trackMetadata.contains("<dc:creator>Artist</dc:creator>"))
        #expect(trackMetadata.contains("<upnp:album>Album</upnp:album>"))
        #expect(trackMetadata.contains("duration=\"00:03:05\""))
        #expect(trackMetadata.contains("<upnp:albumArtURI>"))
        #expect(trackMetadata.contains("https://music.example.com/rest/getCoverArt"))
        #expect(trackMetadata.contains("id=album-1&amp;size=512"))
        let currentIndex = try #require(model.playbackQueue.firstIndex {
            $0.id == model.currentPlaybackQueueEntryID
        })
        model.playNext([makeSong(id: "new-next")])
        #expect(model.playbackQueue.count == 21)
        #expect(model.playbackQueue[currentIndex + 1].song.id == "new-next")
        model.addToQueue([makeSong(id: "new-last")])
        #expect(model.playbackQueue.count == 22)
        #expect(model.playbackQueue.last?.song.id == "new-last")
        #expect(speaker.withLock { $0.requests.filter { Self.actionName($0) == "AddURIToQueue" }.count } == 1)
        model.switchToLocalOutput()
        #expect(await eventually(timeout: .seconds(3)) { model.audioPlayer.route == .local })
        #expect(model.audioPlayer.currentTime == 37)
        #expect(speaker.withLock { $0.requests.contains { Self.actionName($0) == "Stop" } })
        #expect(speaker.withLock { $0.requests.filter { Self.actionName($0) == "RemoveAllTracksFromQueue" }.count } == 2)
        #expect(speaker.withLock { $0.requests.allSatisfy { !Self.bulkQueueActions.contains(Self.actionName($0)) } })
    }

    @Test func quittingStopsSonosWithoutDeletingSavedQueue() async throws {
        let speaker = Mutex((requests: [String](), sourceURI: ""))
        let session = StubURLProtocol.session { request in
            let source = speaker.withLock { state in
                state.requests.append(Self.actionName(request))
                if Self.actionName(request) == "SetAVTransportURI" {
                    state.sourceURI = Self.requestField("CurrentURI", in: request) ?? ""
                }
                return state.sourceURI
            }
            return Self.response(for: request, track: 1, sourceURI: source)
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
        #expect(await eventually { model.sonosSession?.sourceURI != nil })
        let positionBeforeQuit = model.audioPlayer.currentTime
        let initialStops = speaker.withLock { $0.requests.filter { $0 == "Stop" }.count }
        let initialClears = speaker.withLock { $0.requests.filter { $0 == "RemoveAllTracksFromQueue" }.count }

        await model.stopSonosForTermination()

        #expect(speaker.withLock { $0.requests.filter { $0 == "Stop" }.count } == initialStops + 1)
        #expect(speaker.withLock { $0.requests.filter { $0 == "RemoveAllTracksFromQueue" }.count } == initialClears + 1)
        #expect(speaker.withLock { $0.requests.allSatisfy { !Self.bulkQueueActions.contains($0) } })
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

    @Test func finishedTrackStartsNextLocalQueueEntry() async throws {
        let speaker = Mutex((sourceURI: "", state: "PLAYING", seconds: 37, requests: [String]()))
        let session = StubURLProtocol.session { request in
            let state = speaker.withLock { speaker in
                speaker.requests.append(Self.actionName(request))
                if Self.actionName(request) == "SetAVTransportURI" {
                    speaker.sourceURI = Self.requestField("CurrentURI", in: request) ?? ""
                }
                if Self.actionName(request) == "Play" {
                    speaker.state = "PLAYING"
                    speaker.seconds = 0
                }
                return speaker
            }
            return Self.response(
                for: request, sourceURI: state.sourceURI,
                transportState: state.state, seconds: state.seconds
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
        model.selectSonosGroup(Self.group())
        #expect(await eventually(timeout: .seconds(3)) {
            model.sonosSession?.sourceURI != nil && model.audioPlayer.isPlaying
        })

        speaker.withLock { $0.state = "STOPPED"; $0.seconds = 185 }
        await model.pollSonosOnce(generation: model.sonosGeneration, tick: 1)
        #expect(await eventually(timeout: .seconds(3)) { model.currentPlaybackQueueEntryID == second.id })
        #expect(model.currentPlaybackQueueEntryID == second.id)
        #expect(model.audioPlayer.currentSong == second.song)
        #expect(speaker.withLock { $0.requests.filter { $0 == "AddURIToQueue" }.count } == 2)
        #expect(speaker.withLock { $0.requests.allSatisfy { !Self.bulkQueueActions.contains($0) } })
    }

    @Test func externalSourceChangeDetachesWithoutCheckingSonosQueue() async throws {
        let speaker = Mutex((sourceURI: "", volume: 23, requests: [String]()))
        let session = StubURLProtocol.session { request in
            let state = speaker.withLock { speaker in
                speaker.requests.append(Self.actionName(request))
                if Self.actionName(request) == "SetAVTransportURI" {
                    speaker.sourceURI = Self.requestField("CurrentURI", in: request) ?? ""
                }
                return speaker
            }
            return Self.response(for: request, volume: state.volume, sourceURI: state.sourceURI)
        }
        let (model, _, _) = makeViewModel(sonosUPnP: SonosUPnP(session: session))
        let profile = makeProfile()
        model.activeServer = profile
        model.client = NavidromeClient(profile: profile, session: session)
        model.isOnline = true
        let entry = PlaybackQueueEntry(song: makeSong())
        model.playbackQueue = [entry]
        model.currentPlaybackQueueEntryID = entry.id
        model.audioPlayer.restore(song: entry.song, at: 12)
        model.selectSonosGroup(Self.group())
        #expect(await eventually(timeout: .seconds(3)) { model.sonosSession?.sourceURI != nil })

        speaker.withLock { $0.volume = 55 }
        await model.pollSonosOnce(generation: model.sonosGeneration, tick: 5)
        #expect(model.audioPlayer.volume == 0.55)

        speaker.withLock { $0.sourceURI = "https://another.example.com/song.mp3" }
        await model.pollSonosOnce(generation: model.sonosGeneration, tick: 5)
        #expect(model.audioPlayer.route == .local)
        #expect(model.sonosMessage == SonosError.sourceChanged.localizedDescription)
        #expect(speaker.withLock { $0.requests.allSatisfy { !Self.bulkQueueActions.contains($0) } })
    }

    @Test func anotherSonosQueueTrackDetachesWithoutClearingIt() async throws {
        let speaker = Mutex((sourceURI: "", trackURI: "", clears: 0))
        let session = StubURLProtocol.session { request in
            let state = speaker.withLock { speaker in
                if Self.actionName(request) == "RemoveAllTracksFromQueue" {
                    speaker.clears += 1
                }
                if Self.actionName(request) == "SetAVTransportURI" {
                    speaker.sourceURI = Self.requestField("CurrentURI", in: request) ?? ""
                }
                if Self.actionName(request) == "AddURIToQueue" {
                    speaker.trackURI = Self.requestField("EnqueuedURI", in: request) ?? ""
                }
                return speaker
            }
            return Self.response(for: request, sourceURI: state.sourceURI, trackURI: state.trackURI)
        }
        let (model, _, _) = makeViewModel(sonosUPnP: SonosUPnP(session: session))
        let profile = makeProfile()
        model.activeServer = profile
        model.client = NavidromeClient(profile: profile, session: session)
        model.isOnline = true
        let entry = PlaybackQueueEntry(song: makeSong())
        model.playbackQueue = [entry]
        model.currentPlaybackQueueEntryID = entry.id
        model.audioPlayer.restore(song: entry.song, at: 12)
        model.selectSonosGroup(Self.group())
        #expect(await eventually(timeout: .seconds(3)) { model.sonosSession?.trackURI != nil })

        let clearsBeforeChange = speaker.withLock { $0.clears }
        speaker.withLock { $0.trackURI = "https://another.example.com/song.mp3" }
        await model.pollSonosOnce(generation: model.sonosGeneration, tick: 0)
        #expect(model.audioPlayer.route == .local)
        #expect(model.sonosMessage == SonosError.sourceChanged.localizedDescription)
        #expect(speaker.withLock { $0.clears } == clearsBeforeChange)
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

    nonisolated private static func requestField(_ name: String, in request: URLRequest) -> String? {
        guard let body = bodyData(request), let root = try? SonosXML.parse(body) else { return nil }
        return root.firstDescendant(named: name)?.text
    }

    nonisolated private static let bulkQueueActions: Set<String> = ["AddMultipleURIsToQueue", "Browse"]

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
        for request: URLRequest, track: Int = 1, volume: Int = 23,
        sourceURI: String = "x-rincon-queue:RINCON-1#0",
        trackURI: String = "",
        transportState: String = "PLAYING", seconds: Int = 37
    ) -> StubURLProtocol.Response {
        let action = actionName(request)
        let fields: String
        switch action {
        case "GetGroupVolume": fields = "<CurrentVolume>\(volume)</CurrentVolume>"
        case "GetTransportInfo": fields = "<CurrentTransportState>\(transportState)</CurrentTransportState><CurrentTransportStatus>OK</CurrentTransportStatus>"
        case "GetPositionInfo": fields = "<Track>\(track)</Track><TrackURI>\(SonosXML.escape(trackURI))</TrackURI><TrackDuration>00:03:05</TrackDuration><RelTime>\(String(format: "%02d:%02d:%02d", seconds / 3600, (seconds / 60) % 60, seconds % 60))</RelTime>"
        case "GetMediaInfo": fields = "<CurrentURI>\(SonosXML.escape(sourceURI))</CurrentURI>"
        case "AddURIToQueue": fields = "<NumTracksAdded>1</NumTracksAdded><NewQueueLength>1</NewQueueLength>"
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
