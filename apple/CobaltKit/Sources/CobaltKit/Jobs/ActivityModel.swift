import Foundation
import Observation

// `AppModel.activity` (apple 03-PHASE3 3.2): the live `ActivitySummary`, derived from the stores that own the work.
//
// **How it is built, and why**: the model owns nothing. It asks a list of `ActivitySource`s, one per owner of work, what
// they hold, and `ActivitySummary.build` merges and dedupes. Each source is its own file in `Jobs/ActivitySources/`, so the
// Phase 3 lanes that replace an owner (the pipeline store, the downloads engine, the server activity store) replace *one
// source file* and leave this one alone. The public surface below does not change when they do.

/// One owner of work, as the activity list sees it. Sources are read on the main actor, from observable state, so a view
/// that reads `ActivityModel.summary` redraws when any source's inputs move.
@MainActor
public protocol ActivitySource: AnyObject {
    /// The rank of this source when two sources hold the same `sessionID` / `serverJobID`: a lower tier wins
    /// (`ActivitySummary.build`).
    var tier: ActivityTier { get }
    /// What the source holds right now. Ids follow `JobStatus.id`'s forms; `ref` says who owns each.
    func statuses(now: Date) -> [JobStatus]
    /// Does `action` on `status` when the source owns it (by `status.ref`) and returns true; returns false for a status that
    /// is not its own. The model has already checked that the status offers the action (`canFocus`, `canCancel`, ...).
    func perform(_ action: ActivityModel.Action, on status: JobStatus) async -> Bool
}

/// The order of precedence between sources (`ActivitySummary.build`).
public enum ActivityTier: Int, Sendable, CaseIterable {
    /// This device's own jobs: focused, minimized, or still carried by a hidden run.
    case pipeline
    /// Downloads onto this device and the photos album.
    case download
    /// The server's line and the editor's renders.
    case server
    /// Jobs that finished and left the queue.
    case recent
}

/// What `AppModel.activity` is. Nothing here runs work of its own and it keeps no state of its own: it reads.
///
/// **Today's inputs** (Phase 3 wave 1): the queue's jobs (the focused one included, and the ones minimized alongside) and the
/// runs `Pipeline.detach()` still carries in hidden pipelines (`PipelineActivitySource`), `OfflineDownloads` and the photos
/// album (`DownloadActivitySource`), `UnifiedQueue`'s last server answer (the line and the editor's renders) while it is fresh
/// (`ServerActivitySource`), and the jobs that left the queue (`RecentActivitySource`).
@MainActor @Observable
public final class ActivityModel {
    /// What a status can be asked to do (`perform`). Each goes to the source that owns the work.
    public enum Action: Sendable, Equatable {
        /// Opens the job in the focus screen (a pipeline job only; the app opens everything else itself).
        case focus
        /// A job: cancel (or stop following). A download: stop it. A waiting server entry of this key's: the line's cancel.
        case cancel
        /// A failed job: again. A finished one whose device copy failed: the copy again. A failed download: queued again.
        case retry
        /// Takes a failed or finished status off the list.
        case dismiss
    }

    @ObservationIgnored let sources: [any ActivitySource]
    @ObservationIgnored let pipelines: PipelineActivitySource
    @ObservationIgnored let clock: any PipelineClock

    /// `pipelines` is also one of `sources` (the model asks it to minimize a job).
    init(clock: any PipelineClock, pipelines: PipelineActivitySource, sources: [any ActivitySource]) {
        self.clock = clock
        self.pipelines = pipelines
        self.sources = sources
    }

    /// The sources of today's stores (`AppModel.init`).
    convenience init(context: PipelineContext, queue: JobQueue, offline: OfflineDownloads, unified: UnifiedQueue, photos: PhotosSync) {
        let pipelines = PipelineActivitySource(context: context, queue: queue)
        self.init(
            clock: context.clock, pipelines: pipelines,
            sources: [
                pipelines,
                DownloadActivitySource(offline: offline, photos: photos),
                ServerActivitySource(context: context, unified: unified),
                RecentActivitySource(context: context, queue: queue, unified: unified),
            ])
    }

    // MARK: Reading

    /// Everything, deduplicated, with its counts. Reads the sources' observable state, so a view that reads this redraws when
    /// any of it moves.
    public var summary: ActivitySummary {
        let now = clock.now()
        func held(_ tier: ActivityTier) -> [JobStatus] {
            sources.filter { $0.tier == tier }.flatMap { $0.statuses(now: now) }
        }
        return .build(pipelines: held(.pipeline), downloads: held(.download), server: held(.server), recent: held(.recent))
    }

    public var activeCount: Int { summary.activeCount }
    public var attentionCount: Int { summary.attentionCount }
    public var items: [JobStatus] { summary.items }
    public func status(_ id: JobStatus.ID) -> JobStatus? { summary.item(id) }

    // MARK: Minimize

    /// Closes the focus on a job without ending it: the job moves from the focus to "alongside" and stays in `items` (counted in
    /// `activeCount`, with its live stepper, re-focusable with one tap, cancellable). **Never detaches** the pipeline into a
    /// hidden background run: the spec's `minimize(pipelineID)` (`03-PHASE3` 3.1). `jobID` is the job's `Job.ID`, which is the
    /// run id of its pipeline. Returns whether the job is still listed afterwards (false for an unknown or idle job).
    @discardableResult
    public func minimize(_ jobID: Job.ID) -> Bool {
        guard pipelines.minimize(jobID) else { return false }
        return summary.items.contains { $0.ref == .pipeline(jobID) }
    }

    /// `minimize(_:)` for the pipeline the focus screen holds.
    @discardableResult
    public func minimize(_ pipeline: Pipeline) -> Bool {
        guard let id = pipelines.jobID(of: pipeline) else { return false }
        return minimize(id)
    }

    // MARK: Actions

    /// Routes an action on a listed status to the source that owns the work (and through it to the store), exactly as
    /// `UnifiedQueue.perform` does for its rows. An action the status does not offer (`canCancel`, `canRetry`, `canDismiss`,
    /// `canFocus` false) does nothing.
    public func perform(_ action: Action, on id: JobStatus.ID) async {
        guard let status = status(id) else { return }
        switch action {
        case .focus: guard status.canFocus else { return }
        case .cancel: guard status.canCancel else { return }
        case .retry: guard status.canRetry else { return }
        case .dismiss: guard status.canDismiss else { return }
        }
        for source in sources where await source.perform(action, on: status) { return }
    }
}
