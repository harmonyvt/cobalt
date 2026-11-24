import Foundation
import Testing
@testable import CobaltKit

// Phase 3, the one status (apple 03-PHASE3 3.2; 06 matrix, CobaltKit test 1): every `Stage`, the stepper they draw, the
// Cloud ✓ / Device ⚠ split, and the projections from a pipeline, a download, a server row and an editor render.

private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

private func status(
    _ stage: JobStatus.Stage, kind: JobStatus.Kind = .save, fraction: Double? = nil, engine: SaveEngine? = nil,
    fallbackFrom: SaveEngine? = nil, woke: Bool = false, failedStep: JobStep.ID? = nil, sessionID: String? = nil,
    id: String = "job:1"
) -> JobStatus {
    JobStatus(
        id: id, ref: .pipeline(UUID()), kind: kind, title: "x · 1", sessionID: sessionID, stage: stage, fraction: fraction,
        startedAt: t0, updatedAt: t0, engine: engine, fallbackFrom: fallbackFrom, woke: woke, failedStep: failedStep)
}

private func states(_ s: JobStatus) -> [JobStep.ID: JobStep.State] {
    Dictionary(uniqueKeysWithValues: s.steps.map { ($0.id, $0.state) })
}

// MARK: - 1. Every stage

struct JobStatusStageTests {
    /// The twelve stages: whether they count as active, whether they need attention, the step they sit in.
    private static let table: [(JobStatus.Stage, active: Bool, attention: Bool, step: JobStep.ID)] = [
        (.queued(ahead: 2), true, false, .queued),
        (.waking(engine: .ytdlp), true, false, .wake),
        (.fetching(engine: .cobalt, fallbackFrom: nil), true, false, .source),
        (.downloading(bytes: 5, total: 10), true, false, .source),
        (.storing(bytes: 5, total: 10), true, false, .store),
        (.galleryProgress(done: 2, total: 6, currentBytes: 1, currentTotal: 9), true, false, .source),
        (.readingFrames(done: 3, total: 9), true, false, .device),
        (.rendering(phase: .decode, done: 4, total: 10), true, false, .store),
        (.deviceCopy(bytes: 1, total: 2), true, false, .device),
        (.completed(cloudSaved: true, deviceCopy: .savedOnDevice), false, false, .device),
        (.failed(failure: .unreachable, retryable: true), false, true, .source),
        (.awaitingChoice, false, false, .queued),
    ]

    @Test(arguments: 0..<12)
    func eachStageCountsAndSitsInItsStep(index: Int) {
        let row = Self.table[index]
        let s = status(row.0)
        #expect(s.isActive == row.active, "\(row.0)")
        #expect(s.needsAttention == row.attention, "\(row.0)")
        #expect(s.currentStep == row.step, "\(row.0)")
        #expect(!(s.isActive && s.needsAttention), "a status is never both")
        #expect(s.bucket == (row.attention ? .attention : row.active ? .running : .settled))
    }

    @Test func theTableIsEveryCase() {
        // a new Stage case must be added to the table (and to `JobStep`): this fails to compile its switch until it is.
        func name(_ s: JobStatus.Stage) -> String {
            switch s {
            case .queued: "queued"
            case .waking: "waking"
            case .fetching: "fetching"
            case .downloading: "downloading"
            case .storing: "storing"
            case .galleryProgress: "galleryProgress"
            case .readingFrames: "readingFrames"
            case .rendering: "rendering"
            case .deviceCopy: "deviceCopy"
            case .completed: "completed"
            case .failed: "failed"
            case .awaitingChoice: "awaitingChoice"
            }
        }
        #expect(Set(Self.table.map { name($0.0) }).count == 12)
    }

    @Test func aFractionIsClampedAndOptional() {
        #expect(status(.downloading(bytes: 1, total: 4), fraction: 0.25).fraction == 0.25)
        #expect(status(.fetching(engine: nil, fallbackFrom: nil)).fraction == nil)
        #expect(status(.storing(bytes: 9, total: 4), fraction: 4).fraction == 1)
    }

    // MARK: Cloud ✓ and Device ⚠

