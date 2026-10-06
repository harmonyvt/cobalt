import Foundation

// "Wait until saved" and the stop button on it (CONTRACT-PARALLEL.md 15.3 step 6, 15.6).

extension ShortcutActions {
    /// How one session ended while waiting.
    enum SavedResult: Sendable {
        case saved(StudioSession)
        case failed(PipelineFailure)
        case cancelled
    }

    /// Polls each save's session (`?wait=1`, the existing pacer) until it is `ready` or `error`. `progress` is saves
    /// finished of saves asked for (a queued one counts 0, so it only ever grows). Then the library fills in each
    /// finished save's public link (a public original has one) and its webps.
    ///
    /// The stop button, or the task being cancelled, cancels what is still queued on the server (the owner said stop:
    /// nothing is saved) and leaves what already started to finish there, announced by one Hark message (15.6); then
    /// this throws `CancellationError`. Saves that ended in an error are reported in `failures`; when every one did, the
    /// first one's words are thrown.
    public func waitUntilSaved(
        _ outcome: ShortcutSaveOutcome, cancel: ShortcutCancel = ShortcutCancel(), progress: ShortcutProgress? = nil
    ) async throws -> ShortcutSaveOutcome {
        let began = ctx.clock.now()
        var result = outcome
        let targets = outcome.sessions.enumerated().compactMap { index, session in session.map { (index, $0) } }
        // An image upload has no session: it was saved when the server took it, and counts as finished from the start.
        var done = Int64(outcome.saves.filter { $0.state == .saved }.count)
        let total = Int64(targets.count) + done
        progress?(done, total)
        let client = ctx.client
        let clock = ctx.clock
        let limits = ctx.capabilities.limits
        var ended: [Int: SavedResult] = [:]

        if !targets.isEmpty {
            await withTaskCancellationHandler {
                await withTaskGroup(of: (Int, SavedResult).self) { group in
                    for (index, session) in targets {
                        group.addTask { (index, await Self.waitSaved(client: client, clock: clock, session: session, cancel: cancel, limits: limits)) }
                    }
                    // The stop button flips the token; this wakes the long polls at once instead of when they come back.
                    group.addTask {
                        while !cancel.isCancelled, !Task.isCancelled { try? await clock.sleep(seconds: 0.1) }
                        return (-1, .cancelled)
                    }
                    for await (index, state) in group {
                        if index < 0 { group.cancelAll(); continue }
                        ended[index] = state
                        if case .cancelled = state { continue }
                        done += 1
                        progress?(done, total)
                        if done == total { group.cancelAll() }          // the watcher has nothing left to watch
                    }
                }
            } onCancel: {
                cancel.cancel()
            }
        }

        if cancel.isCancelled || Task.isCancelled || ended.values.contains(where: { if case .cancelled = $0 { return true } else { return false } }) {
            let unresolved = targets.map(\.0).filter { index in
                guard let state = ended[index] else { return true }
                if case .cancelled = state { return true }
                return false
            }
            await stopWaiting(outcome, unresolved: unresolved)
            logRun(action: "wait", inputs: outcome.total, accepted: outcome.saves.count, failed: 0, began: began, outcome: "cancelled", waited: true)
            throw CancellationError()
        }

        var failedIndexes: [Int] = []
        for (index, state) in ended {
            switch state {
            case .saved(let session):
                result.saves[index].state = .saved
                if let duration = session.duration { result.saves[index].duration = duration }
                if result.saves[index].service == nil, let service = session.service, service != "upload" { result.saves[index].service = service }
            case .failed(let failure):
                result.saves[index].state = .failed
                failedIndexes.append(index)
                result.failures.append(ShortcutFailure(
                    label: result.saves[index].title, error: .from(failure, lineMax: ctx.capabilities.limits.lineMax), afterHandOver: true))
            case .cancelled:
                break
            }
        }
        // The saves that failed after the hand-over are failures, not results the next action could use.
        for index in failedIndexes.sorted(by: >) {
            result.saves.remove(at: index)
            result.jobIDs.remove(at: index)
            result.sessions.remove(at: index)
        }
        if result.saves.isEmpty, let first = result.failures.first(where: { $0.afterHandOver }) {
            logRun(action: "wait", inputs: outcome.total, accepted: 0, failed: result.failures.count, began: began, outcome: "failed", waited: true)
            throw first.error
        }
        await fillFromLibrary(&result.saves)
        logRun(
            action: "wait", inputs: outcome.total, accepted: result.saves.count, failed: result.failures.count, began: began,
            outcome: result.failures.isEmpty ? "ok" : "partial", waited: true)
        return result
    }

