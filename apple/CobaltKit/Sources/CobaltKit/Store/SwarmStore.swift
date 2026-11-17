import Foundation
import Observation

/// Swarms in the app (apple/CONTRACT-SWARMS.md; APP-API-CONTRACT 59, 61): the list, the one swarm on screen, its changes and
/// the agent sheet.
///
/// - `loadList()` reads `GET /swarms` (the list screen, and the "swarms" badge: `waitingCount`).
/// - `show(id:)` puts one swarm on screen and starts polling it; `hide()` stops. The poll is a task that lives only between
///   the two: every 3 s while the swarm is running, stopping or applying, every 15 s otherwise (`pollInterval(for:)`), on the
///   app's clock (`PipelineContext.clock`), so tests drive it with a virtual one and nobody sleeps for real. Nothing is read
///   after `hide()`.
/// - `approve()` and `apply(skipClashes:)` ask the `ownerCheck` (Face ID / Touch ID) first; a "no" throws
///   `SwarmError.notConfirmed` and sends nothing. `decline()`, `stop()` and `retry()` do not ask.
/// - `setKeep` and `rename` are edits of a draft: nothing is written to 7TV or the library until `apply`.
///
/// Reads the app model's current client on every call, so a server or key change is picked up (`reset()` forgets what the
/// old server said).
@MainActor @Observable
public final class SwarmStore {
    public enum State: Equatable, Sendable {
        case idle
        /// A `loadList()` is running. `list` still holds what was listed before, if anything.
        case loading
        case loaded
        /// The last `loadList()` failed. `list` still holds what was listed before, if anything.
        case failed(SwarmError)
    }

    /// Newest first, as the server lists them (at most 50).
    public private(set) var list: [Swarm] = []
    public private(set) var state: State = .idle
    /// The swarm on screen (between `show(id:)` and `hide()`).
    public private(set) var shown: Swarm?
    /// The last read of `shown` failed (it keeps what it had).
    public private(set) var shownProblem: SwarmError?
    /// The shown swarm's changes, in the server's order (task, then n); empty until `loadChanges()`.
    public private(set) var changes: [SwarmChange] = []
    /// How many changes the server has (`changes.count` once every page is read).
    public private(set) var changesTotal = 0
    public private(set) var changesProblem: SwarmError?
    /// The agent on the sheet (`loadAgent(_:)`), refreshed on every poll until `closeAgent()`.
    public private(set) var agent: SwarmAgent?
    public private(set) var agentProblem: SwarmError?
    /// A swarm is being polled (between `show(id:)` and `hide()`).
    public private(set) var isPolling = false

    /// The results board of the shown swarm (APP-API-CONTRACT 62.4): the rows read so far (100 a page), every agent, the groups.
    /// Set by `loadBoard()`; `loadMoreBoard()` appends.
    public private(set) var board: SwarmBoard?
    public private(set) var boardProblem: SwarmError?
    /// What the board is filtered and ordered by. Change them, then call `loadBoard()`.
    public var boardQuery: String = ""
    public var boardGroup: String?
    public var boardSort: BoardSort = .agent
    /// The agent strip's filter: only this agent's rows (from 1); nil is all.
    public var boardAgent: Int?

    /// Asked before approve and apply. The app model sets Face ID / Touch ID; previews and tests inject their own.
    /// Where a deep link (`cobalt-apple://swarm/<id>[/review|/results]`), a notification or a Live Activity asked to go.
    /// The swarms screen consumes it (navigates, then sets it back to nil).
    public var route: SwarmRoute?
    @ObservationIgnored public var ownerCheck: any OwnerCheck

    /// 3 s while the swarm is running, stopping or applying.
    public static let busyInterval: Duration = .seconds(3)
    /// 15 s otherwise.
    public static let calmInterval: Duration = .seconds(15)
    /// The changes are read this many at a time (the server's limit), and at most this many pages.
    static let changesPage = 200
    static let changesPages = 10
    /// The board is read this many rows at a time.
    public static let boardPage = 100

