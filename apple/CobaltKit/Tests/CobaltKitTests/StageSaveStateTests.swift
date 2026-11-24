import Foundation
import Synchronization
import Testing
@testable import CobaltKit

// The studio's save state (Phase 2, 2.3.1): `StageStore.saveState` goes synced -> dirty -> saving -> synced for a slider
// burst; a refused or lost write keeps its values on show as `failedPatch` and `.failed`, never touches what was moved
// meanwhile, and can be retried or reverted (offline too) to `lastConfirmedStage`, which only the server's words set.
// `busyFields` names the control an awaited write is on. Also `connected_canvases` (additive) on the stage and the feed.

/// What the flaky "server" is told to do: refuse writes, or hold them until the test lets go.
private final class StageFlakyControl: Sendable {
    private struct State {
        var failing = 0                 // refuse this many more PATCHes (-1: every one)
        var holding = false
        var entered = 0                 // PATCHes that reached the server
        var waiters: [CheckedContinuation<Void, Never>] = []
    }

    private let state = Mutex(State())

    func fail(next count: Int) { state.withLock { $0.failing = count } }
    func hold() { state.withLock { $0.holding = true } }
    var entered: Int { state.withLock { $0.entered } }

    func release() {
        let waiting = state.withLock { s -> [CheckedContinuation<Void, Never>] in
            s.holding = false
            let out = s.waiters
            s.waiters = []
            return out
        }
        for waiter in waiting { waiter.resume() }
    }

    /// Called as a PATCH arrives: waits while held, then says whether it is refused.
    func arrive() async -> Bool {
        state.withLock { $0.entered += 1 }
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            let resumeNow = state.withLock { s -> Bool in
                if s.holding {
                    s.waiters.append(c)
                    return false
                }
                return true
            }
            if resumeNow { c.resume() }
        }
        return state.withLock { s -> Bool in
            if s.failing == 0 { return false }
            if s.failing > 0 { s.failing -= 1 }
            return true
        }
    }
}

/// The preview server for every stage read, with `PATCH /stage` under the test's control.
private struct StageFlakyClient: CobaltClient {
    let base: PreviewClient
    let control: StageFlakyControl

    var baseURL: URL { base.baseURL }
    func capabilities() async -> Capabilities { await base.capabilities() }
    func stage() async throws -> StageSnapshot { try await base.stage() }
    func updateStage(_ patch: StagePatch) async throws -> StageSettings {
        if await control.arrive() { throw StageError.unavailable }
        return try await base.updateStage(patch)
    }
    func stageRedemptions(limit: Int, before: Date?) async throws -> [StageRedemption] {
        try await base.stageRedemptions(limit: limit, before: before)
    }
    func updateStageReward(_ kind: StageRewardKind, cost: Int?, cooldownSeconds: Int?, enabled: Bool?) async throws -> StageReward {
        try await base.updateStageReward(kind, cost: cost, cooldownSeconds: cooldownSeconds, enabled: enabled)
    }

    func resolve(_ link: URL) async throws -> CobaltResult { throw PipelineFailure.unsupported }
    func createStudio(link: URL) async throws -> StudioCreated { throw PipelineFailure.unsupported }
    func upload(file: URL, name: String, contentType: String, progress: @escaping @Sendable (TransferProgress) -> Void) async throws -> UploadResult { throw PipelineFailure.unsupported }
    func session(_ id: String, wait: Int) async throws -> StudioSession { throw PipelineFailure.unsupported }
    func sourceURL(session id: String) -> URL { baseURL }
    func render(session id: String, _ request: RenderRequest) async throws -> String { throw PipelineFailure.unsupported }
    func renderStatus(session id: String, job: String, wait: Int) async throws -> RenderStatus { throw PipelineFailure.unsupported }
    func publish(session id: String) async throws -> HostedFile { throw PipelineFailure.unsupported }
    func publish(item id: String) async throws -> HostedFile { throw PipelineFailure.unsupported }
    func openStudio(item id: String) async throws -> StudioCreated { throw PipelineFailure.unsupported }
    func library(cursor: String?, limit: Int) async throws -> LibraryPage { throw PipelineFailure.unsupported }
    func deleteMedia(name: String) async throws {}
    func setTitle(anchor itemID: String, _ title: String?) async throws -> PostTitleResult { throw PipelineFailure.unsupported }
    func registerLiveStartToken(_ token: String, environment: LiveEnvironment) async throws {}
    func registerLiveRun(_ r: LiveRunRegistration) async throws -> LiveRunReply { throw PipelineFailure.unsupported }
    func relayLiveState(run: UUID, _ state: LiveContentState) async throws {}
    func endLiveRun(_ run: UUID) async throws {}
    func liveSelftest() async throws -> LiveSelftest { throw PipelineFailure.unsupported }
    func download(_ file: RemoteFile, to destination: URL, progress: @escaping @Sendable (TransferProgress) -> Void) async throws -> URL { destination }
}

