import Foundation
import Observation

// The quick card's logic (CONTRACT-SHARE-QUICK.md section 3).
//
// The card shows from the first frame. It hands the run to the server at the first moment the server
// holds the save (`canContinueInBackground`, on a server that finishes a save unpolled): the card
// shows its check for `quickHold` seconds, then `continueInBackground()` registers the Hark
// notification, leaves the `SharedJob` for the app, hands the original to the background download
// and completes the request. A save that finished before the hand-off (a cached link) takes the
// saved path instead. A failure keeps the card with the reason. Anything the card cannot finish by
// itself becomes the full sheet.

extension ShareCore {
    /// How long the card shows "cobalt has it" before it closes.
    static let quickHold: Double = 0.6

    /// The link the card names, as the chip does (`instagram · Dd7P496wolG`).
    var quickTitle: String? {
        guard case .link(let info) = pipeline.input else { return nil }
        return "\(info.service) · \(info.ref)"
    }

    /// The card becomes the full sheet (asked, or the run needs it). Nothing that is running stops.
    func expandQuick(_ why: QuickExpand) {
        guard quick.showsCard else { return }
        quickTask?.cancel()
        quickTask = nil
        quick = .expanded(why)
        Telemetry.log(.info, .share, "share quick expanded", data: ["why": .string(why == .asked ? "asked" : "needs-sheet"), "state": .string(pipeline.state.telemetryName)])
    }

    /// The failed card's "try again": the same link, still the card.
    func retryQuick() {
        guard case .failed = quick, case .link(let info) = pipeline.input, !closed else { return }
        quick = .working
        pipeline.start(link: info.url)
        observeQuick()
    }

    /// The failed card's "open cobalt": the app opens (when the system lets the extension open it) and
    /// the sheet goes. Nothing carries on: a failed run has nothing on the server.
    func openCobalt() async {
        defer { complete?() }
        noteClosing()
        quickTask?.cancel()
        quickTask = nil
        pipeline.cancel()
        pipeline.removeTemporaryFiles()
        await relay.finish()
        let opened = await openApp?(URL(string: Notifications.openURL)!) ?? false
        Telemetry.log(.info, .share, "share quick open cobalt", data: ["opened": .bool(opened)])
    }

    /// Previews show a fixed state; the real card logic goes quiet.
    func previewQuick(_ state: QuickShare) {
        quickTask?.cancel()
        quickTask = nil
        quickPinned = true
        quick = state
    }

    // MARK: - Deciding

    /// Watches what the card depends on: the pipeline's state, session and input, and the
    /// capabilities. Re-arms itself while the card is working.
    func observeQuick() {
        guard case .working = quick else { return }
        withObservationTracking {
            _ = pipeline.state
            _ = pipeline.sessionID
            _ = pipeline.input
            _ = capabilities
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.evaluateQuick()
                self?.observeQuick()
            }
        }
    }

    func evaluateQuick() {
        guard case .working = quick, !closed, !quickPinned else { return }
        // The upload is the extension's own work: closing would kill it, so a file gets the sheet.
        if case .file = pipeline.input { expandQuick(.needsSheet); return }
        switch pipeline.state {
        case .failed(let f):
            quick = .failed(f)
            Telemetry.log(.info, .share, "share quick failed", data: ["after_ms": .int(elapsedMs)])
            return
        case .picker, .image:
            expandQuick(.needsSheet)            // a choice to make: only the sheet has the controls
            return
        default: break
        }
        let caps = capabilities
        switch caps.kind {
        case .unreachable: return               // the card opens before it knows the server
        case .plainCobalt, .notCobalt, .legacyFork: expandQuick(.needsSheet); return
        case .fork:
            // A server that would lose an unpolled save keeps the owner on the sheet.
            if !caps.studio || !caps.finishesUnpolled { expandQuick(.needsSheet); return }
        }
        if canContinueInBackground {
            hold()
            return
        }
        switch pipeline.state {
        case .reading, .ready, .savedLocally, .done:
            if pipeline.sessionID != nil { hold() }   // the save finished before the card could hand it off
        default: break
        }
    }

    private var elapsedMs: Int { Int((ctx.clock.now().timeIntervalSince(openedAt) * 1000).rounded()) }

    /// The server holds the save: the check, a moment, then the hand-off.
    private func hold() {
        quick = .holding
        Telemetry.log(.info, .share, "share quick holding", data: ["after_ms": .int(elapsedMs), "state": .string(pipeline.state.telemetryName)])
        let clock = ctx.clock
        let hold = quickHoldSeconds
        quickTask = Task { [weak self] in
            do { try await clock.sleep(seconds: hold) } catch { return }
            guard !Task.isCancelled else { return }
            await self?.handOffQuick()
        }
    }

    /// The overlay finished its island morph: hand off now instead of waiting out `quickHoldSeconds`
    /// (which stays as the upper bound, should the view never call this).
    func finishHoldNow() async {
        guard case .holding = quick, !closed, quickTask != nil else { return }
        quickTask?.cancel()
        quickTask = nil
        await handOffQuick()
    }

    private func handOffQuick() async {
        guard case .holding = quick, !closed else { return }
        quickTask?.cancel()
        quickTask = nil
        if case .failed(let f) = pipeline.state {
            quick = .failed(f)                  // it failed during the moment the check showed
            return
        }
        Telemetry.log(.info, .share, "share quick hand off", data: ["after_ms": .int(elapsedMs), "state": .string(pipeline.state.telemetryName), "bridge": .bool(capabilities.notifyBridge)])
        if canContinueInBackground {
            _ = await continueInBackground()
        } else {
            await handOffSaved()
        }
    }

    /// The save finished while the card was up (a link the server had cached): the run is left for the
    /// app as a save to follow (its poll answers at once), the original goes to the background
    /// download, and the owner is told by this process (the server's "saved" moment has passed).
    private func handOffSaved() async {
        guard let sid = pipeline.sessionID else { _ = await dismissQuietly(); return }
        defer { complete?() }
        noteClosing()
        ctx.jobs.upsert(makeJob(stage: .saving, wantsTrim: false))
        relay.detach()
        handOffOriginal()
        pipeline.cancel()
        pipeline.removeTemporaryFiles()
        await notifier.requestAuthorization()
        await notifier.post(.saved, jobID: jobID, session: sid)
    }

    private func dismissQuietly() async -> Outcome { await close() }
}