    @Test func theCloudCopyAndTheDeviceCopyAreTwoReceipts() {
        let both = status(.completed(cloudSaved: true, deviceCopy: .savedOnDevice))
        #expect(both.steps.map(\.state) == [.done, .done, .done, .done])
        #expect(both.steps.last?.detail == .receipt(.savedOnDevice))
        #expect(!both.isActive && !both.needsAttention && both.bucket == .settled)

        let warn = status(.completed(cloudSaved: true, deviceCopy: .failed(code: "error.app.disk_full")))
        #expect(warn.steps.map(\.id) == [.queued, .source, .store, .device])
        #expect(warn.steps.map(\.state) == [.done, .done, .done, .warning], "Cloud ✓, Device ⚠")
        #expect(warn.steps.last?.detail == .receipt(.failed(code: "error.app.disk_full")))
        #expect(warn.needsAttention && !warn.isActive && warn.bucket == .attention)

        let coming = status(.completed(cloudSaved: true, deviceCopy: .inProgress))
        #expect(coming.isActive && !coming.needsAttention)
        #expect(coming.steps.last?.state == .active)

        let off = status(.completed(cloudSaved: true, deviceCopy: .notNeeded))
        #expect(off.steps.last?.state == .done && off.steps.last?.detail == .receipt(.notNeeded))
    }

    @Test func plainCobaltHasNoLibraryStep() {
        let s = status(.completed(cloudSaved: false, deviceCopy: .savedOnDevice))
        #expect(s.steps.map(\.id) == [.queued, .source, .device])
    }

    // MARK: The stepper

    @Test func aWarmSaveHasFourStepsAndACollapsedWake() {
        let s = status(.downloading(bytes: 1, total: 2), fraction: 0.5)
        #expect(s.steps.map(\.id) == [.queued, .source, .store, .device])
        #expect(s.steps.map(\.state) == [.done, .active, .pending, .pending])
        #expect(s.steps[1].fraction == 0.5 && s.steps[0].fraction == nil)
    }

    @Test func aWakingSaveShowsTheWakeStepOnItsOwn() {
        let s = status(.waking(engine: .ytdlp))
        #expect(s.steps.map(\.id) == [.queued, .wake, .source, .store, .device], "five steps while a container wakes")
        #expect(s.steps.map(\.state) == [.done, .active, .pending, .pending, .pending])
        #expect(s.steps[1].detail == .wake(engine: .ytdlp))
    }

    @Test func theWakeStepStaysOnceItWasShown() {
        let s = status(.downloading(bytes: 1, total: 2), woke: true)
        #expect(s.steps.map(\.id) == [.queued, .wake, .source, .store, .device])
        #expect(s.steps.map(\.state) == [.done, .done, .active, .pending, .pending])
    }

    @Test func aQueuedSaveSaysHowManyAreAhead() {
        let s = status(.queued(ahead: 3))
        #expect(s.steps.first?.state == .active && s.steps.first?.detail == .queue(ahead: 3))
        #expect(s.stage.isWaiting)
    }

    @Test func theSourceStepKeepsItsEngineAndTheSwitch() {
        let running = status(.downloading(bytes: 18, total: 37), engine: .ytdlp, fallbackFrom: .cobalt)
        #expect(running.steps[1].detail == .source(engine: .ytdlp, fallbackFrom: .cobalt, bytes: 18, total: 37))
        // after the download the done step still carries the callout
        let storing = status(.storing(bytes: 1, total: 4), engine: .ytdlp, fallbackFrom: .cobalt)
        #expect(storing.steps[1].state == .done)
        #expect(storing.steps[1].detail == .source(engine: .ytdlp, fallbackFrom: .cobalt, bytes: nil, total: nil))
        #expect(storing.steps[2].state == .active && storing.steps[2].detail == .bytes(1, of: 4))
        // a save no engine is named for says nothing
        #expect(status(.storing(bytes: 1, total: 4)).steps[1].detail == .none)
    }

    @Test func aGalleryCountsItemsInTheSourceStep() {
        let s = status(.galleryProgress(done: 4, total: 6, currentBytes: 6, currentTotal: 9), kind: .gallery, fraction: 4.0 / 6.0)
        #expect(s.steps[1].id == .source && s.steps[1].state == .active)
        #expect(s.steps[1].detail == .items(done: 4, total: 6, currentBytes: 6, currentTotal: 9))
    }

