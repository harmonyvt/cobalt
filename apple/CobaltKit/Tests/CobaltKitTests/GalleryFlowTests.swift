import Foundation
import Testing
@testable import CobaltKit

// The gallery pipeline (apple/CONTRACT-GALLERY.md 1.10, 1.11, 1.15, R7, R8) on `PreviewClient`'s gallery scenarios and the
// virtual clock: a picker becomes a `.gallery` that saves everything at once, a make chosen too early waits for the save and
// is sent once, a remake replaces, the detail's calls reach the server.

private let igLink = URL(string: "https://www.instagram.com/p/Ddy0-gpGg5U/")!
private let xLink = URL(string: "https://x.com/ilokineedsleep/status/2106850389551374806")!

@MainActor private final class Finished { var value = false }

/// Runs `op` while virtual time is driven: a call that waits on the preview server's latency would never return on the
/// virtual clock otherwise.
@MainActor
private func driven<T: Sendable>(_ h: Harness, _ op: @escaping @MainActor () async throws -> T) async throws -> T {
    let flag = Finished()
    let task = Task { @MainActor () throws -> T in
        defer { flag.value = true }
        return try await op()
    }
    await h.drive(until: { flag.value })
    return try await task.value
}

extension Harness {
    /// The session the pipeline holds (a saved gallery has one).
    @MainActor var sid: String { pipeline.sessionID ?? "" }
}

@MainActor
private func preview(_ h: Harness) -> PreviewClient { h.ctx.client as! PreviewClient }

@MainActor
private func calls(_ h: Harness, _ name: String) -> [String] {
    preview(h).galleries.calls.filter { $0.name == name }.map(\.detail)
}

/// Pastes the scenario's link and runs to the end of the save.
@MainActor
private func savedGallery(_ scenario: PreviewScenario, link: URL = igLink) async -> Harness {
    let h = Harness(scenario)
    h.pipeline.start(link: link)
    await h.driveToSettled()
    return h
}

@MainActor
private func webpPlan(_ items: [Int], seconds: Double = 2) -> GalleryMake {
    .slideshow(SlideshowPlan(format: .webp, items: items, photoSeconds: seconds, quality: .med, width: 480))
}

@Suite(.serialized) @MainActor
struct GalleryPipelineTests {
    @Test func aPickerOnAGalleryServerIsSavedWholeWithNoChoice() async throws {
        let h = await savedGallery(.galleryInstagram)
        let p = h.pipeline
        guard case .gallery(let items) = p.state else { Issue.record("\(p.state)"); return }
        #expect(items.count == 10 && items.allSatisfy(\.isPhoto) && items.map(\.id) == Array(0..<10))
        let run = try #require(p.galleryRun)
        #expect(run.phase == .saved && run.total == 10 && run.done == 10 && run.failures.isEmpty && run.make == .none)
        #expect(p.galleryProgress?.done == 10 && p.galleryProgress?.total == 10)
        // the one create asked for every item and said how many it had seen: no `pick…` step, nothing to answer
        #expect(calls(h, "create") == ["items=all count=10 queue=true"])
        #expect(h.kinds.contains("gallery") && !h.kinds.contains("picker"))
        // sizes and thumbs arrived from the library's rows
        #expect(items.allSatisfy { $0.width == 1080 && $0.height == 1350 && $0.thumb != nil })
    }

