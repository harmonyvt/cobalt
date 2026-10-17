import Foundation
import Testing
@testable import CobaltKit

/// A preview app for the queue tab (`AppModel.makePreviewQueue`) on a virtual clock.
@MainActor
struct QueueRig {
    let clock = VirtualClock()
    let app: AppModel

    init(_ state: QueuePreviewState) {
        app = AppModel.makePreviewQueue(state, timeScale: 1, clock: clock)
        app.ctx.settings.autoContinue = false
    }

    var unified: UnifiedQueue { app.unifiedQueue }
    var client: PreviewClient { app.ctx.client as! PreviewClient }
    var server: PreviewServer { client.server }
    func count(_ call: String) -> Int { server.lineCalls.filter { $0 == call }.count }

    func settle() async {
        var last = clock.registrations
        var stable = 0
        while stable < 4 {
            try? await Task.sleep(for: .milliseconds(1))
            let r = clock.registrations
            if r == last { stable += 1 } else { stable = 0; last = r }
        }
    }

    func run(for seconds: Double) async {
        let target = clock.elapsed + seconds
        await settle()
        while clock.elapsed < target {
            await settle()
            guard clock.advance() else { break }
        }
        await settle()
    }

    func drive(until condition: @MainActor () -> Bool, maxVirtualSeconds: Double = 300) async {
        let start = clock.elapsed
        var idle = 0
        while !condition(), clock.elapsed - start < maxVirtualSeconds {
            await settle()
            if condition() { return }
            if clock.advance() { idle = 0 } else {
                idle += 1
                if idle > 30 { return }
                try? await Task.sleep(for: .milliseconds(5))
            }
        }
    }
}

// MARK: - The wire

struct QueueSnapshotDecodingTests {
    private func decode(_ json: String) throws -> QueueSnapshot {
        try CobaltJSON.decoder().decode(QueueSnapshot.self, from: Data(json.utf8))
    }

    @Test func aFullAnswerDecodes() throws {
        let s = try decode("""
        {"status":"success","now":1800000000000,
         "line":{"now":1800000000000,"running":{"kind":"save","mine":false,"sid":null,"job":null,"origin":"share","key_name":"iphone"},
                 "entries":[{"position":2,"kind":"save","mine":true,"sid":"abc","job":null,"at":1,"origin":null,"priority":"batch","key_name":"mac","link":"https://x.com/i/status/1"}],
                 "max":50,"wait_ms":1800000},
         "search":{"enabled":true,"posts":284,"indexed":32,"pending":252,"failed":0,"running":true,"last_run_at":1799999960000,
                   "rate_per_hour":180,"next":[{"post_key":"p1","title":"x · 1"},{"post_key":"p2","title":null}]},
         "posters":{"pending":3}}
        """)
        #expect(s.now == Date(timeIntervalSince1970: 1_800_000_000))
        #expect(s.line?.running?.origin == "share" && s.line?.running?.keyName == "iphone")
        #expect(s.line?.entries.first?.sid == "abc" && s.line?.entries.first?.position == 2)
        let search = try #require(s.search)
        #expect(search.enabled && search.posts == 284 && search.indexed == 32 && search.pending == 252)
        #expect(search.running == true && search.ratePerHour == 180)
        #expect(search.lastRunAt == Date(timeIntervalSince1970: 1_799_999_960))
        #expect(search.next.map(\.postKey) == ["p1", "p2"] && search.next[1].title == nil)
        #expect(s.posters?.pending == 3)
        #expect(s.isActive)
    }

