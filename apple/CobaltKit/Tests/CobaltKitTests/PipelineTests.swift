import Foundation
import Testing
@testable import CobaltKit

let pastedLink = "https://www.instagram.com/reel/Dd7P496wolG/"
let shortLink = "https://x.com/i/status/2105435404002562056"

@MainActor
@Suite(.serialized)
struct PipelineStateMachineTests {
    // MARK: happy path, long clip

    @Test func happyLongClipRunsEveryStageInOrder() async throws {
        let h = Harness(.happy)
        let p = h.pipeline
        p.start(pastedText: "look at this \(pastedLink) wow")
        #expect(p.state == .fetching(since: h.clock.epoch, waking: false))
        #expect(p.rail.steps == [.fetch, .save, .read, .webp])
        #expect(p.rail.index == 0)

        await h.driveToSettled()
        #expect(p.state == .ready)
        #expect(isSubsequence(["fetching", "saving", "reading", "ready"], of: h.kinds))
        #expect(!h.kinds.contains("fetching(waking)"))

        // read: nine real frames, one per 150 ms
        #expect(p.frames.compactMap { $0 }.count == Pipeline.frameCount)
        #expect(p.media?.duration == 14.77)
        #expect(p.media?.width == 720 && p.media?.height == 1280)
        #expect(p.media?.name == "instagram_Dd7P496wolG")
        #expect(p.rail.index == 3)

        // a clip over 10 s starts with a 10 s bracket, and is not an error
        #expect(p.trim == TrimRange(start: 0, end: 10))
        #expect(!p.trimOverLimit)
        #expect(p.sessionID != nil)

        // make the webp: decode counts real frames (150 = 10 s × 15 fps), then pack, then done
        p.makeWebp()
        await h.driveToSettled()
        guard case .done(let result) = p.state else {
            Issue.record("expected .done, got \(p.state)")
            return
        }
        #expect(isSubsequence(["rendering.working", "rendering.decoding", "rendering.packing", "done"], of: h.kinds))
        let totals = h.log.compactMap { s -> Int? in
            if case .rendering(.decoding(_, let total)) = s { return total }
            return nil
        }
        #expect(Set(totals) == [150])
        let dones = h.log.compactMap { s -> Int? in
            if case .rendering(.decoding(let done, _)) = s { return done }
            return nil
        }
        #expect(dones == dones.sorted() && dones.last ?? 0 > 100)

        #expect(result.width == 480 && result.height == 854)
        #expect(result.seconds == 10.1)
        #expect(Format.bytes(result.bytes) == "4.5 MB")
        #expect(result.url.absoluteString == "https://media.capybaraharmony.com/PrEvIeW001.webp")
        #expect(p.result == result)
        #expect(p.rail.finished)
        #expect(!p.litFrames.isEmpty)

        // the webp joined the orbit (`.happy` seeds the clip's own webp link, so the render fills that record)
        #expect(h.app.store.videos.first?.kind == .webp)
        #expect(h.app.store.videos.contains { $0.kind == .webp && $0.remoteURL == result.url && $0.sessionID == p.sessionID })

        // and the link copies
        p.copyResultLink()
        #expect(h.clipboard.last == result.url.absoluteString)
    }

    @Test func renderTakesTheLabsFourPointSevenSeconds() async throws {
        let h = Harness(.happy)
        h.pipeline.start(link: URL(string: pastedLink)!)
        await h.driveToSettled()
        let t0 = h.clock.elapsed
        h.pipeline.makeWebp()
        await h.drive { if case .done = h.pipeline.state { return true } else { return false } }
        let took = h.clock.elapsed - t0
        #expect(took >= 4.6 && took <= 4.95, "render took \(took) virtual seconds")
    }

    // MARK: short clip

    @Test func shortClipFitsWithoutATrim() async throws {
        let h = Harness(.shortClip)
        let p = h.pipeline
        p.start(link: URL(string: shortLink)!)
        await h.driveToSettled()
        #expect(p.state == .ready)
        #expect(p.media?.name == "twitter_2105435404002562056")
        #expect(p.media?.duration == 5.46)
        #expect(p.trim == TrimRange(start: 0, end: 5.46))
        #expect(!p.trimOverLimit)

        p.makeWebp()
        await h.driveToSettled()
        guard case .done(let r) = p.state else { Issue.record("expected .done, got \(p.state)"); return }
        #expect(r.seconds == 5.4 && Format.bytes(r.bytes) == "841 KB")
        let totals = h.log.compactMap { s -> Int? in
            if case .rendering(.decoding(_, let total)) = s { return total }
            return nil
        }
        #expect(Set(totals) == [82])   // round(5.46 × 15)
    }

