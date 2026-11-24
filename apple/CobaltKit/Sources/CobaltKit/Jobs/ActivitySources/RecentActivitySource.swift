import Foundation

/// Jobs that finished and left the queue (`ServerActivityStore.finishedHistory`, kept 30 minutes): the sheet's "recent", with the
/// copy on this device as it stood when the job left (`FinishedWork.deviceCopy`: Cloud saved, Device saved or failed).
@MainActor
final class RecentActivitySource: ActivitySource {
    let tier = ActivityTier.recent
    private let ctx: PipelineContext
    private let queue: JobQueue
    private let unified: UnifiedQueue

    init(context: PipelineContext, queue: JobQueue, unified: UnifiedQueue) {
        self.ctx = context
        self.queue = queue
        self.unified = unified
    }

    func statuses(now: Date) -> [JobStatus] {
        let present = Set(queue.jobs.map(\.id))
        return unified.activityStore.finishedHistory
            .filter { !present.contains($0.id) && now.timeIntervalSince($0.finishedAt) < UnifiedQueue.finishedLinger }
            .map(Self.status(of:))
    }

    /// `JobStatus(finished:)`, with the device-copy receipt the job left with when it is known.
    static func status(of work: FinishedWork) -> JobStatus {
        let base = JobStatus(finished: work)
        guard let receipt = work.deviceCopy else { return base }
        return JobStatus(
            id: base.id, ref: base.ref, kind: base.kind, title: base.title, mediaID: base.mediaID,
            stage: .completed(cloudSaved: true, deviceCopy: receipt), fraction: 1,
            startedAt: base.startedAt, updatedAt: base.updatedAt, canDismiss: true)
    }

    func perform(_ action: ActivityModel.Action, on status: JobStatus) async -> Bool {
        guard case .finished = status.ref else { return false }
        if action == .dismiss, let row = unified.items.first(where: { $0.id == status.id }) { await unified.perform(.dismiss, on: row) }
        return true
    }
}
