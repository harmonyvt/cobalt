import Foundation
import Testing
@testable import CobaltKit

// Phase 3 lane (d), apple 03-PHASE3 3.4.2: the System Health Inspector's model. The containers are sampled from the activity list
// (never asked), the edge is timed around a `capabilities()` call, and the pending edits come from the sync outbox.

private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

private func job(
    _ id: String, _ stage: JobStatus.Stage, kind: JobStatus.Kind = .save, engine: SaveEngine? = nil
) -> JobStatus {
    JobStatus(id: id, ref: .pipeline(UUID()), kind: kind, stage: stage, startedAt: t0, updatedAt: t0, engine: engine)
}

private func state(_ readings: [SystemHealth.ContainerReading], _ name: SystemHealth.ContainerName) -> SystemHealth.ContainerState {
    readings.first { $0.name == name }!.state
}

private let none = SystemHealth.ContainerName.allCases.map { SystemHealth.ContainerReading(name: $0) }

struct ContainerObservationTests {
    @Test func aWakingStageNamesTheContainerThatWakes() {
        let cobalt = SystemHealth.observe([job("a", .waking(engine: .cobalt))], previous: none, now: t0)
        #expect(state(cobalt, .cobalt) == .waking && state(cobalt, .ytdlp) == .unknown)
        let ytdlp = SystemHealth.observe([job("a", .waking(engine: .ytdlp))], previous: none, now: t0)
        #expect(state(ytdlp, .ytdlp) == .waking && state(ytdlp, .cobalt) == .unknown)
        // an unnamed engine is the cobalt container (the only one that ever reported waking unnamed)
        #expect(state(SystemHealth.observe([job("a", .waking(engine: nil))], previous: none, now: t0), .cobalt) == .waking)
    }

    @Test func aStageRunningOnAContainerSaysItIsWarm() {
        let r = SystemHealth.observe(
            [job("a", .downloading(bytes: 1, total: 2), engine: .ytdlp), job("b", .storing(bytes: 1, total: 2))],
            previous: none, now: t0)
        #expect(state(r, .ytdlp) == .warm && state(r, .cobalt) == .warm)
        #expect(r.first { $0.name == .ytdlp }?.observedAt == t0)
    }

    @Test func anEditorRenderIsTheRendererRunning() {
        let r = SystemHealth.observe(
            [job("e", .rendering(phase: .decode, done: 3, total: 10), kind: .editorRender)], previous: none, now: t0)
        #expect(state(r, .editRenderer) == .warm)
        let waiting = SystemHealth.observe([job("e", .queued(ahead: 0), kind: .editorRender)], previous: none, now: t0)
        #expect(state(waiting, .editRenderer) == .unknown, "waiting in a line says nothing about the renderer")
    }

    @Test func aWakeEndsWarmWhenWorkRunsAndUnknownWhenTheJobJustVanishes() {
        let waking = SystemHealth.observe([job("a", .waking(engine: .cobalt))], previous: none, now: t0)
        let warm = SystemHealth.observe([job("a", .fetching(engine: .cobalt, fallbackFrom: nil), engine: .cobalt)], previous: waking, now: t0 + 5)
        #expect(state(warm, .cobalt) == .warm)
        #expect(warm.first { $0.name == .cobalt }?.observedAt == t0 + 5)
        let gone = SystemHealth.observe([], previous: waking, now: t0 + 90)
        #expect(state(gone, .cobalt) == .unknown, "a wake nothing confirms is not still waking")
        #expect(gone.first { $0.name == .cobalt }?.observedAt == t0, "but it keeps when it was last seen")
    }

    @Test func aContainerNothingMentionsKeepsItsLastReading() {
        let warm = SystemHealth.observe([job("a", .storing(bytes: 1, total: 2))], previous: none, now: t0)
        let later = SystemHealth.observe([], previous: warm, now: t0 + 600)
        #expect(later == warm)
    }

    @Test func aReadingThatHasNotChangedKeepsItsTime() {
        let first = SystemHealth.observe([job("a", .waking(engine: .cobalt))], previous: none, now: t0)
        let again = SystemHealth.observe([job("a", .waking(engine: .cobalt))], previous: first, now: t0 + 7)
        #expect(again == first, "the wake began at t0 and still did")
    }

    @MainActor @Test func sampleDrivesIsWakingAndLeavesAFinishedWakeAlone() {
        let health = AppModel.preview(.happy).health
        #expect(!health.isWaking)
        health.sample([job("a", .waking(engine: .ytdlp))], now: t0)
        #expect(health.isWaking)
        health.sample([job("a", .downloading(bytes: 1, total: 2), engine: .ytdlp)], now: t0 + 4)
        #expect(!health.isWaking)
        #expect(state(health.containers, .ytdlp) == .warm)
    }
}

