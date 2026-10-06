import Foundation

// "Wait until saved" and the stop button on it (CONTRACT-PARALLEL.md 15.3 step 6, 15.6); with a gallery's make behind the
// save (CONTRACT-GALLERY 1.13, `Galleries`: save + slideshow webp / gallery image) it waits for the make too.

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
    /// With a make behind the save (`outcome.makeWhat`) each save counts twice (saved, then made): the make is sent by
    /// the save's own job once the save is over, so this waits for that job, and a gallery that was saved but could not
    /// be made is kept as a save with its `makeFailures` entry. Gallery saves are filled in with their item and made links.
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
        let units: Int64 = outcome.asksMake ? 2 : 1
        var done = Int64(outcome.saves.filter { $0.state == .saved }.count) * units
        let total = (Int64(targets.count) + done / units) * units
        var sessionsEnded = 0
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
                        sessionsEnded += 1
                        progress?(done, total)
                        if sessionsEnded == targets.count { group.cancelAll() }          // the watcher has nothing left to watch
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

        // The make behind the save (a slideshow webp, a gallery image): sent by the save's own job when the save is over.
        var makeEnds: [Int: MakeEnd] = [:]
        if outcome.asksMake {
            let saved = targets.map(\.0).filter { if case .saved? = ended[$0] { return true } else { return false } }
            // a save that ended in an error has no make coming: its second unit is given now
            done += Int64(targets.count - saved.count)
            progress?(min(done, total), total)
            do {
                makeEnds = try await waitForMakes(outcome, indices: saved, cancel: cancel) { _ in
                    done += 1
                    progress?(min(done, total), total)
                }
            } catch {
                logRun(action: "wait", inputs: outcome.total, accepted: outcome.saves.count, failed: 0, began: began, outcome: "cancelled", waited: true)
                throw error
            }
        }

        var failedIndexes: [Int] = []
        for (index, state) in ended {
            switch state {
            case .saved(let session):
                result.saves[index].state = .saved
                if let duration = session.duration { result.saves[index].duration = duration }
                if result.saves[index].service == nil, let service = session.service, service != "upload" { result.saves[index].service = service }
                // a ready session says what the post is (a gallery's `item_count`); the library, read below, says the rest
                let known = ShortcutSave(session: session)
                result.saves[index].kind = known.kind ?? result.saves[index].kind
                result.saves[index].itemCount = known.itemCount ?? result.saves[index].itemCount
                if known.kind == .gallery { result.saves[index].hasVideo = known.hasVideo }
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
        var endsByID: [String: MakeEnd] = [:]
        for (index, end) in makeEnds where index < result.saves.count { endsByID[result.saves[index].id] = end }
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
        if let what = outcome.makeWhat {
            for index in result.saves.indices {
                guard let end = endsByID[result.saves[index].id] else { continue }
                // the library lists a made file the moment the server has it; the make's own answer covers a list that lags
                if let url = end.url, !result.saves[index].madeLinks.contains(url) { result.saves[index].madeLinks.insert(url, at: 0) }
                if let failure = end.failure {
                    result.makeFailures.append(ShortcutMakeFailure(title: result.saves[index].title, what: what, failure: failure))
                }
            }
        }
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

    /// A finished save's public link and webps are in `GET /library` (the post `id` is the save's `id`; a gallery's items
    /// and made files come with `v=3`). One page of 20 per call, up to three; a save the library does not list (yet)
    /// keeps what it has.
    func fillFromLibrary(_ saves: inout [ShortcutSave]) async {
        var wanted = Set(saves.filter { $0.state == .saved }.map(\.id))
        guard !wanted.isEmpty, ctx.capabilities.library else { return }
        var found: [String: ShortcutSave] = [:]
        var cursor: String?
        for _ in 0..<3 {
            guard let page = try? await ctx.libraryPage(cursor: cursor, limit: 20) else { break }
            for post in page.posts {
                // a post is the save's `id`, or holds the session the save is
                guard let key = [post.id, post.session?.id].compactMap({ $0 }).first(where: { wanted.contains($0) }) else { continue }
                found[key] = ShortcutSave(post: post)
                wanted.remove(key)
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
            saves[index].kind = post.kind
            saves[index].itemCount = post.itemCount
            saves[index].itemLinks = post.itemLinks
            saves[index].madeLinks = post.madeLinks
            saves[index].itemsFailed = post.itemsFailed
            if saves[index].link == nil { saves[index].link = post.link }
            if saves[index].service == nil { saves[index].service = post.service }
        }
    }

    // MARK: - The make behind a gallery save

    /// How the make behind one save ended.
    struct MakeEnd: Sendable {
        /// The made file's public link (nil when the save is private, or nothing was made).
        var url: URL?
        /// Why the make could not be made (the save stands). nil: made, or nothing was asked of this post.
        var failure: PipelineFailure?
    }

    /// Waits for each save's job to be over (the save kept, and the make, if the post turned out to be a gallery, made or
    /// failed), then reads how the make ended. `tick` is called once per save that is over. Cancelling (the stop button, or
    /// the task) stops what is still in flight the way the tray's x does and throws `CancellationError`: a make that is
    /// queued is cancelled, one that already runs finishes on the server and one Hark message announces it (15.6).
    func waitForMakes(
        _ outcome: ShortcutSaveOutcome, indices: [Int], cancel: ShortcutCancel, tick: (Int) -> Void
    ) async throws -> [Int: MakeEnd] {
        var ends: [Int: MakeEnd] = [:]
        var pending = indices.filter { $0 < outcome.jobIDs.count }
        try await withTaskCancellationHandler {
            while !pending.isEmpty {
                if cancel.isCancelled || Task.isCancelled {
                    await stopJobs(pending.map { outcome.jobIDs[$0] })
                    throw CancellationError()
                }
                for index in pending {
                    // a job that left the queue (cleared, or never kept) has nothing more to wait for
                    guard let job = queue.job(outcome.jobIDs[index]) else { ends[index] = MakeEnd(); tick(index); continue }
                    if job.isLive { continue }
                    ends[index] = Self.makeEnd(of: job)
                    tick(index)
                }
                pending.removeAll { ends[$0] != nil }
                if !pending.isEmpty { try? await ctx.clock.sleep(seconds: Self.makePoll) }
            }
        } onCancel: {
            cancel.cancel()
        }
        return ends
    }

    /// How often the wait looks at the jobs behind the saves.
    static let makePoll: Double = 0.25

    static func makeEnd(of job: Job) -> MakeEnd {
        // a post that is not a gallery (one video, one photo link) has nothing made: the save was all that was asked
        guard case .gallery = job.pipeline.state, let run = job.pipeline.galleryRun else { return MakeEnd() }
        if case .failed(let failure) = run.phase { return MakeEnd(failure: failure) }
        switch run.make {
        case .done(_, let result): return MakeEnd(url: result.url)
        case .failed(_, let failure): return MakeEnd(failure: failure)
        case .none, .waiting, .sending, .queued, .making: return MakeEnd()
        }
    }
}