    // MARK: cold start

    @Test func coldStartSaysWakingAfterOneAndAHalfSeconds() async throws {
        let h = Harness(.coldStart)
        let p = h.pipeline
        p.start(link: URL(string: pastedLink)!)
        let t0 = h.clock.elapsed
        await h.drive { if case .fetching(_, true) = p.state { return true } else { return false } }
        #expect(h.clock.elapsed - t0 >= 1.5 && h.clock.elapsed - t0 < 2.0)
        await h.driveToSettled()
        #expect(p.state == .ready)
        #expect(isSubsequence(["fetching", "fetching(waking)", "saving", "reading", "ready"], of: h.kinds))
        #expect(h.clock.elapsed >= 4.2 + 0.9)   // fetch 4.2 s, then the save
    }

    // MARK: errors

    @Test func noLinkInThePasteboard() {
        let h = Harness(.noLink)
        h.pipeline.start(pastedText: "nothing to see here")
        #expect(h.pipeline.state == .failed(.noLink))
        h.pipeline.start(pastedText: nil)
        #expect(h.pipeline.state == .failed(.noLink))
        h.pipeline.start(pastedText: "ftp://example.com/x.mp4")
        #expect(h.pipeline.state == .failed(.noLink))
        #expect(!PipelineFailure.noLink.keepsTrim)
    }

    @Test func privatePostCannotBeFetched() async throws {
        let h = Harness(.privatePost)
        h.pipeline.start(link: URL(string: pastedLink)!)
        await h.driveToSettled()
        #expect(h.pipeline.state == .failed(.fetchFailed(code: "error.api.fetch.empty")))
        #expect(!(PipelineFailure.fetchFailed(code: "x").keepsTrim))
        #expect(h.clock.elapsed >= 1.5)
    }

    @Test func fileOverTheLimitFailsBeforeAnyUpload() throws {
        let h = Harness(.tooBig)
        let file = try makeTempFile("big.mov")
        h.pipeline.start(file: file)
        #expect(h.pipeline.state == .failed(.tooLarge(limit: 100_000_000)))
        #expect(!h.kinds.contains("uploading"))
        #expect(h.clock.registrations == 0)       // nothing even started waiting on the network
        guard case .file(let name, let bytes, _) = h.pipeline.input else { Issue.record("no input"); return }
        #expect(name == "big.mov" && bytes > 100_000_000)
    }

    @Test func renderBusyKeepsTheTrimAndRetries() async throws {
        let h = Harness(.renderBusy)
        let p = h.pipeline
        p.start(link: URL(string: pastedLink)!)
        await h.driveToSettled()
        #expect(p.state == .ready)
        p.dragTrim(.span, to: 2)
        let chosen = p.trim
        #expect(chosen == TrimRange(start: 2, end: 12))

        p.makeWebp()
        await h.driveToSettled()
        #expect(p.state == .failed(.renderBusy))
        #expect(PipelineFailure.renderBusy.keepsTrim)
        #expect(p.trim == chosen)
        #expect(p.sessionID != nil)

        // "try again" renders once more from the same trim
        p.makeWebp()
        await h.driveToSettled()
        #expect(p.state == .failed(.renderBusy))
        #expect(h.kinds.filter { $0 == "failed(renderBusy)" }.count >= 1)
        #expect(p.trim == chosen)
    }

    @Test func renderLostFailsHalfwayAndKeepsTheTrim() async throws {
        let h = Harness(.renderLost)
        let p = h.pipeline
        p.start(link: URL(string: pastedLink)!)
        await h.driveToSettled()
        p.dragTrim(.span, to: 1)
        let chosen = p.trim
        let t0 = h.clock.elapsed
        p.makeWebp()
        await h.driveToSettled()
        #expect(p.state == .failed(.renderLost))
        #expect(PipelineFailure.renderLost.keepsTrim)
        let took = h.clock.elapsed - t0
        #expect(took >= 4.7 * 0.55 - 0.05 && took <= 4.7 * 0.55 + 0.25, "failed after \(took) s")
        #expect(p.trim == chosen)
        p.backToTrim()
        #expect(p.state == .ready)
    }