    @ObservationIgnored private let ctx: PipelineContext
    /// Bumped by `reset()`: an answer from the old server arriving later is dropped.
    @ObservationIgnored private var generation = 0
    /// Bumped by `show`, `hide` and a restart of the poll: an answer for a swarm that is no longer shown is dropped.
    @ObservationIgnored private var showToken = 0
    /// The swarm `show(id:)` was asked for (`shown` fills in when its first read arrives).
    @ObservationIgnored private var showingID: String?
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var pollingInterval: Duration?
    @ObservationIgnored private var agentNumber: Int?
    /// The clashes counted from each swarm's change list: the wire has no such number.
    @ObservationIgnored private var clashCounts: [String: Int] = [:]
    @ObservationIgnored private var changesFor: String?
    @ObservationIgnored private var boardLoading = false
    /// A change to the board's filter arrived while a read was running: read again when it ends.
    @ObservationIgnored private var boardStale = false
    /// The board screen (or the agent sheet) asked before any swarm was on screen: the launch arguments, a deep link and a
    /// tap all push the screen in the same breath as `show(id:)`, so its first ask comes first. The ask is kept and answered
    /// when the swarm is read (or ends in the screen's error state when it cannot be). `hide()` forgets it.
    @ObservationIgnored private var boardWanted = false

    init(context: PipelineContext, ownerCheck: (any OwnerCheck)? = nil) {
        self.ctx = context
        self.ownerCheck = ownerCheck ?? (context.isPreview ? FixedOwnerCheck(answer: true) : LocalOwnerCheck())
    }

    // MARK: what the screens read

    /// The badge: swarms that wait for you (a plan to approve, changes to apply).
    public var waitingCount: Int { list.filter(\.waitsForYou).count }

    /// "waiting for you", "running", "finished": the list screen's three groups, in the server's order.
    public var groups: (waiting: [Swarm], running: [Swarm], finished: [Swarm]) {
        var waiting: [Swarm] = []
        var running: [Swarm] = []
        var finished: [Swarm] = []
        for swarm in list {
            if swarm.waitsForYou { waiting.append(swarm) } else if swarm.isWorking { running.append(swarm) } else { finished.append(swarm) }
        }
        return (waiting, running, finished)
    }

    /// The row's second line on the app's clock.
    public func rowLine(_ swarm: Swarm) -> String { SwarmWords.rowLine(swarm, now: ctx.clock.now()) }

    /// 3 s while the swarm is running, stopping or applying; 15 s otherwise (waiting for you, done, ended).
    public func pollInterval(for swarm: Swarm) -> Duration {
        swarm.isWorking ? Self.busyInterval : Self.calmInterval
    }

    // MARK: the list

    /// Reads the list (`GET /swarms`). One that is already running is not doubled. A failure keeps what was listed before.
    public func loadList() async {
        guard state != .loading else { return }
        let started = generation
        state = .loading
        do {
            let swarms = try await ctx.client.swarms()
            guard started == generation else { return }
            list = swarms.map(withClashes)
            if let id = shown?.id, let fresh = list.first(where: { $0.id == id }) { shown = fresh }
            state = .loaded
        } catch {
            guard started == generation else { return }
            state = .failed(SwarmError.from(error))
        }
    }

    // MARK: one swarm

    /// Puts a swarm on screen: what the list knows of it at once, then its own read, and from then on a poll until `hide()`.
    public func show(id: String) async {
        pollTask?.cancel()
        pollTask = nil
        showToken += 1
        let token = showToken
        showingID = id
        if let before = shown?.id, before != id {
            // another swarm was on screen: nothing of it is kept
            changes = []
            changesTotal = 0
            changesFor = nil
            changesProblem = nil
            agent = nil
            agentNumber = nil
            agentProblem = nil
            board = nil
            boardProblem = nil
            boardWanted = false
        }
        if shown?.id != id { shown = list.first { $0.id == id }.map(withClashes) }
        shownProblem = nil
        isPolling = true
        await refreshShown(id, token: token)
        guard token == showToken else { return }
        startPolling(id: id, token: token)
    }

