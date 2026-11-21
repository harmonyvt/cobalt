import Foundation
import Testing
@testable import CobaltKit

// Lane B of the lifecycle fix: the objects that used to watch the app notifications themselves (or were driven by
// AppShell's scenePhase) now hear `AppLifecycle`. Each test feeds a fresh `AppLifecycle()`, never `.shared`.

/// Leaving the screen and coming back, as the platform's listener hears it.
@MainActor private enum Trip {
    #if os(macOS)
    static let leave: [LifecycleEvent] = [.willResignActive, .hidden]
    static let back: [LifecycleEvent] = [.unhidden, .becameActive]
    #else
    static let leave: [LifecycleEvent] = [.willResignActive, .didEnterBackground]
    static let back: [LifecycleEvent] = [.willEnterForeground, .becameActive]
    #endif

    static func feed(_ events: [LifecycleEvent], to lifecycle: AppLifecycle) {
        for e in events { lifecycle.feed(e) }
    }
}

// MARK: - Live Activities: one foreground per resume

@MainActor
@Suite(.serialized)
struct LiveLifecycleMigrationTests {
    @Test func theManagerRegistersOnlyWhenAskedTo() {
        let quiet = AppLifecycle()
        let tests = LiveRig(push: false)
        tests.manager.start(observeLifecycle: false, lifecycle: quiet)
        #expect(quiet.subscriberCount == 0)
        let life = AppLifecycle()
        let rig = LiveRig(push: false)
        rig.manager.start(observeLifecycle: true, lifecycle: life)
        #expect(life.subscriberCount == 1)
    }

    @Test func comingBackIsNotTheManagersOwnEvent() async {
        let life = AppLifecycle()
        let rig = LiveRig(push: false)
        rig.manager.start(observeLifecycle: true, lifecycle: life)
        await rig.settle()
        Trip.feed([.becameActive] + Trip.leave + Trip.back, to: life)
        await rig.settle()
        #expect(rig.manager.foregrounds == 0, "only AppModel.pickUpSharedJobs calls foreground()")
    }

    @Test func theBackgroundStartsTheGraceForWorkInFlight() async {
        let life = AppLifecycle()
        let rig = LiveRig(push: false)
        rig.manager.start(observeLifecycle: true, lifecycle: life)
        rig.pipeline.start(link: URL(string: shortLink)!)
        await rig.h.drive { if case .saving = rig.pipeline.state { true } else { false } }
        #expect(rig.grace.begins == 0)
        life.feed(.becameActive)
        life.feed(.willResignActive)
        #expect(rig.grace.begins == 0, "resigning is not leaving")
        life.feed(.didEnterBackground)
        #expect(rig.grace.active && rig.grace.begins == 1)
    }

    @Test func launchAndEachResumeRunForegroundExactlyOnce() async {
        let life = AppLifecycle()
        let rig = LiveRig(push: false)
        rig.manager.start(observeLifecycle: true, lifecycle: life)
        rig.h.app.observeLifecycle(life)

        // launch: the window's task runs the first foreground, then "did become active" arrives
        let launch = Task { await rig.h.app.foreground() }
        await rig.drive { rig.manager.foregrounds >= 1 }
        await launch.value
        life.feed(.becameActive)
        await rig.settle()
        await rig.drive { rig.manager.foregrounds >= 2 }
        #expect(rig.manager.foregrounds == 1, "the activation right after launch shares the launch's run")

        // one resume: one run
        Trip.feed(Trip.leave + Trip.back, to: life)
        await rig.drive { rig.manager.foregrounds >= 2 }
        await rig.settle()
        await rig.drive { rig.manager.foregrounds >= 3 }
        #expect(rig.manager.foregrounds == 2)
    }