    @Test func revokedKeyMarksTheServerKeyInvalid() async throws {
        let h = Harness(.revokedKey)
        #expect(h.app.capabilities.key == .invalid)
        h.app.markKeyInvalid()
        h.pipeline.start(link: URL(string: pastedLink)!)
        await h.driveToSettled()
        #expect(h.pipeline.state == .failed(.keyInvalid))
        #expect(h.app.capabilities.key == .invalid)
        #expect(h.app.serverSummary.key == .invalid)
    }

    // MARK: picker

    @Test func pickerOffersItemsAndSavesOrConverts() async throws {
        let h = Harness(.picker)
        let p = h.pipeline
        p.start(link: URL(string: "https://x.com/PopCrave/status/1682176754792955905")!)
        await h.driveToSettled()
        guard case .picker(let items) = p.state else { Issue.record("expected .picker, got \(p.state)"); return }
        #expect(items.map(\.type) == [.video, .photo])
        #expect(items.map(\.canWebp) == [true, false])

        // a photo cannot become a webp
        p.choose(items[1], .webp)
        #expect(p.state == .picker(items: items))

        // save the video: the sheet stays, photos reports progress
        p.choose(items[0], .save)
        #expect(p.photos == .working)
        await h.drive { p.photos != .working }
        #expect(p.photos == .done)
        #expect(p.state == .picker(items: items))

        // "save both"
        p.saveAllPickerItemsToPhotos()
        await h.drive { p.photos != .working }
        #expect(p.photos == .done)

        // turn the video into a webp: download, then exactly the file flow from .uploading
        p.choose(items[0], .webp)
        await h.driveToSettled()
        #expect(p.state == .ready)
        #expect(isSubsequence(["picker", "fetching", "uploading", "saving", "reading", "ready"], of: h.kinds))
    }

    // MARK: files

    @Test func videoFileUploadsThenReadsLocally() async throws {
        let h = Harness(.happy)
        let p = h.pipeline
        let file = try makeTempFile("IMG_0412.mov")
        p.start(file: file)
        guard case .uploading(let first) = p.state else { Issue.record("expected .uploading"); return }
        #expect(first.bytes == 0 && first.total == 18_200_000)
        #expect(p.rail.steps == [.upload, .save, .read, .webp])

        await h.driveToSettled()
        #expect(p.state == .ready)
        #expect(isSubsequence(["uploading", "saving", "reading", "ready"], of: h.kinds))
        let sent = h.log.compactMap { s -> Int64? in
            if case .uploading(let t) = s { return t.bytes }
            return nil
        }
        #expect(sent == sent.sorted() && (sent.last ?? 0) > 10_000_000)
        #expect(p.media?.name == "IMG_0412.mov")
        #expect(p.trim == TrimRange(start: 0, end: 10))
        #expect(p.frames.compactMap { $0 }.count == 9)
        #expect(p.sessionID != nil)
        // 18.2 MB at 8 MB/s
        #expect(h.clock.elapsed >= 2.2)
    }

    @Test func imageUploadHostsAsIs() async throws {
        let h = Harness(.image)
        let p = h.pipeline
        let file = try makeTempFile("photo.png")
        p.start(file: file)
        await h.driveToSettled()
        guard case .image(let info) = p.state else { Issue.record("expected .image, got \(p.state)"); return }
        #expect(info.isImage && info.name == "photo.png")
        #expect(p.rail.steps == [.upload, .save, .read, .host])
        #expect(p.sessionID == nil)
        #expect(!h.kinds.contains("reading"))

        p.hostOriginal()
        #expect(p.hosting == .working)
        await h.drive { p.hosting != .working }
        #expect(p.hosting == .done)
        #expect(p.hostedURL != nil)
        #expect(h.clipboard.copies.isEmpty, "hosting never writes the pasteboard")
    }

    // MARK: server kinds

