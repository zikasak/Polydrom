import Darwin
import Foundation

struct SonosServiceEndpoint: Sendable {
    let type: String
    let url: URL
}

struct SonosDevice: Sendable, Identifiable {
    let id: String
    let name: String
    let descriptionURL: URL
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
    let memberIDs: [String]
}

struct SonosQueueItem: Sendable {
    let entryID: UUID
    let song: NavidromeSong
    let streamURL: URL
    let artworkURL: URL?
}

struct SonosPosition: Sendable {
    let track: Int
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
    case queueChanged

    var errorDescription: String? {
        switch self {
        case .discoveryUnavailable:
            "No Sonos rooms were found. Check Local Network access and that the Mac and Sonos are on the same network."
        case .invalidResponse:
            "The Sonos speaker returned an invalid response."
        case .unsupportedService:
            "This Sonos speaker does not expose a required playback service."
        case .soapFault(let code):
            "Sonos could not complete the playback command (UPnP error \(code)). Check that the speaker can reach Navidrome."
        case .localServerAddress:
            "Sonos cannot access a Navidrome address on this Mac. Use a server URL reachable from the speaker."
        case .sourceChanged:
            "The Sonos group started playing another source. PolyDrom stopped controlling it."
        case .queueChanged:
            "The Sonos queue changed in another app. Select the group again to copy PolyDrom’s queue."
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
            let memberIDs = members.compactMap { $0.attributes["UUID"] }
            let names = members.compactMap { $0.attributes["ZoneName"] }
            let coordinator = devices[coordinatorID]
            guard let coordinator else { continue }
            groups.append(SonosGroup(
                id: groupID,
                name: names.joined(separator: " + "),
                coordinator: coordinator,
                memberIDs: memberIDs
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
        return SonosDevice(
            id: String(rawID.dropFirst(5)),
            name: root.firstDescendant(named: "roomName")?.text
                ?? root.firstDescendant(named: "friendlyName")?.text ?? "Sonos",
            descriptionURL: url,
            services: services
        )
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

    func clearQueue(_ device: SonosDevice) async throws {
        _ = try await action(device, service: "AVTransport", name: "RemoveAllTracksFromQueue", arguments: [
            ("InstanceID", "0")
        ])
    }

    @discardableResult
    func addQueueItems(_ items: [SonosQueueItem], to device: SonosDevice, at position: Int = 0) async throws -> Int? {
        guard !items.isEmpty else { return nil }
        let response: SonosXMLNode
        if items.count == 1 {
            let item = items[0]
            response = try await action(device, service: "AVTransport", name: "AddURIToQueue", arguments: [
                ("InstanceID", "0"),
                ("EnqueuedURI", item.streamURL.absoluteString),
                ("EnqueuedURIMetaData", Self.didl(for: item)),
                ("DesiredFirstTrackNumberEnqueued", String(position)),
                ("EnqueueAsNext", "0")
            ])
        } else {
            response = try await action(device, service: "AVTransport", name: "AddMultipleURIsToQueue", arguments: [
                ("InstanceID", "0"),
                ("UpdateID", "0"),
                ("NumberOfURIs", String(items.count)),
                ("EnqueuedURIs", items.map { $0.streamURL.absoluteString }.joined(separator: " ")),
                ("EnqueuedURIsMetaData", items.map(Self.didl).joined(separator: " ")),
                ("ContainerURI", ""),
                ("ContainerMetaData", ""),
                ("DesiredFirstTrackNumberEnqueued", String(position)),
                ("EnqueueAsNext", "0")
            ])
        }
        if let added = response.child(named: "NumTracksAdded")?.text,
           Int(added) != items.count { throw SonosError.queueChanged }
        return (response.child(named: "NewQueueLength")?.text).flatMap(Int.init)
    }

    func useQueue(_ device: SonosDevice) async throws {
        _ = try await action(device, service: "AVTransport", name: "SetAVTransportURI", arguments: [
            ("InstanceID", "0"),
            ("CurrentURI", Self.queueURI(for: device)),
            ("CurrentURIMetaData", "")
        ])
    }

    static func queueURI(for device: SonosDevice) -> String {
        "x-rincon-queue:\(device.id)#0"
    }

    func seekTrack(_ index: Int, on device: SonosDevice) async throws {
        try await seek(unit: "TRACK_NR", target: String(index + 1), on: device)
    }

    func seekTime(_ seconds: Double, on device: SonosDevice) async throws {
        let value = max(Int(seconds.rounded()), 0)
        let target = String(format: "%02d:%02d:%02d", value / 3600, (value / 60) % 60, value % 60)
        try await seek(unit: "REL_TIME", target: target, on: device)
    }

    private func seek(unit: String, target: String, on device: SonosDevice) async throws {
        _ = try await action(device, service: "AVTransport", name: "Seek", arguments: [
            ("InstanceID", "0"), ("Unit", unit), ("Target", target)
        ])
    }

    func transport(_ command: String, on device: SonosDevice) async throws {
        let arguments = [("InstanceID", "0"), ("Speed", "1")]
        _ = try await action(device, service: "AVTransport", name: command, arguments: arguments)
    }

    func position(on device: SonosDevice) async throws -> SonosPosition {
        let transport = try await action(device, service: "AVTransport", name: "GetTransportInfo", arguments: [
            ("InstanceID", "0")
        ])
        let position = try await action(device, service: "AVTransport", name: "GetPositionInfo", arguments: [
            ("InstanceID", "0")
        ])
        let media = try await action(device, service: "AVTransport", name: "GetMediaInfo", arguments: [
            ("InstanceID", "0")
        ])
        return SonosPosition(
            track: Int(position.child(named: "Track")?.text ?? "") ?? 0,
            seconds: Self.seconds(position.child(named: "RelTime")?.text) ?? 0,
            duration: Self.seconds(position.child(named: "TrackDuration")?.text) ?? 0,
            transportState: transport.child(named: "CurrentTransportState")?.text ?? "STOPPED",
            transportStatus: transport.child(named: "CurrentTransportStatus")?.text ?? "OK",
            sourceURI: media.child(named: "CurrentURI")?.text ?? ""
        )
    }

    func currentSource(on device: SonosDevice) async throws -> String {
        let result = try await action(device, service: "AVTransport", name: "GetMediaInfo", arguments: [
            ("InstanceID", "0")
        ])
        return result.child(named: "CurrentURI")?.text ?? ""
    }

    func queueVersion(on device: SonosDevice) async throws -> String {
        let result = try await action(device, service: "ContentDirectory", name: "Browse", arguments: [
            ("ObjectID", "Q:0"), ("BrowseFlag", "BrowseMetadata"), ("Filter", "*"),
            ("StartingIndex", "0"), ("RequestedCount", "1"), ("SortCriteria", "")
        ])
        return result.child(named: "UpdateID")?.text ?? ""
    }

    func groupVolume(on device: SonosDevice) async throws -> Int {
        let result = try await action(device, service: "GroupRenderingControl", name: "GetGroupVolume", arguments: [
            ("InstanceID", "0")
        ])
        return Int(result.child(named: "CurrentVolume")?.text ?? "") ?? 0
    }

    func setGroupVolume(_ volume: Int, on device: SonosDevice) async throws {
        _ = try await action(device, service: "GroupRenderingControl", name: "SetGroupVolume", arguments: [
            ("InstanceID", "0"), ("DesiredVolume", String(min(max(volume, 0), 100)))
        ])
    }

    static func seconds(_ time: String?) -> Double? {
        guard let time else { return nil }
        let parts = time.split(separator: ":").compactMap(Double.init)
        guard parts.count == 3 else { return nil }
        return parts[0] * 3600 + parts[1] * 60 + parts[2]
    }

    static func didl(for item: SonosQueueItem) -> String {
        let song = item.song
        let duration = max(song.duration ?? 0, 0)
        let time = String(format: "%02d:%02d:%02d", duration / 3600, (duration / 60) % 60, duration % 60)
        let artist = song.artist.map { "<dc:creator>\(SonosXML.escape($0))</dc:creator>" } ?? ""
        let album = song.album.map { "<upnp:album>\(SonosXML.escape($0))</upnp:album>" } ?? ""
        let artwork = item.artworkURL.map {
            "<upnp:albumArtURI>\(SonosXML.escape($0.absoluteString))</upnp:albumArtURI>"
        } ?? ""
        return """
        <DIDL-Lite xmlns="urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/" xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:upnp="urn:schemas-upnp-org:metadata-1-0/upnp/"><item id="\(item.entryID.uuidString)" parentID="0" restricted="true"><dc:title>\(SonosXML.escape(song.title))</dc:title>\(artist)\(album)\(artwork)<upnp:class>object.item.audioItem.musicTrack</upnp:class><res protocolInfo="http-get:*:audio/mpeg:*" duration="\(time)">\(SonosXML.escape(item.streamURL.absoluteString))</res></item></DIDL-Lite>
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
        let fd = socket(AF_INET, SOCK_DGRAM, 0)
        guard fd >= 0 else { throw SonosError.discoveryUnavailable }
        defer { close(fd) }
        var timeout = timeval(tv_sec: 1, tv_usec: 0)
        _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        var local = sockaddr_in()
        local.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        local.sin_family = sa_family_t(AF_INET)
        local.sin_addr = in_addr(s_addr: INADDR_ANY)
        let bound = withUnsafePointer(to: &local) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else { throw SonosError.discoveryUnavailable }

        var target = sockaddr_in()
        target.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        target.sin_family = sa_family_t(AF_INET)
        target.sin_port = UInt16(1900).bigEndian
        _ = "239.255.255.250".withCString { inet_pton(AF_INET, $0, &target.sin_addr) }
        let query = "M-SEARCH * HTTP/1.1\r\nHOST: 239.255.255.250:1900\r\nMAN: \"ssdp:discover\"\r\nMX: 2\r\nST: urn:schemas-upnp-org:device:ZonePlayer:1\r\n\r\n"
        let sent = query.utf8CString.withUnsafeBytes { bytes in
            withUnsafePointer(to: &target) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    sendto(fd, bytes.baseAddress, bytes.count - 1, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
        guard sent >= 0 else { throw SonosError.discoveryUnavailable }

        var results: [URL: SonosSSDPAddress] = [:]
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            var buffer = [UInt8](repeating: 0, count: 8192)
            var source = sockaddr_storage()
            var sourceLength = socklen_t(MemoryLayout<sockaddr_storage>.size)
            let count = buffer.withUnsafeMutableBytes { bytes in
                withUnsafeMutablePointer(to: &source) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        recvfrom(fd, bytes.baseAddress, bytes.count, 0, $0, &sourceLength)
                    }
                }
            }
            guard count > 0 else { continue }
            let host = withUnsafePointer(to: &source) { pointer -> String in
                pointer.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { ipv4 in
                    var address = ipv4.pointee.sin_addr
                    var chars = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                    _ = inet_ntop(AF_INET, &address, &chars, socklen_t(chars.count))
                    return String(decoding: chars.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
                }
            }
            let message = String(decoding: buffer.prefix(count), as: UTF8.self)
            if let result = parseResponse(message, from: host) {
                results[result.location] = result
            }
        }
        return Array(results.values)
    }
}

struct SonosXMLNode: Sendable {
    let name: String
    let attributes: [String: String]
    var text: String = ""
    var children: [SonosXMLNode] = []

    func child(named target: String) -> SonosXMLNode? {
        children.first { $0.name.split(separator: ":").last == Substring(target) }
    }

    func firstDescendant(named target: String) -> SonosXMLNode? {
        if name.split(separator: ":").last == Substring(target) { return self }
        for child in children {
            if let found = child.firstDescendant(named: target) { return found }
        }
        return nil
    }

    func descendants(named target: String) -> [SonosXMLNode] {
        var matches: [SonosXMLNode] = name.split(separator: ":").last == Substring(target) ? [self] : []
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
