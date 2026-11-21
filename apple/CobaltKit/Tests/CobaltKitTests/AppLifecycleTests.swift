import Foundation
import Testing
@testable import CobaltKit

/// The one lifecycle listener (apple/ARCHITECTURE.md, "Who owns what"): the pure rules, the call order, purges.
@MainActor
@Suite struct AppLifecycleTests {
    final class Recorder: LifecycleAware, Purgeable {
        let name: String
        let log: Log
        init(_ name: String, _ log: Log) { self.name = name; self.log = log }
        func lifecycle(_ event: LifecycleEvent, snapshot: LifecycleSnapshot) { log.lines.append("\(name):\(event)") }
        func purge(_ level: PurgeLevel) { log.lines.append("\(name):purge \(level)") }
    }
    final class Log { var lines: [String] = [] }

    @Test func rulesFollowAResumeAndALeave() {
        var s = LifecycleSnapshot()
        #expect(s.phase == .launching)
        s = LifecycleRules.apply(.becameActive, to: s).snapshot
        #expect(s.phase == .active && s.isActive && s.isForeground)
        s = LifecycleRules.apply(.willResignActive, to: s).snapshot
        #expect(s.phase == .inactive && s.isForeground && !s.isActive)
        let leave = LifecycleRules.apply(.didEnterBackground, to: s)
        #expect(leave.snapshot.phase == .background && leave.purge == .background && leave.deliver)
        s = LifecycleRules.apply(.willEnterForeground, to: leave.snapshot).snapshot
        #expect(s.phase == .inactive)
    }

    @Test func aRepeatIsNotDeliveredButAMemoryWarningAlwaysIs() {
        let active = LifecycleRules.apply(.becameActive, to: LifecycleSnapshot()).snapshot
        #expect(!LifecycleRules.apply(.becameActive, to: active).deliver)
        let warned = LifecycleRules.apply(.memoryWarning, to: active)
        #expect(warned.deliver && warned.purge == .memoryWarning && warned.snapshot.memoryPressure)
        #expect(LifecycleRules.apply(.memoryWarning, to: warned.snapshot).deliver)
        // becoming active again clears the pressure flag
        let back = LifecycleRules.apply(.becameActive, to: LifecycleRules.apply(.willResignActive, to: warned.snapshot).snapshot)
        #expect(!back.snapshot.memoryPressure)
    }

    @Test func thermalStateThrottles() {
        let hot = LifecycleRules.apply(.thermalChanged(.serious), to: LifecycleSnapshot()).snapshot
        #expect(hot.shouldThrottle)
        #expect(!LifecycleSnapshot().shouldThrottle)
    }

    @Test func subscribersAreCalledInOrderThenCachesPurge() {
        let lifecycle = AppLifecycle()
        let log = Log()
        let media = Recorder("media", log), work = Recorder("work", log), telemetry = Recorder("telemetry", log)
        let cache = Recorder("cache", log)
        lifecycle.register(media, order: .media)
        lifecycle.register(work, order: .work)
        lifecycle.register(telemetry, order: .telemetry)
        lifecycle.register(purgeable: cache)
        lifecycle.feed(.didEnterBackground)
        #expect(log.lines == [
            "telemetry:didEnterBackground", "work:didEnterBackground", "media:didEnterBackground", "cache:purge background",
        ])
        #expect(lifecycle.snapshot.phase == .background)
    }

    @Test func registeringTwiceKeepsOneEntryAndTargetsAreWeak() {
        let lifecycle = AppLifecycle()
        let log = Log()
        let a = Recorder("a", log)
        lifecycle.register(a, order: .work)
        lifecycle.register(a, order: .work)
        #expect(lifecycle.subscriberCount == 1)
        do {
            let b = Recorder("b", log)
            lifecycle.register(b, order: .media)
            #expect(lifecycle.subscriberCount == 2)
        }
        #expect(lifecycle.subscriberCount == 1)
        lifecycle.feed(.becameActive)
        #expect(log.lines == ["a:becameActive"])
    }

    @Test func aResumeIsDeliveredOnceNotTwice() {
        // 8.27 audit: the Live Activity resume ran twice, from a Will observer and a Did observer. One listener, one
        // subscriber: willEnterForeground then becameActive are two different events, each delivered once.
        let lifecycle = AppLifecycle()
        let log = Log()
        let live = Recorder("live", log)
        lifecycle.register(live, order: .liveActivities)
        lifecycle.feed(.didEnterBackground)
        lifecycle.feed(.willEnterForeground)
        lifecycle.feed(.becameActive)
        lifecycle.feed(.becameActive)
        #expect(log.lines == ["live:didEnterBackground", "live:willEnterForeground", "live:becameActive"])
    }

    @Test func snapshotsStreamStartsWithTheCurrentValue() async {
        let lifecycle = AppLifecycle()
        lifecycle.feed(.becameActive)
        var iterator = lifecycle.snapshots().makeAsyncIterator()
        let first = await iterator.next()
        #expect(first?.phase == .active)
        lifecycle.feed(.didEnterBackground)
        let second = await iterator.next()
        #expect(second?.phase == .background)
    }
}
