import Foundation
import OSLog

struct AudioPlaybackSnapshot: Equatable, Sendable {
    let song: NavidromeSong
    let position: Double
    let duration: Double
    let isPlaying: Bool
}

struct AudioPlaybackEvent: Equatable, Sendable {
    enum Trigger: Equatable, Sendable {
        case prepared
        case started
        case resumed
        case paused
        case seeked
        case progressed
        case stopped
        case finished
        case failed
    }

    let snapshot: AudioPlaybackSnapshot
    let trigger: Trigger
    let occurredAt: Date
}

enum PlaybackReportingMode: Equatable, Sendable {
    case modern
    case legacy
}

@MainActor
final class PlaybackReporter {
    private struct Configuration {
        let client: NavidromeClient
        let serverKey: String
        let mode: PlaybackReportingMode
    }

    private struct ActiveSession {
        let song: NavidromeSong
        var position: Double
        var duration: Double
        var isPlaying: Bool
        var activeListeningTime: TimeInterval
        var lastUpdatedAt: Date
        var lastReportAt: Date?
        var didSubmitLegacyScrobble: Bool
    }

    private enum ReportRequest: Sendable {
        case modern(songID: String, positionMilliseconds: Int64, state: NavidromePlaybackState)
        case legacyNowPlaying(songID: String)
        case legacySubmission(songID: String)

        var methodName: String {
            switch self {
            case .modern:
                "reportPlayback"
            case .legacyNowPlaying, .legacySubmission:
                "scrobble"
            }
        }

        func perform(using client: NavidromeClient) async throws {
            switch self {
            case .modern(let songID, let positionMilliseconds, let state):
                try await client.reportPlayback(
                    songID: songID,
                    positionMilliseconds: positionMilliseconds,
                    state: state
                )
            case .legacyNowPlaying(let songID):
                try await client.scrobble(songID: songID, submission: false)
            case .legacySubmission(let songID):
                try await client.scrobble(songID: songID, submission: true)
            }
        }
    }

    private let heartbeatInterval: TimeInterval
    private var configuration: Configuration?
    private var activeSession: ActiveSession?
    private var pendingReportTask: Task<Void, Never>?

    init(heartbeatInterval: TimeInterval = 60) {
        self.heartbeatInterval = heartbeatInterval
    }

    func connect(
        client: NavidromeClient,
        serverKey: String,
        mode: PlaybackReportingMode
    ) {
        if configuration?.serverKey != serverKey {
            activeSession = nil
        } else {
            activeSession?.lastReportAt = nil
        }
        configuration = Configuration(client: client, serverKey: serverKey, mode: mode)
    }

    func disconnect() {
        configuration = nil
        activeSession = nil
    }

    func finishForApplicationTermination(at date: Date = Date()) async {
        if activeSession != nil {
            finishActiveSession(at: date, naturalCompletion: false)
        }

        configuration = nil
        activeSession = nil
        let finalReportTask = pendingReportTask
        await finalReportTask?.value
    }

    func handle(_ event: AudioPlaybackEvent) {
        guard configuration != nil else { return }

        switch event.trigger {
        case .prepared:
            return
        case .started:
            startNewSession(for: event)
        case .resumed:
            resumeSession(for: event)
        case .paused:
            pauseSession(for: event)
        case .seeked:
            seekSession(for: event)
        case .progressed:
            updateProgress(for: event)
        case .stopped, .failed:
            finishSession(for: event, naturalCompletion: false)
        case .finished:
            finishSession(for: event, naturalCompletion: true)
        }
    }

    private func startNewSession(for event: AudioPlaybackEvent) {
        if activeSession != nil {
            finishActiveSession(at: event.occurredAt, naturalCompletion: false)
        }

        activeSession = ActiveSession(
            song: event.snapshot.song,
            position: event.snapshot.position,
            duration: event.snapshot.duration,
            isPlaying: event.snapshot.isPlaying,
            activeListeningTime: 0,
            lastUpdatedAt: event.occurredAt,
            lastReportAt: nil,
            didSubmitLegacyScrobble: false
        )
        reportSessionStart(at: event.occurredAt)
    }

    private func resumeSession(for event: AudioPlaybackEvent) {
        guard activeSession?.song.id == event.snapshot.song.id else {
            if activeSession != nil {
                finishActiveSession(at: event.occurredAt, naturalCompletion: false)
            }
            startNewSession(for: event)
            return
        }

        guard var session = activeSession else { return }
        let wasPlaying = session.isPlaying
        update(&session, with: event.snapshot, at: event.occurredAt)
        if !wasPlaying {
            reportPlaying(&session, at: event.occurredAt)
        }
        maybeSubmitLegacyScrobble(&session)
        activeSession = session
    }

    private func pauseSession(for event: AudioPlaybackEvent) {
        guard var session = activeSession,
              session.song.id == event.snapshot.song.id else { return }
        let wasPlaying = session.isPlaying
        update(&session, with: event.snapshot, at: event.occurredAt)
        if wasPlaying, configuration?.mode == .modern {
            reportModern(.paused, session: &session, at: event.occurredAt)
        }
        maybeSubmitLegacyScrobble(&session)
        activeSession = session
    }

    private func seekSession(for event: AudioPlaybackEvent) {
        guard activeSession?.song.id == event.snapshot.song.id else {
            guard event.snapshot.isPlaying else { return }
            if activeSession != nil {
                finishActiveSession(at: event.occurredAt, naturalCompletion: false)
            }
            startNewSession(for: event)
            return
        }

        guard var session = activeSession else { return }
        update(&session, with: event.snapshot, at: event.occurredAt)
        switch configuration?.mode {
        case .modern:
            reportModern(
                session.isPlaying ? .playing : .paused,
                session: &session,
                at: event.occurredAt
            )
        case .legacy where session.isPlaying:
            reportLegacyNowPlaying(session: &session, at: event.occurredAt)
        case .legacy, .none:
            break
        }
        maybeSubmitLegacyScrobble(&session)
        activeSession = session
    }

