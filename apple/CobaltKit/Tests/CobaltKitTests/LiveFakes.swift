import Foundation
import Synchronization
@testable import CobaltKit

/// What the fake server saw, in order.
enum LiveCall: Sendable, Equatable {
    case startToken(String, LiveEnvironment)
    case run(LiveRunRegistration)
    case relay(UUID, LiveContentState)
    case end(UUID)
}

final class LiveCallLog: Sendable {
    private let items = Mutex<[LiveCall]>([])
    func add(_ c: LiveCall) { items.withLock { $0.append(c) } }
    var all: [LiveCall] { items.withLock { $0 } }
    var runs: [LiveRunRegistration] { all.compactMap { if case .run(let r) = $0 { r } else { nil } } }
    var relays: [LiveContentState] { all.compactMap { if case .relay(_, let s) = $0 { s } else { nil } } }
    var ends: [UUID] { all.compactMap { if case .end(let id) = $0 { id } else { nil } } }
    var startTokens: [String] { all.compactMap { if case .startToken(let t, _) = $0 { t } else { nil } } }
    var isEmpty: Bool { all.isEmpty }
}

/// A `ScriptedClient` that records every live call and answers registrations with `reply`.
@MainActor
func recordingClient(
    over base: any CobaltClient, log: LiveCallLog,
    reply: @escaping @Sendable (LiveRunRegistration, Int) async throws -> LiveRunReply = { _, _ in
        LiveRunReply(pushing: true, started: true)
    },
    startToken: @escaping @Sendable (String, Int) async throws -> Void = { _, _ in }
) -> ScriptedClient {
    let runCount = Mutex(0)
    let tokenCount = Mutex(0)
    var c = ScriptedClient(base: base)
    c.startTokenHook = { token, env in
        log.add(.startToken(token, env))
        let n = tokenCount.withLock { v -> Int in v += 1; return v }
        try await startToken(token, n)
    }
    c.runHook = { r in
        log.add(.run(r))
        let n = runCount.withLock { v -> Int in v += 1; return v }
        return try await reply(r, n)
    }
    c.relayHook = { run, state in log.add(.relay(run, state)) }
    c.endHook = { run in log.add(.end(run)) }
    return c
}

// MARK: - ActivityKit, faked

@MainActor
final class FakeLiveHandle: LiveActivityHandle {
    let attributes: LiveRunAttributes
    let activityID = UUID().uuidString
    var state: LiveContentState
    var staleDate: Date?
    var ended = false
    private(set) var updates: [(state: LiveContentState, at: Date, staleDate: Date?)] = []
    private(set) var endCalls: [(state: LiveContentState, dismissAt: Date?)] = []
    private(set) var token: String?
    private var continuations: [AsyncStream<String>.Continuation] = []
    let clock: @MainActor () -> Date

    init(attributes: LiveRunAttributes, state: LiveContentState, staleDate: Date? = nil, clock: @escaping @MainActor () -> Date = { Date() }) {
        self.attributes = attributes
        self.state = state
        self.staleDate = staleDate
        self.clock = clock
    }

    var isEnded: Bool { ended }
    var end: (state: LiveContentState, dismissAt: Date?)? { endCalls.last }
    func isFresh(at now: Date) -> Bool { !ended && (staleDate.map { $0 > now } ?? false) }

    func pushTokens() -> AsyncStream<String> {
        let (stream, continuation) = AsyncStream.makeStream(of: String.self)
        continuations.append(continuation)
        if let token { continuation.yield(token) }
        return stream
    }

    func sendToken(_ t: String) {
        token = t
        for c in continuations { c.yield(t) }
    }

    func update(_ state: LiveContentState, staleDate: Date?) async {
        guard !ended else { return }
        updates.append((state, clock(), staleDate))
        self.state = state
        self.staleDate = staleDate
    }

    func end(_ state: LiveContentState, dismissAt: Date?) async {
        endCalls.append((state, dismissAt))
        self.state = state
        ended = true
    }
}

@MainActor
final class FakeLiveAdapter: LiveActivityAdapter {
    var isAvailable = true
    var handles: [FakeLiveHandle] = []
    private(set) var requests: [(attributes: LiveRunAttributes, state: LiveContentState, staleDate: Date, push: Bool)] = []
    var requestError: (any Error)?
    var currentStartToken: String?
    var clock: @MainActor () -> Date = { Date() }
    private var startContinuations: [AsyncStream<String>.Continuation] = []
    private var activityContinuations: [AsyncStream<any LiveActivityHandle>.Continuation] = []

    var activities: [any LiveActivityHandle] { handles }

    func request(
        _ attributes: LiveRunAttributes, state: LiveContentState, staleDate: Date, push: Bool
    ) throws -> any LiveActivityHandle {
        if let requestError { throw requestError }
        requests.append((attributes, state, staleDate, push))
        let handle = FakeLiveHandle(attributes: attributes, state: state, staleDate: staleDate, clock: clock)
        handles.append(handle)
        return handle
    }

    func startTokens() -> AsyncStream<String> {
        let (stream, continuation) = AsyncStream.makeStream(of: String.self)
        startContinuations.append(continuation)
        return stream
    }

    func pushStartToken(_ t: String) {
        currentStartToken = t
        for c in startContinuations { c.yield(t) }
    }

    func newActivities() -> AsyncStream<any LiveActivityHandle> {
        let (stream, continuation) = AsyncStream.makeStream(of: (any LiveActivityHandle).self)
        activityContinuations.append(continuation)
        return stream
    }

    /// The system push-started an activity (a share-sheet run).
    func systemStarts(_ handle: FakeLiveHandle) {
        handles.append(handle)
        for c in activityContinuations { c.yield(handle) }
    }
}

@MainActor
final class FakeGrace: BackgroundGrace {
    private(set) var begins = 0
    private(set) var ends = 0
    private(set) var active = false
    func begin() { if !active { begins += 1 }; active = true }
    func end() { if active { ends += 1 }; active = false }
}

let hexToken = String(repeating: "ab12", count: 16)          // 64 hex characters
let otherHexToken = String(repeating: "cd34", count: 16)
