import Foundation

// "Make webp" (CONTRACT-PARALLEL.md 15.4): a render of a save, waited for, returning the webp's public link. A render
// is not a job in the queue (renders exist only for the focused job, 5.3): this talks to the server directly, sends
// `queue: true` without `priority` (nobody is looking at a Shortcut), never `notify`, and waits for its own result.

extension ShortcutActions {
    /// The save a webp is made from, resolved.
    struct WebpTarget {
        var session: String?
        /// The original's library item, to reopen a studio session from when the save's own has expired.
        var item: String?
        var duration: Double?
    }

    /// The window the render takes: `start` clamped into the clip, `length` (default the server's maximum) clamped to
    /// `min…max_webp_seconds` and to what is left of the clip. Rounded to milliseconds, like the app's own renders.
    static func webpWindow(start: Double, length: Double?, duration: Double?, limits: Capabilities.Limits) -> (start: Double, length: Double) {
        func round3(_ x: Double) -> Double { (x * 1000).rounded() / 1000 }
        let minLength = limits.minWebpSeconds, maxLength = limits.maxWebpSeconds
        var s = max(0, start)
        if let d = duration, d > 0 { s = min(s, max(0, d - minLength)) }
        var l = min(max(length ?? maxLength, minLength), maxLength)
        if let d = duration, d > 0 { l = min(l, max(0.001, d - s)) }
        return (round3(s), round3(l))
    }

    /// The width asked for: the size parameter, else Settings; always one the server renders.
    func webpWidth(_ size: ShortcutWebpSize) -> Int {
        let wanted = size == .appDefault ? ctx.settings.webpWidth : size.rawValue
        let widths = ctx.capabilities.limits.webpWidths
        if widths.isEmpty || widths.contains(wanted) { return wanted }
        return widths.min { abs($0 - wanted) < abs($1 - wanted) } ?? wanted
    }

    /// "Make webp". `saveID` nil = the latest save with a video. Returns the webp's public link. A stop (the token or the
    /// task's cancellation) cancels a render that is still queued (`DELETE …/render/<job>`: "cancelled. nothing was
    /// saved."); one that already started finishes on the server and one Hark message announces it (15.6).
    public func makeWebp(
        of saveID: String?, start: Double = 0, length: Double? = nil, size: ShortcutWebpSize = .appDefault,
        cancel: ShortcutCancel = ShortcutCancel(), progress: ShortcutProgress? = nil
    ) async throws -> URL {
        let began = ctx.clock.now()
        do {
            return try await withTaskCancellationHandler {
                try await render(saveID, start: start, length: length, size: size, cancel: cancel, progress: progress, began: began)
            } onCancel: {
                cancel.cancel()
            }
        } catch {
            let outcome = error is CancellationError ? "cancelled" : "failed"
            logRun(action: "webp", inputs: 1, accepted: 0, failed: outcome == "failed" ? 1 : 0, began: began, outcome: outcome, waited: true)
            throw error
        }
    }

