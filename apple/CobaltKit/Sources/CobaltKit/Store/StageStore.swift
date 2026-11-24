import Foundation
import Observation

/// Stage, the studio tab (APP-API-CONTRACT 30): the stream canvas OBS loads, the spotlight, the pool, Twitch and its four
/// rewards, the redemptions feed. One `GET /stage` loads the stage and the rewards; every change after that is a write that
/// answers the stage as it is now.
///
/// - Switches and buttons (`setOnAir`, `apply`, `perform`, `rotate`, `updateReward`, `connectTwitch`, `disconnectTwitch`)
///   are awaited and throw `StageError`-classifiable errors (`StageError.from`); the ones with a switch to show are
///   optimistic and put the old value back when the write fails.
/// - The sliders (`setDensity`, `setTileSeconds`, ...) are not awaited: they clamp, show the value at once, and send the
///   latest values 300 ms after the last change (last write wins, one request for the burst). A failed write keeps what the
///   owner set on show but says so: `saveState` is `.failed`, `failedPatch` holds the values that did not go, and `notice`
///   says why. `retryFailedPatch()` sends them again; `revertUnsavedChanges()` puts `lastConfirmedStage` (only ever what the
///   server said) back at once, offline or not, so a slider never stays on a value the server does not have.
/// - `saveState` is the one word for the header: `.synced`, `.dirty` (a slider moved, not sent yet), `.saving`, `.failed`.
///   `busyFields` names the controls with an awaited write in flight (a switch shows its own spinner).
/// - The feed is read every 4 s only between `startPolling()` and `stopPolling()` (the screen being visible); a new
///   redemption also re-reads the stage, since a summon moves the spotlight.
///
/// Reads the app model's current client on every call, so a server or key change is picked up (`reset()` forgets what the
/// old server said).
@MainActor @Observable
public final class StageStore {
    public enum State: Equatable, Sendable {
        case idle
        /// A `load()` is running. `stage` still holds what was loaded before, if anything.
        case loading
        case loaded
        /// The last `load()` failed. `stage` still holds what was loaded before, if anything.
        case failed(StageError)
    }

    /// Where paging the pool for the spotlight picker is.
    public enum PoolState: Equatable, Sendable {
        case idle, loading, loaded
        case failed(StageError)
    }

    /// A write the owner did not ask to await (a slider) failed. Observe `id` to react once per failure.
    public struct Notice: Equatable, Sendable, Identifiable {
        public let id: Int
        public let error: StageError
    }

    /// Whether what the screen shows is what the server has.
    public enum SaveState: Equatable, Sendable {
        /// Nothing waits to be sent and nothing failed.
        case synced
        /// A slider moved; the send is waiting for the burst to end.
        case dirty(fields: Set<StageField>)
        /// A write is on its way (a slider burst, or a switch or reward being awaited).
        case saving(fields: Set<StageField>)
        /// A slider write was refused or never arrived; the values stay shown until retried or reverted.
        case failed(error: StageError, fields: Set<StageField>)
    }

    public private(set) var stage: StageSettings?
    /// The stage exactly as the server last said it (a read or the answer of a write). Never an optimistic edit.
    public private(set) var lastConfirmedStage: StageSettings?
    public private(set) var saveState: SaveState = .synced
    /// The slider values the server did not take (nil when none). What `retryFailedPatch()` sends again.
    public private(set) var failedPatch: StagePatch?
    /// Controls with an awaited write in flight (`apply`, `updateReward`): each shows a spinner of its own.
    public private(set) var busyFields: Set<StageField> = []
    /// The five rewards in the order summon, chaos, shuffle, pin, skip (empty until the first load).
    public private(set) var rewards: [StageReward] = []
    /// The feed, newest first (empty until the first poll).
    public private(set) var redemptions: [StageRedemption] = []
    public private(set) var state: State = .idle
    public private(set) var notice: Notice?
    /// The feed is being polled (the screen is visible).
    public private(set) var isPolling = false
    /// The last poll failed (the feed shows what it had).
    public private(set) var feedProblem = false

    // The spotlight picker's pages of the pool (`GET /stage/pool`).
    public private(set) var poolItems: [StageItem] = []
    public private(set) var poolTotal = 0
    public private(set) var poolState: PoolState = .idle
    @ObservationIgnored private var poolNext: Int? = 0

