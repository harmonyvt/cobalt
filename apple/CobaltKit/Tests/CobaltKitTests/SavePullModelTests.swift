import Foundation
import Synchronization
import Testing
@testable import CobaltKit

// CONTRACT-OFFLINE.md 13.8, 13.9 on the model side: what `AppModel` hands the pull (settings, capabilities, the library over
// the real client, the runs of this app), `setKeepNewSaves`, and the uploads this Mac makes. Temp directories and a loopback
// server; never the real home folder.

@MainActor
private struct ModelRig {
    let clock = VirtualClock()
    let ctx: PipelineContext
    let mac: MacRig
    let store: OfflineStore
    let ledger: PullLedger
    let pull: SavePull
    let app: AppModel

    init(scenario: PreviewScenario = .happy, client: (any CobaltClient)? = nil, gallery: Bool = true) throws {
        ctx = PipelineContext.preview(scenario, timeScale: 1, clock: clock)
        ctx.settings.autoContinue = false
        if let client { ctx.client = client }
        var caps = ctx.capabilities
        caps.kind = .fork
        caps.key = .valid
        caps.library = true
        caps.gallery = gallery
        ctx.capabilities = caps
        mac = try MacRig()
        try mac.commit()
        store = mac.store()
        ledger = PullLedger(directory: mac.sync)
        let downloads = OfflineDownloads(
            store: store, queue: OfflineQueue(directory: mac.sync), transport: nil, clock: clock, client: { [ctx] in ctx.client })
        pull = SavePull(store: store, ledger: ledger, downloads: downloads, clock: clock, scheduler: ClockScheduler(clock: clock))
        let shared = ctx.client
        app = AppModel(context: ctx, library: LibraryModel(context: ctx), savePull: pull, offlineDownloads: downloads, makeClient: { _ in shared })
    }

    func settle() async {
        var last = clock.registrations
        var stable = 0
        while stable < 4 {
            try? await Task.sleep(for: .milliseconds(1))
            let r = clock.registrations
            if r == last { stable += 1 } else { stable = 0; last = r }
        }
    }