    @Test func plainCobaltAndOlderForksKeepTheirPicker() async throws {
        let h = Harness(.picker)
        h.pipeline.start(link: URL(string: pastedLink)!)
        await h.driveToSettled()
        if case .picker(let items) = h.pipeline.state { #expect(items.count == 2) } else { Issue.record("\(h.pipeline.state)") }
        #expect(h.pipeline.galleryRun == nil && !h.ctx.capabilities.gallery)
    }

    @Test func theSaveCountsItemsUpToTheTotalNeverBackwards() async throws {
        let h = Harness(.galleryInstagram)
        h.pipeline.start(link: igLink)
        var seen: [Int] = []
        await h.drive(until: {
            if let done = h.pipeline.galleryProgress?.done, seen.last != done { seen.append(done) }
            return h.isTerminalOrReady()
        })
        #expect(seen == seen.sorted() && seen.last == 10 && seen.contains(0), "\(seen)")
        #expect(h.pipeline.galleryProgress?.total == 10)
    }

    @Test func everyItemIsStoredAsOneKeptMediaOfTheSession() async throws {
        let h = await savedGallery(.galleryInstagram)
        let sid = try #require(h.pipeline.sessionID)
        let store = h.app.store
        #expect(store.media.count >= 1)
        let media = try #require(store.media(session: sid))
        #expect(media.isGallery && media.kind == .gallery && media.items.count == 10 && media.original == nil && media.made.isEmpty)
        #expect(media.items.map(\.itemIndex) == (0..<10).map { Optional($0) })
        for item in media.items {
            #expect(item.role == .item && item.kind == .original && item.sessionID == sid && item.keep && item.libraryID == "\(sid)-i\(String(format: "%02d", item.itemIndex ?? 0))")
        }
        // one media, one planet: nothing else of the session
        #expect(store.videos.filter { $0.sessionID == sid }.count == 10)
        #expect(media.renditions.count == 10)
        // and the album sync never takes an item: Photos only on request
        #expect(media.items.allSatisfy { !PhotosSync.isEligible($0, includeWebps: true) })
        #expect(PhotosKey.of(media.items[3]) == "g:\(sid):3")
    }

    @Test func aSaveWithoutKeepingOfflineStoresNothingButStillFinishes() async throws {
        let h = Harness(.galleryInstagram)
        h.ctx.settings.keepVideosOnDevice = false
        h.pipeline.start(link: igLink)
        await h.driveToSettled()
        #expect(h.pipeline.galleryRun?.phase == .saved && h.pipeline.galleryRun?.done == 10)
        #expect(h.app.store.videos.filter { $0.role != nil }.isEmpty)
    }

    @Test func anItemThatCouldNotBeFetchedLeavesTheRestSaved() async throws {
        let h = await savedGallery(.galleryPartial)
        let run = try #require(h.pipeline.galleryRun)
        #expect(run.phase == .saved && run.total == 10 && run.done == 9 && run.kept == 9)
        #expect(run.failures == [6: "error.api.fetch.expired"])
        #expect(h.app.store.videos.filter { $0.role == .item }.count == 9)
        #expect(!h.app.store.videos.contains { $0.itemIndex == 6 })
    }

    @Test func aSinglePhotoIsAGalleryOfOneAndAVideoIsTodaysFlow() async throws {
        let h = await savedGallery(.galleryOne, link: URL(string: "https://x.com/ilokineedsleep/status/2106850389551374807")!)
        guard case .gallery(let items) = h.pipeline.state else { Issue.record("\(h.pipeline.state)"); return }
        #expect(items.count == 1 && h.pipeline.galleryRun?.total == 1 && h.pipeline.galleryRun?.phase == .saved)
        let media = try #require(h.app.store.media(session: h.sid))
        #expect(!media.isGallery && media.items.count == 1)
    }

    // MARK: making

    @Test func aMakeAfterTheSaveIsSentFocusedAndBecomesATab() async throws {
        let h = await savedGallery(.galleryInstagram)
        let p = h.pipeline
        await p.make(webpPlan(Array(0..<10)))
        #expect(p.galleryRun?.make.isActive == true)
        await h.drive(until: { !(p.galleryRun?.make.isActive ?? true) })
        guard case .done(let made, let result)? = p.galleryRun?.make else { Issue.record("\(String(describing: p.galleryRun?.make))"); return }
        #expect(made == webpPlan(Array(0..<10)) && result.format == .webp && result.itemID != nil && result.width == 480 && result.height == 600)
        let sent = calls(h, "slideshow")
        #expect(sent.count == 1 && sent[0].hasPrefix("webp 0,1,2,3,4,5,6,7,8,9 2.0,2.0") && sent[0].contains("focused=true") && sent[0].contains("quality=med width=480"))
        // the file is on the device, as the media's own made file
        let media = try #require(h.app.store.media(session: h.sid))
        #expect(media.made.count == 1)
        let file = media.made[0]
        #expect(file.role == .slideshow && file.kind == .webp && file.libraryID == result.itemID && file.madeFrom == Array(0..<10) && file.keep)
        #expect(file.madeKind == .slideshow(.webp) && media.items.count == 10)
        #expect(!PhotosSync.isEligible(file, includeWebps: true))
        #expect(PhotosKey.of(file) == "m:\(result.itemID!)")
    }

    @Test func aMakeChosenBeforeTheSaveEndsWaitsForItAndIsSentOnce() async throws {
        let h = Harness(.galleryInstagram)
        let p = h.pipeline
        p.start(link: igLink)
        await h.drive(until: { p.galleryRun?.phase == .saving })
        #expect(p.galleryRun?.phase == .saving)
        let plan = webpPlan([0, 1, 2, 3, 4, 5], seconds: 3)
        await p.make(plan)
        #expect(p.galleryRun?.make == .waiting(plan), "held, nothing sent yet")
        #expect(calls(h, "slideshow").isEmpty)
        // asking again while one waits changes nothing
        await p.make(.image(GalleryImagePlan(items: [0, 1], layout: .strip)))
        #expect(p.galleryRun?.make == .waiting(plan))
        await h.drive(until: { if case .done = p.galleryRun?.make ?? .none { return true } else { return false } })
        guard case .done = p.galleryRun?.make ?? .none else { Issue.record("\(String(describing: p.galleryRun?.make))"); return }
        #expect(calls(h, "slideshow").count == 1 && calls(h, "gallery-image").isEmpty)
        // it went out after the save ended, and it carries the plan's own order and seconds
        let order = preview(h).galleries.calls.map(\.name)
        #expect(order.firstIndex(of: "create")! < order.firstIndex(of: "slideshow")!)
        #expect(calls(h, "slideshow")[0].contains("webp 0,1,2,3,4,5 3.0,3.0,3.0,3.0,3.0,3.0"))
    }

    @Test func aRemakeReplacesTheFileAndADifferentLayoutDoesNot() async throws {
        let h = await savedGallery(.galleryInstagram)
        let p = h.pipeline
        func make(_ m: GalleryMake) async -> MadeResult? {
            await p.make(m)
            await h.drive(until: { !(p.galleryRun?.make.isActive ?? true) })
            if case .done(_, let r)? = p.galleryRun?.make { return r }
            return nil
        }
        let first = try #require(await make(webpPlan(Array(0..<10))))
        #expect(first.replaced.isEmpty)
        let second = try #require(await make(webpPlan(Array(0..<10), seconds: 3)))
        #expect(second.replaced == [first.itemID!], "the server names what it replaced")
        let sid = try #require(p.sessionID)
        var media = try #require(h.app.store.media(session: sid))
        #expect(media.made.count == 1 && media.made[0].libraryID == second.itemID, "one slideshow webp, the new one")
        // an mp4 is another format; a gallery image another kind; each layout is its own
        _ = try #require(await make(.slideshow(SlideshowPlan(format: .mp4, items: [0, 1, 2]))))
        let grid = try #require(await make(.image(GalleryImagePlan(items: Array(0..<10), layout: .grid3))))
        let strip = try #require(await make(.image(GalleryImagePlan(items: Array(0..<10), layout: .strip))))
        #expect(grid.replaced.isEmpty && strip.replaced.isEmpty)
        media = try #require(h.app.store.media(session: sid))
        let kinds = Set(media.made.compactMap(\.madeKind))
        #expect(kinds == [.slideshow(.webp), .slideshow(.mp4), .galleryImage(.grid3), .galleryImage(.strip)] && media.made.count == 4)
        let again = try #require(await make(.image(GalleryImagePlan(items: Array(0..<10), layout: .grid3))))
        #expect(again.replaced == [grid.itemID!])
        #expect(try #require(h.app.store.media(session: sid)).made(.galleryImage(.grid3)).map(\.libraryID) == [again.itemID])
        // the gallery image drew from the photos' real geometry
        #expect(grid.width == 2160 && grid.height == 4500 && strip.width == 1080 && strip.height == 13500)
    }

    @Test func aMakeThatFailsKeepsEverythingAndTheNextOneWorks() async throws {
        let h = await savedGallery(.galleryMakeFails)
        let p = h.pipeline
        await p.make(webpPlan([0, 1, 2]))
        await h.drive(until: { !(p.galleryRun?.make.isActive ?? true) })
        guard case .failed(_, let failure)? = p.galleryRun?.make else { Issue.record("\(String(describing: p.galleryRun?.make))"); return }
        #expect(failure == .server(code: "render.error.webp.encode_failed"))
        #expect(p.galleryRun?.phase == .saved && p.galleryRun?.done == 10, "the photos are untouched")
        #expect(h.app.store.media(session: p.sessionID ?? "")?.made.isEmpty == true)
        await p.make(webpPlan([0, 1, 2]))
        await h.drive(until: { !(p.galleryRun?.make.isActive ?? true) })
        if case .done = p.galleryRun?.make ?? .none {} else { Issue.record("\(String(describing: p.galleryRun?.make))") }
    }

    @Test func thePlansCapsAreRefusedBeforeAnythingIsSent() async throws {
        let h = await savedGallery(.galleryInstagram)
        let app = h.app
        let local = try #require(app.store.media(session: h.sid))
        await app.library.refresh()
        let item = app.mediaItem(for: local)
        let tooLong = GalleryMake.slideshow(SlideshowPlan(format: .webp, items: Array(0..<10), photoSeconds: 10))
        await #expect(throws: PipelineFailure.server(code: "error.webp.too_long")) { try await app.make(tooLong, from: item) }
        await #expect(throws: PipelineFailure.server(code: "error.studio.not_gallery")) {
            try await app.make(.slideshow(SlideshowPlan(format: .mp4, items: [0])), from: item)
        }
        #expect(calls(h, "slideshow").isEmpty)
    }

