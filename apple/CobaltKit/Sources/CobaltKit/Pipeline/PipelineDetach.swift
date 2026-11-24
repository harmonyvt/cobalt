import Foundation

// "Close without throwing work away" (`Pipeline.detach()`), as of Phase 3: **nothing is hidden any more.**
//
// Until Phase 2 a close with work in flight (a render, a host-original publish, the keep-original download) handed the
// run to a hidden `Pipeline`, which nothing on screen listed. Now the run stays what it was,
// a `Job` of the queue: the focus closes (`JobQueue.letGo`), the job is marked released (the tray no longer shows it), and
// it stays in `activity.items` (stage `rendering` / `deviceCopy`, counted in `activeCount`, re-focusable, with its Live
// Activity) until its work settles, when the queue lets it go.

extension Pipeline {
    /// Something of the current run is still going on after the owner lets go of it, and `reset()` would lose its result: a
    /// render on the server, a host-original publish, the keep-original download (the device copy), "save to photos".
    var hasWorkInFlight: Bool {
        if case .rendering = state, sessionID != nil { return true }
        if hosting == .working { return true }
        if keepRequest != nil || photos == .working { return true }
        return false
    }

    /// Closes the run on screen without throwing its work away. When the run belongs to a queue job that still has work in
    /// flight, the queue lets it go (`JobQueue.letGo`): it stays listed, unfocused, until the work settles. With nothing in
    /// flight, or outside a queue (the share sheet, whose `allowsDetach` is false, previews), this is `reset()`.
    public func detach() {
        if ctx.background.allowsDetach, hasWorkInFlight, let queue = ctx.jobQueue, queue.letGo(self) { return }
        reset()
    }

    /// "stop" on a run that is reading its frames while the original's copy still lands on the device: the filmstrip is
    /// cosmetic, so the run stops reading and settles as saved (`.ready`); the keep-original download (and anything else the
    /// run has in flight) carries on under the same run token. Nothing happens in any other state.
    func stopReadingFrames() {
        guard case .reading = state else { return }
        mainTask?.cancel()
        mainTask = nil
        framesFailed = frames.allSatisfy { $0 == nil }
        enterReady()
    }
}