    @Test func plainCobaltSavesLocallyWithoutStudio() async throws {
        let h = Harness(.plainCobalt)
        let p = h.pipeline
        #expect(h.app.capabilities.kind == .plainCobalt)
        p.start(link: URL(string: pastedLink)!)
        #expect(p.rail.steps == [.fetch, .save, .read])
        await h.driveToSettled()
        guard case .savedLocally(let video) = p.state else { Issue.record("expected .savedLocally, got \(p.state)"); return }
        #expect(isSubsequence(["fetching", "saving", "reading", "savedLocally"], of: h.kinds))
        #expect(video.kind == .original && video.link == URL(string: pastedLink))
        #expect(!h.kinds.contains("ready") && !h.kinds.contains("rendering.working"))
        #expect(p.sessionID == nil)
        #expect(p.rail.finished && p.rail.index == 2)
        #expect(h.app.store.videos.first?.id == video.id)
        p.makeWebp()                                // no studio: nothing happens
        #expect(p.state == .savedLocally(video))

        // the file circle is not offered on plain cobalt
        h.pipeline.start(file: try makeTempFile("clip.mov"))
        #expect(h.pipeline.state == .failed(.unsupported))
    }

    @Test func legacyForkDegradesWithoutStepOrCounts() async throws {
        let h = Harness(.legacyFork)
        let p = h.pipeline
        #expect(h.app.capabilities.kind == .legacyFork)
        #expect(!h.app.capabilities.saveProgress && !h.app.capabilities.renderProgress)
        p.start(link: URL(string: pastedLink)!)
        await h.driveToSettled()
        #expect(p.state == .ready)
        // no `step`: the server only ever says "saving"
        #expect(h.kinds.contains("saving(degraded)"))
        #expect(!h.kinds.contains("saving"))

        p.makeWebp()
        await h.driveToSettled()
        guard case .done = p.state else { Issue.record("expected .done, got \(p.state)"); return }
        // no counts: only "working", never decoding / packing
        #expect(h.kinds.contains("rendering.working"))
        #expect(!h.kinds.contains("rendering.decoding") && !h.kinds.contains("rendering.packing"))

        h.pipeline.start(file: try makeTempFile("clip.mov"))
        #expect(h.pipeline.state == .failed(.unsupported))
    }

    // MARK: lifecycle

    @Test func resetReturnsToIdleAndStopsTheRun() async throws {
        let h = Harness(.happy)
        let p = h.pipeline
        p.start(link: URL(string: pastedLink)!)
        await h.settle()
        p.reset()
        #expect(p.state == .idle)
        #expect(p.sessionID == nil && p.media == nil && p.result == nil)
        // time keeps running; the cancelled run must not write into the idle pipeline
        for _ in 0..<40 { await h.settle(); h.clock.advance() }
        #expect(p.state == .idle)
    }

    @Test func aNewRunReplacesTheOldOne() async throws {
        let h = Harness(.happy)
        let p = h.pipeline
        p.start(link: URL(string: pastedLink)!)
        await h.driveToSettled()
        p.makeWebp()
        await h.settle()
        p.start(link: URL(string: shortLink)!)
        #expect(p.result == nil && p.frames.allSatisfy { $0 == nil })
        await h.driveToSettled()
        #expect(p.state == .ready)
        #expect(p.result == nil)
    }

    // MARK: resume

    @Test func resumeASessionLandsOnTheTrim() async throws {
        let h = Harness(.happy)
        let created = try await h.ctx.client.createStudio(link: URL(string: pastedLink)!)
        h.clock.jump(by: 10)                                // the save finished on the server
        let task = Task { @MainActor in
            h.pipeline.resume(session: created.id, media: nil)
        }
        await task.value
        #expect(h.pipeline.sessionID == created.id)
        await h.driveToSettled()
        #expect(h.pipeline.state == .ready)
        #expect(h.pipeline.trim == TrimRange(start: 0, end: 10))
        #expect(h.pipeline.media?.duration == 14.77)
    }

    @Test func resumeFromTheShareSheetMidRenderFinishesTheWebp() async throws {
        let h = Harness(.shortClip)
        let created = try await h.ctx.client.createStudio(link: URL(string: shortLink)!)
        // let the save finish on the (virtual) server, then start a render the app did not poll
        h.clock.jump(by: 10)
        let job = Task { () -> String in
            try await h.ctx.client.render(
                session: created.id, RenderRequest(start: 0, length: 5.46, width: 480, quality: .med))
        }
        let jobID = try await job.value
        let shared = SharedJob(
            id: UUID(), origin: .shareExtension, link: URL(string: shortLink), sessionID: created.id,
            media: nil, trim: TrimRange(start: 0, end: 5.46), stage: .rendering(job: jobID), wantsTrim: false,
            pickedUp: false, updatedAt: h.clock.now())
        h.app.jobs.upsert(shared)
        #expect(h.app.jobs.nextHandoff(now: h.clock.now())?.id == shared.id)

        await h.app.pickUpSharedJobs()
        #expect(h.app.jobs.nextHandoff(now: h.clock.now()) == nil)            // taken over
        guard case .rendering = h.pipeline.state else { Issue.record("expected .rendering, got \(h.pipeline.state)"); return }
        await h.driveToSettled()
        guard case .done(let r) = h.pipeline.state else { Issue.record("expected .done, got \(h.pipeline.state)"); return }
        #expect(Format.bytes(r.bytes) == "841 KB")
    }

