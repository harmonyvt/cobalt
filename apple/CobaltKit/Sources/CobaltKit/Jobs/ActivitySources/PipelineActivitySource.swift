import Foundation

/// This device's own jobs: `JobQueue.jobs` (the focused one, the ones alongside, and the ones the owner let go of whose work is
/// still going: a render, a publish, the copy onto the device, `JobQueue.letGo`). Nothing is carried in a hidden run, so everything
/// this device is doing for a pipeline is in `queue.jobs` and lists here.
///
/// The three members below are the whole contract `ActivityModel` relies on.
@MainActor
final class PipelineActivitySource: ActivitySource {
    let tier = ActivityTier.pipeline
    private let ctx: PipelineContext
    private let queue: JobQueue

    init(context: PipelineContext, queue: JobQueue) {
        self.ctx = context
        self.queue = queue
    }

    func statuses(now: Date) -> [JobStatus] {
        let focused = queue.focusedID
        return queue.jobs.compactMap { JobStatus(job: $0, isFocused: $0.id == focused, now: now) }
    }

    func perform(_ action: ActivityModel.Action, on status: JobStatus) async -> Bool {
        guard case .pipeline(let jobID) = status.ref else { return false }
        switch action {
        case .focus: queue.focus(jobID)
        case .cancel: await queue.cancel(jobID)
        case .retry:
            if case .completed(_, .failed) = status.stage {
                queue.job(jobID)?.pipeline.retryLocalCopy()
            } else {
                queue.retry(jobID)
            }
        case .dismiss:
            // a multi-item post nobody picked is "cancelled" (it goes, nothing was saved); the rest are let go
            if let job = queue.job(jobID), job.isPicker { await queue.cancel(jobID) } else { queue.dismiss(jobID) }
        }
        return true
    }

    /// The focus closes and the job stays (`ActivityModel.minimize`). False for a job the queue does not hold.
    func minimize(_ jobID: Job.ID) -> Bool {
        guard queue.job(jobID) != nil else { return false }
        if queue.focusedID == jobID { queue.unfocus() }
        return true
    }

    func jobID(of pipeline: Pipeline) -> Job.ID? {
        queue.jobs.first { $0.pipeline === pipeline }?.id
    }
}