    @Test func aRenderIsTheStoreStepOfItsKind() {
        let webp = status(.rendering(phase: .pack, done: nil, total: nil), kind: .webpRender)
        #expect(webp.steps.map(\.id) == [.queued, .store, .device])
        #expect(webp.steps.map(\.state) == [.done, .active, .pending])
        #expect(webp.steps[1].detail == .render(phase: .pack, done: nil, total: nil))
        let edit = status(.rendering(phase: .decode, done: 3, total: 10), kind: .editorRender)
        #expect(edit.steps.map(\.id) == [.queued, .store], "an editor render has no device copy")
        let done = status(.completed(cloudSaved: true, deviceCopy: .notNeeded), kind: .editorRender)
        #expect(done.steps.map(\.state) == [.done, .done])
    }

    @Test func aFinishedSaveReadingItsFramesIsOnTheDeviceStep() {
        let s = status(.readingFrames(done: 3, total: 9))
        #expect(s.steps.map(\.state) == [.done, .done, .done, .active])
        #expect(s.steps.last?.detail == .frames(done: 3, total: 9))
    }

    @Test func aDownloadOntoTheDeviceHasTwoSteps() {
        let s = status(.deviceCopy(bytes: 1, total: 2), kind: .deviceDownload)
        #expect(s.steps.map(\.id) == [.queued, .device] && s.steps.map(\.state) == [.done, .active])
        let waiting = status(.queued(ahead: nil), kind: .deviceDownload)
        #expect(waiting.steps.map(\.state) == [.active, .pending])
    }

    @Test func aFailureLandsInTheStepItHappenedIn() {
        let f = JobStatus.Stage.failed(failure: .serverBusy, retryable: true)
        let source = status(f)
        #expect(states(source) == [.queued: .done, .source: .failed, .store: .pending, .device: .pending])
        #expect(source.steps[1].detail == .failure(.serverBusy))
        let store = status(f, failedStep: .store)
        #expect(states(store) == [.queued: .done, .source: .done, .store: .failed, .device: .pending])
        #expect(status(f, kind: .webpRender).currentStep == .store)
        #expect(status(f, kind: .deviceDownload).currentStep == .device)
        let queued = status(f, failedStep: .queued)
        #expect(queued.steps.first?.state == .failed && queued.steps.first?.detail == .failure(.serverBusy))
    }

    @Test func aPostWaitingForThePickIsNotRunningAndNotFailed() {
        let s = status(.awaitingChoice)
        #expect(s.steps.map(\.state) == [.done, .pending, .pending, .pending])
        #expect(!s.isActive && !s.needsAttention && s.bucket == .settled)
    }

    @Test func theDedupeKeysAreTheSessionAndTheServerJob() {
        #expect(status(.awaitingChoice, sessionID: "abc").dedupeKeys == ["sid:abc"])
        #expect(status(.awaitingChoice).dedupeKeys.isEmpty)
        let both = JobStatus(
            id: "x", ref: .server(id: "x"), kind: .webpRender, sessionID: "abc", serverJobID: "j1", stage: .queued(ahead: 1),
            startedAt: t0, updatedAt: t0)
        #expect(both.dedupeKeys == ["sid:abc", "srvjob:j1"])
    }
}

// MARK: - 2. From a pipeline

@MainActor
struct JobStatusPipelineTests {
    private let app = AppModel.preview()

    private func pipeline(_ link: URL? = linkA) -> Pipeline {
        let p = Pipeline(context: app.ctx)
        if let link, let info = LinkInfo(link) { p.input = .link(info) }
        return p
    }

    private func project(_ p: Pipeline, line: LinePosition? = nil) -> JobStatus? {
        p.line = line
        return JobStatus(pipeline: p, ref: .pipeline(UUID()), jobID: UUID(), isFocused: false, startedAt: t0, finishedAt: nil, owned: true, isLive: true, now: t0)
    }

    private func status(of p: Pipeline) -> JobStatus {
        let s = project(p)
        #expect(s != nil)
        return s!
    }

    @Test func anIdlePipelineIsNothing() {
        #expect(project(pipeline()) == nil)
    }