    @ObservationIgnored private let ctx: PipelineContext
    /// Bumped by `reset()`: an answer from the old server arriving later is dropped.
    @ObservationIgnored private var generation = 0
    /// Slider values shown but not yet answered by the server.
    @ObservationIgnored private var pending = StagePatch()
    /// The slider values being sent right now.
    @ObservationIgnored private var inFlight = StagePatch()
    @ObservationIgnored private var failedError: StageError?
    @ObservationIgnored private var busyCounts: [StageField: Int] = [:]
    /// Bumped when the owner reverts: a write that was in flight then is no longer theirs to report as failed.
    @ObservationIgnored private var saveEpoch = 0
    @ObservationIgnored private var debounce: Task<Void, Never>?
    @ObservationIgnored private var flushing = false
    @ObservationIgnored private var flushAgain = false
    @ObservationIgnored private var noticeCounter = 0
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var pollToken = 0
    @ObservationIgnored private var pollFailures = 0
    @ObservationIgnored private var redemptionsLoaded = false
    @ObservationIgnored private var poolToken = 0

    init(context: PipelineContext) {
        self.ctx = context
    }

    // MARK: loading

    /// Reads the stage and its rewards (`GET /stage`). A load that is already running is not doubled. A failure keeps what
    /// was loaded before.
    public func load() async {
        guard state != .loading else { return }
        let started = generation
        state = .loading
        do {
            let snapshot = try await ctx.client.stage()
            guard started == generation else { return }
            adopt(snapshot)
            state = .loaded
        } catch {
            guard started == generation else { return }
            state = .failed(StageError.from(error))
        }
    }

    /// The reward for this action, if loaded.
    public func reward(_ kind: StageRewardKind) -> StageReward? { rewards.first { $0.action == kind } }

    /// The stage and rewards as the server just said them. Slider values not yet sent stay on top of the stage.
    private func adopt(_ snapshot: StageSnapshot) {
        show(snapshot.stage)
        rewards = Self.ordered(snapshot.rewards)
    }

    /// What the owner has changed that the server has not confirmed: slider values that failed, are on their way, or wait.
    private var unsaved: StagePatch {
        (failedPatch ?? StagePatch()).merging(inFlight).merging(pending)
    }

    /// The server just said this: it is the confirmed stage, and the unconfirmed values stay on top of it.
    private func show(_ confirmed: StageSettings) {
        lastConfirmedStage = confirmed
        let waiting = unsaved
        stage = waiting.isEmpty ? confirmed : confirmed.applying(waiting)
    }

    private func refreshSaveState() {
        let saving = inFlight.fields.union(busyFields)
        let next: SaveState
        if !saving.isEmpty {
            next = .saving(fields: saving)
        } else if let failed = failedPatch, !failed.isEmpty {
            next = .failed(error: failedError ?? .other, fields: failed.fields)
        } else if !pending.isEmpty {
            next = .dirty(fields: pending.fields)
        } else {
            next = .synced
        }
        if next != saveState { saveState = next }
    }

    private func setFailed(_ patch: StagePatch, error: StageError? = nil) {
        if patch.isEmpty {
            failedPatch = nil
            failedError = nil
            notice = nil
        } else {
            failedPatch = patch
            if let error { failedError = error }
        }
    }

    private func markBusy(_ fields: Set<StageField>) {
        for field in fields { busyCounts[field, default: 0] += 1 }
        busyFields = Set(busyCounts.keys)
        refreshSaveState()
    }

    private func unmarkBusy(_ fields: Set<StageField>) {
        for field in fields {
            guard let n = busyCounts[field] else { continue }
            if n <= 1 { busyCounts[field] = nil } else { busyCounts[field] = n - 1 }
        }
        busyFields = Set(busyCounts.keys)
        refreshSaveState()
    }

    /// The feed's count of connected OBS canvases (30; `GET /stage/redemptions` carries it, so the 4 s poll keeps it live).
    func noteConnectedCanvases(_ count: Int?) {
        guard let count else { return }
        if stage?.connectedCanvases != count { stage?.connectedCanvases = count }
        if lastConfirmedStage?.connectedCanvases != count { lastConfirmedStage?.connectedCanvases = count }
    }

    private static func ordered(_ rewards: [StageReward]) -> [StageReward] {
        StageRewardKind.allCases.compactMap { kind in rewards.first { $0.action == kind } }
    }

    /// A quiet re-read (no state change): after a failed write, a disconnect, or a new redemption.
    private func refreshQuietly() async {
        let started = generation
        guard let snapshot = try? await ctx.client.stage(), started == generation else { return }
        adopt(snapshot)
    }

    private func post(_ error: Error) {
        noticeCounter += 1
        notice = Notice(id: noticeCounter, error: StageError.from(error))
    }

