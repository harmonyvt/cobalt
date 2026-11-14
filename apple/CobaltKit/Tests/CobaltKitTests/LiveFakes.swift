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

/// A fake job activity (`JobActivityHandle`): it records what the manager wrote, as the island would show it.
@MainActor
final class FakeLiveHandle: JobActivityHandle {
    let attributes: JobLiveAttributes
    let activityID = UUID().uuidString
    var state: JobLiveState
    var staleDate: Date?
    var ended = false
    private(set) var updates: [(state: JobLiveState, at: Date, staleDate: Date?)] = []
    /// Every end, with the state it ended showing (its own when the manager passed none).
    private(set) var endCalls: [(state: JobLiveState, dismissAt: Date?)] = []
    private(set) var token: String?
    private var continuations: [AsyncStream<String>.Continuation] = []
    let clock: @MainActor () -> Date

    init(job: JobLiveJob, staleDate: Date? = nil, clock: @escaping @MainActor () -> Date = { Date() }) {
        self.attributes = job.attributes
        self.state = job.state
        self.staleDate = staleDate
        self.clock = clock
    }

    /// A save's activity as the server (or an older test) would start it: the run's attributes and content, in job words.
    convenience init(
        attributes: LiveRunAttributes, state: LiveContentState, agent: JobLiveAgent? = nil, staleDate: Date? = nil,
        clock: @escaping @MainActor () -> Date = { Date() }
    ) {
        self.init(job: JobLive.job(save: state, attributes: attributes, agent: agent), staleDate: staleDate, clock: clock)
    }

    /// The run, render or thread it shows.
    var run: String { attributes.id }
    var isEnded: Bool { ended }
    var end: (state: JobLiveState, dismissAt: Date?)? { endCalls.last }
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

    func update(_ state: JobLiveState, staleDate: Date?) async {
        guard !ended else { return }
        updates.append((state, clock(), staleDate))
        self.state = state
        self.staleDate = staleDate
    }

    func end(_ state: JobLiveState?, dismissAt: Date?) async {
        let final = state ?? self.state
        endCalls.append((final, dismissAt))
        self.state = final
        ended = true
    }
}

/// A fake old-type activity (`OldLiveActivity`): from an older build, or push-started by the server with an old start
/// token (changeover release). `suspends`: its end really waits, as ActivityKit's does.
@MainActor
final class FakeOldActivity: OldLiveActivity {
    let id: String
    var staleDate: Date?
    var saveRun: (attributes: LiveRunAttributes, state: LiveContentState)?
    var suspends = false
    private(set) var ended = false
    private(set) var endCount = 0
    private(set) var token: String?
    private var continuations: [AsyncStream<String>.Continuation] = []

    init(id: String, staleDate: Date?, saveRun: (attributes: LiveRunAttributes, state: LiveContentState)? = nil) {
        self.id = id
        self.staleDate = staleDate
        self.saveRun = saveRun
    }

    var isEnded: Bool { ended }
    func isFresh(at now: Date) -> Bool { !ended && (staleDate.map { $0 > now } ?? false) }
    func endNow() async {
        if suspends { for _ in 0..<5 { await Task.yield() } }
        ended = true
        endCount += 1
    }

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
}

enum FakeActivityError: Error { case visibility }

/// One `Activity.request` the manager made.
struct FakeRequest {
    let job: JobLiveJob
    let staleDate: Date
    let push: Bool
    var attributes: JobLiveAttributes { job.attributes }
    var state: JobLiveState { job.state }
}

@MainActor
final class FakeLiveAdapter: LiveActivityAdapter {
    var isAvailable = true
    var handles: [FakeLiveHandle] = []
    var old: [FakeOldActivity] = []
    private(set) var requests: [FakeRequest] = []
    var requestError: (any Error)?
    /// ActivityKit refuses `Activity.request` from the background (the system says "visibility"): flip to `false` to
    /// make the fake do the same. Every try is counted, refused ones too.
    var inForeground = true
    private(set) var requestAttempts = 0
    var currentStartToken: String?
    var clock: @MainActor () -> Date = { Date() }
    private var startContinuations: [AsyncStream<String>.Continuation] = []
    private var activityContinuations: [AsyncStream<any JobActivityHandle>.Continuation] = []
    private var oldContinuations: [AsyncStream<any OldLiveActivity>.Continuation] = []

    var activities: [any JobActivityHandle] { handles }
    var oldActivities: [any OldLiveActivity] { old }

    func request(_ job: JobLiveJob, staleDate: Date, push: Bool) throws -> any JobActivityHandle {
        requestAttempts += 1
        if !inForeground { throw FakeActivityError.visibility }
        if let requestError { throw requestError }
        requests.append(FakeRequest(job: job, staleDate: staleDate, push: push))
        let handle = FakeLiveHandle(job: job, staleDate: staleDate, clock: clock)
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

    func newActivities() -> AsyncStream<any JobActivityHandle> {
        let (stream, continuation) = AsyncStream.makeStream(of: (any JobActivityHandle).self)
        activityContinuations.append(continuation)
        return stream
    }

    /// The system push-started an activity (a share-sheet run, an agent job).
    func systemStarts(_ handle: FakeLiveHandle) {
        handles.append(handle)
        for c in activityContinuations { c.yield(handle) }
    }

    func newOldActivities() -> AsyncStream<any OldLiveActivity> {
        let (stream, continuation) = AsyncStream.makeStream(of: (any OldLiveActivity).self)
        oldContinuations.append(continuation)
        return stream
    }

    /// The system push-started an old-type activity (a key with no job start token yet).
    func systemStartsOld(_ a: FakeOldActivity) {
        old.append(a)
        for c in oldContinuations { c.yield(a) }
    }
}

// MARK: - reading job states in the old tests' terms

extension JobLiveState {
    /// The save stage a job state shows, read back from its words (`JobLive.job(save:)`): the step it is on while it works,
    /// "ready to trim" while it waits, done and failed at the end. Lets the tests keep asserting the same moments
    /// ("it read frames, then waited for the trim") in the new shape.
    var stage: LiveContentState.Stage {
        switch phase {
        case .done: return .done
        case .failed, .lost: return .failed
        case .waiting: return headline == "ready to trim" ? .ready : .fetching
        case .working, .quiet:
            switch step < steps.count ? steps[step] : "" {
            case "upload": return .uploading
            case "store": return .saving
            case "read": return .reading
            case "make": return .rendering
            default: return .fetching
            }
        }
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
