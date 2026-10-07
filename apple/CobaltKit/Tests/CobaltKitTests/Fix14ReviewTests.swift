import Foundation
import Testing
@testable import CobaltKit

// Regression tests for the read-only review of the gallery commits before 1.14 (B1, B2, SF1-SF5 and two nits). Each
// test fails on the code the review read and passes on the fix.

private let igLink = URL(string: "https://www.instagram.com/p/Ddy0-gpGg5U/")!
private let sharedSID = "aB3dE6gH9jK2mN5pQ8sTuV"
private let sharedLink = URL(string: "https://www.instagram.com/p/Dc2QA4ng-US/")!

@MainActor
private func gallerySession(_ status: SessionStatus = .ready, items: Int = 3, count: Bool = true, listed: Bool = true) -> StudioSession {
    var s = StudioSession(
        id: sharedSID, status: status, link: sharedLink.absoluteString, service: "instagram", title: "instagram · Dc2QA4ng-US",
        duration: nil, width: status == .ready ? 1080 : nil, height: status == .ready ? 1350 : nil,
        bytes: status == .ready ? 900_000 : nil, createdAt: Date(), expiresAt: Date().addingTimeInterval(86_400),
        errorCode: nil, renders: [])
    if count { s.itemCount = items }
    if listed { s.items = (0..<items).map { SessionItem(i: $0, type: .photo, status: .ready) } }
    return s
}

@MainActor
private final class Taken {
    var galleries: [String] = []
}

// MARK: - B1: a gallery is not one original

@MainActor
@Suite(.serialized)
struct SharedGalleryOnTheAppTests {
    private func rig(recent: [StudioSession] = [], info: StudioSession? = nil, takes: Bool = true) throws -> (FetcherRig, Taken) {
        let rig = try FetcherRig()
        let taken = Taken()
        let f = rig.fetcher
        f.discoversShares = true
        f.serverURL = { URL(string: "https://api.capybaraharmony.com")! }
        f.keepsOriginals = { true }
        f.recentShares = { recent }
        f.sessionInfo = { _ in info }
        f.adoptGallery = { id, _ in taken.galleries.append(id); return takes }
        return (rig, taken)
    }

    @Test func aGallerySavedByTheShareSheetIsFollowedAsAGalleryNotQueuedAsOneOriginal() async throws {
        // the reviewer's probe: a ready session with 3 photos in `recent`
        let (r, taken) = try rig(recent: [gallerySession()])
        await r.fetcher.discoverShares()
        #expect(r.pending.entry(sharedSID) == nil, "no GET /studio/<sid>/source for the lead item")
        #expect(r.session?.tasks.isEmpty != false)
        #expect(taken.galleries == [sharedSID], "handed to the queue as a gallery job")
    }

    @Test func anItemCountOfTwoOrMoreIsEnoughAndASingleFileIsStillAnOriginal() async throws {
        let (counted, taken) = try rig(recent: [gallerySession(items: 2, listed: false)])
        await counted.fetcher.discoverShares()
        #expect(counted.pending.entry(sharedSID) == nil && taken.galleries == [sharedSID])

        var single = gallerySession(items: 1, count: false, listed: false)
        single.duration = 12.5
        let (plain, none) = try rig(recent: [single])
        await plain.fetcher.discoverShares()
        #expect(plain.pending.entry(sharedSID) != nil && none.galleries.isEmpty, "one file is today's original")
    }

    @Test func aGalleryNobodyCanTakeYetQueuesNothingAndIsAskedAgainNextTime() async throws {
        let (r, taken) = try rig(recent: [gallerySession()], takes: false)
        await r.fetcher.discoverShares()
        await r.fetcher.discoverShares()
        #expect(r.pending.entry(sharedSID) == nil && taken.galleries == [sharedSID, sharedSID])
    }

