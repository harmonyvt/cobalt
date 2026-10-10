import Foundation
import Synchronization

/// Keeps a download of a file the owner did not pick (a link at a media file, fetched on this device) to a size limit: the
/// moment the bytes seen, or the length the host announces, pass `limit`, the download task is cancelled and `tripped`
/// says why. A limit of 0 or less means no limit.
final class DownloadGuard: Sendable {
    private struct State {
        var task: Task<URL, any Error>?
        var tripped = false
    }

    private let limit: Int64
    private let state = Mutex(State())

    init(limit: Int64) { self.limit = limit }

    /// The download this guard cancels. A guard that already tripped cancels it at once.
    func attach(_ task: Task<URL, any Error>) {
        let cancelNow = state.withLock { s in
            s.task = task
            return s.tripped
        }
        if cancelNow { task.cancel() }
    }

    /// True once the download went over the limit.
    var tripped: Bool { state.withLock { $0.tripped } }

    func observe(_ progress: TransferProgress) {
        guard limit > 0, max(progress.bytes, progress.total ?? 0) > limit else { return }
        let task = state.withLock { s -> Task<URL, any Error>? in
            s.tripped = true
            return s.task
        }
        task?.cancel()
    }
}