    // MARK: settings you wait for

    /// Sends a patch now (`PATCH /stage`) and shows its fields at once; a refusal puts the old values back and throws. The
    /// pool is never guessed: it changes with the answer.
    public func apply(_ patch: StagePatch) async throws {
        let clamped = patch.clamped()
        let started = generation
        let before = stage
        let fields = clamped.fields
        markBusy(fields)
        defer { if started == generation { unmarkBusy(fields) } }
        if let current = stage { stage = current.applying(clamped) }
        do {
            let answer = try await ctx.client.updateStage(clamped)
            guard started == generation else { return }
            show(answer)
        } catch {
            if started == generation, let before, let current = stage {
                stage = current.applying(clamped.values(in: before))
            }
            throw error
        }
    }

    /// "go live" / "stop".
    public func setOnAir(_ on: Bool) async throws { try await apply(StagePatch(onAir: on)) }

    /// Picks the pool. `StageError.searchUnavailable` for words while the meaning search is off; nothing changes then.
    public func setPool(_ choice: StagePoolChoice) async throws {
        var choice = choice
        if case .search(let words) = choice {
            guard let clean = StageRule.cleanSearch(words) else { throw StageError.badRequest }
            choice = .search(words: clean)
        }
        try await apply(StagePatch(pool: choice))
    }

    /// The store lock: `false` locks the store and its sign-in for everyone on the next request.
    public func setStoreOpen(_ open: Bool) async throws { try await apply(StagePatch(storeOpen: open)) }

    public func setSound(_ on: Bool) async throws { try await apply(StagePatch(sound: on)) }

    /// "unmute all videos": every playing video tile has sound, not only the spotlight. `sound` stays the master switch, so
    /// turning this on also turns `sound` on (one patch).
    public func setSoundAll(_ on: Bool) async throws { try await apply(StagePatch(sound: on ? true : nil, soundAll: on)) }

    /// "play videos through": a playing video stays until it has played once, even past its time.
    public func setPlayThrough(_ on: Bool) async throws { try await apply(StagePatch(playThrough: on)) }

    // MARK: sliders (debounced)

    /// "how crazy", 5...100.
    public func setDensity(_ value: Int) { edit(StagePatch(density: value)) }
    /// "tile life", 3...120 seconds.
    public func setTileSeconds(_ value: Int) { edit(StagePatch(tileSeconds: value)) }
    public func setTileScale(_ value: Double) { edit(StagePatch(tileScale: value)) }
    public func setSpotlightSeconds(_ value: Int) { edit(StagePatch(spotlightSeconds: value)) }
    public func setVideoMax(_ value: Int) { edit(StagePatch(videoMax: value)) }

    /// Shows the clamped value now and schedules the send 300 ms after the last change.
    private func edit(_ patch: StagePatch) {
        guard let current = stage else { return }
        let clamped = patch.clamped()
        stage = current.applying(clamped)
        pending = pending.merging(clamped)
        // a value that failed before and was moved again is the new value's to send
        if let failed = failedPatch { setFailed(failed.removing(clamped)) }
        refreshSaveState()
        debounce?.cancel()
        let started = generation
        debounce = Task { @MainActor [weak self] in
            guard let self else { return }
            do { try await self.ctx.clock.sleep(seconds: StageRule.debounce) } catch { return }
            guard !Task.isCancelled, started == self.generation else { return }
            self.debounce = nil
            await self.flush()
        }
    }

    /// Sends what the sliders hold. A burst is one request; a change made while one is in flight goes in the next. A write
    /// that fails keeps its values in `failedPatch` (and on show); what was changed meanwhile is not touched.
    private func flush() async {
        if flushing {
            flushAgain = true
            return
        }
        flushing = true
        defer { flushing = false }
        let started = generation
        repeat {
            flushAgain = false
            let patch = pending
            guard !patch.isEmpty else {
                refreshSaveState()
                return
            }
            pending = StagePatch()
            inFlight = patch
            let epoch = saveEpoch
            refreshSaveState()
            let client = ctx.client
            // an unstructured task: a slider moving again must not cancel a request that is already on its way
            let outcome = await Task { await Self.send(client, patch) }.value
            guard started == generation else { return }
            inFlight = StagePatch()
            switch outcome {
            case .success(let answer):
                if let failed = failedPatch { setFailed(failed.removing(patch)) }
                show(answer)
            case .failure(let error):
                // reverted meanwhile: the owner gave those values up, so a refusal is not theirs to see
                if saveEpoch == epoch {
                    setFailed((failedPatch ?? StagePatch()).merging(patch), error: StageError.from(error))
                    post(error)
                }
            }
            refreshSaveState()
        } while flushAgain || !pending.isEmpty
    }