    func drive(until condition: @MainActor () -> Bool, maxVirtualSeconds: Double = 300) async {
        var idle = 0
        while !condition() && clock.elapsed < maxVirtualSeconds {
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

@MainActor
@Suite(.serialized)
struct SavePullModelTests {
    private nonisolated static let page = #"""
    {"status":"success","counts":{"posts":1,"files":1},"usage":{"public_bytes":0,"private_bytes":9},"next":null,"posts":[
     {"id":"old","service":"instagram","link":"https://www.instagram.com/reel/DeHC9jcpfQW/","created_at":1000000000000,
      "files":[{"id":"f1","kind":"private","source":"saved","name":"a.mp4","content_type":"video/mp4","created_at":1000000000000,"deletable":false}]}]}
    """#

    private func server() async throws -> LoopbackServer {
        try await LoopbackServer.start { req in
            req.path == "/library" ? .json(Self.page) : .json(#"{"status":"error","error":{"code":"error.api.generic"}}"#, status: 404)
        }
    }

    private func http(_ server: LoopbackServer) -> HTTPCobaltClient { HTTPCobaltClient(baseURL: server.base, apiKey: { "KEY-9" }) }

    // MARK: the library request

    @Test func aQuietCheckOnAGalleryServerIsOneRequestOfFiveAskingForV3WithTheKey() async throws {
        let server = try await server()
        defer { server.stop() }
        let t = try ModelRig(client: http(server), gallery: true)
        await t.app.savePull.check()
        #expect(server.requests.count == 1)
        let r = try #require(server.requests.first)
        #expect(r.method == "GET" && r.path == "/library" && r.query.contains("limit=5") && r.query.contains("v=3"))
        #expect(r.headers["authorization"] == "Api-Key KEY-9")
        #expect(t.app.savePull.status.lastChecked != nil && t.app.savePull.status.paused == nil)
    }

    @Test func anOlderServerIsAskedForV2AndAnOlderStillForNeither() async throws {
        let server = try await server()
        defer { server.stop() }
        let t = try ModelRig(client: http(server), gallery: false)
        t.ctx.capabilities.visibility = true
        await t.app.savePull.check()
        #expect(server.requests[0].query.contains("v=2") && !server.requests[0].query.contains("v=3"))
        t.ctx.capabilities.visibility = false
        t.clock.jump(by: 300)
        await t.app.savePull.check()
        #expect(!server.requests[1].query.contains("v="))
    }

    @Test func aModelWhoseCapabilitiesAreNotKnownYetPausesAndAsksNothing() async throws {
        let server = try await server()
        defer { server.stop() }
        let t = try ModelRig(client: http(server))
        t.app.apply(.unknown)
        await t.app.savePull.check()
        #expect(server.requests.isEmpty && t.app.savePull.status.paused == .noServer)
        // the server answers: the check that waited runs
        var caps = Capabilities.unknown
        caps.kind = .fork
        caps.key = .valid
        caps.library = true
        t.app.apply(caps)
        #expect(await eventually(15) { server.requests.count == 1 })
    }

    // MARK: keep new saves offline

    @Test func settingKeepNewSavesWritesTheSettingAndTakesANewBaselineOnlyWhenItChanges() async throws {
        let server = try await server()
        defer { server.stop() }
        let t = try ModelRig(client: http(server))
        await t.app.savePull.check()
        let first = try #require(t.ledger.read().enabledAt)

        t.app.setKeepNewSaves(true)                                      // already on: nothing changes
        #expect(t.ctx.settings.keepVideosOnDevice && t.ledger.read().enabledAt == first)

        t.app.setKeepNewSaves(false)
        #expect(!t.ctx.settings.keepVideosOnDevice && t.ledger.read().enabledAt == nil, "off forgets the baseline")
        let asked = server.requests.count
        await t.app.savePull.check()
        #expect(server.requests.count == asked && t.app.savePull.status.paused == .keepOff)

        t.clock.jump(by: 1_000)
        t.app.setKeepNewSaves(true)
        #expect(t.ctx.settings.keepVideosOnDevice && t.ledger.read().enabledAt == t.clock.now(), "on takes a new baseline")
        #expect(await eventually(15) { server.requests.count == asked + 1 }, "and checks")
    }

    @Test func anotherServerForTheModelTakesANewBaseline() async throws {
        let server = try await server()
        defer { server.stop() }
        let t = try ModelRig(client: http(server))
        await t.app.savePull.check()
        let host = try #require(t.ledger.read().server)
        #expect(host == t.ctx.settings.serverURL.absoluteString)
        t.clock.jump(by: 500)
        t.app.serverChanged()
        #expect(t.ledger.read().enabledAt == t.clock.now() && t.ledger.read().done.isEmpty)
        // the new server's capabilities arrive: the check that waited for them runs
        let asked = server.requests.count
        var caps = Capabilities.unknown
        caps.kind = .fork
        caps.key = .valid
        caps.library = true
        t.app.apply(caps)
        #expect(await eventually(15) { server.requests.count == asked + 1 })
    }

    // MARK: this Mac's own runs

    @Test func anUploadOnTheWireHoldsBackUploadsAndATickedPostKeyIsRememberedAfterwards() async throws {
        let t = try ModelRig(scenario: .image)
        t.app.watchOwnUploads()
        #expect(!t.app.uploadIsInFlight && t.app.ownUploadIDs.isEmpty)
        let p = t.app.pipeline
        p.start(file: try makeTempFile("photo.png"))
        guard case .uploading = p.state else { Issue.record("expected .uploading"); return }
        #expect(t.app.uploadIsInFlight, "the file is on the wire: its row may be listed before the run knows its id")
        #expect(t.app.ownUploadIDs.isEmpty)

        await t.drive { if case .image = p.state { return true } else { return false } }
        guard case .image = p.state else { Issue.record("expected .image, got \(p.state)"); return }
        let id = try #require(p.uploadedItemID)
        #expect(!t.app.uploadIsInFlight && t.app.ownUploadIDs == [id], "the run's own upload: the library id is the post's key")
        #expect(await eventually(15) { t.ledger.read().own[id] != nil }, "heard as the queue changed, so a finished run's row is never fetched back")
    }

    @Test func aCheckAlsoReadsTheRunsItIsHandedAndSettlesTheirUploads() async throws {
        let t = try ModelRig(scenario: .image)
        let p = t.app.pipeline
        p.start(file: try makeTempFile("photo.png"))
        await t.drive { if case .image = p.state { return true } else { return false } }
        let id = try #require(p.uploadedItemID)
        await t.app.savePull.check()
        #expect(t.ledger.read().own[id] != nil)
    }

    @Test func aSessionIsHeldWhileARunOfTheQueueFollowsItAndAfterThatNot() async throws {
        let t = try ModelRig(scenario: .happy)
        let p = t.app.pipeline
        p.start(link: URL(string: "https://www.instagram.com/reel/DeHC9jcpfQW/")!)
        await t.drive { p.sessionID != nil }
        let sid = try #require(p.sessionID)
        #expect(t.app.queue.jobs.contains { $0.isLive && $0.pipeline.sessionID == sid }, "the run is still going")
        #expect(t.app.holdsSession(sid), "so its post is not the pull's to fetch")
        #expect(!t.app.holdsSession("someone-elses-session"))
        await t.drive { t.app.queue.live.isEmpty }
        #expect(!t.app.holdsSession(sid), "and once the run has nothing more to do it is let go")

        // finished, but the original is still coming into the store (the library lists the post before the record lands)
        let fetching = Task<StoredVideo?, Never> { try? await Task.sleep(for: .seconds(30)); return nil }
        p.keepRequest = fetching
        #expect(t.app.holdsSession(sid), "the run's own copy is on its way: not the pull's to fetch")
        #expect(!t.app.holdsSession("someone-elses-session"))
        fetching.cancel()
        p.keepRequest = nil
        #expect(!t.app.holdsSession(sid))
    }

    // MARK: previews

    @Test func aPreviewModelHasAPullThatIsNotWiredToAnything() async throws {
        let app = AppModel.preview(.happy)
        await app.savePull.check()
        app.setKeepNewSaves(false)
        app.setKeepNewSaves(true)
        #expect(app.savePull.status.available == MacFolder.platformHasFolder && app.savePull.status.lastChecked == nil)
    }
}
