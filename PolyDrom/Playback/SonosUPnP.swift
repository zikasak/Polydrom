import Darwin
import Foundation

struct SonosServiceEndpoint: Sendable {
    let type: String
    let url: URL
}

struct SonosDevice: Sendable, Identifiable {
    let id: String
    let services: [String: SonosServiceEndpoint]

    func service(_ name: String) throws -> SonosServiceEndpoint {
        guard let service = services[name] else { throw SonosError.unsupportedService(name) }
        return service
    }
}

struct SonosGroup: Sendable, Identifiable {
    let id: String
    let name: String
    let coordinator: SonosDevice
}

struct SonosTrack: Sendable {
    let entryID: UUID
    let song: NavidromeSong
    let streamURL: URL
    let artworkURL: URL?
    var mimeType = "audio/mpeg"
    /// Seconds of the song the stream leaves out at its start.
    var startOffset: Double = 0
    /// False when the speaker cannot jump to another position within the stream.
    var isSeekable = true
}

struct SonosPosition: Sendable {
    let trackURI: String
    let seconds: Double
    let duration: Double
    let transportState: String
    let transportStatus: String
    let sourceURI: String
}

enum SonosError: LocalizedError, Sendable {
    case discoveryUnavailable
    case invalidResponse
    case unsupportedService(String)
    case soapFault(String)
    case localServerAddress
    case sourceChanged

    var errorDescription: String? {
        switch self {
        case .discoveryUnavailable:
            "No Sonos rooms were found. Check Local Network access and that the Mac and Sonos are on the same network."
        case .invalidResponse:
            "The Sonos speaker returned an invalid response."
        case .unsupportedService:
            "This Sonos speaker does not expose a required playback service."
        case .soapFault(let code):
            "Sonos could not complete the playback command (UPnP error \(code))."
        case .localServerAddress:
            "Sonos cannot access a Navidrome address on this Mac. Use a server URL reachable from the speaker."
        case .sourceChanged:
            "Sonos playback changed in another app. PolyDrom stopped controlling it."
        }
    }
}

struct SonosUPnP: Sendable {
    let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func discoverGroups() async throws -> [SonosGroup] {
        let addresses = try await SonosSSDP.search()
        var devices: [String: SonosDevice] = [:]
        for address in addresses {
            if let device = try? await describe(address.location, expectedHost: address.host) {
                devices[device.id] = device
            }
        }
        guard let first = devices.values.first else { throw SonosError.discoveryUnavailable }

        let topology = try await action(first, service: "ZoneGroupTopology", name: "GetZoneGroupState")
        guard let state = topology.firstDescendant(named: "ZoneGroupState")?.text else {
            throw SonosError.invalidResponse
        }
        let stateRoot = try SonosXML.parse(Data(state.utf8))

        for node in stateRoot.descendants(named: "ZoneGroup") {
            guard let coordinatorID = node.attributes["Coordinator"],
                  devices[coordinatorID] == nil else { continue }
            if let location = node.descendants(named: "ZoneGroupMember")
                .first(where: { $0.attributes["UUID"] == coordinatorID })?
                .attributes["Location"],
                let url = URL(string: location), let host = url.host {
                if let device = try? await describe(url, expectedHost: host) {
                    devices[device.id] = device
                }
            }
        }
        return Self.groups(from: stateRoot, devices: devices)
    }