    @Test func aServerThatCannotMakeSaysSoAndTheSaveStillWorks() async throws {
        let h = await savedGallery(.galleryNoMake)
        #expect(h.ctx.capabilities.gallery && !h.ctx.capabilities.galleryMake && h.pipeline.galleryRun?.phase == .saved)
        await h.app.library.refresh()
        let local = try #require(h.app.store.media(session: h.sid))
        await #expect(throws: PipelineFailure.unsupported) { try await h.app.make(webpPlan([0, 1]), from: h.app.mediaItem(for: local)) }
    }

    // MARK: the media as the detail sees it

    @Test func theLibraryAndTheDeviceAreOneMediaWithItsItemsAndMadeTabs() async throws {
        let h = await savedGallery(.galleryInstagram)
        let app = h.app
        let p = h.pipeline
        await p.make(.image(GalleryImagePlan(items: Array(0..<10), layout: .grid3)))
        await h.drive(until: { !(p.galleryRun?.make.isActive ?? true) })
        await app.library.refresh()
        let sid = try #require(p.sessionID)
        let post = try #require(app.library.posts.first { $0.id == sid })
        #expect(post.kind == .gallery && post.itemCount == 10)
        let item = app.mediaItem(for: post)
        #expect(item.local != nil && item.kind == .gallery && item.itemCount == 10 && item.video == nil && item.webps.isEmpty)
        #expect(item.items.count == 10 && item.items.allSatisfy { $0.local != nil && $0.file != nil && $0.isItem })
        #expect(item.items.map(\.itemIndex) == (0..<10).map { Optional($0) } && item.items.allSatisfy { $0.itemType == .photo })
        #expect(item.made.count == 1)
        let tab = try #require(item.made.first)
        #expect(tab.madeKind == .galleryImage(.grid3) && tab.local != nil && tab.file != nil && tab.tabName == "gallery image · 3 across")
        // the tabs: items first, then what was made; the face of a media with nothing animated is its first item
        #expect(item.renditions.map(\.isItem) == Array(repeating: true, count: 10) + [false])
        #expect(item.face.itemIndex == 0)
        // the same media from the device side joins the same post
        #expect(app.mediaItem(for: try #require(app.store.media(session: sid))).id == item.id)
        #expect(item.title == .post(service: "instagram", ref: "Ddy0-gpGg5U"))
        #expect(item.titleText == "instagram · Ddy0-gpGg5U")
    }

