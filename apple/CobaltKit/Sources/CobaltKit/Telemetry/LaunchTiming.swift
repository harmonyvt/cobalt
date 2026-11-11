import Foundation
import Synchronization

/// Audit step 0, the app half: how long from launch until the library has something to show, and how
/// long a library load took. Both go through `Telemetry.log`, which does nothing until the app calls
/// `Telemetry.start`. `arm()` is that launch; previews and tests never arm, so they log nothing.
enum LaunchTiming {
    private static let armedAt = Mutex<Date?>(nil)
    private static let notedContent = Mutex(false)

    static func arm(now: Date = Date()) {
        armedAt.withLock { if $0 == nil { $0 = now } }
    }

    /// Once per launch, the first time the library has a post (from the cache or from the network).
    static func noteFirstContent(source: String, now: Date = Date()) {
        guard let start = armedAt.withLock({ $0 }) else { return }
        let first = notedContent.withLock { flag -> Bool in
            if flag { return false }
            flag = true
            return true
        }
        guard first else { return }
        Telemetry.log(.info, .app, "launch to first content", data: [
            "ms": .int(millis(from: start, to: now)), "source": .string(source),
        ])
    }

    /// One library load, however it was filled. No-op until `arm` (the real app).
    static func noteLibraryLoad(ms: Int, posts: Int, source: String) {
        guard armedAt.withLock({ $0 != nil }) else { return }
        Telemetry.log(.info, .ui, "library load", data: [
            "ms": .int(ms), "posts": .int(posts), "source": .string(source),
        ])
    }

    static func millis(from start: Date, to end: Date = Date()) -> Int {
        max(0, Int((end.timeIntervalSince(start) * 1000).rounded()))
    }
}
