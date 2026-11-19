import Foundation
import Testing
@testable import CobaltKit

// The editor window's loader (apple/CONTRACT-EDITOR.md 4.2, 4.7): a closed edit dismisses, a blank id fails, a load that
// runs out of time fails, and a finish that lost the race cannot put the opening skeleton back.

struct EditorWindowLoadTests {
    private let start = Date(timeIntervalSinceReferenceDate: 1_000)

    @Test func aClosedEditDismissesInsteadOfSpinning() {
        let now = start
        #expect(EditorWindowLoad.presentation(hasSession: false, phase: .idle, now: now) == .dismiss)
        #expect(EditorWindowLoad.presentation(hasSession: true, phase: .idle, now: now) == .editor)
    }

    @Test func anOpenSessionWinsOverAStaleFailureOrLoad() {
        let opening = EditorOpenPhase.opening("beach", start)
        let failed = EditorOpenPhase.failed("beach", .offline)
        #expect(EditorWindowLoad.presentation(hasSession: true, phase: opening, now: start) == .editor)
        #expect(EditorWindowLoad.presentation(hasSession: true, phase: failed, now: start) == .editor)
        #expect(EditorWindowLoad.presentation(hasSession: false, phase: failed, now: start) == .failed(.offline))
    }

    @Test func openingAProjectShowsTheSkeletonUntilTheTimeout() {
        let phase = EditorOpenPhase.opening("beach", start)
        #expect(EditorWindowLoad.timeout == 20)
        #expect(EditorWindowLoad.presentation(hasSession: false, phase: phase, now: start.addingTimeInterval(19)) == .loading)
        #expect(
            EditorWindowLoad.presentation(hasSession: false, phase: phase, now: start.addingTimeInterval(20))
                == .failed(.other("timed out")))
        #expect(EditorWindowLoad.expiring(phase, now: start.addingTimeInterval(19)) == phase)
        #expect(
            EditorWindowLoad.expiring(phase, now: start.addingTimeInterval(20)) == .failed("beach", .other("timed out")))
    }

    @Test func aBlankIdFailsImmediatelyAndNeverLoads() {
        var load = EditorOpenAttempt()
        let blank = load.begin("   ", now: start)      // a mutating call cannot sit inside #expect
        #expect(blank == .rejected(1))
        #expect(load.phase == .failed("", .other("missing")))
        #expect(EditorWindowLoad.presentation(hasSession: false, phase: load.phase, now: start) == .failed(.other("missing")))
        #expect(EditorWindowLoad.presentation(hasSession: false, phase: .opening("  ", start), now: start) == .failed(.other("missing")))
    }

    @Test func expiringLeavesAFailureAndAnIdlePhaseAlone() {
        let failed = EditorOpenPhase.failed("beach", .unavailable)
        #expect(EditorWindowLoad.expiring(failed, now: start.addingTimeInterval(100)) == failed)
        #expect(EditorWindowLoad.expiring(.idle, now: start.addingTimeInterval(100)) == .idle)
        var load = EditorOpenAttempt()
        load.timeout(now: start.addingTimeInterval(100))
        #expect(load.phase == .idle)
    }

    @Test func resultsMapOntoIdleOrAFailure() {
        #expect(EditorWindowLoad.result(of: .notFound) == .notFound)
        #expect(EditorWindowLoad.result(of: .other("cancelled")) == .cancelled)
        #expect(EditorWindowLoad.result(of: .other("unsaved")) == .cancelled)
        #expect(EditorWindowLoad.result(of: .other("timed out")) == .failed(.other("timed out")))
        #expect(EditorWindowLoad.result(of: .offline) == .failed(.offline))
        #expect(EditorWindowLoad.phase(after: .opened, projectID: "beach") == .idle)
        #expect(EditorWindowLoad.phase(after: .notFound, projectID: "beach") == .idle)
        #expect(EditorWindowLoad.phase(after: .cancelled, projectID: "beach") == .idle)
        #expect(EditorWindowLoad.phase(after: .failed(.offline), projectID: "beach") == .failed("beach", .offline))
    }

    @Test func aStaleFinishCannotReplaceTheOpenOnScreen() {
        var load = EditorOpenAttempt()
        guard case .started(let first, _) = load.begin("beach", now: start) else {
            Issue.record("the first open should start")
            return
        }
        guard case .started(let second, let id) = load.begin("cats", now: start) else {
            Issue.record("the second open should start")
            return
        }
        #expect(id == "cats" && second == 2)
        let staleFirst = load.finish(first, projectID: "beach", result: .failed(.offline))
        #expect(staleFirst == false)
        #expect(load.phase == .opening("cats", start))
        let secondLanded = load.finish(second, projectID: "cats", result: .opened)
        #expect(secondLanded)
        #expect(load.phase == .idle)
    }

    @Test func dismissingMakesTheInFlightOpenStaleAndTheWindowDismisses() {
        var load = EditorOpenAttempt()
        guard case .started(let mine, _) = load.begin("beach", now: start) else {
            Issue.record("the open should start")
            return
        }
        load.dismiss()
        #expect(load.phase == .idle)
        let staleMine = load.finish(mine, projectID: "beach", result: .opened)
        #expect(staleMine == false)
        #expect(load.phase == .idle)
        #expect(EditorWindowLoad.presentation(hasSession: false, phase: load.phase, now: start) == .dismiss)
    }

    @Test func aTimeoutOnTheOpenMovesItToAFailureTheOwnerCanClose() {
        var load = EditorOpenAttempt()
        _ = load.begin("beach", now: start)
        load.timeout(now: start.addingTimeInterval(19))
        #expect(load.phase == .opening("beach", start))
        load.timeout(now: start.addingTimeInterval(20))
        #expect(load.phase == .failed("beach", .other("timed out")))
        #expect(EditorWindowLoad.presentation(hasSession: false, phase: load.phase, now: start.addingTimeInterval(20)) == .failed(.other("timed out")))
    }

    @Test func anAbandonedSessionIsDroppedOnlyWhenNothingNewerIsOpening() {
        let opening = EditorOpenPhase.opening("cats", start)
        #expect(EditorWindowLoad.shouldDropAbandonedSession(
            stillOwns: false, phase: .idle, openedProjectID: "beach", sessionProjectID: "beach"))
        #expect(!EditorWindowLoad.shouldDropAbandonedSession(
            stillOwns: true, phase: .idle, openedProjectID: "beach", sessionProjectID: "beach"))
        #expect(!EditorWindowLoad.shouldDropAbandonedSession(
            stillOwns: false, phase: opening, openedProjectID: "beach", sessionProjectID: "beach"))
        #expect(!EditorWindowLoad.shouldDropAbandonedSession(
            stillOwns: false, phase: .idle, openedProjectID: "beach", sessionProjectID: nil))
        #expect(!EditorWindowLoad.shouldDropAbandonedSession(
            stillOwns: false, phase: .idle, openedProjectID: "beach", sessionProjectID: "cats"))
        #expect(EditorWindowLoad.shouldDropAbandonedSession(
            stillOwns: false, phase: .failed("", .other("missing")), openedProjectID: "beach", sessionProjectID: "beach"))
    }
}