    @Test func resumeJobStages() async throws {
        let h = Harness(.happy)
        let done = WebpResult(
            job: "J", url: URL(string: "https://media.capybaraharmony.com/PrEvIeW001.webp")!,
            bytes: 841_000, width: 480, height: 568, seconds: 5.4)
        func job(_ stage: SharedJob.Stage) -> SharedJob {
            SharedJob(
                id: UUID(), origin: .app, link: nil, sessionID: nil, media: nil, trim: nil, stage: stage,
                wantsTrim: false, pickedUp: false, updatedAt: h.clock.now())
        }
        h.pipeline.resume(job(.failed(code: "error.webp.job_lost")))
        #expect(h.pipeline.state == .failed(.server(code: "error.webp.job_lost")))
        var withSession = job(.done(done))
        withSession.sessionID = nil
        h.pipeline.resume(withSession)
        #expect(h.pipeline.state == .done(done))
        #expect(h.pipeline.result == done)
    }
}

// MARK: - Trim math (section 4.4, pinned from Main.dc.html)

@MainActor
@Suite(.serialized)
struct TrimTests {
    /// A pipeline already on `.ready` for the long clip (D = 14.77, L = 10).
    private func readyPipeline() async throws -> (Harness, Pipeline) {
        let h = Harness(.happy)
        h.pipeline.start(link: URL(string: pastedLink)!)
        await h.driveToSettled()
        #expect(h.pipeline.state == .ready)
        return (h, h.pipeline)
    }

    @Test func startsOnTheFirstTenSeconds() async throws {
        let (_, p) = try await readyPipeline()
        #expect(p.trim == TrimRange(start: 0, end: 10))
        #expect(p.trim.length == 10)
        #expect(p.maxClipSeconds == 10)
    }

    @Test func draggingTheEndPastTheLimitRubberBandsAtAQuarter() async throws {
        let (_, p) = try await readyPipeline()
        p.dragTrim(.end, to: 14)                    // b - a = 14 > 10, excess 4 → b = 0 + 10 + 4 × 0.25
        #expect(p.trim.start == 0)
        #expect(abs(p.trim.end - 11) < 1e-9)
        #expect(p.trimOverLimit)
        #expect(p.limitHits == 1)

        p.dragTrim(.end, to: 14.5)                  // still over: no second hit
        #expect(p.trimOverLimit && p.limitHits == 1)
        #expect(abs(p.trim.end - 11.125) < 1e-9)

        p.dragTrim(.end, to: 99)                    // clamped to the clip's end first (14.77)
        #expect(abs(p.trim.end - (10 + 4.77 * 0.25)) < 1e-9)
    }

    @Test func releasingSnapsBackToExactlyTheLimit() async throws {
        let (_, p) = try await readyPipeline()
        p.dragTrim(.end, to: 14)
        p.endTrimDrag()
        #expect(p.trim == TrimRange(start: 0, end: 10))
        #expect(!p.trimOverLimit)
        #expect(p.limitHits == 1)

        // dragging the start handle past the limit snaps the START handle
        p.dragTrim(.span, to: 3)                    // (3, 13)
        #expect(p.trim == TrimRange(start: 3, end: 13))
        p.dragTrim(.start, to: 1)                   // a = 13 - 10 - 2 × 0.25 = 2.5
        #expect(abs(p.trim.start - 2.5) < 1e-9 && p.trim.end == 13)
        #expect(p.trimOverLimit && p.limitHits == 2)
        p.endTrimDrag()
        #expect(p.trim == TrimRange(start: 3, end: 13))
        #expect(!p.trimOverLimit)
    }

