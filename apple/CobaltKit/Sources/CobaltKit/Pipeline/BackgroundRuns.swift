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
    private(set) var runs: [Pipeline] = []

    /// Whether the app is the active app (a finished webp is announced only when it is not).
    var activity: any AppActivity = AlwaysActive()
    /// Held while any run is detached, so the system gives the process the few seconds it allows
    /// after the app leaves the screen.
    var grace: any BackgroundGrace = NoGrace()

    /// False in the share extension: `detach()` is then a plain `reset()`.
    var allowsDetach = true

    var isEmpty: Bool { runs.isEmpty }
    var count: Int { runs.count }

    /// The `SharedJob` ids detached runs keep current: the foreground pickup must not take them
    /// into the visible pipeline while this process is still running them.
    var jobIDs: Set<UUID> { Set(runs.map(\.jobRecordID)) }

    func owns(job id: UUID) -> Bool { runs.contains { $0.jobRecordID == id } }

    func add(_ run: Pipeline) {
        runs.append(run)
        grace.begin()
    }

    /// A detached run settled (every piece of its work finished or was cancelled).
    func finished(_ run: Pipeline, announceWebp: Bool) {
        runs.removeAll { $0 === run }
        if runs.isEmpty { grace.end() }
        guard announceWebp, !activity.isActive, let notifier = run.ctx.notifier else { return }
        let id = run.liveRunID
        Task { await notifier.post(.webpReady, jobID: id) }
    }

    /// The server changed (or the app is shutting a run down): the work belonged to the old server.
    func cancelAll() {
        for run in runs { run.cancelDetached() }
    }
}

@MainActor
final class NoGrace: BackgroundGrace {
    func begin() {}
    func end() {}
}