    @Test func anActivationBeforeTheLaunchTaskRunsTheFirstForegroundAndTheTaskSharesIt() async {
        let life = AppLifecycle()
        let rig = LiveRig(push: false)
        rig.manager.start(observeLifecycle: true, lifecycle: life)
        rig.h.app.observeLifecycle(life)
        life.feed(.becameActive)
        let launch = Task { await rig.h.app.foreground() }
        await rig.drive { rig.manager.foregrounds >= 1 }
        await launch.value
        await rig.settle()
        await rig.drive { rig.manager.foregrounds >= 2 }
        #expect(rig.manager.foregrounds == 1)
    }
}

// MARK: - Continued processing: resign and become active

@MainActor
struct ContinuedLifecycleMigrationTests {
    @Test func resignAndActiveReachTheControllerAndOneLeaveIsOnePut() async throws {
        let life = AppLifecycle()
        let rig = CQRig(.server, notifyBridge: true)
        rig.controller.observeLifecycle(life)
        rig.queue.observeLifecycle(life)
        let jobs = rig.queue.add([.link(linkA), .link(linkB)], via: .review)
        await rig.line.drive(until: { rig.hasSessions(jobs) })
        await rig.line.settle()
        life.feed(.becameActive)
        await rig.settleNotify()
        let deletes = rig.line.calls.filter { $0 == "DELETE line/notify" }.count

        rig.activity.isActive = false
        life.feed(.willResignActive)                       // ContinuedProcessing.appResigned
        await rig.settleNotify()
        #if os(macOS)
        life.feed(.hidden)                                 // JobQueue.appLeft (the Mac's "background")
        #else
        life.feed(.didEnterBackground)                     // JobQueue.appLeft
        #endif
        await rig.settleNotify()
        #expect(rig.line.calls.filter { $0 == "PUT line/notify" }.count == 1, "\(rig.line.calls)")

        rig.activity.isActive = true
        #if os(macOS)
        life.feed(.unhidden)
        #else
        life.feed(.willEnterForeground)
        #endif
        life.feed(.becameActive)                           // ContinuedProcessing.appBecameActive
        await rig.settleNotify()
        #expect(rig.line.calls.filter { $0 == "DELETE line/notify" }.count == deletes + 1, "\(rig.line.calls)")
    }
}

// MARK: - The queue tab's polling

@MainActor
struct UnifiedQueueLifecycleMigrationTests {
    @Test func leavingStopsThePollAndComingBackStartsIt() async {
        let life = AppLifecycle()
        let rig = QueueRig(.quiet)
        rig.unified.observeLifecycle(life)
        life.feed(.becameActive)
        rig.unified.setVisible(true)
        await rig.settle()
        #expect(rig.count("GET queue") == 1, "the first poll is at once")
        await rig.run(for: 61)
        let before = rig.count("GET queue")

        Trip.feed(Trip.leave, to: life)
        #expect(!rig.unified.isForeground && !rig.unified.shouldPoll)
        await rig.run(for: 120)
        #expect(rig.count("GET queue") == before, "never while the app is away")

        Trip.feed(Trip.back, to: life)
        #expect(rig.unified.isForeground)
        await rig.settle()
        #expect(rig.count("GET queue") == before + 1)
        rig.unified.setVisible(false)
    }

    @Test func resigningAloneStopsThePollOnIOSButNotOnTheMac() {
        let life = AppLifecycle()
        let rig = QueueRig(.quiet)
        rig.unified.observeLifecycle(life)
        life.feed(.becameActive)
        life.feed(.willResignActive)
        #if os(macOS)
        #expect(rig.unified.isForeground, "Cmd-Tab: the Mac keeps polling, as scenePhase did")
        #else
        #expect(!rig.unified.isForeground, "Control Center: not active")
        #endif
    }
}

// MARK: - The app's "is it active" answer

@MainActor
struct AppActivityLifecycleMigrationTests {
    @Test func systemAppActivityReadsTheListener() {
        let life = AppLifecycle()
        let activity = SystemAppActivity(lifecycle: life)
        #expect(!activity.isActive, "a listener that never started (an extension, a test) reads inactive")
        life.feed(.becameActive)
        #expect(activity.isActive)
        life.feed(.willResignActive)
        #expect(!activity.isActive)
        life.feed(.becameActive)
        #expect(activity.isActive)
    }
}