    @Test func missingOptionalFieldsDecode() throws {
        // search disabled says only that; no posters; the line could not be read (null); unknown keys are ignored
        let s = try decode(#"{"now":1800000000000,"line":null,"search":{"enabled":false},"surprise":{"a":1}}"#)
        #expect(s.line == nil && s.posters == nil)
        let search = try #require(s.search)
        #expect(!search.enabled && search.posts == 0 && search.running == nil && search.lastRunAt == nil)
        #expect(search.ratePerHour == nil && search.next.isEmpty && !search.hasWork)
        #expect(!s.isActive)
        // before migration 0011: running, last_run_at and rate_per_hour are null
        let older = try decode(#"{"search":{"enabled":true,"posts":10,"indexed":4,"pending":6,"failed":0,"running":null,"last_run_at":null,"rate_per_hour":null,"next":[]}}"#)
        #expect(older.now == nil && older.search?.running == nil && older.search?.hasWork == true)
        // an empty object is an empty snapshot
        #expect(try decode("{}") == QueueSnapshot())
    }

    @Test func aMalformedPartIsNilNotAFailure() throws {
        let s = try decode(#"{"line":"busy","search":[1,2],"posters":{"pending":"many"},"now":"soon"}"#)
        #expect(s.line == nil && s.search == nil && s.now == nil && s.posters == nil)
        // one odd row of `next` never hides the others
        let t = try decode(#"{"search":{"enabled":true,"posts":3,"indexed":1,"pending":2,"next":[{"post_key":"a"},{"title":"no key"},7,{"post_key":"b"}]}}"#)
        #expect(t.search?.next.map(\.postKey) == ["a", "b"])
    }

    @Test func theCapabilityIsReadAndAbsentMeansOff() throws {
        func caps(_ features: String) throws -> Capabilities {
            let json = #"{"server":"cobalt-cloudflare","features":\#(features),"key":"valid"}"#
            return try #require(HTTPCobaltClient.parseForkCapabilities(Data(json.utf8)))
        }
        #expect(try caps(#"{"studio":true,"queue":true}"#).queue)
        #expect(try !caps(#"{"studio":true,"queue":false}"#).queue)
        #expect(try !caps(#"{"studio":true}"#).queue)
        #expect(!Capabilities.unknown.queue)
    }
}

// MARK: - Polling

@MainActor
struct UnifiedQueuePollingTests {
    @Test func theCadence() {
        #expect(UnifiedQueue.delay(active: true, failures: 0) == 5)
        #expect(UnifiedQueue.delay(active: false, failures: 0) == 30)
        #expect(UnifiedQueue.delay(active: true, failures: 1) == 10)
        #expect(UnifiedQueue.delay(active: false, failures: 2) == 20)
        #expect(UnifiedQueue.delay(active: false, failures: 5) == 120)
        #expect(UnifiedQueue.delay(active: false, failures: 50) == 120)
    }

    @Test func capabilityOffMeansNoPolling() async {
        let rig = QueueRig(.localOnly)
        #expect(!rig.app.capabilities.queue)
        rig.unified.setVisible(true)
        await rig.run(for: 120)
        #expect(rig.count("GET queue") == 0)
        #expect(rig.unified.snapshot == nil)
        // an explicit refresh does not ask either
        #expect(await rig.unified.refresh() == false)
        #expect(rig.count("GET queue") == 0)
        rig.unified.setVisible(false)
    }

    @Test func pollsOnlyWhileVisibleAndInFront() async {
        let rig = QueueRig(.quiet)
        await rig.run(for: 60)
        #expect(rig.count("GET queue") == 0, "the tab is not on screen")
        rig.unified.setVisible(true)
        await rig.settle()
        #expect(rig.count("GET queue") == 1, "the first poll is at once")
        #expect(rig.unified.snapshot != nil)
        await rig.run(for: 61)
        let quiet = rig.count("GET queue")
        #expect(quiet >= 2 && quiet <= 4, "every 30 s while nothing moves: \(quiet)")
        rig.unified.setForeground(false)
        await rig.run(for: 120)
        #expect(rig.count("GET queue") == quiet, "never in the background")
        rig.unified.setForeground(true)
        await rig.settle()
        #expect(rig.count("GET queue") == quiet + 1)
        rig.unified.setVisible(false)
        let shown = rig.count("GET queue")
        await rig.run(for: 120)
        #expect(rig.count("GET queue") == shown, "never off screen")
    }

    @Test func pollsFasterWhileTheServerIsBusy() async {
        let rig = QueueRig(.busy)
        rig.unified.setVisible(true)
        await rig.settle()
        #expect(rig.unified.snapshot?.isActive == true)
        let first = rig.count("GET queue")
        await rig.run(for: 20)
        let busy = rig.count("GET queue") - first
        #expect(busy >= 3 && busy <= 5, "every 5 s while something moves: \(busy)")
        rig.unified.setVisible(false)
    }

    @Test func errorsBackOffAndAreSaid() async {
        let rig = QueueRig(.quiet)
        rig.server.queueFails = true
        rig.unified.setVisible(true)
        await rig.settle()
        #expect(rig.unified.serverProblem)
        await rig.run(for: 35)
        // 10 s, 20 s, 40 s between tries (the run may wake the next one past 35 s): at most 4, not the 8 of every 5 s
        let tries = rig.count("GET queue")
        #expect(tries >= 3 && tries <= 4, "\(tries)")
        rig.server.queueFails = false
        await rig.run(for: 85)
        #expect(!rig.unified.serverProblem && rig.unified.snapshot != nil)
        rig.unified.setVisible(false)
    }

    @Test func turningTheCapabilityOffStopsAndForgets() async {
        let rig = QueueRig(.quiet)
        rig.unified.setVisible(true)
        await rig.settle()
        #expect(rig.unified.snapshot != nil)
        var caps = rig.app.capabilities
        caps.queue = false
        rig.app.apply(caps)
        #expect(rig.unified.snapshot == nil)
        let before = rig.count("GET queue")
        await rig.run(for: 90)
        #expect(rig.count("GET queue") == before)
        rig.unified.setVisible(false)
    }
}

// MARK: - The merge

@MainActor
struct UnifiedQueueMergeTests {
    @Test func aServerEntryThatIsALocalJobShowsOnce() async {
        let rig = QueueRig(.busy)
        await rig.settle()
        await rig.unified.refresh()
        let jobs = rig.app.queue.jobs
        #expect(jobs.count == 2)
        let sessions = Set(jobs.compactMap(\.pipeline.sessionID))
        #expect(sessions.count == 2, "both links are queued on the server")
        // the server's line does name them (this key's, with their sids)...
        let mine = rig.unified.snapshot?.line?.entries.filter(\.mine) ?? []
        #expect(Set(mine.compactMap(\.sid)) == sessions)
        // ...and the tab shows each once, as the job
        let items = rig.unified.items
        #expect(items.filter { $0.job != nil }.count == 2)
        let serverRows = items.compactMap { item -> ServerWork? in if case .server(let w) = item.kind { return w } else { return nil } }
        #expect(!serverRows.contains { $0.sid.map(sessions.contains) ?? false })
        // the share running ahead of them is the server's own row, under "now"
        let share = items.first { if case .server(let w) = $0.kind { return w.running && w.isShare } else { return false } }
        #expect(share?.section == .now && share?.actions.isEmpty == true)
    }

    @Test func sectionsComeInTheTabsOrder() async {
        let rig = QueueRig(.busy)
        await rig.settle()
        await rig.unified.refresh()
        let items = rig.unified.items
        let sections = items.map(\.section)
        #expect(sections == sections.sorted(), "\(sections)")
        #expect(Set(sections) == [.now, .waiting, .indexing, .downloads, .photos, .finished, .failed])
        #expect(rig.unified.sections.map(\.section) == [.now, .waiting, .indexing, .downloads, .photos, .finished, .failed])
        // waiting in line order: 2nd, then 3rd
        let places = items.filter { $0.section == .waiting }.compactMap { item -> Int? in
            if case .inLine(let n, _)? = item.job?.pipeline.line { return n }
            if case .server(let w) = item.kind { return w.position }
            return nil
        }
        #expect(places == places.sorted() && places.first == 2, "\(places)")
        // finished newest first
        let finished = items.filter { $0.section == .finished }.compactMap { item -> Date? in
            if case .finished(let w) = item.kind { return w.finishedAt } else { return nil }
        }
        #expect(finished.count == 2 && finished == finished.sorted(by: >))
        // the index: one row with the real numbers
        guard case .indexing(let search)? = items.first(where: { $0.section == .indexing })?.kind else {
            Issue.record("no indexing row")
            return
        }
        #expect(search.posts == 284 && search.indexed + search.pending == 284 && !search.next.isEmpty)
        // the failed download offers try again and dismiss; the running one, cancel
        let failed = items.first { if case .download(let r) = $0.kind { return r.isFailed } else { return false } }
        #expect(failed?.section == .failed && failed?.actions == [.retry, .dismiss])
        let going = items.first { $0.section == .downloads }
        #expect(going?.actions == [.cancel])
        // the header counts: 1 running share + photos + the download; 2 waiting; 1 failed
        let summary = rig.unified.summary
        #expect(summary.waiting == 2 && summary.failed == 1 && summary.running >= 3)
    }

    @Test func withoutTheRouteOnlyThisDevicesWorkShows() async {
        let rig = QueueRig(.localOnly)
        await rig.settle()
        let items = rig.unified.items
        #expect(!items.isEmpty)
        #expect(!items.contains { if case .server = $0.kind { return true } else { return false } })
        #expect(!items.contains { $0.section == .indexing })
        #expect(items.filter { $0.job != nil }.count == 2)
    }

    @Test func quietIsEmpty() async {
        let rig = QueueRig(.quiet)
        rig.unified.setVisible(true)
        await rig.settle()
        #expect(rig.unified.snapshot?.search?.hasWork == false)
        #expect(rig.unified.isEmpty && rig.unified.summary.isQuiet && rig.unified.badgeCount == 0)
        rig.unified.setVisible(false)
    }

    @Test func aFinishedJobStaysUnderRecentlyFinishedAfterItLeavesTheQueue() async {
        let rig = QueueRig(.quiet)
        let job = rig.app.queue.add([.link(linkA)], via: .review)[0]
        await rig.drive(until: { job.isFinished })
        #expect(rig.unified.items.first { $0.job?.id == job.id }?.section == .finished)
        // past the tray's 5 s (and the keep-original download): the job leaves the queue
        await rig.drive(until: { rig.app.queue.job(job.id) == nil }, maxVirtualSeconds: 120)
        #expect(rig.app.queue.job(job.id) == nil)
        #expect(rig.unified.finishedHistory.map(\.id) == [job.id])
        let row = rig.unified.items.first { $0.id == "finished:\(job.id.uuidString)" }
        #expect(row?.section == .finished && row?.actions == [.open, .dismiss])
        if let row { await rig.app.perform(.dismiss, on: row) }
        #expect(rig.unified.finishedHistory.isEmpty)
    }
}

// MARK: - Actions

@MainActor
struct UnifiedQueueActionTests {
    @Test func downloadsRouteToTheEngine() async {
        let rig = QueueRig(.busy)
        await rig.settle()
        let failed = rig.unified.items.first { if case .download(let r) = $0.kind { return r.isFailed } else { return false } }
        guard let failed, case .download(let row) = failed.kind else {
            Issue.record("no failed download")
            return
        }
        await rig.app.perform(.retry, on: failed)
        #expect(rig.app.offlineDownloads.rows.first { $0.id == row.id }?.isFailed == false, "queued again")
        let again = rig.unified.items.first { $0.id == failed.id }
        if let again, again.actions.contains(.cancel) { await rig.app.perform(.cancel, on: again) }
        #expect(!rig.app.offlineDownloads.rows.contains { $0.id == row.id }, "stopped and gone")
    }

    @Test func openGoesWhereTheWorkLives() async {
        let rig = QueueRig(.busy)
        await rig.settle()
        await rig.unified.refresh()
        rig.app.selectedTab = .queue
        let indexing = rig.unified.items.first { $0.section == .indexing }
        if let indexing { rig.app.open(indexing) }
        #expect(rig.app.selectedTab == .library)
        let photos = rig.unified.items.first { $0.section == .photos }
        if let photos { rig.app.open(photos) }
        #expect(rig.app.selectedTab == .settings)
        let waiting = rig.unified.items.first { $0.section == .waiting && $0.job != nil }
        if let waiting, let job = waiting.job { rig.app.open(waiting); #expect(rig.app.queue.focusedID == job.id) }
        #expect(rig.app.selectedTab == .save)
    }

    @Test func anActionTheRowDoesNotOfferDoesNothing() async {
        let rig = QueueRig(.busy)
        await rig.settle()
        await rig.unified.refresh()
        guard let share = rig.unified.items.first(where: { if case .server = $0.kind { return true } else { return false } }) else {
            Issue.record("no server row")
            return
        }
        let before = rig.server.lineCalls.count
        await rig.app.perform(.cancel, on: share)
        #expect(rig.server.lineCalls.count == before, "the share is not this key's: nothing is asked")
    }
}