    @Test func overTurnsOnOncePerEntry() async throws {
        let (_, p) = try await readyPipeline()
        p.dragTrim(.end, to: 12)                    // over
        p.dragTrim(.end, to: 10)                    // back inside (b - a = 10, not > 10)
        #expect(!p.trimOverLimit && p.limitHits == 1)
        p.dragTrim(.end, to: 13)                    // over again: second hit
        #expect(p.trimOverLimit && p.limitHits == 2)
        p.endTrimDrag()
    }

    @Test func handlesStayHalfASecondApartAndInsideTheClip() async throws {
        let (_, p) = try await readyPipeline()
        p.dragTrim(.start, to: 12)                  // clamped to b - 0.5
        #expect(p.trim == TrimRange(start: 9.5, end: 10))
        p.dragTrim(.start, to: -4)                  // clamped to 0
        #expect(p.trim.start == 0)
        p.dragTrim(.end, to: 0.1)                   // clamped to a + 0.5
        #expect(p.trim == TrimRange(start: 0, end: 0.5))
        p.dragTrim(.end, to: 50)                    // clamped to D, then rubber band: 0 + 10 + 4.27 × 0.25
        #expect(abs(p.trim.end - (10 + (14.77 - 10) * 0.25)) < 1e-9)
        p.endTrimDrag()
        #expect(p.trim == TrimRange(start: 0, end: 10))
    }

    @Test func spanKeepsItsLengthAndStaysInsideTheClip() async throws {
        let (_, p) = try await readyPipeline()
        p.dragTrim(.span, to: 99)
        #expect(abs(p.trim.start - 4.77) < 1e-9 && abs(p.trim.end - 14.77) < 1e-9)
        p.dragTrim(.span, to: -5)
        #expect(p.trim == TrimRange(start: 0, end: 10))
        #expect(!p.trimOverLimit && p.limitHits == 0)
    }

    @Test func nudgesMoveTenthsAndCountAHitAtTheLimit() async throws {
        let (_, p) = try await readyPipeline()
        p.nudgeTrim(.end, by: 0.1)                  // 10.1 → snapped back to 10, a hit
        #expect(p.trim == TrimRange(start: 0, end: 10) && p.limitHits == 1)
        p.nudgeTrim(.start, by: 0.1)
        #expect(abs(p.trim.start - 0.1) < 1e-9 && p.limitHits == 1)
        p.nudgeTrim(.start, by: -0.5)               // clamped at 0
        #expect(p.trim.start == 0)
        p.nudgeTrim(.end, by: -20)                  // keeps 0.5 s
        #expect(abs(p.trim.end - 0.5) < 1e-9)
        p.nudgeTrim(.span, by: 20)                  // slides, length kept, clamped to D
        #expect(abs(p.trim.length - 0.5) < 1e-9 && abs(p.trim.end - 14.77) < 1e-9)
    }

    @Test func trimIsIgnoredOutsideTheReadyState() async throws {
        let h = Harness(.happy)
        h.pipeline.dragTrim(.end, to: 3)
        h.pipeline.nudgeTrim(.end, by: 0.1)
        #expect(h.pipeline.trim == TrimRange(start: 0, end: 10) && h.pipeline.limitHits == 0)
    }

    @Test func pureMathMatchesTheBoard() {
        // moveDrag 'in': a = b - L - ex × 0.25
        let a = TrimMath.drag(.start, to: 1, from: TrimRange(start: 3, end: 13), duration: 20, limit: 10)
        #expect(a.over && abs(a.range.start - 2.5) < 1e-9)
        // moveDrag 'out'
        let b = TrimMath.drag(.end, to: 18, from: TrimRange(start: 4, end: 14), duration: 20, limit: 10)
        #expect(b.over && abs(b.range.end - (4 + 10 + 4 * 0.25)) < 1e-9)
        // endDrag: the moved handle snaps
        #expect(TrimMath.release(b.range, moved: .end, limit: 10) == TrimRange(start: 4, end: 14))
        #expect(TrimMath.release(a.range, moved: .start, limit: 10) == TrimRange(start: 3, end: 13))
        // nudge
        let n = TrimMath.nudge(.end, by: 0.1, from: TrimRange(start: 0, end: 10), duration: 14.77, limit: 10)
        #expect(n.hitLimit && n.range == TrimRange(start: 0, end: 10))
    }
}
