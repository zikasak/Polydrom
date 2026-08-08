import Foundation
import Synchronization
import Testing
@testable import PolyDrom

@Suite(.serialized)
@MainActor
struct PlaybackReportingTests {
    @Test func modernReportingSerializesTheFullPlaybackLifecycle() async throws {
        let requests = Mutex<[URLRequest]>([])
        let client = try #require(NavidromeClient(
            profile: makeProfile(),
            session: StubURLProtocol.session { request in
                requests.withLock { $0.append(request) }
                return envelope(#"{"status":"ok"}"#)
            }
        ))
        let reporter = PlaybackReporter()
        reporter.connect(client: client, serverKey: "server", mode: .modern)
        let first = makeSong(id: "first", duration: 180)
        let second = makeSong(id: "second", duration: 100)
        let origin = Date(timeIntervalSince1970: 1_000)

        reporter.handle(event(first, position: 0, isPlaying: true, trigger: .started, at: origin))
        reporter.handle(event(first, position: 12, isPlaying: false, trigger: .paused, at: origin + 10))
        reporter.handle(event(first, position: 12, isPlaying: true, trigger: .resumed, at: origin + 20))
        reporter.handle(event(first, position: 30, isPlaying: true, trigger: .seeked, at: origin + 21))
        reporter.handle(event(first, position: 31, isPlaying: true, trigger: .progressed, at: origin + 50))
        reporter.handle(event(first, position: 70, isPlaying: true, trigger: .progressed, at: origin + 82))
        reporter.handle(event(second, position: 0, isPlaying: true, trigger: .started, at: origin + 83))
        reporter.handle(event(second, position: 100, isPlaying: false, trigger: .finished, at: origin + 183))

