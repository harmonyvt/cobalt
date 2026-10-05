import Foundation
import Testing
@testable import CobaltKit

// A run link opens a finished run's media (CONTRACT-SHARE-QUICK.md, R3): `AppModel.requestedMediaID`.

@MainActor
@Suite(.serialized)
struct RunLinkMediaTests {
    private func shareJob(_ h: Harness, session: String?, wantsTrim: Bool = false) -> SharedJob {
        SharedJob(
            id: UUID(), origin: .shareExtension, link: URL(string: shortLink), sessionID: session, media: nil, trim: nil,
            stage: .saving, wantsTrim: wantsTrim, pickedUp: false, updatedAt: h.clock.now())
    }

    /// The original the background hand-off (or the app's own save) stores for `session`.
    @discardableResult
    private func storeOriginal(_ h: Harness, session: String, kind: StoredVideo.Kind = .original) async throws -> StoredMedia {
        let media = MediaInfo(name: "clip", duration: 5, width: 720, height: 1280, bytes: nil, isImage: kind == .webp)
        let video = try await h.ctx.store.add(
            file: try makeTempFile("clip-\(UUID().uuidString.prefix(4)).\(kind == .webp ? "webp" : "mp4")", bytes: 2_000),
            kind: kind, media: media, sessionID: session, link: URL(string: shortLink), remoteURL: nil, move: true)
        return try #require(h.ctx.store.media(containing: video.id))
    }

    @Test func aFinishedRunWithItsOriginalInTheStoreOpensAsThatMedia() async throws {
        let h = Harness(.coldStart)
        let created = try await h.ctx.client.createStudio(link: URL(string: shortLink)!)
        let media = try await storeOriginal(h, session: created.id)
        #expect(h.app.requestedMediaID == nil)
        h.app.selectedTab = .library
        #expect(h.app.openRunLink(URL(string: "cobalt-apple://session/\(created.id)")!))
        #expect(h.app.requestedMediaID == media.id)
        #expect(h.app.selectedTab == .save)
        #expect(h.pipeline.state == .idle, "nothing is resumed over the media")
    }

    @Test func theHandedOffJobRecordIsSettledSoTheNextForegroundDoesNotResumeIt() async throws {
        let h = Harness(.coldStart)
        let created = try await h.ctx.client.createStudio(link: URL(string: shortLink)!)
        let job = shareJob(h, session: created.id)
        h.ctx.jobs.upsert(job)
        let media = try await storeOriginal(h, session: created.id)
        #expect(h.app.openRunLink(URL(string: "cobalt-apple://job/\(job.id.uuidString)?session=\(created.id)")!))
        #expect(h.app.requestedMediaID == media.id)
        #expect(h.ctx.jobs.all().isEmpty)
        await h.app.pickUpSharedJobs()
        #expect(h.pipeline.state == .idle, "the run is not taken over the media")
    }

    @Test func aJobLinkWithoutASessionFindsTheMediaThroughTheJobRecord() async throws {
        let h = Harness(.coldStart)
        let created = try await h.ctx.client.createStudio(link: URL(string: shortLink)!)
        let job = shareJob(h, session: created.id)
        h.ctx.jobs.upsert(job)
        let media = try await storeOriginal(h, session: created.id)
        #expect(h.app.openRunLink(URL(string: "cobalt-apple://job/\(job.id.uuidString)")!))
        #expect(h.app.requestedMediaID == media.id)
    }

    @Test func aRunWithoutItsOriginalYetStillGoesToTheHomePipeline() async throws {
        let h = Harness(.coldStart)
        let created = try await h.ctx.client.createStudio(link: URL(string: shortLink)!)
        let run = UUID()
        #expect(h.app.openRunLink(URL(string: "cobalt-apple://job/\(run.uuidString)?session=\(created.id)")!))
        #expect(h.app.requestedMediaID == nil)
        #expect(h.pipeline.liveRunID == run && h.pipeline.sessionID == created.id)
    }

    @Test func onlyAnOriginalOfTheSessionCountsNotAWebpOrAnotherSession() async throws {
        let h = Harness(.coldStart)
        let created = try await h.ctx.client.createStudio(link: URL(string: shortLink)!)
        try await storeOriginal(h, session: created.id, kind: .webp)
        try await storeOriginal(h, session: "SomeOtherSid")
        #expect(h.app.openRunLink(URL(string: "cobalt-apple://session/\(created.id)")!))
        #expect(h.app.requestedMediaID == nil, "a webp of the session is not its saved video")
        #expect(h.pipeline.sessionID == created.id, "so the run is followed as before")
    }

    @Test func aRunStillRunningOnTheHomeScreenIsLeftToIt() async throws {
        let h = Harness(.coldStart)
        h.pipeline.start(link: URL(string: shortLink)!)
        await h.drive(until: { h.pipeline.sessionID != nil })
        let sid = try #require(h.pipeline.sessionID)
        let state = h.pipeline.state
        try await storeOriginal(h, session: sid)
        #expect(h.app.openRunLink(URL(string: "cobalt-apple://session/\(sid)")!))
        #expect(h.app.requestedMediaID == nil, "the owner is watching this run: the media is not pulled out from under it")
        #expect(h.pipeline.state == state)
    }

    @Test func trimInCobaltStaysTheTrim() async throws {
        let h = Harness(.coldStart)
        let created = try await h.ctx.client.createStudio(link: URL(string: shortLink)!)
        try await storeOriginal(h, session: created.id)
        #expect(h.app.openRunLink(URL(string: "cobalt-apple://session/\(created.id)?trim=1")!))
        #expect(h.app.requestedMediaID == nil)
        let job = shareJob(h, session: created.id, wantsTrim: true)
        h.ctx.jobs.upsert(job)
        #expect(h.app.openRunLink(URL(string: "cobalt-apple://job/\(job.id.uuidString)")!))
        #expect(h.app.requestedMediaID == nil, "a job that asked for the trim keeps going to the trim")
    }

    @Test func aDismissedHomeRunDoesNotBlockTheMedia() async throws {
        let h = Harness(.coldStart)
        h.pipeline.start(link: URL(string: shortLink)!)
        await h.driveToSettled()
        let sid = try #require(h.pipeline.sessionID)
        let media = try await storeOriginal(h, session: sid)
        h.pipeline.reset()
        #expect(h.app.openRunLink(URL(string: "cobalt-apple://session/\(sid)")!))
        #expect(h.app.requestedMediaID == media.id)
    }
}