@MainActor
private struct SaveStateRig {
    let app = AppModel.makePreview(.happy, timeScale: 0.01, clock: SystemClock())
    let control = StageFlakyControl()
    let base: PreviewClient

    init() {
        base = app.ctx.client as! PreviewClient
        app.ctx.client = StageFlakyClient(base: base, control: control)
    }

    var store: StageStore { app.stage }
    var server: PreviewStageState { base.stageState }

    /// Waits (a real few milliseconds at a time) until `condition` holds.
    func until(_ condition: @MainActor () -> Bool) async {
        for _ in 0..<2_000 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(2))
        }
    }
}

@MainActor
struct StageSaveStateTests {
    @Test func aSliderBurstGoesDirtySavingSynced() async throws {
        let rig = SaveStateRig()
        await rig.store.load()
        #expect(rig.store.saveState == .synced)
        #expect(rig.store.lastConfirmedStage?.density == 30)

        rig.control.hold()
        rig.store.setDensity(50)
        #expect(rig.store.saveState == .dirty(fields: [.density]), "moved, not sent yet")
        #expect(rig.store.stage?.density == 50)
        #expect(rig.store.lastConfirmedStage?.density == 30, "an edit is never the confirmed stage")

        await rig.until { rig.control.entered == 1 }
        #expect(rig.store.saveState == .saving(fields: [.density]))
        #expect(rig.store.lastConfirmedStage?.density == 30, "still only what the server said")

        rig.control.release()
        await rig.store.settle()
        #expect(rig.store.saveState == .synced)
        #expect(rig.store.failedPatch == nil)
        #expect(rig.store.lastConfirmedStage?.density == 50, "the answer confirms it")
        #expect(rig.store.stage?.density == 50)
    }

    @Test func aRefusedWriteIsFailedAndKeepsItsValuesOnShow() async throws {
        let rig = SaveStateRig()
        await rig.store.load()
        rig.control.fail(next: -1)
        rig.store.setDensity(77)
        await rig.store.settle()
        #expect(rig.store.saveState == .failed(error: .unavailable, fields: [.density]))
        #expect(rig.store.failedPatch == StagePatch(density: 77))
        #expect(rig.store.stage?.density == 77, "the owner's value stays until they choose")
        #expect(rig.store.notice?.error == .unavailable)
        #expect(rig.store.lastConfirmedStage?.density == 30)
        #expect(rig.server.stage.density == 30, "the server never had it")
    }

    @Test func retryingSendsTheFailedValuesAgain() async throws {
        let rig = SaveStateRig()
        await rig.store.load()
        rig.control.fail(next: 1)
        rig.store.setDensity(77)
        await rig.store.settle()
        #expect(rig.store.failedPatch == StagePatch(density: 77))
        await rig.store.retryFailedPatch()
        #expect(rig.store.saveState == .synced)
        #expect(rig.store.failedPatch == nil && rig.store.notice == nil)
        #expect(rig.store.lastConfirmedStage?.density == 77)
        #expect(rig.server.stage.density == 77)
    }

    @Test func aRetryThatFailsAgainStaysFailed() async throws {
        let rig = SaveStateRig()
        await rig.store.load()
        rig.control.fail(next: -1)
        rig.store.setTileSeconds(60)
        await rig.store.settle()
        await rig.store.retryFailedPatch()
        #expect(rig.store.saveState == .failed(error: .unavailable, fields: [.tileSeconds]))
        #expect(rig.store.failedPatch == StagePatch(tileSeconds: 60))
        #expect(rig.store.stage?.tileSeconds == 60)
    }