    @Test func aSaveFoundWhileSavingThatTurnsOutToBeAGalleryIsHandedOverWhenItsFileArrives() async throws {
        // "save now" / the 8 s fallback: while saving the session carries no item count, so it is queued as an original
        let saving = gallerySession(.saving, count: false, listed: false)
        let (r, taken) = try rig(recent: [saving], info: gallerySession())
        await r.fetcher.discoverShares()
        let entry = try #require(r.pending.entry(sharedSID))
        #expect(entry.media?.duration == nil, "nothing known yet")
        let task = try #require(r.session?.tasks.first)
        r.session?.respond(task: task.id, status: 200, body: Data(repeating: 1, count: 2_000), contentType: "image/jpeg")
        #expect(await eventually { taken.galleries == [sharedSID] })
        #expect(!r.store.videos.contains { $0.sessionID == sharedSID }, "the lead item is not stored as the post's original")
        #expect(r.pending.entry(sharedSID) == nil)
    }

    @Test func aSharedPhotoIsNamedFromTheResponsesContentTypeNotMp4() async throws {
        for (type, ext) in [("image/jpeg", "jpg"), ("image/png", "png"), ("image/webp", "webp"), ("image/heic", "heic"), ("video/mp4", "mp4"), (nil, "mp4")] {
            let r = try FetcherRig()
            r.handOff("S1")
            let task = try #require(r.session?.tasks.first)
            r.session?.respond(task: task.id, status: 200, body: Data(repeating: 7, count: 2_000), contentType: type)
            #expect(await eventually { r.store.videos.contains { $0.sessionID == "S1" } }, "\(type ?? "none")")
            let stored = try #require(r.store.videos.first { $0.sessionID == "S1" })
            #expect(stored.fileURL?.pathExtension == ext, "\(type ?? "none") -> \(stored.fileURL?.lastPathComponent ?? "")")
        }
        #expect(OriginalFetcher.fileExtension(forContentType: "image/jpeg; charset=binary") == "jpg")
    }

