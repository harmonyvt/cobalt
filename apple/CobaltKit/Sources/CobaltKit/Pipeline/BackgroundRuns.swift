import Foundation

/// The runs the owner closed with `Pipeline.detach()` while server work was still in flight (a
/// render, a host-original publish, the keep-original download). Each is carried on by a hidden
/// `Pipeline` of its own, so the work finishes exactly the way an attached run's would: a finished
/// webp joins the store, a finished publish is recorded on the entry, the `SharedJob` and the Live
/// Activity end normally. Owned by the `PipelineContext` (so by the app, never by a view).
///
/// A run that is still going when the app is killed leaves its `SharedJob` record behind: the
/// relaunch pickup (`AppModel.pickUpSharedJobs`) resumes a detached render from it.
@MainActor
final class BackgroundRuns {
    /// Runs closed with `detach()`: hidden pipelines of their own.
    private(set) var detached: [Pipeline] = []
    /// The pipelines of the queue's jobs the owner is not looking at (set by the `JobQueue`): they finish the way a
    /// detached run does, so continued processing and the "relates to this media" checks see them too.
    var queueRuns: () -> [Pipeline] = { [] }
    /// Every `SharedJob` id the queue's pipelines keep current (focused ones too): a foreground pickup must not take
    /// them over while this process still runs them.
    var queueJobIDs: () -> Set<UUID> = { [] }

    /// Every run carried on without the screen: detached ones and the queue's unfocused jobs.
    var runs: [Pipeline] { detached + queueRuns() }

    /// Whether the app is the active app (a finished webp is announced only when it is not).
    var activity: any AppActivity = AlwaysActive()
    /// Held while any run is detached, so the system gives the process the few seconds it allows
    /// after the app leaves the screen.
    var grace: any BackgroundGrace = NoGrace()

    /// False in the share extension: `detach()` is then a plain `reset()`.
    var allowsDetach = true

    /// Detached runs only (the queue's jobs are `queueRuns()`).
    var isEmpty: Bool { detached.isEmpty }
    var count: Int { detached.count }

    /// The `SharedJob` ids detached runs and the queue's jobs keep current: the foreground pickup must not take
    /// them into the visible pipeline while this process is still running them.
    var jobIDs: Set<UUID> { Set(detached.map(\.jobRecordID)).union(queueJobIDs()) }

    func owns(job id: UUID) -> Bool { jobIDs.contains(id) }

    func add(_ run: Pipeline) {
        detached.append(run)
        refreshGrace()
    }

    /// The queue has work going on that nobody is looking at (a live job the owner has not focused): the system keeps
    /// the process for the few seconds it allows after the app leaves, as it does for a detached run.
    func queueBusyChanged(_ busy: Bool) {
        queueBusy = busy
        refreshGrace()
    }
    private var queueBusy = false
    private var holdsGrace = false

    private func refreshGrace() {
        let wanted = !detached.isEmpty || queueBusy
        guard wanted != holdsGrace else { return }
        holdsGrace = wanted
        if wanted { grace.begin() } else { grace.end() }
    }

    /// A detached run settled (every piece of its work finished or was cancelled).
    func finished(_ run: Pipeline, announceWebp: Bool) {
        detached.removeAll { $0 === run }
        refreshGrace()
        guard announceWebp, !activity.isActive, let notifier = run.ctx.notifier else { return }
        let id = run.liveRunID
        Task { await notifier.post(.webpReady, jobID: id) }
    }

    /// The server changed (or the app is shutting a run down): the work belonged to the old server.
    func cancelAll() {
        for run in detached { run.cancelDetached() }
    }
}

@MainActor
final class NoGrace: BackgroundGrace {
    func begin() {}
    func end() {}
}