    /// One session until it is ready, errored or cancelled. Transient answers (a 502, a dropped connection) are asked
    /// again a few times, like every other idempotent read.
    nonisolated static func waitSaved(
        client: any CobaltClient, clock: any PipelineClock, session: String, cancel: ShortcutCancel, limits: Capabilities.Limits
    ) async -> SavedResult {
        var pacer = PollPacer()
        var transient = 0
        while true {
            if cancel.isCancelled || Task.isCancelled { return .cancelled }
            do {
                try await pacer.beforePoll(clock: clock)
                if cancel.isCancelled || Task.isCancelled { return .cancelled }
                let s = try await client.session(session, wait: 1)
                transient = 0
                pacer.observe(s, clock: clock)
                switch s.status {
                case .ready: return .saved(s)
                case .error:
                    return .failed(mapFailure(code: s.errorCode ?? "error.studio.unknown", during: .saving, limits: limits))
                case .saving: continue
                }
            } catch {
                if error is CancellationError { return .cancelled }
                if let e = error as? CobaltError, isTransient(e), transient < 5 {
                    transient += 1
                    do { try await clock.sleep(seconds: 1) } catch { return .cancelled }
                    continue
                }
                guard let failure = pipelineFailure(from: error, during: .saving, limits: limits) else { return .cancelled }
                return .failed(failure)
            }
        }
    }

    nonisolated private static func isTransient(_ e: CobaltError) -> Bool {
        switch e {
        case .network(let code): return code != .cancelled
        case .invalidResponse(let status), .api(_, let status): return [502, 503, 504].contains(status)
        default: return false
        }
    }

    /// The stop button (15.6): what is queued is cancelled (nothing is saved), what already runs on the server finishes
    /// there and one Hark message announces it. Runs as a task of its own: this is called with the action's task
    /// already cancelled, and a cancelled task's requests would be cancelled with it.
    func stopWaiting(_ outcome: ShortcutSaveOutcome, unresolved: [Int]) async {
        await stopJobs(unresolved.filter { $0 < outcome.jobIDs.count }.map { outcome.jobIDs[$0] })
    }

    /// Cancels each job the way the tray's x does (3.4): queued → `DELETE …/line`, nothing saved; on the server already →
    /// "stopped following", the server finishes it, and the owner hears of that through one summary.
    func stopJobs(_ ids: [UUID]) async {
        await Task { @MainActor in
            var leftRunning = 0
            for id in ids {
                await self.queue.cancel(id)
                if self.queue.notice?.kind == .stoppedFollowing { leftRunning += 1 }
                self.queue.clearNotice()
            }
            if leftRunning > 0 { await self.registerLineNotify(watching: leftRunning) }
        }.value
    }

    // MARK: - Public links

    /// A finished save's public link and webps are in `GET /library` (the post `id` is the save's `id`). One page of
    /// 20 per call, up to three; a save the library does not list (yet) keeps what it has.
    func fillFromLibrary(_ saves: inout [ShortcutSave]) async {
        var wanted = Set(saves.filter { $0.state == .saved }.map(\.id))
        guard !wanted.isEmpty, ctx.capabilities.library else { return }
        let client = ctx.client
        let v2 = ctx.capabilities.visibility
        var found: [String: ShortcutSave] = [:]
        var cursor: String?
        for _ in 0..<3 {
            guard let page = try? await client.library(cursor: cursor, limit: 20, v2: v2) else { break }
            for post in page.posts where wanted.contains(post.id) {
                found[post.id] = ShortcutSave(post: post)
                wanted.remove(post.id)
            }
            guard !wanted.isEmpty, let next = page.next else { break }
            cursor = next
        }
        for index in saves.indices {
            guard let post = found[saves[index].id] else { continue }
            saves[index].publicLink = post.publicLink
            saves[index].webpLinks = post.webpLinks
            saves[index].duration = post.duration ?? saves[index].duration
            saves[index].hasVideo = post.hasVideo
            if saves[index].link == nil { saves[index].link = post.link }
            if saves[index].service == nil { saves[index].service = post.service }
        }
    }
}
