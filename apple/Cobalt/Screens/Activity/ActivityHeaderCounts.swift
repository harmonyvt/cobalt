import CobaltKit
import Foundation

/// The tray's header counts ("2 running · 1 waiting", "1 finished"), read from the one count (`model.activity.summary`) and not from
/// the cards the tray happens to show. Before, the header counted `queue.alongside` only (not the focused job, not the job the pane
/// shows), so the tray said "1 running" while the toolbar said 2; now every surface says the same number (apple 03-PHASE3 3.2).
///
/// A status is **waiting** when its stage is a place in a line (`Stage.isWaiting`), **running** for any other active one, **failed**
/// when it needs attention, **picking** while a multi-item post waits for the owner and **finished** for this device's own job that
/// is done and still lingering in the tray (the finished ones that already left it are the sheet's "recent", not the tray's news).
struct ActivityHeaderCounts: Equatable {
    var running = 0
    var waiting = 0
    var finished = 0
    var failed = 0
    var picking = 0

    init(_ summary: ActivitySummary) {
        for item in summary.items {
            switch item.bucket {
            case .attention:
                failed += 1
            case .running:
                if item.stage.isWaiting { waiting += 1 } else { running += 1 }
            case .settled:
                guard case .pipeline = item.ref else { continue }
                if case .awaitingChoice = item.stage { picking += 1 } else { finished += 1 }
            }
        }
    }

    var text: String {
        if running + waiting + finished + failed + picking == 0 { return Copy.Queue.allDone }
        return TrayCopy.header(running: running, waiting: waiting, finished: finished, failed: failed, picking: picking)
    }
}