    /// The swarm screen went away (or the app left the front): the poll stops and nothing is kept on screen.
    public func hide() {
        showToken += 1
        showingID = nil
        pollTask?.cancel()
        pollTask = nil
        pollingInterval = nil
        isPolling = false
        shown = nil
        shownProblem = nil
        changes = []
        changesTotal = 0
        changesFor = nil
        changesProblem = nil
        agent = nil
        agentNumber = nil
        agentProblem = nil
        board = nil
        boardProblem = nil
        boardWanted = false
        boardQuery = ""
        boardGroup = nil
        boardSort = .agent
        boardAgent = nil
    }

    private func startPolling(id: String, token: Int) {
        pollTask?.cancel()
        isPolling = true
        pollTask = Task { @MainActor [weak self] in
            await self?.pollLoop(id: id, token: token)
        }
    }

    private func pollLoop(id: String, token: Int) async {
        while !Task.isCancelled {
            guard token == showToken, showingID == id else { return }
            let interval = shown.map(pollInterval(for:)) ?? Self.calmInterval
            pollingInterval = interval
            do { try await ctx.clock.sleep(seconds: interval.seconds) } catch { return }
            guard !Task.isCancelled, token == showToken else { return }
            await refreshShown(id, token: token)
        }
    }

    /// One poll tick: the swarm, then (while the sheet or the check list is open) what hangs off it.
    private func refreshShown(_ id: String, token: Int) async {
        let started = generation
        do {
            let fresh = try await ctx.client.swarm(id: id)
            guard started == generation, token == showToken else { return }
            let before = shown?.apply.status
            shownProblem = nil
            adopt(fresh, restart: false)
            // the changes: counted for the "apply 338" button as soon as there is something to apply, and kept fresh after
            if fresh.mode == .propose, fresh.apply.status != .none {
                if changesFor != id || before != fresh.apply.status || fresh.apply.status == .applying {
                    await loadChanges()
                }
            }
        } catch {
            guard started == generation, token == showToken else { return }
            let problem = SwarmError.from(error)
            shownProblem = problem
            // a board or a sheet that asked early has nothing to wait for any more: it shows the error, not a spinner
            if board == nil, boardWanted { boardProblem = problem }
            if agent == nil, agentNumber != nil { agentProblem = problem }
            if case .notFound = problem { return }
        }
        guard token == showToken, !Task.isCancelled else { return }
        if let n = agentNumber { await loadAgent(n, quiet: true) }
        // an open board stays fresh while the swarm works (only when it is one page, so rows already scrolled to are not lost);
        // one that asked before the swarm was shown is read now
        if boardWanted, board == nil, boardProblem == nil { await loadBoard() }
        else if let board, board.swarm.id == id, (shown?.isWorking ?? false), board.rows.count <= Self.boardPage { await loadBoard() }
    }

    /// Puts a fresh swarm in the list and on screen; restarts the poll when its pace changed.
    private func adopt(_ swarm: Swarm, restart: Bool = true) {
        let swarm = withClashes(swarm)
        if let i = list.firstIndex(where: { $0.id == swarm.id }) { list[i] = swarm }
        guard showingID == swarm.id else { return }
        shown = swarm
        if restart, isPolling, pollingInterval != pollInterval(for: swarm) { startPolling(id: swarm.id, token: showToken) }
    }

    private func withClashes(_ swarm: Swarm) -> Swarm {
        var s = swarm
        s.clashCount = clashCounts[swarm.id] ?? 0
        return s
    }

    // MARK: one agent

    /// Reads one agent (`GET /swarms/<id>/agents/<n>`, n from 1) for the sheet; it is read again on every poll until
    /// `closeAgent()`. A failure keeps the agent that was on the sheet if it is the same one.
    public func loadAgent(_ n: Int) async { await loadAgent(n, quiet: false) }