    private func render(
        _ saveID: String?, start: Double, length: Double?, size: ShortcutWebpSize, cancel: ShortcutCancel,
        progress: ShortcutProgress?, began: Date
    ) async throws -> URL {
        let readiness = try await prepare()
        let caps = ctx.capabilities
        guard caps.studio else { throw ShortcutError.failed(.unsupported) }
        let client = ctx.client
        let limits = caps.limits
        func units(_ done: Int64) { progress?(done, 100) }
        units(0)

        // The save and its session: its own while it lives, else the original opened again (queued when busy).
        let target = try await webpTarget(for: saveID)
        var session = target.session
        var duration = target.duration
        if session == nil {
            guard let item = target.item else { throw ShortcutError.saveNotFound }
            let created: StudioCreated
            do { created = try await client.openStudio(item: item, queue: caps.line) }
            catch { throw Self.shortcutError(error, during: .saving, caps: caps) }
            session = created.id
            let result = await Self.waitSaved(client: client, clock: ctx.clock, session: created.id, cancel: cancel, limits: limits)
            switch result {
            case .saved(let s): duration = duration ?? s.duration
            case .failed(let f): throw ShortcutError.from(f, lineMax: readiness.lineMax)
            case .cancelled:
                // Nothing was rendered: a queued reopen is cancelled, one already reading just ends.
                await Task { _ = try? await client.cancelQueued(session: created.id) }.value
                throw CancellationError()
            }
        }
        guard let sid = session else { throw ShortcutError.saveNotFound }
        units(5)
        try Task.checkCancellation()
        if cancel.isCancelled { throw CancellationError() }

        let window = Self.webpWindow(start: start, length: length, duration: duration, limits: limits)
        let request = RenderRequest(
            start: window.start, length: window.length, width: webpWidth(size), quality: ctx.settings.webpQuality,
            notify: false, crop: nil, queue: caps.line ? true : nil, priority: nil)
        let job: String
        do { job = try await client.render(session: sid, request) }
        catch { throw Self.shortcutError(error, during: .rendering, caps: caps) }

        // Waiting: the queued place, then frames, then the pack, as progress.
        var transient = 0
        while true {
            if cancel.isCancelled || Task.isCancelled {
                await stopRender(session: sid, job: job)
                throw CancellationError()
            }
            let status: RenderStatus
            do {
                status = try await client.renderStatus(session: sid, job: job, wait: 1)
                transient = 0
            } catch {
                if error is CancellationError { await stopRender(session: sid, job: job); throw CancellationError() }
                if let e = error as? CobaltError, Self.isTransientRead(e), transient < 5 {
                    transient += 1
                    try? await ctx.clock.sleep(seconds: 1)
                    continue
                }
                throw Self.shortcutError(error, during: .rendering, caps: caps)
            }
            switch status {
            case .pending(let phase, let done, let total, _):
                switch phase {
                case .decode:
                    if let done, let total, total > 0 { units(5 + Int64(80 * Double(done) / Double(total))) }
                case .pack: units(90)
                default: break                                              // queued, fetching, not said: still 5
                }
            case .success(let r):
                units(100)
                logRun(action: "webp", inputs: 1, accepted: 1, failed: 0, began: began, outcome: "ok", waited: true)
                return r.url
            case .failed(let code):
                throw ShortcutError.from(mapFailure(code: code, during: .rendering, limits: limits), lineMax: readiness.lineMax)
            }
        }
    }

    nonisolated private static func isTransientRead(_ e: CobaltError) -> Bool {
        switch e {
        case .network(let code): return code != .cancelled
        case .invalidResponse(let status), .api(_, let status): return [502, 503, 504].contains(status)
        default: return false
        }
    }

    /// 15.4 "Make webp": still queued → `DELETE …/render/<job>`; started (409) → the render finishes on the server and
    /// one `PUT /studio/line/notify` makes sure the owner hears of it. A separate task: the action's own is cancelled.
    private func stopRender(session: String, job: String) async {
        await Task { @MainActor in
            do {
                switch try await self.ctx.client.cancelQueued(session: session, job: job) {
                case .cancelled: break
                case .started: await self.registerLineNotify(watching: 1)
                }
            } catch {
                // the cancel could not reach the server: the render may still run, so the owner is told when it ends
                await self.registerLineNotify(watching: 1)
            }
        }.value
    }

    // MARK: - Which save

    /// A given save (by post key), else the latest with a video. The session is the post's own while it is ready and
    /// unexpired; else the original's item to open again.
    func webpTarget(for saveID: String?) async throws -> WebpTarget {
        let caps = ctx.capabilities
        let client = ctx.client
        var post: LibraryPost?
        if let saveID {
            post = model.library.posts.first { $0.id == saveID }
            if post == nil, caps.library {
                post = try await libraryPosts(maxPages: 3) { $0.contains { $0.id == saveID } }.first { $0.id == saveID }
            }
            if post == nil {
                // a link save that has no library post (yet): its own session, when it can still be rendered on
                if let s = try? await client.session(saveID, wait: 0), s.status == .ready, s.expiresAt > ctx.clock.now() {
                    return WebpTarget(session: s.id, item: s.itemID, duration: s.duration)
                }
                throw ShortcutError.saveNotFound
            }
        } else {
            guard caps.library else { throw ShortcutError.failed(.unsupported) }
            let posts = try await libraryPosts { Self.matches($0, .videos).count >= 1 }
            post = Self.matches(posts, .videos).first
            if post == nil { throw ShortcutError.noVideo }
        }
        guard let post else { throw ShortcutError.saveNotFound }
        guard ShortcutSave(post: post).hasVideo else { throw ShortcutError.noVideo }
        if let s = post.session, s.status == .ready, s.expiresAt > ctx.clock.now() {
            return WebpTarget(session: s.id, item: nil, duration: post.duration)
        }
        // the original (private copy, else a hosted one), reopened as a studio session
        let original = post.files.first { $0.role == .privateCopy } ?? post.files.first { $0.role != .webp }
        guard let item = original?.id else { throw ShortcutError.saveNotFound }
        return WebpTarget(session: nil, item: item, duration: post.duration)
    }
}