    private func updateProgress(for event: AudioPlaybackEvent) {
        guard activeSession?.song.id == event.snapshot.song.id else {
            guard event.snapshot.isPlaying else { return }
            if activeSession != nil {
                finishActiveSession(at: event.occurredAt, naturalCompletion: false)
            }
            startNewSession(for: event)
            return
        }

        guard var session = activeSession else { return }
        let wasPlaying = session.isPlaying
        update(&session, with: event.snapshot, at: event.occurredAt)

        if wasPlaying != session.isPlaying {
            if session.isPlaying {
                reportPlaying(&session, at: event.occurredAt)
            } else if configuration?.mode == .modern {
                reportModern(.paused, session: &session, at: event.occurredAt)
            }
        } else if shouldSendHeartbeat(for: session, at: event.occurredAt) {
            reportPlaying(&session, at: event.occurredAt)
        }

        maybeSubmitLegacyScrobble(&session)
        activeSession = session
    }

    private func finishSession(for event: AudioPlaybackEvent, naturalCompletion: Bool) {
        guard var session = activeSession,
              session.song.id == event.snapshot.song.id else { return }
        update(&session, with: event.snapshot, at: event.occurredAt)
        activeSession = session
        finishActiveSession(at: event.occurredAt, naturalCompletion: naturalCompletion)
    }

    private func finishActiveSession(at date: Date, naturalCompletion: Bool) {
        guard var session = activeSession else { return }
        advanceListeningTime(&session, to: date)

        switch configuration?.mode {
        case .modern:
            reportModern(.stopped, session: &session, at: date)
        case .legacy:
            if naturalCompletion || qualifiesForLegacyScrobble(session) {
                submitLegacyScrobbleIfNeeded(&session)
            }
        case .none:
            break
        }

        activeSession = nil
    }

    private func reportSessionStart(at date: Date) {
        guard var session = activeSession else { return }
        switch configuration?.mode {
        case .modern:
            reportModern(.starting, session: &session, at: date)
            reportModern(.playing, session: &session, at: date)
        case .legacy:
            reportLegacyNowPlaying(session: &session, at: date)
        case .none:
            break
        }
        activeSession = session
    }

    private func reportPlaying(_ session: inout ActiveSession, at date: Date) {
        switch configuration?.mode {
        case .modern:
            reportModern(.playing, session: &session, at: date)
        case .legacy:
            reportLegacyNowPlaying(session: &session, at: date)
        case .none:
            break
        }
    }

    private func reportModern(
        _ state: NavidromePlaybackState,
        session: inout ActiveSession,
        at date: Date
    ) {
        enqueue(
            .modern(
                songID: session.song.id,
                positionMilliseconds: milliseconds(from: session.position),
                state: state
            )
        )
        session.lastReportAt = date
    }

    private func reportLegacyNowPlaying(session: inout ActiveSession, at date: Date) {
        enqueue(.legacyNowPlaying(songID: session.song.id))
        session.lastReportAt = date
    }

    private func maybeSubmitLegacyScrobble(_ session: inout ActiveSession) {
        guard configuration?.mode == .legacy,
              qualifiesForLegacyScrobble(session) else { return }
        submitLegacyScrobbleIfNeeded(&session)
    }

    private func submitLegacyScrobbleIfNeeded(_ session: inout ActiveSession) {
        guard !session.didSubmitLegacyScrobble else { return }
        enqueue(.legacySubmission(songID: session.song.id))
        session.didSubmitLegacyScrobble = true
    }

    private func qualifiesForLegacyScrobble(_ session: ActiveSession) -> Bool {
        let threshold = session.duration > 0
            ? min(session.duration * 0.5, 240)
            : 240
        return session.activeListeningTime >= threshold
    }

    private func shouldSendHeartbeat(for session: ActiveSession, at date: Date) -> Bool {
        guard session.isPlaying else { return false }
        guard let lastReportAt = session.lastReportAt else { return true }
        return date.timeIntervalSince(lastReportAt) >= heartbeatInterval
    }

    private func update(
        _ session: inout ActiveSession,
        with snapshot: AudioPlaybackSnapshot,
        at date: Date
    ) {
        advanceListeningTime(&session, to: date)
        session.position = snapshot.position
        if snapshot.duration > 0 {
            session.duration = snapshot.duration
        }
        session.isPlaying = snapshot.isPlaying
    }

    private func advanceListeningTime(_ session: inout ActiveSession, to date: Date) {
        if session.isPlaying {
            session.activeListeningTime += max(date.timeIntervalSince(session.lastUpdatedAt), 0)
        }
        session.lastUpdatedAt = date
    }

    private func enqueue(_ request: ReportRequest) {
        guard let client = configuration?.client else { return }
        let precedingTask = pendingReportTask
        pendingReportTask = Task {
            _ = await precedingTask?.value
            do {
                try await request.perform(using: client)
            } catch {
                AppLog.playback.error(
                    "Playback report failed: \(request.methodName, privacy: .public)"
                )
                AppLog.playback.debug(
                    "Playback report failure reason: \(error.localizedDescription, privacy: .private)"
                )
            }
        }
    }

    private func milliseconds(from seconds: Double) -> Int64 {
        Int64((max(seconds, 0) * 1_000).rounded())
    }
}