    static func groups(from stateRoot: SonosXMLNode, devices: [String: SonosDevice]) -> [SonosGroup] {
        var groups: [SonosGroup] = []
        for node in stateRoot.descendants(named: "ZoneGroup") {
            guard let coordinatorID = node.attributes["Coordinator"],
                  let groupID = node.attributes["ID"] else { continue }
            let members = node.descendants(named: "ZoneGroupMember")
                .filter { $0.attributes["Invisible"] != "1" }
            guard !members.isEmpty else { continue }
            let names = members.compactMap { $0.attributes["ZoneName"] }
            guard let coordinator = devices[coordinatorID] else { continue }
            groups.append(SonosGroup(
                id: groupID,
                name: names.joined(separator: " + "),
                coordinator: coordinator
            ))
        }
        return groups.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func describe(_ url: URL, expectedHost: String) async throws -> SonosDevice {
        guard url.scheme == "http", url.host == expectedHost else { throw SonosError.invalidResponse }
        var request = URLRequest(url: url)
        request.timeoutInterval = 3
        let (data, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200, data.count < 512_000 else {
            throw SonosError.invalidResponse
        }
        let root = try SonosXML.parse(data)
        guard root.firstDescendant(named: "manufacturer")?.text.localizedCaseInsensitiveContains("Sonos") == true,
              let rawID = root.firstDescendant(named: "UDN")?.text,
              rawID.hasPrefix("uuid:") else { throw SonosError.invalidResponse }
        var services: [String: SonosServiceEndpoint] = [:]
        for service in root.descendants(named: "service") {
            guard let type = service.child(named: "serviceType")?.text,
                  let path = service.child(named: "controlURL")?.text,
                  let serviceURL = URL(string: path, relativeTo: url)?.absoluteURL,
                  serviceURL.host == url.host,
                  let name = type.split(separator: ":").dropLast().last.map(String.init) else { continue }
            services[name] = SonosServiceEndpoint(type: type, url: serviceURL)
        }
        return SonosDevice(id: String(rawID.dropFirst(5)), services: services)
    }

    func action(
        _ device: SonosDevice,
        service serviceName: String,
        name: String,
        arguments: [(String, String)] = []
    ) async throws -> SonosXMLNode {
        let endpoint = try device.service(serviceName)
        let fields = arguments.map { "<\($0.0)>\(SonosXML.escape($0.1))</\($0.0)>" }.joined()
        let body = """
        <?xml version="1.0" encoding="utf-8"?>
        <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">
        <s:Body><u:\(name) xmlns:u="\(endpoint.type)">\(fields)</u:\(name)></s:Body></s:Envelope>
        """
        var request = URLRequest(url: endpoint.url)
        request.httpMethod = "POST"
        request.httpBody = Data(body.utf8)
        request.timeoutInterval = 4
        request.setValue("text/xml; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.setValue("\"\(endpoint.type)#\(name)\"", forHTTPHeaderField: "SOAPACTION")
        let (data, response) = try await session.data(for: request)
        guard data.count < 1_000_000 else { throw SonosError.invalidResponse }
        let root = try SonosXML.parse(data)
        if let fault = root.firstDescendant(named: "Fault") {
            let code = fault.firstDescendant(named: "errorCode")?.text ?? "unknown"
            throw SonosError.soapFault(code)
        }
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let result = root.firstDescendant(named: "\(name)Response") else {
            throw SonosError.invalidResponse
        }
        return result
    }

    /// Runs an action on the speaker's only AVTransport instance.
    @discardableResult
    private func avTransport(
        _ name: String,
        on device: SonosDevice,
        arguments: [(String, String)] = []
    ) async throws -> SonosXMLNode {
        try await action(device, service: "AVTransport", name: name, arguments: [Self.instance] + arguments)
    }

    func clearQueue(_ device: SonosDevice) async throws {
        try await avTransport("RemoveAllTracksFromQueue", on: device)
    }

    func enqueueTrack(_ track: SonosTrack, on device: SonosDevice) async throws {
        let response = try await avTransport("AddURIToQueue", on: device, arguments: [
            ("EnqueuedURI", track.streamURL.absoluteString),
            ("EnqueuedURIMetaData", Self.didl(for: track)),
            ("DesiredFirstTrackNumberEnqueued", "0"),
            ("EnqueueAsNext", "0")
        ])
        if let added = response.child(named: "NumTracksAdded")?.text, added != "1" {
            throw SonosError.invalidResponse
        }
    }

    func useQueue(_ device: SonosDevice) async throws {
        try await avTransport("SetAVTransportURI", on: device, arguments: [
            ("CurrentURI", Self.queueURI(for: device)),
            ("CurrentURIMetaData", "")
        ])
    }

    static func queueURI(for device: SonosDevice) -> String {
        "x-rincon-queue:\(device.id)#0"
    }

    func seekFirstTrack(on device: SonosDevice) async throws {
        try await seek(unit: "TRACK_NR", target: "1", on: device)
    }

    func seekTime(_ seconds: Double, on device: SonosDevice) async throws {
        try await seek(unit: "REL_TIME", target: Self.timeText(Int(seconds.rounded())), on: device)
    }

    private func seek(unit: String, target: String, on device: SonosDevice) async throws {
        try await avTransport("Seek", on: device, arguments: [("Unit", unit), ("Target", target)])
    }

    func transport(_ command: String, on device: SonosDevice) async throws {
        try await avTransport(command, on: device, arguments: [("Speed", "1")])
    }

    func position(on device: SonosDevice) async throws -> SonosPosition {
        let transport = try await avTransport("GetTransportInfo", on: device)
        let position = try await avTransport("GetPositionInfo", on: device)
        let media = try await avTransport("GetMediaInfo", on: device)
        return SonosPosition(
            trackURI: position.child(named: "TrackURI")?.text ?? "",
            seconds: Self.seconds(position.child(named: "RelTime")?.text) ?? 0,
            duration: Self.seconds(position.child(named: "TrackDuration")?.text) ?? 0,
            transportState: transport.child(named: "CurrentTransportState")?.text ?? "STOPPED",
            transportStatus: transport.child(named: "CurrentTransportStatus")?.text ?? "OK",
            sourceURI: media.child(named: "CurrentURI")?.text ?? ""
        )
    }

    func groupVolume(on device: SonosDevice) async throws -> Int {
        let result = try await action(
            device, service: "GroupRenderingControl", name: "GetGroupVolume", arguments: [Self.instance]
        )
        return Int(result.child(named: "CurrentVolume")?.text ?? "") ?? 0
    }

    func setGroupVolume(_ volume: Int, on device: SonosDevice) async throws {
        _ = try await action(device, service: "GroupRenderingControl", name: "SetGroupVolume", arguments: [
            Self.instance, ("DesiredVolume", String(min(max(volume, 0), 100)))
        ])
    }

    /// Sonos speakers expose a single instance of each service.
    private static let instance = ("InstanceID", "0")

    /// A duration or position as UPnP writes it, e.g. "00:03:05".
    private static func timeText(_ seconds: Int) -> String {
        let value = max(seconds, 0)
        return String(format: "%02d:%02d:%02d", value / 3600, (value / 60) % 60, value % 60)
    }

    static func seconds(_ time: String?) -> Double? {
        guard let time else { return nil }
        let parts = time.split(separator: ":").compactMap(Double.init)
        guard parts.count == 3 else { return nil }
        return parts[0] * 3600 + parts[1] * 60 + parts[2]
    }

    static func didl(for item: SonosTrack) -> String {
        let song = item.song
        let time = timeText((song.duration ?? 0) - Int(item.startOffset))
        let artist = song.artist.map { "<dc:creator>\(SonosXML.escape($0))</dc:creator>" } ?? ""
        let album = song.album.map { "<upnp:album>\(SonosXML.escape($0))</upnp:album>" } ?? ""
        let artwork = item.artworkURL.map {
            "<upnp:albumArtURI>\(SonosXML.escape($0.absoluteString))</upnp:albumArtURI>"
        } ?? ""
        return """
        <DIDL-Lite xmlns="urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/" \
        xmlns:dc="http://purl.org/dc/elements/1.1/" \
        xmlns:upnp="urn:schemas-upnp-org:metadata-1-0/upnp/">\
        <item id="\(item.entryID.uuidString)" parentID="0" restricted="true">\
        <dc:title>\(SonosXML.escape(song.title))</dc:title>\(artist)\(album)\(artwork)\
        <upnp:class>object.item.audioItem.musicTrack</upnp:class>\
        <res protocolInfo="http-get:*:\(item.mimeType):*" duration="\(time)">\
        \(SonosXML.escape(item.streamURL.absoluteString))</res></item></DIDL-Lite>
        """
    }
}

struct SonosSSDPAddress: Sendable {
    let location: URL
    let host: String
}

enum SonosSSDP {
    static func search() async throws -> [SonosSSDPAddress] {
        try await Task.detached(priority: .utility) { try scan() }.value
    }

    static func parseResponse(_ response: String, from host: String) -> SonosSSDPAddress? {
        let headers = response.components(separatedBy: .newlines)
        guard headers.first?.contains("200") == true,
              headers.contains(where: { $0.lowercased().contains("zoneplayer:1") }),
              let line = headers.first(where: { $0.lowercased().hasPrefix("location:") }),
              let url = URL(string: String(line.dropFirst("location:".count)).trimmingCharacters(in: .whitespacesAndNewlines)),
              url.scheme == "http", url.host == host else { return nil }
        return SonosSSDPAddress(location: url, host: host)
    }

    private static func scan() throws -> [SonosSSDPAddress] {
        let socketDescriptor = socket(AF_INET, SOCK_DGRAM, 0)
        guard socketDescriptor >= 0 else { throw SonosError.discoveryUnavailable }
        defer { close(socketDescriptor) }
        var timeout = timeval(tv_sec: 1, tv_usec: 0)
        _ = setsockopt(socketDescriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        var local = sockaddr_in()
        local.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        local.sin_family = sa_family_t(AF_INET)
        local.sin_addr = in_addr(s_addr: INADDR_ANY)
        let bound = withUnsafePointer(to: &local) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(socketDescriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else { throw SonosError.discoveryUnavailable }

        var target = sockaddr_in()
        target.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        target.sin_family = sa_family_t(AF_INET)
        target.sin_port = UInt16(1900).bigEndian
        _ = "239.255.255.250".withCString { inet_pton(AF_INET, $0, &target.sin_addr) }
        let query = [
            "M-SEARCH * HTTP/1.1",
            "HOST: 239.255.255.250:1900",
            "MAN: \"ssdp:discover\"",
            "MX: 2",
            "ST: urn:schemas-upnp-org:device:ZonePlayer:1",
            "",
            ""
        ].joined(separator: "\r\n")
        let destination = target
        func sendQuery() -> Bool {
            query.utf8CString.withUnsafeBytes { bytes in
                withUnsafePointer(to: destination) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        sendto(socketDescriptor, bytes.baseAddress, bytes.count - 1, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                    }
                }
            } >= 0
        }

        var results: [URL: SonosSSDPAddress] = [:]
        var delivered = false
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            // Right after launch macOS may still be resolving Local Network access and rejects or
            // drops the datagram, so repeat the query each receive timeout until a speaker answers.
            if results.isEmpty { delivered = sendQuery() || delivered }
            var buffer = [UInt8](repeating: 0, count: 8192)
            var source = sockaddr_storage()
            var sourceLength = socklen_t(MemoryLayout<sockaddr_storage>.size)
            let count = buffer.withUnsafeMutableBytes { bytes in
                withUnsafeMutablePointer(to: &source) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        recvfrom(socketDescriptor, bytes.baseAddress, bytes.count, 0, $0, &sourceLength)
                    }
                }
            }
            guard count > 0 else { continue }
            let host = withUnsafePointer(to: &source) { pointer -> String in
                pointer.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { ipv4 in
                    var address = ipv4.pointee.sin_addr
                    var chars = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                    _ = inet_ntop(AF_INET, &address, &chars, socklen_t(chars.count))
                    return String(bytes: chars.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, encoding: .utf8) ?? ""
                }
            }
            if let message = String(bytes: buffer.prefix(count), encoding: .utf8),
               let result = parseResponse(message, from: host) {
                results[result.location] = result
            }
        }
        guard delivered else { throw SonosError.discoveryUnavailable }
        return Array(results.values)
    }
}