    @Test func aLinkBeingCheckedIsFetching() {
        let p = pipeline()
        p.setState(.fetching(since: t0, waking: false))
        let s = status(of: p)
        #expect(s.stage == .fetching(engine: nil, fallbackFrom: nil) && s.kind == .save)
        #expect(s.sourceHost == "instagram.com" && s.title == "instagram · Dd7P496wolG")
        #expect(s.canCancel && s.canFocus && !s.canRetry && !s.canDismiss)
    }

    @Test func theServersWakingIsTheWakeStage() {
        let p = pipeline()
        var save = SaveStatus()
        save.waking = true
        save.wakingEngine = .ytdlp
        p.saveStatus = save
        p.setState(.fetching(since: t0, waking: true))
        let s = status(of: p)
        #expect(s.stage == .waking(engine: .ytdlp) && s.woke)
        #expect(s.steps.map(\.id) == [.queued, .wake, .source, .store, .device])
    }

    @Test func theEngineAndTheSwitchRideAlongOnTheStatus() {
        let p = pipeline()
        var save = SaveStatus()
        save.phase = .downloading
        save.engine = .ytdlp
        save.fallbackFrom = .cobalt
        p.saveStatus = save
        p.setState(.saving(bytes: 18, total: 36, since: t0))
        let s = status(of: p)
        #expect(s.stage == .downloading(bytes: 18, total: 36) && s.fraction == 0.5)
        #expect(s.engine == .ytdlp && s.fallbackFrom == .cobalt)
        #expect(s.steps[1].detail == .source(engine: .ytdlp, fallbackFrom: .cobalt, bytes: 18, total: 36))
    }

    @Test func storingIsNotDownloading() {
        let p = pipeline()
        var save = SaveStatus()
        save.phase = .storing
        p.saveStatus = save
        p.setState(.saving(bytes: 9, total: 12, since: t0))
        #expect(status(of: p).stage == .storing(bytes: 9, total: 12))
        // a server that says no steps: the one "saving" line is the library write
        p.saveStatus = SaveStatus()
        #expect(status(of: p).stage == .storing(bytes: 9, total: 12))
    }

    @Test func anUploadSendsFromThisDevice() {
        let p = pipeline(nil)
        p.input = .file(name: "IMG_1.mov", bytes: 100, contentType: "video/quicktime")
        p.setState(.uploading(TransferProgress(bytes: 25, total: 100)))
        let s = status(of: p)
        #expect(s.kind == .upload && s.stage == .downloading(bytes: 25, total: 100) && s.fraction == 0.25)
        #expect(s.sourceHost == nil && s.title == "IMG_1")
    }

    @Test func aPlaceInLineIsAQueuedStageWhateverTheStateIs() {
        let p = pipeline()
        p.setState(.fetching(since: t0, waking: false))
        #expect(project(p, line: .inLine(3, behind: nil))?.stage == .queued(ahead: 2))
        #expect(project(p, line: .inLine(1, behind: nil))?.stage == .queued(ahead: 0))
        #expect(project(p, line: .serverBusy(since: t0, label: "a save from your mac"))?.stage == .queued(ahead: nil))
        p.setState(.rendering(.working(since: t0)))
        #expect(project(p, line: .inLine(2, behind: nil))?.stage == .queued(ahead: 1))
        #expect(project(p, line: nil)?.kind == .webpRender)
    }

    @Test func rendersMapOntoTheWirePhases() {
        let p = pipeline()
        p.setState(.rendering(.decoding(done: 3, total: 12)))
        var s = status(of: p)
        #expect(s.kind == .webpRender && s.stage == .rendering(phase: .decode, done: 3, total: 12) && s.fraction == 0.25)
        p.setState(.rendering(.packing(since: t0)))
        s = status(of: p)
        #expect(s.stage == .rendering(phase: .pack, done: nil, total: nil) && s.fraction == nil)
        p.setState(.rendering(.working(since: t0)))
        #expect(status(of: p).stage == .rendering(phase: nil, done: nil, total: nil))
    }

    @Test func readingTheFilmstripIsTheDeviceStep() {
        let p = pipeline()
        p.setState(.reading(developed: 3, of: 9))
        let s = status(of: p)
        #expect(s.stage == .readingFrames(done: 3, total: 9) && s.currentStep == .device)
    }