    @Test func aMakeFromTheDetailOfASavedPostIsAJobOfTheQueue() async throws {
        let h = await savedGallery(.galleryInstagram)
        let app = h.app
        let sid = try #require(h.pipeline.sessionID)
        // the owner closes the focus and the finished job goes
        let job = try #require(app.queue.galleryJob(session: sid))
        app.queue.dismiss(job.id)
        #expect(app.queue.galleryJob(session: sid) == nil)
        await app.library.refresh()
        let item = app.mediaItem(for: try #require(app.library.posts.first { $0.id == sid }))
        try await app.make(.slideshow(SlideshowPlan(format: .mp4, items: [4, 2, 0], photoSeconds: 1.5)), from: item)
        let made = try #require(app.queue.jobs.last)
        #expect(made.via == .make && made.isLive && made.pipeline.sessionID == sid && made.pipeline.galleryRun?.phase == .saved)
        // it never takes the focus
        #expect(app.queue.focusedID != made.id)
        await h.drive(until: { app.queue.jobs.contains { $0.id == made.id && !$0.isLive } })
        guard case .done(_, let result)? = made.pipeline.galleryRun?.make else { Issue.record("\(String(describing: made.pipeline.galleryRun?.make))"); return }
        #expect(result.format == .mp4 && result.seconds == 4.5)
        let sent = calls(h, "slideshow")
        #expect(sent.count == 1 && sent[0].hasPrefix("mp4 4,2,0 1.5,1.5,1.5") && sent[0].contains("focused=true"))
        #expect(made.isFinished)
        // the file lands on this device and the media shows it as a tab
        let after = app.mediaItem(for: try #require(app.library.posts.first { $0.id == sid }))
        #expect(after.made.count == 1 && after.made[0].local != nil && after.made[0].tabName == "slideshow")
    }

    @Test func anExpiredSessionCannotBeMadeFrom() async throws {
        let h = await savedGallery(.galleryInstagram)
        let app = h.app
        let sid = try #require(h.pipeline.sessionID)
        app.queue.dismiss(try #require(app.queue.galleryJob(session: sid)).id)
        await app.library.refresh()
        var post = try #require(app.library.posts.first { $0.id == sid })
        post.session = nil                                    // the library lists no open session any more
        let item = app.mediaItem(for: post)
        await #expect(throws: PipelineFailure.expired) { try await app.make(webpPlan([0, 1]), from: item) }
    }

    // MARK: deleting, switching, linking

    @Test func deletingItemsGoesToTheServerAndTheDeviceAndTheLastOneIsRefused() async throws {
        let h = await savedGallery(.galleryInstagram)
        let app = h.app
        let sid = try #require(h.pipeline.sessionID)
        await app.library.refresh()
        var item = app.mediaItem(for: try #require(app.library.posts.first { $0.id == sid }))
        try await driven(h) { try await app.deleteItems([2, 5], of: item) }
        #expect(calls(h, "delete") == ["\(sid)-i02", "\(sid)-i05"])
        await app.library.refresh()
        item = app.mediaItem(for: try #require(app.library.posts.first { $0.id == sid }))
        #expect(item.items.map(\.itemIndex) == [0, 1, 3, 4, 6, 7, 8, 9].map { Optional($0) })
        #expect(app.store.media(session: sid)?.items.count == 8 && app.store.media(session: sid)?.isGallery == true)
        // the last one is refused: that is "delete everything"
        let all = item.items.compactMap(\.itemIndex)
        await #expect(throws: PipelineFailure.server(code: "error.library.last_item")) { try await app.deleteItems(all, of: item) }
        #expect(app.store.media(session: sid)?.items.count == 8, "nothing went")
        try await driven(h) { try await app.deleteItems([0, 1, 3, 4, 6, 7, 8], of: item) }
        await app.library.refresh()
        item = app.mediaItem(for: try #require(app.library.posts.first { $0.id == sid }))
        #expect(item.items.map(\.itemIndex) == [9])
        await #expect(throws: PipelineFailure.server(code: "error.library.last_item")) { try await app.deleteItems([9], of: item) }
    }

    @Test func deletingAMadeFileLeavesTheItems() async throws {
        let h = await savedGallery(.galleryInstagram)
        let app = h.app
        let p = h.pipeline
        await p.make(webpPlan(Array(0..<10)))
        await h.drive(until: { !(p.galleryRun?.make.isActive ?? true) })
        let sid = try #require(p.sessionID)
        await app.library.refresh()
        let item = app.mediaItem(for: try #require(app.library.posts.first { $0.id == sid }))
        let tab = try #require(item.made.first)
        try await driven(h) { try await app.deleteMade(tab, of: item) }
        #expect(app.store.media(session: sid)?.made.isEmpty == true && app.store.media(session: sid)?.items.count == 10)
        await #expect(throws: PipelineFailure.unsupported) { try await app.deleteMade(item.items[0], of: item) }
    }

    @Test func theWholePostSwitchesPrivateAndPublicAndItsLinksAreCopied() async throws {
        let h = await savedGallery(.galleryInstagram)
        let app = h.app
        let sid = try #require(h.pipeline.sessionID)
        await app.library.refresh()
        var item = app.mediaItem(for: try #require(app.library.posts.first { $0.id == sid }))
        // saves are public by default (the app's setting), so every item has a link
        var links = app.copyAllLinks(item).split(separator: "\n")
        #expect(links.count == 10 && links.allSatisfy { $0.hasPrefix("https://media.capybaraharmony.com/") })
        _ = try await driven(h) { try await app.setPublic(false, for: item) }
        #expect(calls(h, "visibility") == ["private post"])
        item = app.mediaItem(for: try #require(app.library.posts.first { $0.id == sid }))
        let stillPublic = item.items.contains { $0.isPublic }
        #expect(!stillPublic && app.copyAllLinks(item).isEmpty, "private: no links")
        _ = try await driven(h) { try await app.setPublic(true, for: item) }
        item = app.mediaItem(for: try #require(app.library.posts.first { $0.id == sid }))
        let allPublic = item.items.allSatisfy { $0.isPublic }
        #expect(allPublic)
        links = app.copyAllLinks(item).split(separator: "\n")
        #expect(links.count == 10)
    }

    @Test func aMissingItemIsRetriedAndLandsOnTheDevice() async throws {
        let h = await savedGallery(.galleryPartial)
        let app = h.app
        let sid = try #require(h.pipeline.sessionID)
        app.queue.dismiss(try #require(app.queue.galleryJob(session: sid)).id)
        await app.library.refresh()
        var item = app.mediaItem(for: try #require(app.library.posts.first { $0.id == sid }))
        #expect(item.missing == [6] && item.items.count == 9 && item.itemCount == 9)
        try await app.retryMissing(item)
        let job = try #require(app.queue.jobs.last)
        await h.drive(until: { app.queue.jobs.contains { $0.id == job.id && !$0.isLive } })
        #expect(calls(h, "retry") == ["6"])
        #expect(job.pipeline.galleryRun?.phase == .saved && job.pipeline.galleryRun?.failures.isEmpty == true)
        #expect(app.store.media(session: sid)?.items.count == 10 && app.store.videos.contains { $0.itemIndex == 6 })
        await app.library.refresh()
        item = app.mediaItem(for: try #require(app.library.posts.first { $0.id == sid }))
        #expect(item.missing.isEmpty && item.items.count == 10)
    }

    @Test func aVideoItemMakesItsOwnWebpAndAPhotoCannot() async throws {
        let h = await savedGallery(.galleryMixed, link: URL(string: "https://www.instagram.com/p/DdMix1xedPo/")!)
        let app = h.app
        let sid = try #require(h.pipeline.sessionID)
        app.queue.dismiss(try #require(app.queue.galleryJob(session: sid)).id)
        await app.library.refresh()
        let item = app.mediaItem(for: try #require(app.library.posts.first { $0.id == sid }))
        #expect(item.items.map(\.itemType) == [.photo, .photo, .video, .gif])
        #expect(!app.makeWebp(for: item, itemIndex: 0), "a photo has no webp button")
        #expect(!app.makeWebp(for: item, itemIndex: 9))
        #expect(app.makeWebp(for: item, itemIndex: 2))
        let p = app.pipeline
        await h.drive(until: { p.state == .ready })
        #expect(p.state == .ready && p.sessionID == sid && p.targetMediaID == item.local?.id)
        p.makeWebp()
        await h.drive(until: { if case .done = p.state { return true } else { return false } })
        guard case .done = p.state else { Issue.record("\(p.state)"); return }
        #expect(calls(h, "render") == ["item=2"], "the render names the item; a lead render names none")
        let media = try #require(app.store.media(session: sid))
        #expect(media.items.count == 4 && media.webps.count == 1 && media.webps[0].madeFrom == [2])
        let leaf = FolderNaming.fileName(for: media.webps[0], in: media)
        #expect(leaf == "03 · webp 1.webp")
        // it is a webp of the gallery's video: a tab after the items, and the photo's pipeline never sees it
        let after = app.mediaItem(for: media)
        #expect(after.webps.count == 1 && after.items.count == 4 && after.video == nil)
    }

    @Test func aBatchPasteSavesAGalleryWholeWithoutLookingFirst() async throws {
        let h = Harness(.galleryInstagram)
        let app = h.app
        let jobs = app.queue.add([.link(igLink), .link(xLink)], via: .paste)
        #expect(jobs.count == 2)
        await h.drive(until: { jobs.allSatisfy { !$0.isLive } })
        for job in jobs {
            guard case .gallery = job.pipeline.state else { Issue.record("\(job.pipeline.state)"); continue }
            #expect(job.pipeline.galleryRun?.phase == .saved && job.isFinished)
        }
        // no resolve first, and every create asked for everything
        #expect(calls(h, "create").allSatisfy { $0.hasPrefix("items=all count=- ") })
        #expect(!preview(h).server.lineCalls.contains("POST /"))
    }

    @Test func aGalleryJobIsLiveWhileItSavesAndFinishedAfter() async throws {
        let h = Harness(.galleryInstagram)
        let app = h.app
        let job = try #require(app.queue.add([.link(igLink)], via: .paste).first)
        await h.drive(until: { job.pipeline.galleryRun?.phase == .saving })
        #expect(job.isLive && !job.isFinished && !job.isFailed)
        await h.drive(until: { !(app.queue.job(job.id)?.isLive ?? false) })
        let done = try #require(app.queue.job(job.id))
        #expect(done.isFinished && !done.isLive && done.finishedAt != nil)
        #expect(app.queue.summary == JobSummary(live: 0, waiting: 0, finished: 1, failed: 0))
    }
}

@Suite(.serialized) @MainActor
struct GalleryJobOptionTests {
    private func run(_ handling: GalleryHandling?, _ scenario: PreviewScenario = .galleryInstagram) async -> Harness {
        let h = Harness(scenario)
        let job = h.app.queue.add([.link(igLink)], via: .shortcut, options: JobOptions(galleries: handling)).first
        await h.drive(until: { job.map { j in h.app.queue.job(j.id).map { !$0.isLive } ?? true } ?? true })
        return h
    }

    @Test func aShortcutThatAsksForASlideshowWebpGetsOneBehindTheSave() async throws {
        let h = await run(.slideshowWebp)
        let job = try #require(h.app.queue.jobs.first)
        await h.drive(until: { !(job.pipeline.galleryRun?.make.isActive ?? false) && job.pipeline.galleryRun?.make != GalleryRun.Make.none })
        guard case .done(.slideshow(let plan), let result)? = job.pipeline.galleryRun?.make else {
            Issue.record("\(String(describing: job.pipeline.galleryRun?.make))"); return
        }
        #expect(plan.format == .webp && plan.items == Array(0..<10) && plan.photoSeconds == 2 && plan.fade && result.format == .webp)
        #expect(calls(h, "create") == ["items=all count=- queue=true"], "no resolve first: a Shortcut goes straight in")
    }

    @Test func aShortcutThatAsksForAGalleryImageGetsItsLayout() async throws {
        let h = await run(.galleryImage(.strip))
        let job = try #require(h.app.queue.jobs.first)
        await h.drive(until: { if case .done = job.pipeline.galleryRun?.make ?? .none { return true } else { return false } })
        guard case .done(.image(let plan), let result)? = job.pipeline.galleryRun?.make else {
            Issue.record("\(String(describing: job.pipeline.galleryRun?.make))"); return
        }
        #expect(plan.layout == .strip && plan.items == Array(0..<10) && result.width == 1080 && result.height == 13500)
    }

    @Test func aMakeThatCannotBeMadeIsSaidNotSent() async throws {
        // 4 photos 3 s... no: a mixed post has two photos, and a gallery image needs two: it can be made; one photo cannot
        let h = Harness(.galleryOne)
        let job = h.app.queue.add([.link(igLink)], via: .shortcut, options: JobOptions(galleries: .galleryImage(.grid3))).first
        await h.drive(until: { job.map { j in h.app.queue.job(j.id).map { !$0.isLive } ?? true } ?? true })
        let state = h.app.queue.jobs.first?.pipeline.galleryRun?.make
        if case .failed(_, let failure)? = state { #expect(failure == .server(code: "render.error.studio.too_few_photos")) } else { Issue.record("\(String(describing: state))") }
        #expect(calls(h, "gallery-image").isEmpty)
    }

    @Test func firstVideoOnlyAsksTheServerForTodaysRule() async throws {
        let h = await run(.firstVideo, .galleryMixed)
        #expect(calls(h, "create") == ["items=first-video count=- queue=true"])
    }

    @Test func aLedgerEntryFromBeforeGalleriesStillDecodes() throws {
        let old = Data(#"{"title":"t","makePublic":true}"#.utf8)
        let options = try JSONDecoder().decode(JobOptions.self, from: old)
        #expect(options == JobOptions(title: "t", makePublic: true) && options.galleries == nil)
        let round = try JSONDecoder().decode(JobOptions.self, from: JSONEncoder().encode(JobOptions(galleries: .galleryImage(.row))))
        #expect(round.galleries == .galleryImage(.row))
    }
}

@Suite(.serialized) @MainActor
struct GalleryStoreTests {
    private func store() throws -> (OfflineStore, URL) {
        let dir = try makeTempDirectory()
        let store = OfflineStore(
            root: dir.appendingPathComponent("Videos"), tools: PreviewMediaTools(clock: SystemClock(), clip: PreviewData.long),
            defaults: UserDefaults(suiteName: "gallery-store-\(UUID().uuidString)")!, visibleRoot: dir.appendingPathComponent("Documents"))
        try? FileManager.default.createDirectory(at: dir.appendingPathComponent("Documents"), withIntermediateDirectories: true)
        return (store, dir)
    }

    private func file(_ dir: URL, _ name: String) throws -> URL {
        let url = dir.appendingPathComponent(UUID().uuidString.prefix(6) + name)
        try PreviewMedia.placeholderBytes.write(to: url)
        return url
    }

    private func add(
        _ store: OfflineStore, _ dir: URL, ext: String = "jpg", session: String, kind: StoredVideo.Kind = .original,
        role: GalleryRole? = nil, index: Int? = nil, library: String? = nil, title: String? = nil, from: [Int]? = nil, spec: String? = nil
    ) async throws -> StoredVideo {
        try await store.add(
            file: try file(dir, "x.\(ext)"), kind: kind, media: MediaInfo(name: "n", duration: nil, width: 4, height: 5, bytes: nil, isImage: ext != "mp4"),
            sessionID: session, link: URL(string: "https://www.instagram.com/p/Ddy0-gpGg5U/"), remoteURL: nil, move: true, keep: true,
            role: role, itemIndex: index, madeFrom: from, madeSpec: spec.map { Data($0.utf8) }, libraryID: library)
    }

    @Test func itemsOfOneSessionJoinOneMediaOneToAnIndex() async throws {
        let (store, dir) = try store()
        for i in [2, 0, 1] { _ = try await add(store, dir, session: "S1", role: .item, index: i, library: "r\(i)") }
        #expect(store.media.count == 1)
        let media = try #require(store.media.first)
        #expect(media.items.map(\.itemIndex) == [0, 1, 2], "in the post's order, whatever order they landed in")
        #expect(media.isGallery && media.kind == .gallery && media.original == nil)
        // the same item twice is the same item (a retry, a second path): never a second record
        let again = try await add(store, dir, session: "S1", role: .item, index: 1, library: "r1")
        #expect(store.media.first?.items.count == 3 && again.id == media.items[1].id)
        // an item of another session is another media
        _ = try await add(store, dir, session: "S2", role: .item, index: 0, library: "z0")
        #expect(store.media.count == 2)
    }

    @Test func madeFilesJoinTheirMediaByRoleAndNeverBecomeItsOriginal() async throws {
        let (store, dir) = try store()
        for i in 0..<3 { _ = try await add(store, dir, session: "S1", role: .item, index: i, library: "r\(i)") }
        let webp = try await add(store, dir, ext: "webp", session: "S1", kind: .webp, role: .slideshow, library: "m1", from: [0, 1, 2], spec: #"{"format":"webp"}"#)
        let mp4 = try await add(store, dir, ext: "mp4", session: "S1", role: .slideshow, library: "m2", from: [0, 1], spec: #"{"format":"mp4"}"#)
        let image = try await add(store, dir, session: "S1", role: .export, library: "m3", from: [0, 1, 2], spec: #"{"kind":"gallery","layout":"grid3","items":[0,1,2]}"#)
        #expect(store.media.count == 1)
        let media = try #require(store.media.first)
        #expect(media.made.count == 3 && media.original == nil && media.webps.isEmpty && media.items.count == 3)
        #expect(media.made(.slideshow(.webp)).map(\.id) == [webp.id] && media.made(.slideshow(.mp4)).map(\.id) == [mp4.id])
        #expect(media.made(.galleryImage(.grid3)).map(\.id) == [image.id])
        #expect(media.renditions.count == 6)
        // the same library row is the same file
        let dup = try await add(store, dir, ext: "webp", session: "S1", kind: .webp, role: .slideshow, library: "m1")
        #expect(dup.id == webp.id && store.media.first?.made.count == 3)
        // the planet shows the newest animated file, else the newest made video, else the first item
        #expect(media.face.id == webp.id || media.face.kind == .webp)
        // a record of the old kind is untouched: a plain original and a webp of it still make a plain media
        _ = try await add(store, dir, ext: "mp4", session: "P1")
        _ = try await add(store, dir, ext: "webp", session: "P1", kind: .webp)
        let plain = try #require(store.media(session: "P1"))
        #expect(plain.original != nil && plain.items.isEmpty && plain.made.isEmpty && plain.webps.count == 1 && !plain.isGallery && plain.kind == .video)
    }

    @Test func theKindOfAMediaIsWhatItHolds() async throws {
        let (store, dir) = try store()
        _ = try await add(store, dir, ext: "jpg", session: "P1")
        #expect(store.media(session: "P1")?.kind == .photo)
        _ = try await add(store, dir, ext: "mp4", session: "V1")
        #expect(store.media(session: "V1")?.kind == .video)
        _ = try await add(store, dir, ext: "webp", session: "W1", kind: .webp)
        #expect(store.media(session: "W1")?.kind == .webp)
    }

    @Test func theFolderNamesOfASavedGalleryAreTheContractsAndAKeptGalleryIsOneFolder() async throws {
        let (store, dir) = try store()
        let root = try #require(store.visibleRoot)
        var items: [StoredVideo] = []
        for i in [0, 1, 2] { items.append(try await add(store, dir, session: "S1", role: .item, index: i, library: "r\(i)")) }
        // a video item and a webp of it, a slideshow of each format, a gallery image
        let video = try await add(store, dir, ext: "mp4", session: "S1", role: .item, index: 3, library: "r3")
        let webp = try await add(store, dir, ext: "webp", session: "S1", kind: .webp, library: nil, from: [3])
        let sw = try await add(store, dir, ext: "webp", session: "S1", kind: .webp, role: .slideshow, library: "m1", spec: #"{"format":"webp"}"#)
        let sm = try await add(store, dir, ext: "mp4", session: "S1", role: .slideshow, library: "m2", spec: #"{"format":"mp4"}"#)
        let gi = try await add(store, dir, session: "S1", role: .export, library: "m3", spec: #"{"kind":"gallery","layout":"grid3","items":[0,1]}"#)
        await store.reload()
        let media = try #require(store.media.first)
        func leaf(_ v: StoredVideo) -> String { FolderNaming.fileName(for: store.videos.first { $0.id == v.id }!, in: media) }
        #expect(leaf(items[0]) == "01.jpg" && leaf(items[2]) == "03.jpg" && leaf(video) == "04.mp4")
        #expect(leaf(webp) == "04 · webp 1.webp")
        #expect(leaf(sw) == "slideshow.webp" && leaf(sm) == "slideshow.mp4" && leaf(gi) == "gallery image · 3 across.jpg")
        let placement = FolderNaming.placement(for: try #require(store.videos.first { $0.id == items[1].id }), in: media)
        #expect(placement == FolderNaming.Placement(folder: "instagram · Ddy0-gpGg5U", name: "02.jpg"))
        // every kept file is in the one folder, tagged with its media; the Files path says so
        let paths = store.videos.compactMap { v in store.records.first { $0.id == v.id }?.visiblePath }
        #expect(paths.count == 8)
        let folders = Set(paths.map { ($0 as NSString).deletingLastPathComponent })
        #expect(folders == ["instagram · Ddy0-gpGg5U"], "\(paths)")
        #expect(Set(paths.map { ($0 as NSString).lastPathComponent }) == ["01.jpg", "02.jpg", "03.jpg", "04.mp4", "04 · webp 1.webp", "slideshow.webp", "slideshow.mp4", "gallery image · 3 across.jpg"])
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("instagram · Ddy0-gpGg5U/01.jpg").path))
        // a plain kept video is flat, as before
        let plain = try await add(store, dir, ext: "mp4", session: "P1")
        await store.reload()
        let flat = try #require(store.records.first { $0.id == plain.id }?.visiblePath)
        #expect(!flat.contains("/"))
    }

    @Test func aRemakeFreesTheNameSoTheNewFileTakesIt() async throws {
        let (store, dir) = try store()
        for i in 0..<2 { _ = try await add(store, dir, session: "S1", role: .item, index: i, library: "r\(i)") }
        let first = try await add(store, dir, ext: "webp", session: "S1", kind: .webp, role: .slideshow, library: "m1", spec: #"{"format":"webp"}"#)
        await store.reload()
        #expect(store.records.first { $0.id == first.id }?.visiblePath == "instagram · Ddy0-gpGg5U/slideshow.webp")
        // what `Pipeline.finishMake` does: the old record goes (with its Files copy), then the new one is added
        await store.remove(first.id)
        let second = try await add(store, dir, ext: "webp", session: "S1", kind: .webp, role: .slideshow, library: "m4", spec: #"{"format":"webp"}"#)
        await store.reload()
        #expect(store.records.first { $0.id == second.id }?.visiblePath == "instagram · Ddy0-gpGg5U/slideshow.webp", "never `slideshow (2).webp`")
    }

    @Test func theFolderGoesWithItsLastFile() async throws {
        let (store, dir) = try store()
        let root = try #require(store.visibleRoot)
        let a = try await add(store, dir, session: "S1", role: .item, index: 0, library: "r0")
        let b = try await add(store, dir, session: "S1", role: .item, index: 1, library: "r1")
        let folder = root.appendingPathComponent("instagram · Ddy0-gpGg5U")
        #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent("01.jpg").path))
        await store.remove(a.id)
        #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent("02.jpg").path), "the folder stays while a file is in it")
        await store.remove(b.id)
        #expect(!FileManager.default.fileExists(atPath: folder.path), "the last file takes the folder along")
    }

    @Test func aFolderWithTheOwnersFileInItStays() async throws {
        let (store, dir) = try store()
        let root = try #require(store.visibleRoot)
        let a = try await add(store, dir, session: "S1", role: .item, index: 0, library: "r0")
        let folder = root.appendingPathComponent("instagram · Ddy0-gpGg5U")
        let mine = folder.appendingPathComponent("my notes.txt")
        try Data("hi".utf8).write(to: mine)
        await store.remove(a.id)
        #expect(FileManager.default.fileExists(atPath: mine.path), "never the owner's own file")
        #expect(FileManager.default.fileExists(atPath: folder.path))
        // and a folder the owner made (no tag of ours) is never removed, even when empty
        let theirs = root.appendingPathComponent("holiday")
        try FileManager.default.createDirectory(at: theirs, withIntermediateDirectories: true)
        OfflineFolder.removeEmptyGalleryFolder(theirs)
        #expect(FileManager.default.fileExists(atPath: theirs.path))
    }

    @Test func aGalleryRecordSurvivesTheIndexAndTheVisibleTag() async throws {
        let (store, dir) = try store()
        let item = try await add(store, dir, session: "S1", role: .item, index: 4, library: "r4", from: [4], spec: #"{"k":1}"#)
        await store.reload()
        let reopened = OfflineStore(root: store.root, tools: PreviewMediaTools(clock: SystemClock(), clip: PreviewData.long), visibleRoot: store.visibleRoot)
        let back = try #require(reopened.videos.first { $0.id == item.id })
        #expect(back.role == .item && back.itemIndex == 4 && back.libraryID == "r4" && back.madeFrom == [4] && back.madeSpec == Data(#"{"k":1}"#.utf8))
        // an index written before galleries decodes with none of them
        let old = Data(#"{"id":"a","kind":"original","name":"n","bytes":1,"createdAt":0}"#.utf8)
        let decoded = try JSONDecoder().decode(StoredVideo.self, from: old)
        #expect(decoded.role == nil && decoded.itemIndex == nil && decoded.libraryID == nil && decoded.madeSpec == nil)
    }
}