    @Test func revertingPutsTheConfirmedStageBackWithoutAnyRequest() async throws {
        let rig = SaveStateRig()
        await rig.store.load()
        rig.control.fail(next: -1)
        rig.store.setDensity(77)
        rig.store.setTileScale(1.5)
        await rig.store.settle()
        let writes = rig.control.entered
        #expect(rig.store.stage?.density == 77)
        rig.store.revertUnsavedChanges()
        #expect(rig.store.stage?.density == 30 && rig.store.stage?.tileScale == 1)
        #expect(rig.store.saveState == .synced)
        #expect(rig.store.failedPatch == nil && rig.store.notice == nil)
        #expect(rig.control.entered == writes, "a revert asks the server nothing")
    }

    @Test func revertingDropsValuesStillWaitingToBeSent() async throws {
        let rig = SaveStateRig()
        await rig.store.load()
        rig.store.setDensity(90)
        #expect(rig.store.saveState == .dirty(fields: [.density]))
        rig.store.revertUnsavedChanges()
        #expect(rig.store.stage?.density == 30 && rig.store.saveState == .synced)
        await rig.store.settle()
        #expect(rig.control.entered == 0, "nothing was sent")
    }

    @Test func aSliderMovedWhileAWriteWasInFlightIsNotWipedByItsFailure() async throws {
        let rig = SaveStateRig()
        await rig.store.load()
        rig.control.hold()
        rig.control.fail(next: 1)               // only the first write is refused
        rig.store.setDensity(50)
        await rig.until { rig.control.entered == 1 }
        rig.store.setTileSeconds(40)            // moved while density is on its way
        #expect(rig.store.stage?.tileSeconds == 40)
        rig.control.release()
        await rig.store.settle()
        // the density write failed; the tile life one went in the next request and was taken
        #expect(rig.store.failedPatch == StagePatch(density: 50))
        #expect(rig.store.saveState == .failed(error: .unavailable, fields: [.density]))
        #expect(rig.store.stage?.density == 50 && rig.store.stage?.tileSeconds == 40)
        #expect(rig.store.lastConfirmedStage?.tileSeconds == 40 && rig.store.lastConfirmedStage?.density == 30)
        #expect(rig.server.stage.tileSeconds == 40)
    }

    @Test func movingAFailedSliderAgainMakesItTheNewValuesToSend() async throws {
        let rig = SaveStateRig()
        await rig.store.load()
        rig.control.fail(next: 1)
        rig.store.setDensity(77)
        await rig.store.settle()
        #expect(rig.store.failedPatch == StagePatch(density: 77))
        rig.store.setDensity(20)
        #expect(rig.store.failedPatch == nil, "superseded")
        #expect(rig.store.saveState == .dirty(fields: [.density]))
        await rig.store.settle()
        #expect(rig.store.saveState == .synced && rig.server.stage.density == 20)
    }

    @Test func aRefreshWhileFailedKeepsTheUnsavedValuesOnShow() async throws {
        let rig = SaveStateRig()
        await rig.store.load()
        rig.control.fail(next: -1)
        rig.store.setDensity(77)
        await rig.store.settle()
        await rig.store.load()                  // a read answers the old density; the failed value stays on top of it
        #expect(rig.store.stage?.density == 77 && rig.store.lastConfirmedStage?.density == 30)
        #expect(rig.store.saveState == .failed(error: .unavailable, fields: [.density]))
    }

    @Test func anAwaitedSwitchNamesItsFieldWhileItIsOnItsWay() async throws {
        let rig = SaveStateRig()
        await rig.store.load()
        rig.control.hold()
        let store = rig.store
        let task = Task { @MainActor in try await store.setOnAir(false) }
        await rig.until { rig.control.entered == 1 }
        #expect(store.busyFields == [.onAir])
        #expect(store.saveState == .saving(fields: [.onAir]))
        #expect(store.stage?.onAir == false, "shown at once")
        #expect(store.lastConfirmedStage?.onAir == true)
        rig.control.release()
        try await task.value
        #expect(store.busyFields.isEmpty && store.saveState == .synced)
        #expect(store.lastConfirmedStage?.onAir == false)
    }

