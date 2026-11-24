import Foundation

/// What carries on without the screen. **Nothing is hidden:** `Pipeline.detach()` does not hand a run to a hidden pipeline: a run
/// the owner closes with work in flight (a render, a host-original publish, the keep-original download) stays a `Job` of the
/// queue, released and unfocused, and `activity.items` lists it until it settles (`JobQueue.letGo`). So this holds only what the
/// queue reports (`queueRuns`, `queueJobIDs`) plus the app's foreground state and background grace.
///
/// A run that is still going when the app is killed leaves its `SharedJob` record behind: the relaunch pickup
/// (`AppModel.pickUpSharedJobs`) resumes a render from it. Owned by the `PipelineContext` (so by the app, never by a view).
@MainActor
final class BackgroundRuns {
    /// The pipelines of the queue's jobs the owner is not looking at (set by the `JobQueue`; released ones included): they
    /// finish while the app runs, and continued processing and the "relates to this media" checks see them.
    var queueRuns: () -> [Pipeline] = { [] }
    /// Every `SharedJob` id the queue's pipelines keep current (focused ones too): a foreground pickup must not take
    /// them over while this process still runs them.
    var queueJobIDs: () -> Set<UUID> = { [] }

    /// Every run carried on without the screen: the queue's unfocused jobs (released ones included).
    var runs: [Pipeline] { queueRuns() }

    /// Whether the app is the active app (a finished webp is announced only when it is not).
    var activity: any AppActivity = AlwaysActive()
    /// Held while the queue has work nobody is looking at, so the system gives the process the few seconds it allows
    /// after the app leaves the screen.
    var grace: any BackgroundGrace = NoGrace()

    /// False in the share extension: `detach()` is then a plain `reset()` (the extension has no queue to keep a run in).
    var allowsDetach = true

    /// The `SharedJob` ids the queue's jobs keep current: the foreground pickup must not take them into the visible pipeline
    /// while this process is still running them.
    var jobIDs: Set<UUID> { queueJobIDs() }

    func owns(job id: UUID) -> Bool { jobIDs.contains(id) }

    /// The queue has work going on that nobody is looking at (a live job the owner has not focused): the system keeps
    /// the process for the few seconds it allows after the app leaves.
    func queueBusyChanged(_ busy: Bool) {
        queueBusy = busy
        refreshGrace()
    }
    private var queueBusy = false
    private var holdsGrace = false

    private func refreshGrace() {
        let wanted = queueBusy
        guard wanted != holdsGrace else { return }
        holdsGrace = wanted
        if wanted { grace.begin() } else { grace.end() }
    }
}

@MainActor
final class NoGrace: BackgroundGrace {
    func begin() {}
    func end() {}
}
