import Foundation
import Testing
@testable import CobaltKit

// Phase 3 lane (d), apple 03-PHASE3 3.4.1: the six rows of the activity pill's priority table, as a pure function of the one
// count, the network, the library sync and the container wake. The words are the app's (`Copy.Activity`); these tests pin which
// state wins and which segment of the sheet a tap opens.

private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

private func job(_ id: String, _ stage: JobStatus.Stage, fraction: Double? = nil) -> JobStatus {
    JobStatus(id: id, ref: .pipeline(UUID()), kind: .save, stage: stage, fraction: fraction, startedAt: t0, updatedAt: t0)
}

private let fetching = JobStatus.Stage.fetching(engine: nil, fallbackFrom: nil)
private let failed = JobStatus.Stage.failed(failure: .unreachable, retryable: true)

private func sync(_ state: SyncHealthState, pending: Int = 0) -> SyncStatusSnapshot {
    SyncStatusSnapshot(state: state, pendingCount: pending, cursorSeq: 4821, lastSyncedAt: t0)
}

private func resolve(
    _ items: [JobStatus] = [], offline: Bool = false, sync: SyncStatusSnapshot? = nil, waking: Bool = false
) -> ActivityPillState {
    ActivityPillState.resolve(summary: ActivitySummary(items: items), offline: offline, sync: sync, waking: waking)
}

struct ActivityPillRowTests {
    @Test func row6IdleAndHealthy() {
        #expect(resolve() == .idle)
        #expect(resolve(sync: sync(.idle)) == .idle)
        #expect(resolve(sync: sync(.disabled)) == .idle, "an engine that is off says nothing")
        #expect(!ActivityPillState.idle.isLoud)
        #expect(ActivityPillState.idle.priority == 6)
    }

    @Test func row5ContainerWaking() {
        #expect(resolve(waking: true) == .waking)
        #expect(ActivityPillState.waking.priority == 5)
        #expect(ActivityPillState.waking.segment == .system)
    }

    @Test func row4LibrarySyncing() {
        #expect(resolve(sync: sync(.syncing)) == .syncing(pending: 0))
        #expect(resolve(sync: sync(.syncing, pending: 3)) == .syncing(pending: 3))
        #expect(resolve(sync: sync(.repulling)) == .syncing(pending: 0))
        #expect(ActivityPillState.syncing(pending: 0).priority == 4)
        #expect(ActivityPillState.syncing(pending: 0).segment == .system)
    }

    @Test func row3WorkInMotionCountsTheFocusedJobAndEveryOtherOne() {
        let one = resolve([job("job:a", fetching, fraction: 0.42)])
        #expect(one == .active(count: 1, fraction: 0.42), "a lone job carries its own percent")
        let two = resolve([job("job:a", fetching, fraction: 0.42), job("job:b", .queued(ahead: 0))])
        #expect(two == .active(count: 2, fraction: nil), "two jobs: the count, no percent")
        #expect(resolve([job("job:a", fetching)]) == .active(count: 1, fraction: nil), "a job that cannot say has no percent")
        #expect(ActivityPillState.active(count: 1, fraction: nil).priority == 3)
        #expect(ActivityPillState.active(count: 1, fraction: nil).segment == .activity)
    }

    @Test func row2OfflineKeepsTheEditsWaitingOnTheDevice() {
        #expect(resolve(offline: true) == .offline(pending: 0))
        #expect(resolve(offline: true, sync: sync(.offline(pending: 2), pending: 2)) == .offline(pending: 2))
        // the sync engine learns first: nothing reaches the server even though the app has not flagged it
        #expect(resolve(sync: sync(.offline(pending: 1), pending: 1)) == .offline(pending: 1))
        #expect(ActivityPillState.offline(pending: 0).priority == 2)
        #expect(ActivityPillState.offline(pending: 0).segment == .system)
    }