    @Test func aSavedJobIsCloudDoneAndSaysWhereTheDeviceCopyStands() {
        let p = pipeline()
        p.setState(.ready)
        #expect(status(of: p).stage == .completed(cloudSaved: true, deviceCopy: .notNeeded))
        p.localCopyState = .downloading(TransferProgress(bytes: 1, total: 4))
        var s = status(of: p)
        #expect(s.stage == .deviceCopy(bytes: 1, total: 4) && s.fraction == 0.25 && s.isActive)
        p.localCopyState = .savedOnDevice
        s = status(of: p)
        #expect(s.stage == .completed(cloudSaved: true, deviceCopy: .savedOnDevice) && !s.isActive && s.fraction == 1)
        p.localCopyState = .failed(code: "error.app.disk_full")
        s = status(of: p)
        #expect(s.stage == .completed(cloudSaved: true, deviceCopy: .failed(code: "error.app.disk_full")))
        #expect(s.needsAttention && !s.isActive, "Cloud ✓, Device ⚠ needs attention but is not running")
    }

    @Test func aFailedDeviceCopyOffersRetryOnlyWhenThereIsSomethingToFetchAgain() {
        let p = pipeline()
        p.setState(.done(WebpResult(job: "j", url: URL(string: "https://x.test/a.webp")!, bytes: 1, width: 1, height: 1, seconds: 1)))
        p.localCopyState = .failed(code: "error.app.offline")
        #expect(status(of: p).kind == .webpRender && status(of: p).canRetry == false)
        p.localCopyJob = .original(session: "s", media: MediaInfo(name: "a", duration: 1, width: 1, height: 1, bytes: 1, isImage: false))
        #expect(status(of: p).canRetry)
    }

    @Test func plainCobaltEndsSavedOnTheDeviceOnly() {
        let p = pipeline()
        let stored = StoredVideo(
            id: "v", kind: .original, fileURL: nil, posterURL: nil, name: "a.mp4", duration: 1, width: 1, height: 1, bytes: 1,
            sessionID: nil, link: nil, remoteURL: nil, createdAt: t0)
        p.setState(.savedLocally(stored))
        p.localCopyState = .savedOnDevice
        let s = status(of: p)
        #expect(s.stage == .completed(cloudSaved: false, deviceCopy: .savedOnDevice))
    }

    @Test func aFailureCarriesWhetherTryAgainCanHelp() {
        let p = pipeline()
        p.setState(.failed(.unreachable))
        var s = status(of: p)
        #expect(s.stage == .failed(failure: .unreachable, retryable: true) && s.canRetry)
        p.setState(.failed(.keyInvalid))
        s = status(of: p)
        #expect(s.stage == .failed(failure: .keyInvalid, retryable: false) && !s.canRetry)
        #expect(s.needsAttention && s.bucket == .attention)
    }

    @Test func aRenderFailureLandsInTheStoreStep() {
        let p = pipeline()
        p.setState(.failed(.renderBusy))
        #expect(status(of: p).currentStep == .store)
    }

    @Test func aPickerWaitsForTheOwner() {
        let p = pipeline()
        p.setState(.picker(items: []))
        let s = status(of: p)
        #expect(s.stage == .awaitingChoice && !s.isActive)
    }

    @Test func aGalleryCountsItsItemsThenItsMake() {
        let p = pipeline()
        p.galleryRun = GalleryRun(total: 6)
        p.setState(.gallery(items: []))
        p.galleryRun?.done = 4
        var s = status(of: p)
        #expect(s.kind == .gallery && s.stage == .galleryProgress(done: 4, total: 6, currentBytes: nil, currentTotal: nil))
        #expect(s.fraction == 4.0 / 6.0)
        p.galleryRun?.phase = .saved
        #expect(status(of: p).stage == .completed(cloudSaved: true, deviceCopy: .notNeeded))
        let plan = GalleryMake.slideshow(SlideshowPlan(format: .webp, items: Array(0..<4)))
        p.galleryRun?.make = .making(plan, .init(phase: .composing, done: 2, total: 4))
        s = status(of: p)
        #expect(s.stage == .rendering(phase: .decode, done: 2, total: 4) && s.isActive)
        p.galleryRun?.make = .queued(plan, ahead: 2)
        #expect(status(of: p).stage == .queued(ahead: 2))
        p.galleryRun?.make = .failed(plan, .renderBusy)
        s = status(of: p)
        #expect(s.stage == .failed(failure: .renderBusy, retryable: true) && s.canRetry && s.currentStep == .store)
        p.galleryRun?.phase = .failed(.fetchFailed(code: "error.api.fetch.empty"))
        #expect(status(of: p).needsAttention)
    }

