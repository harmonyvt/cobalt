import Foundation
import Synchronization
import Testing
@testable import CobaltKit

// Phase 3 lane (b): `OfflineDownloads` holds every pull onto this device. These tests pin the three things it absorbed: the share
// sheet's pending originals (the extension's ledger, read-only apart from stop and retry), a tracked transfer (the library's
// share copy), and the keys that keep one session one row. The ledger's FORMAT is pinned here too: the extension process writes
// `Sync/originals.json`, so an older build must read what this one writes and the other way round.

private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

// MARK: - The ledger file is unchanged

@MainActor
@Suite(.serialized)
struct PendingOriginalsFormatTests {
    /// What a build before Phase 3 wrote, key for key (the extension of an older app may still write exactly this).
    private let old = #"""
    {"items":[
      {"id":"S1","link":"https://www.instagram.com/p/abc/","media":{"name":"clip","duration":5,"width":720,"height":1280,"bytes":3000,"isImage":false},
       "sourceURL":"https://api.capybaraharmony.com/studio/S1/source","sourceWait":true,"createdAt":725846400,
       "state":{"queued":{}},"backgroundStarts":1,"updatedAt":725846400},
      {"id":"S2","sourceURL":"https://api.capybaraharmony.com/studio/S2/source","sourceWait":false,"createdAt":725846400,
       "state":{"gone":{"code":"error.studio.expired"}},"backgroundStarts":0,"updatedAt":725846400}
    ]}
    """#

    @Test func aLedgerWrittenBeforePhase3DecodesAndKeepsItsStates() throws {
        let file = try JSONDecoder().decode(PendingOriginalsFile.self, from: Data(old.utf8))
        #expect(file.items.map(\.id) == ["S1", "S2"])
        #expect(file.items[0].state == .queued && file.items[0].media?.bytes == 3_000 && file.items[0].backgroundStarts == 1)
        #expect(file.items[1].state == .gone(code: "error.studio.expired"))
    }

    @Test func aLedgerWithKeysThisBuildDoesNotKnowStillDecodes() throws {
        // a later build may add a key (additively): this one must read it, ignoring what it does not know
        let future = old.replacingOccurrences(of: #""backgroundStarts":1,"#, with: #""backgroundStarts":1,"somethingNew":{"a":[1,2]},"#)
        let file = try JSONDecoder().decode(PendingOriginalsFile.self, from: Data(future.utf8))
        #expect(file.items.count == 2 && file.items[0].id == "S1")
    }

    @Test func whatThisBuildWritesHasNoKeyAnOlderReaderLacks() throws {
        // the keys of an entry, as the oldest reader (the struct before Phase 3) lists them
        let known: Set<String> = [
            "id", "link", "media", "sourceURL", "sourceWait", "createdAt", "state", "backgroundStarts", "updatedAt",
        ]
        let dir = try makeTempDirectory()
        let ledger = PendingOriginals(directory: dir)
        ledger.enqueue(
            PendingOriginal(
                id: "S9", link: URL(string: "https://x.test/a"), media: MediaInfo(name: "n", duration: 1, width: 1, height: 1, bytes: 9, isImage: false),
                sourceURL: URL(string: "https://x.test/s")!, sourceWait: true, createdAt: t0, state: .queued, updatedAt: t0),
            now: t0)
        let data = try Data(contentsOf: dir.appendingPathComponent("originals.json"))
        let root = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(Set(root.keys) == ["items"])
        let item = try #require((root["items"] as? [[String: Any]])?.first)
        #expect(Set(item.keys).isSubset(of: known), "no new key: \(Set(item.keys).subtracting(known))")
        // and the old reader's own file round-trips through the new one unchanged in meaning
        let again = try JSONDecoder().decode(PendingOriginalsFile.self, from: data)
        #expect(again.items.first?.id == "S9" && again.items.first?.state == .queued)
    }
}

// MARK: - Pending originals as rows

@MainActor
@Suite(.serialized)
struct PendingOriginalRowTests {
    private func engine(_ rig: FetcherRig) throws -> OfflineDownloads {
        OfflineDownloads(
            store: rig.store, queue: OfflineQueue(directory: try makeTempDirectory()), transport: nil, clock: rig.h.clock,
            client: { rig.h.ctx.client }, pendingOriginals: rig.pending)
    }

    @Test func aHandedOffOriginalIsARowKeyedByItsSession() async throws {
        let rig = try FetcherRig()
        let downloads = try engine(rig)
        #expect(downloads.rows.isEmpty && downloads.unfinishedCount == 0)
        rig.handOff("S1", sourceWait: false, saveReady: false)           // queued: no task yet
        let row = try #require(downloads.rows.first)
        #expect(downloads.rows.count == 1)
        #expect(row.id == "s:S1" && row.origin == .pendingOriginal && row.state == .waiting && row.name == "clip")
        #expect(await eventually { downloads.unfinishedCount == 1 }, "the queue's badge counts it, with no reconcile in between")
        #expect(downloads.summary.left == 1)
        let status = JobStatus(download: row, now: t0)
        #expect(status.id == "download:s:S1" && status.sessionID == "S1" && status.kind == .deviceDownload)
    }

    @Test func aRunningTaskIsDownloadingAndAStoredEntryIsNotARow() async throws {
        let rig = try FetcherRig()
        let downloads = try engine(rig)
        rig.handOff("S1")                                                   // a task started
        guard case .downloading? = downloads.rows.first?.state else { Issue.record("expected downloading"); return }
        let session = try #require(rig.session)
        session.respond(task: 1, status: 200, body: Data(repeating: 9, count: 1_000))
        #expect(await eventually { if case .stored? = rig.pending.entry("S1")?.state { true } else { false } })
        #expect(downloads.rows.isEmpty)
        #expect(await eventually { downloads.unfinishedCount == 0 })
    }

    @Test func failedForGoodAndGoneAreFailedRowsAndAFailureThatWillBeRetriedIsWaiting() async throws {
        let rig = try FetcherRig()
        let downloads = try engine(rig)
        rig.handOff("A", sourceWait: false); rig.handOff("B", sourceWait: false); rig.handOff("C", sourceWait: false)
        let now = rig.h.clock.now()
        rig.pending.update("A", now: now) { $0.state = .failed(code: NSURLErrorNotConnectedToInternet, tries: 1) }
        rig.pending.update("B", now: now) { $0.state = .failed(code: 503, tries: PendingOriginals.maxTries) }
        rig.pending.update("C", now: now) { $0.state = .gone(code: "error.studio.expired") }
        let byKey = Dictionary(uniqueKeysWithValues: downloads.rows.map { ($0.id, $0.state) })
        #expect(byKey["s:A"] == .waiting, "tries are left: the foreground starts it again")
        #expect(byKey["s:B"] == .failed(.other(503)))
        #expect(byKey["s:C"] == .failed(.gone))
        #expect(await eventually { downloads.unfinishedCount == 1 }, "only A is going")
        #expect(OfflineDownloads.failure(ofLedgerCode: 403) == .auth)
        #expect(OfflineDownloads.failure(ofLedgerCode: Int(ENOSPC)) == .full)
        #expect(OfflineDownloads.failure(ofLedgerCode: NSURLErrorTimedOut) == .unreachable)
    }

    @Test func aPipelinesOwnOriginalOfTheSameSessionIsTheOnlyRow() async throws {
        let rig = try FetcherRig()
        let downloads = try engine(rig)
        rig.handOff("S1", sourceWait: false)
        let own = Pipeline.originalJob(session: "S1", media: rig.media, link: nil, mediaID: nil, now: t0)
        downloads.seedPreview([(own, .waiting)])
        let rows = downloads.rows.filter { $0.id == "s:S1" }
        #expect(rows.count == 1, "one session, one row")
        #expect(rows.first?.origin == .save, "the pipeline's own job wins")
        #expect(await eventually { downloads.unfinishedCount == 1 })
    }

    @Test func aChangeToTheLedgerReachesAnObserverOfTheEngine() async throws {
        let rig = try FetcherRig()
        let downloads = try engine(rig)
        let before = downloads.unfinishedCount
        rig.handOff("S1", sourceWait: false)
        #expect(await eventually { downloads.unfinishedCount == before + 1 })
        rig.pending.remove("S1")
        #expect(await eventually { downloads.unfinishedCount == before && downloads.rows.isEmpty })
    }

    @Test func stopCancelsTheTaskAndDropsTheEntryAndRetryStartsAGivenUpOneAgain() async throws {
        let rig = try FetcherRig()
        let downloads = try engine(rig)
        rig.handOff("S1")                                                   // downloading, task 1
        let session = try #require(rig.session)
        #expect(session.liveIDs == [1])
        downloads.stop(key: "s:S1")
        #expect(await eventually { rig.pending.entry("S1") == nil && session.liveIDs.isEmpty })
        #expect(downloads.rows.isEmpty)

        rig.handOff("S2", sourceWait: false)
        rig.pending.update("S2", now: rig.h.clock.now()) { $0.state = .failed(code: 503, tries: PendingOriginals.maxTries) }
        #expect(downloads.rows.first?.isFailed == true)
        downloads.retry(key: "s:S2")
        #expect(await eventually { if case .downloading? = rig.pending.entry("S2")?.state { true } else { false } })
        #expect(session.tasks.contains { $0.label == "S2" })
    }

    @Test func aGoneEntryCanBeDismissedAndIsNotRetried() async throws {
        let rig = try FetcherRig()
        let downloads = try engine(rig)
        rig.handOff("S1", sourceWait: false)
        rig.pending.update("S1", now: rig.h.clock.now()) { $0.state = .gone(code: "error.studio.expired") }
        let row = try #require(downloads.rows.first)
        let shown = DownloadActivitySource.status(of: row, now: t0)
        #expect(shown.canDismiss && !shown.canRetry, "the activity list offers no retry on a session the server ended")
        downloads.retry(key: "s:S1")                                         // nothing to start
        #expect(rig.pending.entry("S1")?.state == .gone(code: "error.studio.expired"))
        downloads.stop(key: "s:S1")
        #expect(await eventually { rig.pending.entry("S1") == nil })
    }

    @Test func withoutALedgerThereAreNoPendingRowsAndAFakeTransportNeverReadsTheRealOne() throws {
        let rig = try DownloadRig()
        #expect(rig.engine.pending == nil, "a test engine does not read the app group's file")
        #expect(rig.engine.rows.isEmpty)
    }
}

// MARK: - A tracked transfer (the share copy)

/// A download the test holds open until it lets it go.
private final class TransferGate: Sendable {
    private let open = Mutex(false)
    func release() { open.withLock { $0 = true } }
    func wait() async throws {
        while !open.withLock({ $0 }) { try await Task.sleep(for: .milliseconds(5)) }
    }
}

@MainActor
@Suite(.serialized)
struct TrackedTransferTests {
    @Test func aTransferIsARowWhileItRunsAndGoneWhenItEnds() async throws {
        let t = try DownloadRig()
        let gate = TransferGate()
        let key = OfflineDownloads.shareKey("post-1")
        let work = Task { @MainActor in
            try await t.engine.transfer(key: key, name: "harbour", expectedBytes: 5_000) { progress in
                progress(TransferProgress(bytes: 1_250, total: 5_000))
                try await gate.wait()
                return URL(fileURLWithPath: "/tmp/harbour.mp4")
            }
        }
        #expect(await t.settled { t.engine.rows.contains { $0.id == key } })
        // the relay hops to the main actor: a loaded parallel run needs more than `settled`'s 3 s
        #expect(await eventually(15) { t.engine.states[key] == .downloading(TransferProgress(bytes: 1_250, total: 5_000)) })
        let row = try #require(t.engine.rows.first { $0.id == key })
        #expect(row.origin == .share && row.name == "harbour" && row.expectedBytes == 5_000)
        #expect(t.engine.unfinishedCount == 1 && t.engine.summary.left == 1)
        #expect(t.queue.all().isEmpty, "never in the queue's ledger: it does not survive a relaunch, and lands nowhere")
        let status = JobStatus(download: row, now: t0)
        #expect(status.id == "download:share:post-1" && status.kind == .deviceDownload && status.canCancel)
        if case .deviceCopy(let bytes, let total) = status.stage { #expect(bytes == 1_250 && total == 5_000) } else { Issue.record("stage") }
        #expect(abs((status.fraction ?? 0) - 0.25) < 0.001)

        gate.release()
        #expect(try await work.value == URL(fileURLWithPath: "/tmp/harbour.mp4"))
        #expect(t.engine.rows.isEmpty && t.engine.states[key] == nil && t.engine.unfinishedCount == 0)
    }

    @Test func aFailedTransferStaysAsAFailedRowUntilItIsDismissedOrRunsAgain() async throws {
        let t = try DownloadRig()
        let key = OfflineDownloads.shareKey("post-2")
        struct Boom: Error {}
        await #expect(throws: CobaltError.self) {
            try await t.engine.transfer(key: key, name: "dock", expectedBytes: nil) { _ in
                throw CobaltError.network(.timedOut)
            } as URL
        }
        #expect(t.engine.states[key] == .failed(.unreachable))
        #expect(t.engine.unfinishedCount == 0, "a failed row is not work in motion")
        let row = try #require(t.engine.rows.first { $0.id == key })
        #expect(row.isFailed)
        // the share card's retry runs it again under the same key: one row, going
        let gate = TransferGate()
        let again = Task { @MainActor in
            try await t.engine.transfer(key: key, name: "dock") { _ in try await gate.wait(); return 1 }
        }
        #expect(await t.settled { t.engine.states[key] == .downloading(TransferProgress(bytes: 0, total: nil)) })
        #expect(t.engine.rows.filter { $0.id == key }.count == 1)
        gate.release()
        _ = try await again.value
        #expect(t.engine.rows.isEmpty)

        // dismissing clears a failed one
        _ = try? await t.engine.transfer(key: key, name: "dock") { _ in throw CobaltError.noAPIKey } as Int
        #expect(t.engine.states[key] == .failed(.auth))
        t.engine.dismissFailedTransfers()
        #expect(t.engine.rows.isEmpty && t.engine.states[key] == nil)
    }

    @Test func stopCancelsTheCopyAndLeavesNoRow() async throws {
        let t = try DownloadRig()
        let gate = TransferGate()
        let key = OfflineDownloads.shareKey("post-3")
        let work = Task { @MainActor () -> Bool in
            do {
                _ = try await t.engine.transfer(key: key, name: "x") { _ in try await gate.wait(); return 1 }
                return false
            } catch { return true }
        }
        #expect(await t.settled { t.engine.rows.contains { $0.id == key } })
        t.engine.stop(key: key)
        #expect(await work.value, "the copy threw")
        #expect(t.engine.rows.isEmpty && t.engine.states[key] == nil, "stopped is not failed")
    }

    @Test func aFailedShareRowOffersDismissButNotARetryTheShareCardOwns() throws {
        let row = OfflineDownloadRow(id: "share:p", name: "p", state: .failed(.unreachable), queuedAt: t0, origin: .share)
        let status = DownloadActivitySource.status(of: row, now: t0)
        #expect(status.canDismiss && !status.canRetry)
        // every other kind keeps what `JobStatus(download:)` says
        let kept = OfflineDownloadRow(id: "f:1", name: "p", state: .failed(.unreachable), queuedAt: t0)
        #expect(DownloadActivitySource.status(of: kept, now: t0).canRetry)
        let pending = OfflineDownloadRow(id: "s:1", name: "p", state: .failed(.unreachable), queuedAt: t0, origin: .pendingOriginal)
        #expect(DownloadActivitySource.status(of: pending, now: t0).canRetry)
    }

    @Test func theKeepOfflineRowsKeepTheirOriginAndAreStillListed() async throws {
        let t = try DownloadRig()
        let v = try await t.evicted()
        t.engine.enqueue([t.existingJob(v)])
        #expect(t.engine.rows.first?.origin == .keepOffline)
        var pulled = t.existingJob(v, key: "f:P", sources: [.libraryItem(id: "P")])
        pulled.origin = OfflineJob.pulledOrigin
        t.engine.enqueue([pulled])
        #expect(Set(t.engine.rows.map(\.origin)) == [.keepOffline, .pulled])
    }
}
