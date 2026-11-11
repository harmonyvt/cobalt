import Foundation
import Observation

/// Tells the sync glow how far the owner's own saves and uploads have got, so the line fills as they
/// run (`SyncGlowStatus.setActivity`). Follows the job queue itself, like the Mac's Dock badge, so it
/// keeps up with work started from the share sheet, a shortcut or the menu bar too.
@MainActor
final class SyncGlowActivityFeed {
    private weak var queue: JobQueue?
    private weak var status: SyncGlowStatus?

    init(queue: JobQueue, status: SyncGlowStatus) {
        self.queue = queue
        self.status = status
        track()
    }

    /// How far one piece of work is: 0...1, or nil when its length is not known. Only live work counts.
    static func fraction(of state: PipelineState) -> Double?? {
        func ratio(_ done: Int64?, _ total: Int64?) -> Double? {
            guard let done, let total, total > 0 else { return nil }
            return min(max(Double(done) / Double(total), 0), 1)
        }
        switch state {
        case .fetching: return .some(nil)
        case .uploading(let p): return .some(ratio(p.bytes, p.total))
        case .saving(let bytes, let total, _): return .some(ratio(bytes, total))
        case .reading(let developed, let of): return .some(of > 0 ? min(max(Double(developed) / Double(of), 0), 1) : nil)
        case .rendering(.decoding(let done, let total)): return .some(total > 0 ? min(max(Double(done) / Double(total), 0), 1) : nil)
        case .rendering: return .some(nil)
        default: return nil
        }
    }

    /// The glow's activity for these jobs (`SyncGlowActivity.combine`); nil when none is running.
    static func activity(of jobs: [Job]) -> Double? {
        let parts: [Double?] = jobs.filter(\.isLive).compactMap { (job: Job) -> Double?? in
            if case .gallery = job.state { return .some(nil) }
            return fraction(of: job.state)
        }
        return SyncGlowActivity.combine(parts)
    }

    private func track() {
        guard let queue else { return }
        let value = withObservationTracking {
            Self.activity(of: queue.jobs)
        } onChange: { [weak self] in
            // Fires before the new value lands: read again once it has.
            Task { @MainActor in self?.track() }
        }
        status?.setActivity(value)
    }
}