@MainActor
struct EdgeTimingTests {
    @Test func theEdgeIsTimedAroundTheCapabilitiesCall() async {
        let health = AppModel.preview(.happy).health
        #expect(health.edge == nil)
        health.probe = {
            try? await Task.sleep(for: .milliseconds(30))
            var caps = Capabilities.unknown
            caps.kind = .fork
            return caps
        }
        await health.checkEdge()
        let edge = try! #require(health.edge)
        #expect(edge.reachable && edge.kind == .fork)
        #expect(edge.rttMilliseconds >= 25, "the 30 ms the call took, measured (\(edge.rttMilliseconds))")
        #expect(!health.isCheckingEdge)
    }

    @Test func anUnreachableServerIsAReadingNotAnError() async {
        let health = AppModel.preview(.happy).health
        health.probe = {
            var caps = Capabilities.unknown
            caps.kind = .unreachable
            return caps
        }
        await health.checkEdge()
        #expect(health.edge?.reachable == false && health.edge?.kind == .unreachable)
    }

    @Test func aSecondCheckWhileOneRunsWaitsForItAndTimesOnlyOnce() async {
        let health = AppModel.preview(.happy).health
        var calls = 0
        health.probe = {
            calls += 1
            try? await Task.sleep(for: .milliseconds(40))
            return .unknown
        }
        async let a: Void = health.checkEdge()
        async let b: Void = health.checkEdge()
        _ = await (a, b)
        #expect(calls == 1)
    }
}

struct PendingEditTests {
    private func op(_ kind: SyncOp.Kind, target: String = "p1", title: String? = nil, status: String? = nil, makePublic: Bool? = nil, at: Double = 0, sending: Bool = false) -> SyncOp {
        SyncOp(
            opID: "op-\(kind.rawValue)-\(at)", kind: kind, target: target,
            payload: SyncOp.Payload(anchor: "f1", title: title, status: status, makePublic: makePublic, fileID: nil, before: nil),
            createdAt: t0.addingTimeInterval(at), tries: 2, nextAttemptAt: t0, sending: sending)
    }

    @Test func eachOutboxKindMapsToOneWordableEdit() {
        #expect(PendingSyncEdit(op(.title, title: "harbour.mov")).kind == .rename(to: "harbour.mov"))
        #expect(PendingSyncEdit(op(.title, title: "")).kind == .rename(to: nil), "an empty title clears the custom one")
        #expect(PendingSyncEdit(op(.delete)).kind == .delete)
        #expect(PendingSyncEdit(op(.hide, status: "hidden")).kind == .hide)
        #expect(PendingSyncEdit(op(.hide)).kind == .hide, "no status means hidden, as the engine reads it")
        #expect(PendingSyncEdit(op(.hide, status: "off")).kind == .unhide)
        #expect(PendingSyncEdit(op(.visibility, makePublic: true)).kind == .visibility(makePublic: true))
        #expect(PendingSyncEdit(op(.visibility, makePublic: false)).kind == .visibility(makePublic: false))
        #expect(PendingSyncEdit(op(.visibility, status: "public")).kind == .visibility(makePublic: true))
        #expect(PendingSyncEdit(op(.visibility, status: "private")).kind == .visibility(makePublic: false))
    }

    @Test func theEditKeepsWhichPostItIsOnAndHowFarItGot() {
        let edit = PendingSyncEdit(op(.title, target: "post-9", title: "x", at: 5, sending: true))
        #expect(edit.postID == "post-9" && edit.tries == 2 && edit.isSending)
        #expect(edit.createdAt == t0.addingTimeInterval(5))
    }

    @MainActor @Test func theOutboxIsListedOldestFirstAndReadOnly() async throws {
        let dir = try makeTempDirectory()
        let store = try SyncStore(fileURL: dir.appendingPathComponent("library.sqlite"))
        _ = try await store.commit(post: nil, op: op(.delete, target: "late", at: 30))
        _ = try await store.commit(post: nil, op: op(.title, target: "early", title: "harbour.mov", at: 10))
        let sync = LibrarySync(store: store, transport: NoPull(), sender: NoSend())
        let edits = await sync.pendingEdits()
        #expect(edits.map(\.postID) == ["early", "late"])
        #expect(edits.first?.kind == .rename(to: "harbour.mov"))
        #expect(try await store.pendingOps().count == 2, "listing the outbox does not touch it")
    }
}

private struct NoPull: SyncTransport {
    func pull(since: Int64, limit: Int) async throws -> SyncPage { throw SyncError.retryable("test") }
}

private struct NoSend: SyncSender {
    func send(_ op: SyncOp) async throws -> SyncReceipt { throw SyncError.retryable("test") }
}