    @Test func row1AttentionIsAFailedJobOrASyncProblem() {
        #expect(resolve([job("job:a", failed)]) == .attention(retries: 1, sync: false))
        let device = JobStatus.Stage.completed(cloudSaved: true, deviceCopy: .failed(code: "error.app.disk_full"))
        #expect(resolve([job("job:a", device)]) == .attention(retries: 1, sync: false), "Cloud ok, Device failed counts")
        #expect(resolve(sync: sync(.error(code: "503", pending: 0, nextRetryAt: t0))) == .attention(retries: 0, sync: true))
        #expect(resolve(sync: sync(.error(code: nil, pending: 2, nextRetryAt: nil))) == .attention(retries: 0, sync: true))
        #expect(ActivityPillState.attention(retries: 1, sync: false).priority == 1)
    }
}

struct ActivityPillPriorityTests {
    @Test func attentionBeatsEverythingElse() {
        let state = resolve(
            [job("job:a", failed), job("job:b", fetching)], offline: true, sync: sync(.syncing, pending: 2), waking: true)
        #expect(state == .attention(retries: 1, sync: false))
    }

    @Test func aSyncErrorBeatsOfflineAndWork() {
        let state = resolve([job("job:b", fetching)], offline: true, sync: sync(.error(code: "503", pending: 1, nextRetryAt: nil), pending: 1))
        #expect(state == .attention(retries: 0, sync: true))
    }

    @Test func offlineBeatsWorkSyncingAndWaking() {
        #expect(resolve([job("job:b", fetching)], offline: true, waking: true) == .offline(pending: 0))
        #expect(resolve(offline: true, sync: sync(.syncing, pending: 1), waking: true) == .offline(pending: 1))
    }

    @Test func workBeatsSyncingAndWaking() {
        #expect(resolve([job("job:b", fetching)], sync: sync(.syncing, pending: 1), waking: true) == .active(count: 1, fraction: nil))
    }

    @Test func syncingBeatsWaking() {
        #expect(resolve(sync: sync(.syncing), waking: true) == .syncing(pending: 0))
    }

    @Test func priorityIsTheTableOrder() {
        let states: [ActivityPillState] = [
            .attention(retries: 1, sync: false), .offline(pending: 0), .active(count: 1, fraction: nil),
            .syncing(pending: 0), .waking, .idle,
        ]
        #expect(states.map(\.priority) == [1, 2, 3, 4, 5, 6])
    }

    @Test func aFailureTapOpensTheFailuresAndASyncProblemOpensTheHealth() {
        #expect(ActivityPillState.attention(retries: 2, sync: false).segment == .activity)
        #expect(ActivityPillState.attention(retries: 2, sync: true).segment == .activity, "a failed job is the news first")
        #expect(ActivityPillState.attention(retries: 0, sync: true).segment == .system)
    }
}

struct ActivityPillCountTests {
    @Test func theCountsAreTheSummarysAndNothingElse() {
        // the pill reads the one count: the same ActivitySummary the island and the sheet read
        let summary = ActivitySummary(items: [
            job("job:a", fetching, fraction: 0.5), job("job:b", .downloading(bytes: 1, total: 2)),
            job("job:c", failed),
        ])
        let inputs = ActivityPillState.Inputs(summary: summary, offline: false, sync: nil, waking: false)
        #expect(inputs.activeCount == summary.activeCount && inputs.attentionCount == summary.attentionCount)
        #expect(inputs.soleFraction == nil, "two are active: no single percent")
    }

    @Test func theSoleFractionIsTheActiveJobsNotAFailedOnes() {
        let summary = ActivitySummary(items: [job("job:a", failed, fraction: 0.9), job("job:b", fetching, fraction: 0.25)])
        #expect(ActivityPillState.Inputs(summary: summary, offline: false, sync: nil, waking: false).soleFraction == 0.25)
    }

    @Test func negativeCountsAreNeverNegative() {
        #expect(ActivityPillState.Inputs(activeCount: -3, attentionCount: -1).activeCount == 0)
        #expect(ActivityPillState.resolve(.init(activeCount: -3, attentionCount: -1)) == .idle)
    }
}