    @Test func aGalleryWakeIsKept() {
        let p = pipeline()
        p.galleryRun = GalleryRun(total: 3)
        p.galleryRun?.waking = true
        p.setState(.gallery(items: []))
        #expect(status(of: p).woke)
    }

    @Test func aJobOfTheQueueIsOwnedAndFocusable() {
        let jobs = app.queue.add([.link(linkA)], via: .paste)
        let s = JobStatus(job: jobs[0], isFocused: true, now: t0)
        #expect(s?.id == "job:\(jobs[0].id.uuidString)" && s?.ref == .pipeline(jobs[0].id))
        #expect(s?.isFocused == true && s?.canFocus == true && s?.canCancel == true)
    }

    @Test func aBarePipelineIsReadAsAStatusButNothingCanBeDoneToIt() {
        let p = pipeline()
        p.setState(.rendering(.working(since: t0)))
        let s = JobStatus(pipeline: p, now: t0)
        #expect(s?.isActive == true)
        #expect(s?.canFocus == false && s?.canCancel == false && s?.canDismiss == false)
        #expect(s?.ref == .pipeline(p.liveRunID))
        p.setState(.idle)
        #expect(JobStatus(pipeline: p, now: t0) == nil, "an idle pipeline is no status")
    }
}

// MARK: - 3. From the other owners

@MainActor
struct JobStatusOwnerTests {
    @Test func aDownloadWaitingRunningAndFailed() {
        let waiting = OfflineDownloadRow(id: "s:abc", name: "harbour.mov", state: .waiting, queuedAt: t0)
        var s = JobStatus(download: waiting, now: t0)
        #expect(s.kind == .deviceDownload && s.stage == .queued(ahead: nil) && s.sessionID == "abc" && s.canCancel)
        #expect(s.id == "download:s:abc" && s.ref == .download(key: "s:abc"))

        let running = OfflineDownloadRow(id: "f:9", name: "a", state: .downloading(TransferProgress(bytes: 2, total: nil)), expectedBytes: 8, queuedAt: t0)
        s = JobStatus(download: running, now: t0)
        #expect(s.stage == .deviceCopy(bytes: 2, total: 8) && s.fraction == 0.25 && s.sessionID == nil)

        let failed = OfflineDownloadRow(id: "f:9", name: "a", state: .failed(.full), queuedAt: t0)
        s = JobStatus(download: failed, now: t0)
        #expect(s.needsAttention && s.canRetry && s.canDismiss && !s.canCancel)
        #expect(s.stage == .failed(failure: .server(code: "error.app.disk_full"), retryable: true))
        func why(_ f: OfflineFailure) -> JobStatus {
            JobStatus(download: OfflineDownloadRow(id: "f:1", name: "a", state: .failed(f), queuedAt: t0), now: t0)
        }
        #expect(why(.unreachable).stage == .failed(failure: .unreachable, retryable: true))
        #expect(why(.gone).stage == .failed(failure: .expired, retryable: true))
        #expect(why(.other(503)).stage == .failed(failure: .server(code: "http.503"), retryable: true))
        // a refused key is not cured by asking again
        #expect(why(.auth).stage == .failed(failure: .keyInvalid, retryable: false) && !why(.auth).canRetry)
    }