    private func loadAgent(_ n: Int, quiet: Bool) async {
        agentNumber = n
        // no swarm yet: the ask stays in `agentNumber` and `show(id:)` answers it (or fails it)
        guard let id = shown?.id else { return }
        let started = generation
        let token = showToken
        do {
            let fresh = try await ctx.client.swarmAgent(id: id, agent: n)
            guard started == generation, token == showToken, agentNumber == n else { return }
            agent = fresh
            agentProblem = nil
        } catch {
            guard started == generation, token == showToken, agentNumber == n else { return }
            if agent?.agent != n { agent = nil }
            agentProblem = SwarmError.from(error)
        }
    }

    /// The sheet closed: the agent is not read any more.
    public func closeAgent() {
        agent = nil
        agentNumber = nil
        agentProblem = nil
    }

    // MARK: the changes

    /// Reads every change of the shown swarm (`GET /swarms/<id>/changes`, 200 a page) and counts the clashes. A failure keeps
    /// what was read before.
    public func loadChanges() async {
        guard let id = shown?.id else { return }
        let started = generation
        let token = showToken
        var all: [SwarmChange] = []
        var total = 0
        var offset = 0
        do {
            for _ in 0..<Self.changesPages {
                let page = try await ctx.client.swarmChanges(id: id, offset: offset, limit: Self.changesPage)
                guard started == generation, token == showToken else { return }
                all.append(contentsOf: page.changes)
                total = page.total
                offset += max(1, page.changes.count)
                if page.changes.isEmpty || all.count >= page.total { break }
            }
        } catch {
            guard started == generation, token == showToken else { return }
            changesProblem = SwarmError.from(error)
            return
        }
        guard started == generation, token == showToken else { return }
        changes = all
        changesTotal = total
        changesFor = id
        changesProblem = nil
        countClashes(id)
    }

    /// The kept changes with a clash, of the swarm whose list was just read.
    private func countClashes(_ id: String) {
        let n = changes.filter { $0.keep && $0.clash != nil && $0.status != .done }.count
        clashCounts[id] = n
        if let i = list.firstIndex(where: { $0.id == id }) { list[i].clashCount = n }
        if shown?.id == id { shown?.clashCount = n }
    }

    // MARK: the results board

    /// Reads the first page of the board with the current `boardQuery`, `boardGroup`, `boardAgent` and `boardSort`
    /// (`GET /swarms/<id>/board`, 100 rows). The board on screen is replaced; a failure keeps it. A read already running is
    /// not doubled.
    public func loadBoard() async {
        guard let id = shown?.id else {
            // no swarm yet: `show(id:)` answers this once it has read the swarm (or fails it)
            boardWanted = true
            return
        }
        boardWanted = true
        // a read already running is not doubled, but the filter may have changed since it began: it is read again when it ends
        if boardLoading { boardStale = true; return }
        boardLoading = true
        defer { boardLoading = false }
        repeat {
            boardStale = false
            let started = generation
            let token = showToken
            do {
                let page = try await ctx.client.swarmBoard(
                    id: id, query: boardQuery.isEmpty ? nil : boardQuery, agent: boardAgent, status: nil, group: boardGroup,
                    sort: boardSort, offset: 0, limit: Self.boardPage)
                guard started == generation, token == showToken else { return }
                board = page
                boardProblem = nil
                if shown?.id == id {
                    var fresh = page.swarm
                    fresh.clashCount = shown?.clashCount ?? 0
                    shown = fresh
                }
            } catch {
                guard started == generation, token == showToken else { return }
                boardProblem = SwarmError.from(error)
            }
        } while boardStale
    }