    @Test func aRefusedSwitchIsPutBackAndNoLongerBusy() async throws {
        let rig = SaveStateRig()
        await rig.store.load()
        rig.control.fail(next: 1)
        await #expect(throws: StageError.unavailable) { try await rig.store.setSound(false) }
        #expect(rig.store.stage?.sound == true && rig.store.lastConfirmedStage?.sound == true)
        #expect(rig.store.busyFields.isEmpty)
        #expect(rig.store.saveState == .synced, "an awaited switch reports through its throw, not through the sliders' failure")
    }

    @Test func aServerChangeForgetsTheSaveState() async throws {
        let rig = SaveStateRig()
        await rig.store.load()
        rig.control.fail(next: -1)
        rig.store.setDensity(77)
        await rig.store.settle()
        #expect(rig.store.saveState != .synced)
        rig.store.reset()
        #expect(rig.store.saveState == .synced)
        #expect(rig.store.failedPatch == nil && rig.store.lastConfirmedStage == nil && rig.store.busyFields.isEmpty)
    }
}

// MARK: - connected_canvases

struct StageConnectedCanvasesTests {
    private func stage(_ extra: String) throws -> StageSettings {
        let json = """
        {"on_air":true,"live_url":"https://studio.capybaraharmony.com/live/Zk7Q2abcdefghijklmnopqrstuvwxk7Q2",
         "store_url":"https://studio.capybaraharmony.com/store"\(extra)}
        """
        return try CobaltJSON.decoder().decode(StageSettings.self, from: Data(json.utf8))
    }

    @Test func theCountDecodesAndAnOlderServerLeavesItUnknown() throws {
        #expect(try stage(#","connected_canvases":2"#).connectedCanvases == 2)
        #expect(try stage(#","connected_canvases":0"#).connectedCanvases == 0)
        #expect(try stage("").connectedCanvases == nil)
        #expect(try stage(#","connected_canvases":-3"#).connectedCanvases == 0, "never below none")
        #expect(try stage(#","connected_canvases":"many""#).connectedCanvases == nil, "an odd value is unknown, not a failure")
    }

    @Test func nilIsUnknownNeverNone() throws {
        #expect(try stage("").obsPresence == .unknown)
        #expect(try stage(#","connected_canvases":0"#).obsPresence == .disconnected)
        #expect(try stage(#","connected_canvases":3"#).obsPresence == .connected(3))
    }

    @Test func theFeedCarriesTheCountToo() throws {
        let page = try CobaltJSON.decoder().decode(
            StageRedemptionsPage.self, from: Data(#"{"status":"success","redemptions":[],"connected_canvases":1}"#.utf8))
        #expect(page.connectedCanvases == 1 && page.redemptions.isEmpty)
        let old = try CobaltJSON.decoder().decode(StageRedemptionsPage.self, from: Data(#"{"redemptions":[]}"#.utf8))
        #expect(old.connectedCanvases == nil)
    }

    @MainActor
    @Test func theFeedPollUpdatesTheStageAndItsConfirmedCopy() async throws {
        let app = AppModel.makePreview(.happy, timeScale: 0.01, clock: SystemClock())
        await app.stage.load()
        #expect(app.stage.stage?.connectedCanvases == 1, "the preview's connected stage carries one canvas")
        app.stage.noteConnectedCanvases(2)
        #expect(app.stage.stage?.connectedCanvases == 2 && app.stage.lastConfirmedStage?.connectedCanvases == 2)
        app.stage.noteConnectedCanvases(nil)
        #expect(app.stage.stage?.connectedCanvases == 2, "a feed that does not say leaves it alone")
        app.stage.noteConnectedCanvases(0)
        #expect(app.stage.stage?.obsPresence == .disconnected)
    }

    @Test func aPatchKnowsItsFieldsAndRemovesThem() {
        let patch = StagePatch(onAir: true, density: 5, videoMax: 3)
        #expect(patch.fields == [.onAir, .density, .videoMax])
        #expect(patch.removing(StagePatch(density: 1)) == StagePatch(onAir: true, videoMax: 3))
        #expect(StagePatch().fields.isEmpty)
    }
}