    @Test func theQueueFollowsASharedGalleryToTheEndAndKeepsEveryItem() async throws {
        let h = Harness(.galleryInstagram)
        let app = h.app
        app.queue.trayIsShown = true
        // the gallery is on the server (saved here once, then forgotten by the device: the Feather build's share sheet)
        h.pipeline.start(link: igLink)
        await h.driveToSettled()
        let sid = try #require(h.pipeline.sessionID)
        app.queue.dismiss(try #require(app.queue.galleryJob(session: sid)).id)
        for v in app.store.videos where v.sessionID == sid { await app.store.remove(v.id) }
        #expect(app.store.media(session: sid) == nil)

        #expect(app.queue.adoptSharedGallery(session: sid, link: igLink))
        let job = try #require(app.queue.galleryJob(session: sid) ?? app.queue.jobs.last)
        await h.drive(until: { !(app.queue.job(job.id)?.isLive ?? false) && job.pipeline.galleryRun?.isSaved == true })
        guard case .gallery(let items) = job.pipeline.state else { Issue.record("\(job.pipeline.state)"); return }
        #expect(items.count == 10)
        #expect(app.store.media(session: sid)?.items.count == 10, "every item kept, not a lead file")
        // the same session again does not start a second job
        let before = app.queue.jobs.count
        #expect(app.queue.adoptSharedGallery(session: sid, link: igLink))
        #expect(app.queue.jobs.count == before)
    }

    @Test func withNoTrayNothingIsStartedBehindTheOwnersBack() async throws {
        let h = Harness(.galleryInstagram)
        #expect(h.app.queue.trayIsShown == false)
        #expect(h.app.queue.adoptSharedGallery(session: sharedSID, link: sharedLink) == false)
        #expect(h.app.queue.jobs.isEmpty)
    }
}

// MARK: - B2: a reel never shows the gallery sheet

@Suite @MainActor struct ShareLinkShapeTests {
    @Test func thePureShapeCheckSaysWhichLinksCanBeGalleries() {
        let single = [
            "https://www.instagram.com/reel/DeHC9jcpfQW/", "https://www.instagram.com/reels/DeHC9jcpfQW/",
            "https://www.instagram.com/tv/DeHC9jcpfQW/", "https://www.instagram.com/someone/reel/DeHC9jcpfQW/?igsh=x",
            "https://www.youtube.com/watch?v=dQw4w9WgXcQ", "https://youtu.be/dQw4w9WgXcQ", "https://m.youtube.com/shorts/abc",
            "https://www.tiktok.com/@user/video/7300000000000000000",
            "https://x.com/user/status/2106850389551374806/video/1", "https://twitter.com/user/status/1/video/2",
            "https://cdn.example.com/a/b/clip.mp4", "https://cdn.example.com/photo.JPG?x=1", "https://example.com/song.m4a",
        ]
        for link in single { #expect(!InstantShare.mayBeGallery(URL(string: link)!), "\(link)") }
        let maybe = [
            "https://www.instagram.com/p/Ddy0-gpGg5U/", "https://instagram.com/p/Ddy0-gpGg5U/?img_index=2",
            "https://x.com/ilokineedsleep/status/2106850389551374806?s=20", "https://twitter.com/i/status/2106850389551374806",
            "https://www.tiktok.com/@user/photo/7300000000000000000", "https://vm.tiktok.com/ZMabc/",
            "https://example.com/some/post", "https://bsky.app/profile/a/post/b",
        ]
        for link in maybe { #expect(InstantShare.mayBeGallery(URL(string: link)!), "\(link)") }
    }

    @Test func aReelIsTheInstantSaveAtOnceWithNoResolveNoSheetAndNoEightSecondWait() async {
        let reel = LinkInfo(URL(string: "https://www.instagram.com/reel/DeHC9jcpfQW/")!)!
        let rig = GSRig(link: reel)
        rig.begin()
        await gsSettle()
        #expect(rig.sender.sent == [.plain(reel)], "the one request is today's instant save")
        #expect(rig.server.resolves == 0 && rig.server.capabilityReads == 0, "the server is not asked what the link is")
        #expect(!rig.flow.sheetShown && rig.flow.finish == .sent)
        // time passing changes nothing: no checking sheet at 700 ms, no `saving everything` at 8 s, still one request
        await rig.clock.advance(by: .seconds(9))
        #expect(rig.sender.sent == [.plain(reel)] && !rig.flow.sheetShown)
        #expect(rig.notices.posted.map(\.head) == ["saving to cobalt"])
    }

    @Test func aPostLinkStillAsksTheServerAndKeepsTheGalleryFlow() async {
        let rig = GSRig(link: LinkInfo(igLink)!)
        rig.begin()
        await gsSettle()
        #expect(rig.server.resolves == 1 && rig.server.capabilityReads == 1)
        await rig.clock.advance(by: .milliseconds(700))
        #expect(rig.flow.phase == .checking && rig.flow.sheetShown)
        await rig.answer(gsPicker(Array(repeating: .photo, count: 4)))
        #expect(rig.flow.phase == .choosing)
    }
}

// MARK: - SF1 / SF2: the tray's x and retry for a make

@Suite(.serialized) @MainActor
struct GalleryJobControlsTests {
    private func preview(_ h: Harness) -> PreviewClient { h.ctx.client as! PreviewClient }

    @Test func xOnAMakeWaitingForItsSaveCancelsOnlyTheMakeNeverTheSave() async throws {
        let h = Harness(.galleryInstagram)
        let app = h.app
        let job = try #require(app.queue.add([.link(igLink)], via: .paste).first)
        await h.drive(until: { job.pipeline.galleryRun?.phase == .saving })
        let p = job.pipeline
        await p.make(.slideshow(SlideshowPlan(format: .webp, items: [0, 1, 2], quality: .med, width: 480)))
        guard case .waiting? = p.galleryRun?.make else { Issue.record("\(String(describing: p.galleryRun?.make))"); return }
        p.observeLine(queueAhead: 2)                                       // the save waits in the server's line
        #expect(p.makeJobID == nil)
        let flag = Flag()
        let cancel = Task { @MainActor in await app.queue.cancel(job.id); flag.done = true }
        await h.drive(until: { flag.done })
        await cancel.value
        #expect(!preview(h).server.lineCalls.contains { $0.hasPrefix("DELETE line") }, "no cancel went to the server: \(preview(h).server.lineCalls)")
        #expect(p.galleryRun?.make == GalleryRun.Make.none)
        // the save goes on to its end and the items are kept
        await h.drive(until: { p.galleryRun?.isSaved == true })
        #expect(p.galleryRun?.phase == .saved && app.store.media(session: p.sessionID ?? "")?.items.count == 10)
        #expect(app.queue.job(job.id) != nil, "the job is still there, now a saved gallery")
    }

    @Test func retryingAFailedMakeIsTheSameMakeNotANewSaveOfTheLink() async throws {
        let h = Harness(.galleryMakeFails)
        let app = h.app
        h.pipeline.start(link: igLink)
        await h.driveToSettled()
        let sid = try #require(h.pipeline.sessionID)
        app.queue.dismiss(try #require(app.queue.galleryJob(session: sid)).id)
        await app.library.refresh()
        let item = app.mediaItem(for: try #require(app.library.posts.first { $0.id == sid }))
        let plan = SlideshowPlan(format: .webp, items: [0, 1, 2], quality: .med, width: 480)
        try await app.make(.slideshow(plan), from: item)
        let failed = try #require(app.queue.jobs.last)
        await h.drive(until: { if case .failed? = failed.pipeline.galleryRun?.make { return true } else { return false } })
        let creates = preview(h).galleries.calls.filter { $0.name == "create" }.count

        app.queue.retry(failed.id)
        let again = try #require(app.queue.jobs.last)
        #expect(again.id != failed.id && app.queue.job(failed.id) == nil)
        await h.drive(until: { if case .done? = again.pipeline.galleryRun?.make { return true } else { return false } })
        let sent = preview(h).galleries.calls.filter { $0.name == "slideshow" }
        #expect(sent.count == 2 && sent[0] == sent[1], "the same make: \(sent)")
        #expect(preview(h).galleries.calls.filter { $0.name == "create" }.count == creates, "no second save of the post")
        #expect(again.pipeline.sessionID == sid)
    }

    @Test func retryingAFailedRetryOfMissingItemsRetriesThoseItemsNotAFullSave() async throws {
        let h = Harness(.galleryPartial)
        let app = h.app
        h.pipeline.start(link: igLink)
        await h.driveToSettled()
        let sid = try #require(h.pipeline.sessionID)
        app.queue.dismiss(try #require(app.queue.galleryJob(session: sid)).id)
        await app.library.refresh()
        let item = app.mediaItem(for: try #require(app.library.posts.first { $0.id == sid }))
        try await app.retryMissing(item)
        let job = try #require(app.queue.jobs.last)
        await h.drive(until: { !(app.queue.job(job.id)?.isLive ?? false) })
        let creates = preview(h).galleries.calls.filter { $0.name == "create" }.count
        job.pipeline.setState(.failed(.server(code: "error.studio.busy")))              // the retry's request was refused
        #expect(job.isFailed)

        app.queue.retry(job.id)
        let again = try #require(app.queue.jobs.last)
        #expect(again.id != job.id && again.via == .make)
        await h.drive(until: { !(app.queue.job(again.id)?.isLive ?? false) && again.pipeline.galleryRun != nil })
        #expect(preview(h).galleries.calls.filter { $0.name == "retry" }.count == 2, "the missing items were asked for again")
        #expect(preview(h).galleries.calls.filter { $0.name == "create" }.count == creates, "never the link as a new save")
    }
}

@MainActor private final class Flag { var done = false }

// MARK: - SF3: a finished gallery is a gallery whatever the cached capabilities say

@Suite(.serialized) @MainActor
struct RelaunchedGalleryTests {
    @Test func aGallerySessionResumedBeforeTheCapabilitiesAreKnownStillFinishesAsAGallery() async throws {
        let h = Harness(.galleryInstagram)
        let app = h.app
        h.pipeline.start(link: igLink)
        await h.driveToSettled()
        let sid = try #require(h.pipeline.sessionID)
        app.queue.dismiss(try #require(app.queue.galleryJob(session: sid)).id)
        h.ctx.capabilities = .unknown                                            // right after a relaunch or a cold wake
        let shared = SharedJob(
            id: UUID(), origin: .app, link: igLink, sessionID: sid, media: nil, trim: nil, stage: .saving, wantsTrim: false,
            pickedUp: false, updatedAt: h.ctx.clock.now())
        let job = try #require(app.queue.add([.shared(shared)], via: .relaunch).first)
        await h.drive(until: { if case .gallery = job.pipeline.state { return job.pipeline.galleryRun?.isSaved == true } else { return false } })
        guard case .gallery(let items) = job.pipeline.state else { Issue.record("\(job.pipeline.state)"); return }
        #expect(items.count == 10 && job.pipeline.galleryRun?.phase == .saved)
    }
}

// MARK: - SF4: the replaced file goes even when the new one does not come down

@Suite(.serialized) @MainActor
struct ReplacedMakeTests {
    @Test func theOldLocalFileLeavesWhenTheServerSaysItWasReplacedEvenIfTheNewDownloadFails() async throws {
        let h = Harness(.galleryInstagram)
        let p = h.pipeline
        p.start(link: igLink)
        await h.driveToSettled()
        let sid = try #require(p.sessionID)
        func make(_ seconds: Double) async -> MadeResult? {
            await p.make(.slideshow(SlideshowPlan(format: .webp, items: Array(0..<10), photoSeconds: seconds, quality: .med, width: 480)))
            await h.drive(until: { !(p.galleryRun?.make.isActive ?? true) })
            if case .done(_, let r)? = p.galleryRun?.make { return r }
            return nil
        }
        let first = try #require(await make(2))
        #expect(h.app.store.media(session: sid)?.made.map(\.libraryID) == [first.itemID])
        (h.ctx.client as! PreviewClient).server.failMadeDownloads = true
        let second = try #require(await make(3))
        #expect(second.replaced == [first.itemID!])
        #expect(h.app.store.media(session: sid)?.made.isEmpty == true, "the replaced file is gone here; the new one waits in the library (one tab, not two)")
        #expect(h.app.store.media(session: sid)?.items.count == 10, "the photos are untouched")
    }
}

// MARK: - the folder rule (a single photo is flat, a gallery is a folder)

@Suite(.serialized) @MainActor
struct FolderPlacementTests {
    @Test func aSinglePastedPhotoIsAFlatFileAndAGalleryAndItsMadeFilesAreAFolder() async throws {
        // the pipeline stores each item with the post's size, so the first item of a gallery is not mistaken for a lone photo
        let single = await Harness(.galleryOne).savedStore(igLink)
        let photo = try #require(single.videos.first { $0.role == .item })
        let alone = try #require(single.media.first { $0.items.contains { $0.id == photo.id } })
        #expect(alone.items.count == 1 && photo.postItems == 1)
        let flat = FolderNaming.placement(for: photo, in: alone)
        #expect(flat.folder == nil && flat.name.hasSuffix(".jpg"), "a single photo is a flat file: \(flat)")

        let many = await Harness(.galleryInstagram).savedStore(igLink)
        let manyItems = many.videos.filter { $0.role == .item }
        #expect(manyItems.count == 10 && manyItems.allSatisfy { $0.postItems == 10 })
        let first = try #require(many.videos.first { $0.itemIndex == 0 })
        // what the store held when item 0 was the only one kept so far
        let early = try #require(StoredMedia(id: first.mediaID, original: nil, webps: [], items: [first]))
        #expect(FolderNaming.placement(for: first, in: early).folder != nil, "the first item of a gallery goes into the folder")
        #expect(FolderNaming.placement(for: first, in: early).name == "01.jpg")

        // without the size (an older record, a rebuilt index) the media decides: one item alone is flat, a made file makes a folder
        var bare = photo
        bare.postItems = nil
        let lone = try #require(StoredMedia(id: bare.mediaID, original: nil, webps: [], items: [bare]))
        #expect(FolderNaming.placement(for: bare, in: lone).folder == nil)
        let slideshow = StoredVideo(
            id: "m", kind: .webp, fileURL: nil, posterURL: nil, name: "n", duration: nil, width: nil, height: nil, bytes: 1,
            sessionID: bare.sessionID, link: bare.link, remoteURL: nil, createdAt: Date(), mediaID: bare.mediaID, role: .slideshow,
            madeSpec: Data(#"{"format":"webp"}"#.utf8), libraryID: "m1")
        let withMade = try #require(StoredMedia(id: bare.mediaID, original: nil, webps: [], items: [bare], made: [slideshow]))
        #expect(FolderNaming.placement(for: bare, in: withMade).folder != nil)
        #expect(FolderNaming.placement(for: slideshow, in: withMade).folder != nil)
    }
}

extension Harness {
    /// Pastes `link` and runs the save to its end: what the store then holds.
    @MainActor func savedStore(_ link: URL) async -> (videos: [StoredVideo], media: [StoredMedia]) {
        pipeline.start(link: link)
        await driveToSettled()
        return (app.store.videos, app.store.media)
    }
}

// MARK: - the index nit

@Suite(.serialized) @MainActor
struct LenientRoleTests {
    @Test func anUnknownFutureRoleReadsAsNoneAndNeverMakesTheIndexUnreadable() async throws {
        let dir = try makeTempDirectory()
        let tools = PreviewMediaTools(clock: SystemClock(), clip: PreviewData.long)
        let store = OfflineStore(root: dir.appendingPathComponent("Videos"), tools: tools, defaults: UserDefaults(suiteName: "lenient-\(UUID().uuidString)")!)
        let file = dir.appendingPathComponent("a.webp")
        try PreviewMedia.placeholderBytes.write(to: file)
        let made = try await store.add(
            file: file, kind: .webp, media: MediaInfo(name: "n", duration: nil, width: 4, height: 5, bytes: nil, isImage: true),
            sessionID: "S1", link: nil, remoteURL: nil, move: true, keep: false, role: .slideshow, libraryID: "m1")
        let plain = try await store.add(
            file: try { let u = dir.appendingPathComponent("b.mp4"); try PreviewMedia.placeholderBytes.write(to: u); return u }(),
            kind: .original, media: MediaInfo(name: "p", duration: 3, width: 4, height: 5, bytes: nil, isImage: false),
            sessionID: "S2", link: nil, remoteURL: nil, move: true, keep: false)
        // a later build wrote a role this one has never heard of
        let indexURL = OfflineStore.indexURL(root: store.root)
        let text = try String(contentsOf: indexURL, encoding: .utf8)
        #expect(text.contains(#""role":"slideshow""#) || text.contains(#""role" : "slideshow""#))
        try text.replacingOccurrences(of: #""role":"slideshow""#, with: #""role":"mosaic""#)
            .replacingOccurrences(of: #""role" : "slideshow""#, with: #""role" : "mosaic""#)
            .write(to: indexURL, atomically: true, encoding: .utf8)
        let reopened = OfflineStore(root: store.root, tools: tools, defaults: UserDefaults(suiteName: "lenient-\(UUID().uuidString)")!)
        #expect(reopened.videos.count == 2, "every record is still read")
        #expect(reopened.videos.first { $0.id == made.id }?.role == nil)
        #expect(reopened.videos.first { $0.id == plain.id } != nil)

        // the same for the other places a role is written: a record, a file's tag, a download job
        let json = Data(#"{"id":"a","kind":"original","name":"n","bytes":1,"createdAt":0,"role":"mosaic"}"#.utf8)
        #expect(try JSONDecoder().decode(StoredVideo.self, from: json).role == nil)
        let tag = Data(#"{"v":1,"id":"a","media":"a","kind":"original","created":0,"role":"mosaic","item":2}"#.utf8)
        let decoded = try #require(OfflineTag.decode(tag), "a file with an unknown role is still cobalt's")
        #expect(decoded.role == nil && decoded.item == 2)
        let known = Data(#"{"v":1,"id":"a","media":"a","kind":"original","created":0,"role":"item","item":2}"#.utf8)
        #expect(OfflineTag.decode(known)?.role == .item)
        // and a role is still written when there is one, and no key when there is none
        let encoder = JSONEncoder()
        #expect(String(decoding: try encoder.encode(try #require(OfflineTag.decode(known))), as: UTF8.self).contains(#""role":"item""#))
        #expect(!String(decoding: try encoder.encode(decoded), as: UTF8.self).contains("role"))
    }
}