    /// Reads the next 100 rows and appends them. Nothing when the board is not loaded or has no more.
    public func loadMoreBoard() async {
        guard let id = shown?.id, let current = board, current.swarm.id == id, current.hasMore, !boardLoading else { return }
        boardLoading = true
        defer { boardLoading = false }
        let started = generation
        let token = showToken
        let filter = (boardQuery, boardGroup, boardSort, boardAgent)
        do {
            let page = try await ctx.client.swarmBoard(
                id: id, query: filter.0.isEmpty ? nil : filter.0, agent: filter.3, status: nil, group: filter.1, sort: filter.2,
                offset: current.offset + current.rows.count, limit: Self.boardPage)
            guard started == generation, token == showToken, board == current else { return }
            board = current.appending(page)
            boardProblem = nil
        } catch {
            guard started == generation, token == showToken else { return }
            boardProblem = SwarmError.from(error)
        }
    }

    // MARK: answering

    /// Approves the shown plan with the hash the screen was showing. Asks the owner first (`SwarmError.notConfirmed`: nothing
    /// is sent). The refusals that mean "the plan is not what you saw" read the swarm again before they throw.
    public func approve() async throws {
        guard let swarm = shown else { throw SwarmError.notShown }
        guard await ownerCheck.confirm(reason: "approve \(swarm.name), up to \(SwarmWords.money(swarm.capUSD))") else {
            throw SwarmError.notConfirmed
        }
        try await send { try await $0.approveSwarm(id: swarm.id, hash: swarm.specHash) }
    }

    /// Declines the shown plan. No Face ID: saying no is always safe.
    public func decline() async throws {
        guard let swarm = shown else { throw SwarmError.notShown }
        try await send { try await $0.declineSwarm(id: swarm.id) }
    }

    /// Stops the shown swarm (nothing is undone). No Face ID.
    public func stop() async throws {
        guard let swarm = shown else { throw SwarmError.notShown }
        try await send { try await $0.stopSwarm(id: swarm.id) }
    }

    /// Runs the failed or skipped agents again; the swarm waits for a new approval. No Face ID (approving it is the gate).
    public func retry() async throws {
        guard let swarm = shown else { throw SwarmError.notShown }
        try await send { try await $0.retrySwarm(id: swarm.id) }
    }

    /// What "apply n" says and sends: the kept changes not done yet, without the clashes (the number the server counts for
    /// `skip_clashes`). Read from the change list once it is in, else from what the server counted (`Swarm.applyCount`). Both
    /// swarm screens show this one number.
    public var applyCount: Int {
        guard let swarm = shown else { return 0 }
        guard changesFor == swarm.id, !changes.isEmpty, changes.count >= changesTotal else { return swarm.applyCount }
        return changes.filter { $0.keep && $0.clash == nil && $0.status != .done }.count
    }

    /// Applies the kept changes (the clashes left out when `skipClashes`). Asks the owner first (`SwarmError.notConfirmed`:
    /// nothing is sent). With `skipClashes` it sends `applyCount`, the number the button showed: if the server would apply
    /// another number it answers `SwarmError.countMismatch`, and the swarm and its changes are read again so the button shows
    /// the new number. The poll goes to 3 s as it starts applying.
    public func apply(skipClashes: Bool) async throws {
        guard let swarm = shown else { throw SwarmError.notShown }
        let shownCount = applyCount
        let count = skipClashes ? shownCount : swarm.apply.total
        guard await ownerCheck.confirm(reason: "apply \(count) changes to \(swarm.name)") else { throw SwarmError.notConfirmed }
        try await send { try await $0.applySwarm(id: swarm.id, hash: swarm.specHash, skipClashes: skipClashes, count: skipClashes ? shownCount : nil) }
        if changesFor == swarm.id { await loadChanges() }
    }

    private func send(_ call: (any CobaltClient) async throws -> Swarm) async throws {
        let started = generation
        do {
            let answer = try await call(ctx.client)
            guard started == generation else { return }
            adopt(answer)
        } catch {
            let mapped = SwarmError.from(error)
            switch mapped {
            case .hashMismatch, .notAwaiting, .expired, .notFound, .notReady:
                // the plan is not what the screen showed: read it again so the screen says what is true now
                if let id = shown?.id { await refreshShown(id, token: showToken) }
            case .countMismatch:
                // the list moved on (an edit elsewhere, a clash found): read the swarm and every change again so "apply n" is true
                if let id = shown?.id {
                    await refreshShown(id, token: showToken)
                    await loadChanges()
                }
            default: break
            }
            throw mapped
        }
    }