    @Test func aServerRowIsForeignUnlessItIsThisKeys() {
        let share = ServerWork(kind: "save", running: true, mine: false, origin: "share", keyName: "iphone", sid: "s1", link: URL(string: "https://x.com/i/status/1"))
        var s = JobStatus(server: share, id: "server:running:s1", at: t0)
        #expect(s?.kind == .save && s?.stage == .fetching(engine: nil, fallbackFrom: nil) && s?.sessionID == "s1")
        #expect(s?.remote == JobStatus.Remote(keyName: "iphone", fromShare: true))
        #expect(s?.sourceHost == "x.com" && s?.title == "x · 1" && s?.canCancel == false)

        let mine = ServerWork(kind: "save", running: false, position: 3, mine: true, keyName: "mac", sid: "s2")
        s = JobStatus(server: mine, id: "server:s2", at: t0)
        #expect(s?.stage == .queued(ahead: 2) && s?.remote == nil && s?.canCancel == true)

        let webp = ServerWork(kind: "render", running: true, mine: true, sid: "s3", job: "j")
        #expect(JobStatus(server: webp, id: "server:j", at: t0)?.kind == .webpRender)
        #expect(JobStatus(server: ServerWork(kind: "poster", running: true), id: "server:p", at: t0) == nil, "posters are not the owner's work")
    }

    private func render(_ status: EditRender.Status, progress: Double? = nil, error: String? = nil, kind: EditRender.Kind = .edit) -> EditRender {
        EditRender(
            id: "r1", projectID: "p1", revision: 1, title: "birthday cut", status: status, queueAhead: status == .queued ? 2 : nil,
            progress: progress, secondsDone: 3.2, secondsTotal: 10, error: error, itemID: status == .done ? "it1" : nil,
            createdAt: t0, startedAt: t0, kind: kind)
    }

    @Test func anEditorRenderRunsThroughItsStatuses() {
        #expect(JobStatus(edit: render(.queued), now: t0)?.stage == .queued(ahead: 2))
        #expect(JobStatus(edit: render(.preparing, progress: 0.05), now: t0)?.stage == .rendering(phase: .fetching, done: nil, total: nil))
        let running = JobStatus(edit: render(.rendering, progress: 0.4), now: t0)
        #expect(running?.stage == .rendering(phase: .decode, done: 3, total: 10) && running?.fraction == 0.4)
        #expect(running?.kind == .editorRender && running?.canCancel == true && running?.canFocus == true)
        #expect(JobStatus(edit: render(.finishing, progress: 0.95), now: t0)?.stage == .rendering(phase: .pack, done: nil, total: nil))
        let done = JobStatus(edit: render(.done), now: t0)
        #expect(done?.stage == .completed(cloudSaved: true, deviceCopy: .notNeeded) && done?.mediaID == "post:it1" && done?.canDismiss == true)
        #expect(JobStatus(edit: render(.cancelled), now: t0) == nil)
    }

    @Test func aFailedEditorRenderNeedsAttentionAndRetriesUnlessItHasNoProject() {
        let failed = JobStatus(edit: render(.error, error: "error.edit.render_failed"), now: t0)
        #expect(failed?.needsAttention == true && failed?.canRetry == true && failed?.currentStep == .store)
        let chat = JobStatus(edit: render(.error, error: "error.edit.timeout", kind: .chat), now: t0)
        #expect(chat?.canRetry == false && chat?.canFocus == false, "a chat video has no project to open or try again from")
    }

    @Test func aFinishedJobThatLeftTheQueueIsARecentOne() {
        let saved = FinishedWork(id: UUID(), title: "x · 1", outcome: .saved, finishedAt: t0, mediaID: "m1")
        var s = JobStatus(finished: saved)
        #expect(s.stage == .completed(cloudSaved: true, deviceCopy: .savedOnDevice) && s.mediaID == "m1" && s.bucket == .settled)
        s = JobStatus(finished: FinishedWork(id: UUID(), title: "w", outcome: .webp(WebpResult(job: "j", url: URL(string: "https://x.test/a.webp")!, bytes: 1, width: 1, height: 1, seconds: 1)), finishedAt: t0))
        #expect(s.kind == .webpRender && s.stage == .completed(cloudSaved: true, deviceCopy: .notNeeded))
    }

    @Test func theAlbumAddingSavesIsOneStatusWhileItAdds() {
        let s = JobStatus(photos: PhotosSync.Progress(done: 3, total: 7), now: t0)
        #expect(s?.kind == .photosExport && s?.stage == .deviceCopy(bytes: nil, total: nil) && s?.fraction == 3.0 / 7.0 && s?.id == "photos")
        #expect(JobStatus(photos: nil, now: t0) == nil && JobStatus(photos: PhotosSync.Progress(done: 0, total: 0), now: t0) == nil)
    }
}