        #expect(await eventually { requests.withLock { $0.count == 10 } })
        let captured = requests.withLock { $0 }
        #expect(captured.allSatisfy { apiMethod(in: $0) == "reportPlayback" })
        #expect(captured.map { queryValue("state", in: $0) } == [
            "starting", "playing", "paused", "playing", "playing",
            "playing", "stopped", "starting", "playing", "stopped"
        ])
        #expect(captured.map { queryValue("mediaId", in: $0) } == [
            "first", "first", "first", "first", "first",
            "first", "first", "second", "second", "second"
        ])
        #expect(captured.map { queryValue("positionMs", in: $0) } == [
            "0", "0", "12000", "12000", "30000",
            "70000", "70000", "0", "0", "100000"
        ])
    }

    @Test func legacyReportingIgnoresRestorationAndScrobblesQualifyingListensOnce() async throws {
        let requests = Mutex<[URLRequest]>([])
        let client = try #require(NavidromeClient(
            profile: makeProfile(),
            session: StubURLProtocol.session { request in
                requests.withLock { $0.append(request) }
                return envelope(#"{"status":"ok"}"#)
            }
        ))
        let reporter = PlaybackReporter()
        reporter.connect(client: client, serverKey: "server", mode: .legacy)
        let first = makeSong(id: "first", duration: 10)
        let second = makeSong(id: "second", duration: 100)
        let third = makeSong(id: "third", duration: 100)
        let origin = Date(timeIntervalSince1970: 2_000)

        reporter.handle(event(first, position: 0, isPlaying: false, trigger: .prepared, at: origin))
        reporter.handle(event(first, position: 0, isPlaying: true, trigger: .resumed, at: origin + 1))
        reporter.handle(event(first, position: 6, isPlaying: true, trigger: .progressed, at: origin + 7))
        reporter.handle(event(first, position: 6, isPlaying: false, trigger: .paused, at: origin + 8))
        reporter.handle(event(first, position: 6, isPlaying: false, trigger: .stopped, at: origin + 9))
        reporter.handle(event(second, position: 0, isPlaying: true, trigger: .started, at: origin + 10))
        reporter.handle(event(second, position: 1, isPlaying: false, trigger: .stopped, at: origin + 11))
        reporter.handle(event(third, position: 0, isPlaying: true, trigger: .started, at: origin + 12))
        reporter.handle(event(third, position: 100, isPlaying: false, trigger: .finished, at: origin + 13))

        #expect(await eventually { requests.withLock { $0.count == 5 } })
        let captured = requests.withLock { $0 }
        #expect(captured.allSatisfy { apiMethod(in: $0) == "scrobble" })
        #expect(captured.map { queryValue("id", in: $0) } == [
            "first", "first", "second", "third", "third"
        ])
        #expect(captured.map { queryValue("submission", in: $0) } == [
            "false", "true", "false", "false", "true"
        ])
        #expect(captured.allSatisfy { queryValue("position", in: $0) == nil })
    }

    @Test func reportFailuresRemainBestEffortAndTheNextHeartbeatRetriesState() async throws {
        let requestCount = Mutex(0)
        let client = try #require(NavidromeClient(
            profile: makeProfile(),
            session: StubURLProtocol.session { _ in
                requestCount.withLock { $0 += 1 }
                return StubURLProtocol.Response(statusCode: 503, json: "{}")
            }
        ))
        let reporter = PlaybackReporter()
        reporter.connect(client: client, serverKey: "server", mode: .modern)
        let song = makeSong(duration: 180)
        let origin = Date(timeIntervalSince1970: 3_000)

        reporter.handle(event(song, position: 0, isPlaying: true, trigger: .started, at: origin))
        reporter.handle(event(song, position: 61, isPlaying: true, trigger: .progressed, at: origin + 61))

        #expect(await eventually { requestCount.withLock { $0 == 3 } })
    }

    @Test func applicationTerminationStopsAndFlushesModernPlayback() async throws {
        let requests = Mutex<[URLRequest]>([])
        let client = try #require(NavidromeClient(
            profile: makeProfile(),
            session: StubURLProtocol.session { request in
                requests.withLock { $0.append(request) }
                return envelope(#"{"status":"ok"}"#)
            }
        ))
        let reporter = PlaybackReporter()
        reporter.connect(client: client, serverKey: "server", mode: .modern)
        let song = makeSong(duration: 180)
        let origin = Date(timeIntervalSince1970: 4_000)

        reporter.handle(event(song, position: 0, isPlaying: true, trigger: .started, at: origin))
        reporter.handle(event(song, position: 42, isPlaying: true, trigger: .progressed, at: origin + 10))
        await reporter.finishForApplicationTermination(at: origin + 11)

        let captured = requests.withLock { $0 }
        #expect(captured.map { queryValue("state", in: $0) } == ["starting", "playing", "stopped"])
        #expect(captured.map { queryValue("positionMs", in: $0) } == ["0", "0", "42000"])
    }

    @Test func applicationTerminationSubmitsOnlyQualifyingLegacyPlayback() async throws {
        let requests = Mutex<[URLRequest]>([])
        let client = try #require(NavidromeClient(
            profile: makeProfile(),
            session: StubURLProtocol.session { request in
                requests.withLock { $0.append(request) }
                return envelope(#"{"status":"ok"}"#)
            }
        ))
        let reporter = PlaybackReporter()
        reporter.connect(client: client, serverKey: "server", mode: .legacy)
        let song = makeSong(duration: 10)
        let origin = Date(timeIntervalSince1970: 5_000)

        reporter.handle(event(song, position: 0, isPlaying: true, trigger: .started, at: origin))
        await reporter.finishForApplicationTermination(at: origin + 6)

        let captured = requests.withLock { $0 }
        #expect(captured.map { queryValue("submission", in: $0) } == ["false", "true"])
    }

    @Test func stalledSkipStopsAtActualPositionWithoutLegacySubmission() async throws {
        let modernRequests = Mutex<[URLRequest]>([])
        let legacyRequests = Mutex<[URLRequest]>([])
        let modernClient = try #require(NavidromeClient(
            profile: makeProfile(),
            session: StubURLProtocol.session { request in
                modernRequests.withLock { $0.append(request) }
                return envelope(#"{"status":"ok"}"#)
            }
        ))
        let legacyClient = try #require(NavidromeClient(
            profile: makeProfile(),
            session: StubURLProtocol.session { request in
                legacyRequests.withLock { $0.append(request) }
                return envelope(#"{"status":"ok"}"#)
            }
        ))
        let song = makeSong(duration: 120)
        let origin = Date(timeIntervalSince1970: 6_000)

        let modernReporter = PlaybackReporter()
        modernReporter.connect(client: modernClient, serverKey: "modern", mode: .modern)
        modernReporter.handle(event(song, position: 0, isPlaying: true, trigger: .started, at: origin))
        modernReporter.handle(event(song, position: 37, isPlaying: false, trigger: .failed, at: origin + 1))
        await modernReporter.finishForApplicationTermination(at: origin + 2)

        let legacyReporter = PlaybackReporter()
        legacyReporter.connect(client: legacyClient, serverKey: "legacy", mode: .legacy)
        legacyReporter.handle(event(song, position: 0, isPlaying: true, trigger: .started, at: origin))
        legacyReporter.handle(event(song, position: 37, isPlaying: false, trigger: .failed, at: origin + 1))
        await legacyReporter.finishForApplicationTermination(at: origin + 2)

        let capturedModern = modernRequests.withLock { $0 }
        #expect(capturedModern.map { queryValue("state", in: $0) } == ["starting", "playing", "stopped"])
        #expect(capturedModern.map { queryValue("positionMs", in: $0) } == ["0", "0", "37000"])
        let capturedLegacy = legacyRequests.withLock { $0 }
        #expect(capturedLegacy.map { queryValue("submission", in: $0) } == ["false"])
    }

    private func event(
        _ song: NavidromeSong,
        position: Double,
        isPlaying: Bool,
        trigger: AudioPlaybackEvent.Trigger,
        at date: Date
    ) -> AudioPlaybackEvent {
        AudioPlaybackEvent(
            snapshot: AudioPlaybackSnapshot(
                song: song,
                position: position,
                duration: Double(song.duration ?? 0),
                isPlaying: isPlaying
            ),
            trigger: trigger,
            occurredAt: date
        )
    }
}