    // MARK: the check screen

    /// Ticks or unticks one change (a draft: nothing is written until `apply`). It shows at once; a refusal puts it back.
    public func setKeep(_ n: Int, _ keep: Bool) async throws {
        try await decide(SwarmDecision(n: n, keep: keep))
    }

    /// Gives one change a new name (`after`, written into its `edit_arg`).
    public func rename(_ n: Int, to name: String) async throws {
        try await decide(SwarmDecision(n: n, after: name))
    }

    private func decide(_ decision: SwarmDecision) async throws {
        guard let swarm = shown else { throw SwarmError.notShown }
        let started = generation
        let before = changes
        if let i = changes.firstIndex(where: { $0.n == decision.n }) {
            if let keep = decision.keep { changes[i].keep = keep }
            if let after = decision.after { changes[i].after = after }
        }
        do {
            let answer = try await ctx.client.decideSwarm(id: swarm.id, changes: [decision])
            guard started == generation else { return }
            for fresh in answer.changes {
                if let i = changes.firstIndex(where: { $0.n == fresh.n }) { changes[i] = fresh }
            }
            adopt(answer.swarm)
            // the server refreshed the clashes of the whole group the change belongs to: read the list for the partners
            await loadChanges()
        } catch {
            if started == generation, shown?.id == swarm.id { changes = before }
            throw SwarmError.from(error)
        }
    }

    // MARK: talking to the agents

    /// Sends one agent (from 1) or every agent a message; it shows as `sender: you`. Empty text is refused. The sheet's agent
    /// and the swarm are read again.
    @discardableResult
    public func send(to recipient: SwarmRecipient, text: String) async throws -> SwarmSent {
        guard let swarm = shown else { throw SwarmError.notShown }
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, clean.count <= 2000 else { throw SwarmError.badRequest }
        let started = generation
        do {
            let answer = try await ctx.client.sendSwarm(id: swarm.id, to: recipient, text: clean)
            guard started == generation else { return answer }
            if let fresh = try? await ctx.client.swarm(id: swarm.id) { adopt(fresh) }
            if let n = agentNumber { await loadAgent(n, quiet: true) }
            return answer
        } catch {
            throw SwarmError.from(error)
        }
    }

    // MARK: server change

    /// Another server or key: nothing from the old one is kept.
    func reset() {
        generation += 1
        hide()
        list = []
        state = .idle
        clashCounts = [:]
    }
}

extension Duration {
    /// The duration in seconds, for the pipeline's clock.
    var seconds: Double { Double(components.seconds) + Double(components.attoseconds) / 1e18 }
}

/// A place inside swarms a link can open (CONTRACT-SWARMS 2).
public enum SwarmRoute: Hashable, Sendable {
    case swarm(String)
    case review(String)
    case board(String)

    public var swarmID: String {
        switch self { case .swarm(let id), .review(let id), .board(let id): id }
    }

    /// `cobalt-apple://swarm/<id>`, `.../review`, `.../results`; nil for any other link.
    public init?(url: URL) {
        guard url.scheme?.lowercased() == "cobalt-apple", url.host(percentEncoded: false)?.lowercased() == "swarm" else { return nil }
        let parts = url.pathComponents.filter { $0 != "/" }
        guard let id = parts.first, !id.isEmpty, id.allSatisfy({ $0.isLetter || $0.isNumber }) else { return nil }
        switch parts.count > 1 ? parts[1].lowercased() : nil {
        case nil: self = .swarm(id)
        case "review": self = .review(id)
        case "results": self = .board(id)
        default: return nil
        }
    }
}