struct SonosXMLNode: Sendable {
    let name: String
    let attributes: [String: String]
    var text: String = ""
    var children: [SonosXMLNode] = []

    /// Whether the element is called `target` once its namespace prefix is dropped.
    private func isNamed(_ target: String) -> Bool {
        name.split(separator: ":").last == Substring(target)
    }

    func child(named target: String) -> SonosXMLNode? {
        children.first { $0.isNamed(target) }
    }

    func firstDescendant(named target: String) -> SonosXMLNode? {
        if isNamed(target) { return self }
        for child in children {
            if let found = child.firstDescendant(named: target) { return found }
        }
        return nil
    }

    func descendants(named target: String) -> [SonosXMLNode] {
        var matches: [SonosXMLNode] = isNamed(target) ? [self] : []
        for child in children { matches += child.descendants(named: target) }
        return matches
    }
}

enum SonosXML {
    static func parse(_ data: Data) throws -> SonosXMLNode {
        let delegate = SonosXMLParser()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        guard parser.parse(), let root = delegate.root else { throw SonosError.invalidResponse }
        return root
    }

    static func escape(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }
}

private final class SonosXMLParser: NSObject, XMLParserDelegate {
    var root: SonosXMLNode?
    private var stack: [SonosXMLNode] = []

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        stack.append(SonosXMLNode(name: elementName, attributes: attributeDict))
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard !stack.isEmpty else { return }
        stack[stack.count - 1].text += string
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?) {
        guard let completed = stack.popLast() else { return }
        if stack.isEmpty {
            root = completed
        } else {
            stack[stack.count - 1].children.append(completed)
        }
    }
}