    /// Sends the values that failed again, with whatever was moved since. Returns when everything has been answered.
    public func retryFailedPatch() async {
        guard let failed = failedPatch, !failed.isEmpty else { return }
        pending = failed.merging(pending)
        setFailed(StagePatch())
        debounce?.cancel()
        debounce = nil
        refreshSaveState()
        await flush()
        await settle()
    }

    /// Gives the unsaved slider values up: the stage goes back to `lastConfirmedStage` now, with no request, so it works
    /// offline too. A write already on its way is not cancelled; if the server took it, its answer shows.
    public func revertUnsavedChanges() {
        saveEpoch += 1
        debounce?.cancel()
        debounce = nil
        pending = StagePatch()
        flushAgain = false
        setFailed(StagePatch())
        if let confirmed = lastConfirmedStage { stage = confirmed }
        refreshSaveState()
    }

    nonisolated private static func send(_ client: any CobaltClient, _ patch: StagePatch) async -> Result<StageSettings, Error> {
        do { return .success(try await client.updateStage(patch)) } catch { return .failure(error) }
    }

    /// Waits until every slider change has been sent and answered (tests, and a screen that is about to go away).
    public func settle() async {
        var guardCount = 0
        while debounce != nil || flushing || !pending.isEmpty, guardCount < 4_000 {
            guardCount += 1
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    // MARK: the canvas

    /// "rotate": a new OBS token; the old link stops working at once.
    public func rotate() async throws {
        let started = generation
        let answer = try await ctx.client.rotateStage()
        guard started == generation else { return }
        show(answer)
    }

    /// An owner action on the canvas: skip, pin, unpin, shuffle, chaos, or a pick from the pool. Throws
    /// `StageError.offAir` while the stage is off air, `.notFound` for an item that left the pool, and `.videosOnly` for a
    /// picture. The answer carries the new spotlight; the feed is read again so the "you" line shows.
    public func perform(_ action: StageAction) async throws {
        let started = generation
        let answer = try await ctx.client.stageAction(action)
        guard started == generation else { return }
        show(answer)
        await refreshRedemptions()
    }

    // MARK: rewards

    /// Saves a reward (`PATCH /stage/rewards/<action>`) and updates it on Twitch. The new values show at once; a refusal
    /// puts the old ones back and throws. The answer's `synced` is false when Twitch refused.
    public func updateReward(_ kind: StageRewardKind, cost: Int? = nil, cooldownSeconds: Int? = nil, enabled: Bool? = nil) async throws {
        let started = generation
        let before = reward(kind)
        let cleanCost = cost.map { StageRule.clamp($0, to: StageRule.costRange) }
        let cleanCooldown = cooldownSeconds.map { StageRule.clamp($0, to: StageRule.cooldownRange) }
        let field: Set<StageField> = [.reward(kind)]
        markBusy(field)
        defer { if started == generation { unmarkBusy(field) } }
        replaceReward(kind) { r in
            if let cleanCost { r.cost = cleanCost }
            if let cleanCooldown { r.cooldownSeconds = cleanCooldown }
            if let enabled { r.enabled = enabled }
        }
        do {
            let answer = try await ctx.client.updateStageReward(kind, cost: cleanCost, cooldownSeconds: cleanCooldown, enabled: enabled)
            guard started == generation else { return }
            replaceReward(kind) { $0 = answer }
        } catch {
            if started == generation, let before { replaceReward(kind) { $0 = before } }
            throw error
        }
    }

    private func replaceReward(_ kind: StageRewardKind, _ change: (inout StageReward) -> Void) {
        guard let i = rewards.firstIndex(where: { $0.action == kind }) else { return }
        change(&rewards[i])
    }

    // MARK: Twitch

    /// Starts the Twitch sign-in: the authorize URL for an `ASWebAuthenticationSession` with callback scheme
    /// `cobalt-apple`. `StageError.twitchOff` while the server has no Twitch secrets. Call `load()` when the session ends.
    public func connectTwitch() async throws -> URL {
        try await ctx.client.connectStageTwitch()
    }

    /// Takes Twitch off the stage: the webhook, the five rewards on Twitch and the connection (best effort on Twitch's side).
    public func disconnectTwitch() async throws {
        let started = generation
        let answer = try await ctx.client.disconnectStageTwitch()
        guard started == generation else { return }
        show(answer)
        await refreshQuietly()                    // the rewards, no longer synced
    }

    // MARK: the feed

    /// Reads the feed now (`GET /stage/redemptions`). A new line also re-reads the stage: a summon moved the spotlight.
    public func refreshRedemptions() async {
        let started = generation
        do {
            let page = try await ctx.client.stageRedemptionsPage(limit: StageRule.redemptionsLimit, before: nil)
            guard started == generation else { return }
            let list = page.redemptions
            pollFailures = 0
            noteConnectedCanvases(page.connectedCanvases)
            // only on a change, so a quiet poll redraws nothing
            if feedProblem { feedProblem = false }
            let arrived = redemptionsLoaded && list.first?.id != redemptions.first?.id
            if list != redemptions { redemptions = list }
            redemptionsLoaded = true
            if arrived, stage != nil { await refreshQuietly() }
        } catch {
            guard started == generation, !Task.isCancelled else { return }
            pollFailures += 1
            feedProblem = true
        }
    }

    /// The screen is visible: the feed is read now and then every 4 s (a failing server backs off to 30 s) until `stopPolling()`.
    public func startPolling() {
        guard pollTask == nil else { return }
        isPolling = true
        pollToken += 1
        let token = pollToken
        pollTask = Task { @MainActor [weak self] in
            await self?.pollLoop()
            guard let self, self.pollToken == token else { return }
            self.pollTask = nil
            self.isPolling = false
        }
    }

    /// The screen went away (or the app left the front).
    public func stopPolling() {
        pollToken += 1
        pollTask?.cancel()
        pollTask = nil
        isPolling = false
    }

    private func pollLoop() async {
        while !Task.isCancelled {
            await refreshRedemptions()
            guard !Task.isCancelled else { return }
            let wait = StageRule.pollInterval * pow(2, Double(min(pollFailures, 3)))
            do { try await ctx.clock.sleep(seconds: min(wait, 30)) } catch { return }
        }
    }

    // MARK: the pool, for the spotlight picker

    /// Reads the first page of the pool again (`GET /stage/pool`).
    public func loadPool() async {
        poolToken += 1
        poolItems = []
        poolTotal = 0
        poolNext = 0
        poolState = .idle
        await loadMorePool()
    }

    /// Reads the next page of the pool; a no-op on the last page or while one is loading. A failure keeps the pages read.
    public func loadMorePool() async {
        guard poolState != .loading, let offset = poolNext else { return }
        let started = generation
        let token = poolToken
        poolState = .loading
        do {
            let page = try await ctx.client.stagePool(offset: offset, limit: StageRule.poolPageSize)
            guard started == generation, token == poolToken else { return }
            var seen = Set(poolItems.map(\.id))
            for item in page.items where seen.insert(item.id).inserted { poolItems.append(item) }
            poolTotal = page.total
            // a `next` that does not move past this page would be asked for again forever
            poolNext = page.next.flatMap { $0 > offset ? $0 : nil }
            poolState = .loaded
        } catch {
            guard started == generation, token == poolToken else { return }
            poolState = .failed(StageError.from(error))
        }
    }

    /// More pages can be read.
    public var poolHasMore: Bool { poolNext != nil }

    // MARK: server change

    /// Another server or key: nothing from the old one is kept.
    func reset() {
        generation += 1
        poolToken += 1
        debounce?.cancel()
        debounce = nil
        pending = StagePatch()
        inFlight = StagePatch()
        failedError = nil
        busyCounts = [:]
        saveEpoch += 1
        flushAgain = false
        stopPolling()
        stage = nil
        lastConfirmedStage = nil
        failedPatch = nil
        busyFields = []
        saveState = .synced
        rewards = []
        redemptions = []
        redemptionsLoaded = false
        feedProblem = false
        pollFailures = 0
        notice = nil
        state = .idle
        poolItems = []
        poolTotal = 0
        poolNext = 0
        poolState = .idle
    }
}

// The screen starts and stops the feed (`StageScreen.syncPolling`); the store also stops it itself when the app leaves the
// screen, so a studio screen kept alive behind another tab or window cannot keep reading. Coming back is the screen's
// (it knows whether it is in front); registered once by `AppModel.observeLifecycle`.
extension StageStore: LifecycleAware {
    func observeLifecycle(_ lifecycle: AppLifecycle = .shared) {
        lifecycle.register(self, order: .work)
    }

    public func lifecycle(_ event: LifecycleEvent, snapshot: LifecycleSnapshot) {
        if event == .didEnterBackground || event == .hidden { stopPolling() }
    }
}
