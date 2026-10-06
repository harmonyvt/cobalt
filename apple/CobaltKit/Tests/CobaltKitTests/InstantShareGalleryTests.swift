import Foundation
import Synchronization
import Testing
@testable import CobaltKit

// The share sheet for a gallery (apple/CONTRACT-GALLERY.md 1.12; APP-API-CONTRACT 18.12): the 700 ms and 8 s budgets on a
// clock the test turns by hand, ONE sheet height (the `rows` the sheet is built from never changes once it shows), one
// request per choice with the 18.12 bodies, a single item closing without a sheet, the older-server card.

private let apiKey = "7c1f2a60-4b0e-4d2f-9a53-3f1d8e9b6a21"
private let apiBase = URL(string: "https://api.capybaraharmony.com")!
private let igLink = LinkInfo(URL(string: "https://www.instagram.com/p/Ddy0-gpGg5U/")!)!
private let igTitle = "instagram · Ddy0-gpGg5U"

// MARK: - A clock you turn by hand

final class GSClock: @unchecked Sendable {
    private struct Waiter { var id: Int; var deadline: Duration; var continuation: CheckedContinuation<Void, any Error> }
    private let lock = NSLock()
    private var nextID = 0
    private var elapsed: Duration = .zero
    private var waiters: [Waiter] = []
    private var cancelled = Set<Int>()

    var now: Duration { lock.withLock { elapsed } }

    func sleep(_ duration: Duration) async throws {
        let id = lock.withLock { () -> Int in nextID += 1; return nextID }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, any Error>) in
                let gone = lock.withLock { () -> Bool in
                    if cancelled.remove(id) != nil { return true }
                    waiters.append(Waiter(id: id, deadline: elapsed + duration, continuation: c))
                    return false
                }
                if gone { c.resume(throwing: CancellationError()) }
            }
        } onCancel: {
            let waiter: Waiter? = lock.withLock {
                guard let i = waiters.firstIndex(where: { $0.id == id }) else { cancelled.insert(id); return nil }
                return waiters.remove(at: i)
            }
            waiter?.continuation.resume(throwing: CancellationError())
        }
    }

    /// Moves the clock forward, waking every sleeper whose time comes, in order, letting the work they start run.
    @MainActor
    func advance(by duration: Duration) async {
        await gsSettle()                                                        // sleepers the flow just started get to register
        let target = lock.withLock { elapsed + duration }
        while true {
            let next: Waiter? = lock.withLock {
                guard let i = waiters.indices.filter({ waiters[$0].deadline <= target })
                    .min(by: { waiters[$0].deadline < waiters[$1].deadline }) else { return nil }
                let waiter = waiters.remove(at: i)
                elapsed = max(elapsed, waiter.deadline)
                return waiter
            }
            guard let next else { break }
            next.continuation.resume()
            await gsSettle()
        }
        lock.withLock { elapsed = target }
        await gsSettle()
    }
}

/// Lets every task that is ready run (the flow's tasks hop between the main actor and the fakes).
@MainActor
func gsSettle() async {
    for _ in 0..<40 { await Task.yield() }
    try? await Task.sleep(for: .milliseconds(3))
    for _ in 0..<40 { await Task.yield() }
}

// MARK: - The server and the sender

actor GSGate<T: Sendable> {
    private var value: T?
    private var waiters: [Int: CheckedContinuation<T?, Never>] = [:]
    private var next = 0

    func wait() async -> T? {
        if let value { return value }
        let id = next
        next += 1
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (c: CheckedContinuation<T?, Never>) in
                if Task.isCancelled { c.resume(returning: nil) } else { waiters[id] = c }
            }
        } onCancel: {
            Task { await self.cancel(id) }
        }
    }

    private func cancel(_ id: Int) { waiters.removeValue(forKey: id)?.resume(returning: nil) }

    func open(_ v: T) {
        value = v
        for (_, c) in waiters { c.resume(returning: v) }
        waiters.removeAll()
    }
}

final class GSServer: ShareGalleryServer, @unchecked Sendable {
    let resolveGate = GSGate<Result<CobaltResult, CobaltError>>()
    let capsGate = GSGate<Capabilities>()
    private let asked = Mutex<(resolves: Int, caps: Int)>((0, 0))

    var resolves: Int { asked.withLock { $0.resolves } }
    var capabilityReads: Int { asked.withLock { $0.caps } }

    func resolve(_ link: URL) async throws -> CobaltResult {
        asked.withLock { $0.resolves += 1 }
        guard let answer = await resolveGate.wait() else { throw CancellationError() }
        return try answer.get()
    }

    func capabilities() async -> Capabilities {
        asked.withLock { $0.caps += 1 }
        return await capsGate.wait() ?? .unknown
    }

    func answer(_ result: CobaltResult, caps: Capabilities) async {
        await resolveGate.open(.success(result))
        await capsGate.open(caps)
    }
}

final class GSSender: ShareGallerySender, @unchecked Sendable {
    private let state = Mutex<(sent: [ShareSend], result: InstantShare.Result)>(([], .saved))
    var holdGate: GSGate<Bool>?

    var sent: [ShareSend] { state.withLock { $0.sent } }
    var result: InstantShare.Result {
        get { state.withLock { $0.result } }
        set { state.withLock { $0.result = newValue } }
    }

    func send(_ request: ShareSend, job: UUID) async -> InstantShare.Result {
        state.withLock { $0.sent.append(request) }
        if let holdGate { _ = await holdGate.wait() }
        return state.withLock { $0.result }
    }

    /// The options of the one request, when it was a gallery request.
    var options: StudioCreateOptions? {
        for case .options(_, let o) in sent { return o }
        return nil
    }
}

final class GSNotices: @unchecked Sendable {
    private let state = Mutex<(posted: [(head: String, body: String)], removed: Int)>(([], 0))
    var posted: [(head: String, body: String)] { state.withLock { $0.posted } }
    var removed: Int { state.withLock { $0.removed } }
    func post(_ head: String, _ body: String) { state.withLock { $0.posted.append((head, body)) } }
    func remove() { state.withLock { $0.removed += 1 } }
}

func gsPicker(_ kinds: [MediaType]) -> CobaltResult {
    .picker(items: kinds.enumerated().map { PickerItem(id: $0.offset, type: $0.element, url: URL(string: "https://cdn.example/\($0.offset)")!) }, audio: nil)
}

func gsCaps(gallery: Bool = true, make: Bool = true) -> Capabilities {
    var caps = Capabilities.unknown
    caps.kind = .fork
    caps.studio = true
    caps.createNotify = true
    caps.gallery = gallery
    caps.galleryMake = gallery && make
    return caps
}

@MainActor
struct GSRig {
    let flow: ShareGalleryFlow
    let server: GSServer
    let sender: GSSender
    let clock: GSClock
    let notices: GSNotices

    init(link: LinkInfo = igLink, makePublic: Bool = true) {
        server = GSServer()
        sender = GSSender()
        clock = GSClock()
        notices = GSNotices()
        let notices = notices, clock = clock
        var env = ShareGalleryEnvironment(server: server, sender: sender)
        env.sleep = { try await clock.sleep($0) }
        env.notify = { _, head, body in notices.post(head, body) }
        env.unnotify = { _ in notices.remove() }
        env.makePublic = makePublic
        env.now = { Date(timeIntervalSince1970: 1_000 + Double(clock.now.components.seconds) + Double(clock.now.components.attoseconds) / 1e18) }
        flow = ShareGalleryFlow(link: link, env: env)
    }

    func begin() { flow.begin() }

    func answer(_ result: CobaltResult, caps: Capabilities = gsCaps()) async {
        await server.answer(result, caps: caps)
        await gsSettle()
    }
}

private func ms(_ n: Int) -> Duration { .milliseconds(n) }

// MARK: - Timing: 700 ms and 8 s

@Suite @MainActor struct ShareGalleryTimingTests {
    @Test func aPickerThatAnswersInTimeShowsTheSheetOnceComplete() async {
        let rig = GSRig()
        rig.begin()
        #expect(rig.flow.phase == .resolving && !rig.flow.sheetShown)
        await rig.clock.advance(by: ms(420))
        #expect(!rig.flow.sheetShown, "nothing is shown while the server is still being asked")
        await rig.answer(gsPicker(Array(repeating: .photo, count: 10)))
        #expect(rig.flow.phase == .choosing && rig.flow.sheetShown)
        #expect(rig.flow.rows == .full && rig.flow.canMake)
        let summary = rig.flow.summary
        #expect(summary?.count == 10 && summary?.photos == 10 && summary?.videos == 0 && summary?.photosOnly == true)
        // the clock running on does not change what the sheet is
        await rig.clock.advance(by: ms(9_000))
        #expect(rig.flow.phase == .choosing && rig.sender.sent.isEmpty, "waiting on the owner is not the 8 s fallback")
    }

    @Test func noAnswerAt700msShowsTheSameSheetCheckingAndTheAnswerFillsItInPlace() async {
        let rig = GSRig()
        rig.begin()
        await rig.clock.advance(by: ms(699))
        #expect(!rig.flow.sheetShown)
        await rig.clock.advance(by: ms(1))
        #expect(rig.flow.phase == .checking && rig.flow.sheetShown && rig.flow.rows == .full)
        let rowsWhileChecking = rig.flow.rows
        await rig.clock.advance(by: ms(4_500))                                  // 5.2 s: the server wakes
        await rig.answer(gsPicker(Array(repeating: .photo, count: 10)))
        #expect(rig.flow.phase == .choosing)
        #expect(rig.flow.rows == rowsWhileChecking, "the sheet's rows (and so its height) do not change when the answer comes")
        #expect(rig.flow.canChoose && rig.flow.canMake)
    }

    @Test func theHeaderSaysItIsWakingTheServerAfter2point5Seconds() async {
        let rig = GSRig()
        rig.begin()
        await rig.clock.advance(by: ms(2_499))
        #expect(rig.flow.phase == .checking && !rig.flow.waking)
        await rig.clock.advance(by: ms(1))
        #expect(rig.flow.waking)
    }

    @Test func after8SecondsWithNoAnswerItSavesEverythingAndCloses() async throws {
        let rig = GSRig()
        rig.begin()
        await rig.clock.advance(by: ms(7_999))
        #expect(rig.sender.sent.isEmpty)
        await rig.clock.advance(by: ms(1))
        #expect(rig.sender.sent.count == 1)
        let options = try #require(rig.sender.options)
        #expect(options.items == .all && options.itemCount == nil, "no count: nothing was seen to check against")
        #expect(options.notify == NotifyOptIn(on: [.saved, .failed], label: igTitle))
        #expect(options.slideshow == nil && options.galleryImage == nil)
        #expect(rig.notices.posted.count == 1)
        #expect(rig.notices.posted.first?.head == "saving everything to cobalt" && rig.notices.posted.first?.body == "open cobalt to make something from it")
        #expect(rig.flow.finish == nil && rig.flow.phase == .sent(.timeout), "the sheet is on screen: `sent` holds a moment")
        await rig.clock.advance(by: ms(500))
        #expect(rig.flow.finish == .sent)
    }

    @Test func aPickerWithoutCapabilitiesWaitsForThemAndThenFallsBackAt8Seconds() async {
        let rig = GSRig()
        rig.begin()
        await rig.server.resolveGate.open(.success(gsPicker([.photo, .photo, .photo])))
        await gsSettle()
        #expect(rig.flow.phase == .resolving, "the rows depend on what the server can do")
        await rig.clock.advance(by: ms(700))
        #expect(rig.flow.phase == .checking)
        await rig.server.capsGate.open(gsCaps())
        await gsSettle()
        #expect(rig.flow.phase == .choosing)
    }

    @Test func capabilitiesThatNeverComeStillEndAtTheFallback() async {
        let rig = GSRig()
        rig.begin()
        await rig.server.resolveGate.open(.success(gsPicker([.photo, .photo, .photo])))
        await rig.clock.advance(by: ms(8_000))
        #expect(rig.sender.sent.count == 1 && rig.sender.options?.items == .all)
    }
}

// MARK: - One item: notification only

@Suite @MainActor struct ShareGallerySingleTests {
    @Test func aReelAnsweredInTimeIsTheInstantSaveAndNoSheetEverShows() async {
        let rig = GSRig()
        rig.begin()
        await rig.clock.advance(by: ms(380))
        await rig.answer(.file(url: URL(string: "https://cdn.example/a.mp4")!, filename: nil))
        #expect(rig.sender.sent == [.plain(igLink)])
        #expect(!rig.flow.sheetShown)
        #expect(rig.flow.finish == .sent, "nothing is shown, so nothing is held")
        #expect(rig.notices.posted.map(\.head) == ["saving to cobalt"] && rig.notices.posted.first?.body == igTitle)
    }

    @Test func aOnePhotoPickerIsASingleItemToo() async {
        let rig = GSRig()
        rig.begin()
        await rig.answer(gsPicker([.photo]))
        #expect(rig.sender.sent == [.plain(igLink)] && !rig.flow.sheetShown && rig.flow.finish == .sent)
    }

    @Test func aSlowAnswerThatIsOneItemClosesTheSheetWithSentToCobalt() async {
        let rig = GSRig()
        rig.begin()
        await rig.clock.advance(by: ms(5_000))
        #expect(rig.flow.phase == .checking && rig.flow.sheetShown)
        await rig.answer(.file(url: URL(string: "https://cdn.example/a.mp4")!, filename: nil))
        #expect(rig.sender.sent == [.plain(igLink)])
        #expect(rig.flow.phase == .sent(.single) && rig.flow.finish == nil, "`sent to cobalt` holds a beat")
        await rig.clock.advance(by: ms(499))
        #expect(rig.flow.finish == nil)
        await rig.clock.advance(by: ms(1))
        #expect(rig.flow.finish == .sent)
    }

    @Test func aLinkTheServerCannotResolveIsStillSavedAndTheServerSaysWhyThroughHark() async {
        let rig = GSRig()
        rig.begin()
        await rig.server.resolveGate.open(.failure(.api(code: "error.api.content.post.unavailable", httpStatus: 200)))
        await gsSettle()
        #expect(rig.sender.sent == [.plain(igLink)])
        #expect(rig.flow.finish == .sent)
    }
}

// MARK: - A gallery: the three choices, one request each

@Suite @MainActor struct ShareGalleryChoiceTests {
    private func choosing(_ kinds: [MediaType], caps: Capabilities = gsCaps(), makePublic: Bool = true) async -> GSRig {
        let rig = GSRig(makePublic: makePublic)
        rig.begin()
        await rig.answer(gsPicker(kinds), caps: caps)
        return rig
    }

    @Test func saveAllSendsOneRequestWithTheCountAndTheSavedOptIn() async throws {
        let rig = await choosing(Array(repeating: .photo, count: 10))
        rig.flow.choose(.saveAll)
        await gsSettle()
        #expect(rig.sender.sent.count == 1)
        let o = try #require(rig.sender.options)
        #expect(o.items == .all && o.itemCount == 10 && o.origin == "share" && o.queue && o.makePublic == true)
        #expect(o.notify == NotifyOptIn(on: [.saved, .failed], label: igTitle))
        #expect(o.slideshow == nil && o.galleryImage == nil)
        #expect(rig.notices.posted.first?.head == "saving 10 photos to cobalt" && rig.notices.posted.first?.body == igTitle)
        #expect(rig.flow.phase == .sent(.saveAll))
        await rig.clock.advance(by: ms(500))
        #expect(rig.flow.finish == .sent)
    }

    @Test func slideshowWebpSendsThePlanWithTheRenderedOptInAndTheOwnersWebpSettings() async throws {
        let rig = await choosing(Array(repeating: .photo, count: 10))
        rig.flow.choose(.slideshowWebp)
        await gsSettle()
        let o = try #require(rig.sender.options)
        #expect(o.notify == NotifyOptIn(on: [.rendered, .failed], label: igTitle))
        let plan = try #require(o.slideshow)
        #expect(plan.format == .webp && plan.items == Array(0..<10) && plan.photoSeconds == 2 && plan.fade)
        #expect(plan.frame == .asPosted && plan.sound == .none && plan.quality == .med && plan.width == 480)
        #expect(o.galleryImage == nil && o.itemCount == 10)
        #expect(rig.notices.posted.first?.head == "saving 10 photos to cobalt" && rig.notices.posted.first?.body == "making a slideshow webp · \(igTitle)")
    }

    @Test(arguments: GalleryLayout.allCases)
    func galleryImageSendsTheLayoutTheOwnerTapped(_ layout: GalleryLayout) async throws {
        let rig = await choosing(Array(repeating: .photo, count: 10))
        rig.flow.choose(.galleryImage(layout))
        await gsSettle()
        let o = try #require(rig.sender.options)
        #expect(o.galleryImage == GalleryImagePlan(items: Array(0..<10), layout: layout) && o.slideshow == nil)
        #expect(o.notify?.on == [.rendered, .failed])
        #expect(rig.notices.posted.first?.body == "making a gallery image · \(igTitle)")
    }

    @Test func aSecondTapSendsNothingMore() async {
        let rig = await choosing(Array(repeating: .photo, count: 4))
        rig.flow.choose(.saveAll)
        rig.flow.choose(.slideshowWebp)
        rig.flow.choose(.galleryImage(.strip))
        await gsSettle()
        #expect(rig.sender.sent.count == 1 && rig.notices.posted.count == 1)
    }

    @Test func saveNowInTheCheckingStateSendsEverythingWithNoCount() async throws {
        let rig = GSRig()
        rig.begin()
        await rig.clock.advance(by: ms(1_000))
        #expect(rig.flow.phase == .checking && rig.flow.canSaveNow && !rig.flow.canChoose)
        rig.flow.choose(.saveAll)                                               // row 1 in this state
        await gsSettle()
        let o = try #require(rig.sender.options)
        #expect(o.items == .all && o.itemCount == nil && o.notify == NotifyOptIn(on: [.saved, .failed], label: igTitle))
        #expect(rig.notices.posted.first?.head == "saving everything to cobalt")
        // the answer that comes later changes nothing: one request, ever
        await rig.answer(gsPicker([.photo, .photo]))
        #expect(rig.sender.sent.count == 1)
    }

    @Test func aMixedPostSendsSecondsNullForVideosAndOnlyPhotosInTheImage() async throws {
        let kinds: [MediaType] = [.photo, .video, .photo, .gif]
        let webp = await choosing(kinds)
        #expect(webp.flow.summary?.photos == 2 && webp.flow.summary?.videos == 2 && webp.flow.summary?.photosOnly == false)
        webp.flow.choose(.slideshowWebp)
        await gsSettle()
        let plan = try #require(webp.sender.options?.slideshow)
        #expect(plan.seconds(for: webp.sender.options?.itemInfo ?? []) == [2, nil, 2, nil])
        #expect(webp.notices.posted.first?.head == "saving 4 items to cobalt")
        let image = await choosing(kinds)
        image.flow.choose(.galleryImage(.grid3))
        await gsSettle()
        let sent = try #require(image.sender.options)
        #expect(sent.galleryImage?.photoOnly(in: sent.itemInfo).items == [0, 2])
    }

    @Test func aGalleryImageNeedsTwoPhotos() async {
        let rig = await choosing([.photo, .video])
        #expect(rig.flow.summary?.imagePossible == false)
        rig.flow.choose(.galleryImage(.grid3))
        await gsSettle()
        #expect(rig.sender.sent.isEmpty, "the row is disabled")
        rig.flow.choose(.slideshowWebp)
        await gsSettle()
        #expect(rig.sender.sent.count == 1, "the webp row is still live")
    }

    @Test func moreThan20ItemsNameTheFirst20AndTheRealCount() async throws {
        let rig = await choosing(Array(repeating: .photo, count: 21))
        #expect(rig.flow.summary?.count == 20 && rig.flow.summary?.total == 21)
        rig.flow.choose(.slideshowWebp)
        await gsSettle()
        let o = try #require(rig.sender.options)
        #expect(o.itemCount == 21 && o.slideshow?.items == Array(0..<20))
    }

    @Test func aPrivateSaveLeavesPublicOut() async throws {
        let rig = await choosing([.photo, .photo], makePublic: false)
        rig.flow.choose(.saveAll)
        await gsSettle()
        #expect(rig.sender.options?.makePublic == nil)
    }

    @Test func theWebpRowsEstimateIsAboutTwentySecondsForTenPhotos() async throws {
        let rig = await choosing(Array(repeating: .photo, count: 10))
        let summary = try #require(rig.flow.summary)
        #expect(summary.webpSeconds == 20)
        // 10 stills + 9 crossfades at 480×600, the contract's 6.5 constants: 1.7-1.8 MB
        #expect((1_700_000...1_800_000).contains(summary.webpBytes), "\(summary.webpBytes)")
    }
}

// MARK: - A server that cannot (yet)

@Suite @MainActor struct ShareGalleryServerTests {
    @Test func aServerWithoutGalleriesShowsTheSameHeightCardAndSendsNothing() async {
        let rig = GSRig()
        rig.begin()
        await rig.answer(gsPicker([.photo, .photo, .photo]), caps: gsCaps(gallery: false))
        #expect(rig.flow.phase == .oldServer && rig.flow.sheetShown && rig.flow.rows == .full)
        rig.flow.choose(.saveAll)
        await gsSettle()
        #expect(rig.sender.sent.isEmpty, "there are no choices on this card")
        rig.flow.openCobalt()
        #expect(rig.flow.finish == .openCobalt && rig.sender.sent.isEmpty)
    }

    @Test func closingTheOldServerCardSendsNothing() async {
        let rig = GSRig()
        rig.begin()
        await rig.answer(gsPicker([.photo, .photo, .photo]), caps: gsCaps(gallery: false))
        rig.flow.cancel()
        #expect(rig.flow.finish == .cancelled && rig.sender.sent.isEmpty)
    }

    @Test func noMakesKnownBeforeTheSheetShowsIsTheShorterOneRowSheet() async {
        let rig = GSRig()
        rig.begin()
        await rig.clock.advance(by: ms(450))
        await rig.answer(gsPicker([.photo, .photo, .photo]), caps: gsCaps(make: false))
        #expect(rig.flow.phase == .choosing && rig.flow.rows == .short && !rig.flow.canMake)
        rig.flow.choose(.slideshowWebp)
        await gsSettle()
        #expect(rig.sender.sent.isEmpty)
        rig.flow.choose(.saveAll)
        await gsSettle()
        #expect(rig.sender.sent.count == 1)
    }

    @Test func noMakesFoundOutWhileTheSheetShowsKeepsTheRowsDisabledAtTheSameHeight() async {
        let rig = GSRig()
        rig.begin()
        await rig.clock.advance(by: ms(1_000))
        let rows = rig.flow.rows
        await rig.answer(gsPicker([.photo, .photo, .photo]), caps: gsCaps(make: false))
        #expect(rig.flow.phase == .choosing && rig.flow.rows == rows && rows == .full && !rig.flow.canMake)
        rig.flow.choose(.galleryImage(.grid3))
        rig.flow.choose(.slideshowWebp)
        await gsSettle()
        #expect(rig.sender.sent.isEmpty)
    }

    @Test func theRowsAreDecidedOnceWhateverTheOrderOfEvents() async {
        // every path to a gallery sheet: its rows are one of two values, and a shown sheet keeps its value
        for (delay, make) in [(0, true), (0, false), (900, true), (900, false), (3_000, true)] {
            let rig = GSRig()
            rig.begin()
            await rig.clock.advance(by: ms(delay))
            let before = rig.flow.sheetShown ? rig.flow.rows : nil
            await rig.answer(gsPicker([.photo, .photo, .photo]), caps: gsCaps(make: make))
            let shownRows = rig.flow.rows
            if let before { #expect(before == shownRows) }
            await rig.clock.advance(by: ms(1_000))
            #expect(rig.flow.rows == shownRows)
        }
    }
}

// MARK: - Closing, failing

@Suite @MainActor struct ShareGalleryEndingTests {
    @Test func closingTheChoiceSheetSendsNothing() async {
        let rig = GSRig()
        rig.begin()
        await rig.answer(gsPicker([.photo, .photo, .photo]))
        rig.flow.cancel()
        #expect(rig.flow.finish == .cancelled && rig.sender.sent.isEmpty && rig.notices.posted.isEmpty)
    }

    @Test func closingWhileCheckingStopsTheClockAndSendsNothing() async {
        let rig = GSRig()
        rig.begin()
        await rig.clock.advance(by: ms(1_000))
        rig.flow.cancel()
        await rig.clock.advance(by: ms(10_000))
        #expect(rig.flow.finish == .cancelled && rig.sender.sent.isEmpty, "the 8 s fallback does not fire for a sheet the owner closed")
    }

    @Test func aRequestInFlightCannotBeClosedAway() async {
        let rig = GSRig()
        rig.sender.holdGate = GSGate<Bool>()
        rig.begin()
        await rig.answer(gsPicker([.photo, .photo, .photo]))
        rig.flow.choose(.saveAll)
        await gsSettle()
        #expect(rig.flow.isSending)
        rig.flow.cancel()
        #expect(rig.flow.finish == nil && rig.flow.isSending)
        await rig.sender.holdGate?.open(true)
        await gsSettle()
        #expect(!rig.flow.isSending)
    }

    @Test func aRefusedRequestFailsInsideTheShownSheetAndTakesTheNotificationBack() async {
        let rig = GSRig()
        rig.sender.result = .failed(.rejected(status: 401))
        rig.begin()
        await rig.answer(gsPicker([.photo, .photo, .photo]))
        rig.flow.choose(.slideshowWebp)
        await gsSettle()
        #expect(rig.flow.phase == .failed(.rejected(status: 401)) && rig.flow.sheetShown)
        #expect(rig.flow.cardFailure == nil, "the sheet draws it inside its own frame")
        #expect(rig.notices.removed == 1 && rig.flow.finish == nil)
        rig.flow.openCobalt()
        #expect(rig.flow.finish == .openCobalt)
    }

    @Test func aRefusedSingleSaveWithNoSheetIsTheControllersOneLineCard() async {
        let rig = GSRig()
        rig.sender.result = .failed(.unreachable)
        rig.begin()
        await rig.answer(.file(url: URL(string: "https://cdn.example/a.mp4")!, filename: nil))
        #expect(rig.flow.cardFailure == .unreachable && !rig.flow.sheetShown && rig.flow.finish == nil)
    }
}

// MARK: - On the wire: the real engine and a fake transport (no app group: the foreground transport)

@Suite @MainActor struct ShareGalleryWireTests {
    private func wire(
        kinds: [MediaType], caps: Capabilities = gsCaps(), choose: ShareGalleryFlow.Request,
        background: Bool = true
    ) async throws -> (json: [String: Any], request: URLRequest, transport: FakeSaveTransport) {
        let transport = FakeSaveTransport(background: background)
        transport.autoAnswer = { _ in .status(201, Data(#"{"status":"success","id":"aB3dE6gH9jK2mN5pQ8sTuV"}"#.utf8)) }
        let client = HTTPCobaltClient(baseURL: apiBase, apiKey: { apiKey })
        let engine = InstantShareEngine(transport: transport, directory: try makeTempDirectory(), foregroundWait: 2, registerWait: 0.2)
        let server = GSServer()
        let clock = GSClock()
        var env = ShareGalleryEnvironment(server: server, sender: EngineShareSender(engine: engine, client: client))
        env.sleep = { try await clock.sleep($0) }
        let flow = ShareGalleryFlow(link: igLink, env: env)
        flow.begin()
        await server.answer(gsPicker(kinds), caps: caps)
        await gsSettle()
        flow.choose(choose)
        for _ in 0..<200 where transport.uploads.isEmpty { try? await Task.sleep(for: .milliseconds(10)) }
        let upload = try #require(transport.uploads.first)
        #expect(transport.uploads.count == 1, "one request per choice")
        let json = try #require(try JSONSerialization.jsonObject(with: upload.body) as? [String: Any])
        return (json, upload.request, transport)
    }

    private let ten = Array(repeating: MediaType.photo, count: 10)

    @Test func saveAllIsThe18_12Body() async throws {
        let (json, request, _) = try await wire(kinds: ten, choose: .saveAll)
        #expect(request.httpMethod == "POST" && request.url?.absoluteString == "https://api.capybaraharmony.com/studio")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Api-Key \(apiKey)")
        let expected: [String: Any] = [
            "url": "https://www.instagram.com/p/Ddy0-gpGg5U/", "items": "all", "item_count": 10, "public": true,
            "origin": "share", "queue": true,
            "notify": ["on": ["saved", "failed"], "label": igTitle] as [String: Any],
        ]
        #expect(NSDictionary(dictionary: json).isEqual(to: expected), "\(json)")
    }

    @Test func slideshowWebpIsThe18_12Body() async throws {
        let (json, _, _) = try await wire(kinds: ten, choose: .slideshowWebp)
        let expected: [String: Any] = [
            "url": "https://www.instagram.com/p/Ddy0-gpGg5U/", "items": "all", "item_count": 10, "public": true,
            "origin": "share", "queue": true,
            "notify": ["on": ["rendered", "failed"], "label": igTitle] as [String: Any],
            "slideshow": [
                "items": Array(0..<10), "seconds": Array(repeating: 2, count: 10), "fade": true, "frame": "keep",
                "sound": "none", "format": "webp", "quality": "med", "width": 480,
            ] as [String: Any],
        ]
        #expect(NSDictionary(dictionary: json).isEqual(to: expected), "\(json)")
    }

    @Test func galleryImageIsThe18_12Body() async throws {
        let (json, _, _) = try await wire(kinds: ten, choose: .galleryImage(.grid3))
        let expected: [String: Any] = [
            "url": "https://www.instagram.com/p/Ddy0-gpGg5U/", "items": "all", "item_count": 10, "public": true,
            "origin": "share", "queue": true,
            "notify": ["on": ["rendered", "failed"], "label": igTitle] as [String: Any],
            "gallery_image": ["items": Array(0..<10), "layout": "grid3"] as [String: Any],
        ]
        #expect(NSDictionary(dictionary: json).isEqual(to: expected), "\(json)")
    }

    @Test func aMixedPostSendsNullSecondsForItsVideosAndGif() async throws {
        let (json, _, _) = try await wire(kinds: [.photo, .video, .photo, .gif], choose: .slideshowWebp)
        let seconds = try #require((json["slideshow"] as? [String: Any])?["seconds"] as? [Any])
        #expect(seconds.count == 4 && (seconds[0] as? Int) == 2 && seconds[1] is NSNull && (seconds[2] as? Int) == 2 && seconds[3] is NSNull)
        let (image, _, _) = try await wire(kinds: [.photo, .video, .photo, .gif], choose: .galleryImage(.strip))
        #expect((image["gallery_image"] as? [String: Any])?["items"] as? [Int] == [0, 2])
    }

    @Test func theForegroundTransportWaitsForTheServersAnswerAndAFailureShowsInTheSheet() async throws {
        // no app group: the request goes through an ephemeral session and the sheet waits for the answer
        let transport = FakeSaveTransport(background: false)
        transport.autoAnswer = { _ in .status(401, Data()) }
        let client = HTTPCobaltClient(baseURL: apiBase, apiKey: { apiKey })
        let engine = InstantShareEngine(transport: transport, directory: try makeTempDirectory(), foregroundWait: 2, registerWait: 0.2)
        let server = GSServer()
        let clock = GSClock()
        var env = ShareGalleryEnvironment(server: server, sender: EngineShareSender(engine: engine, client: client))
        env.sleep = { try await clock.sleep($0) }
        let flow = ShareGalleryFlow(link: igLink, env: env)
        flow.begin()
        await server.answer(gsPicker([.photo, .photo, .photo]), caps: gsCaps())
        await gsSettle()
        flow.choose(.saveAll)
        for _ in 0..<200 where flow.isSending || flow.phase == .choosing { try? await Task.sleep(for: .milliseconds(10)) }
        #expect(flow.phase == .failed(.rejected(status: 401)) && flow.sheetShown)
    }

    @Test func aSingleItemUsesTodaysInstantBody() async throws {
        let transport = FakeSaveTransport(background: true)
        let client = HTTPCobaltClient(baseURL: apiBase, apiKey: { apiKey })
        let engine = InstantShareEngine(transport: transport, directory: try makeTempDirectory(), foregroundWait: 2, registerWait: 0.2)
        let server = GSServer()
        let clock = GSClock()
        var env = ShareGalleryEnvironment(server: server, sender: EngineShareSender(engine: engine, client: client))
        env.sleep = { try await clock.sleep($0) }
        let flow = ShareGalleryFlow(link: igLink, env: env)
        flow.begin()
        await server.answer(.file(url: URL(string: "https://cdn.example/a.mp4")!, filename: nil), caps: gsCaps())
        for _ in 0..<200 where transport.uploads.isEmpty { try? await Task.sleep(for: .milliseconds(10)) }
        let upload = try #require(transport.uploads.first)
        let json = try #require(try JSONSerialization.jsonObject(with: upload.body) as? [String: Any])
        #expect(Set(json.keys) == ["url", "public", "origin", "notify"], "no items: the server's own rule")
        for _ in 0..<300 where flow.finish == nil { try? await Task.sleep(for: .milliseconds(10)) }
        #expect(flow.finish == .sent)
    }
}

// MARK: - Words

@Suite struct ShareGalleryTextTests {
    private func summary(photos: Int, videos: Int) -> ShareGalleryFlow.Summary {
        ShareGalleryFlow.Summary(
            items: (0..<(photos + videos)).map { GalleryItem(id: $0, type: $0 < photos ? .photo : .video) }, total: photos + videos,
            photos: photos, videos: videos, webpSeconds: 0, webpBytes: 0)
    }

    @Test func theNotificationsReadLikeTheContract() {
        #expect(ShareGalleryText.saving(summary(photos: 10, videos: 0)) == "saving 10 photos to cobalt")
        #expect(ShareGalleryText.saving(summary(photos: 2, videos: 2)) == "saving 4 items to cobalt")
        #expect(ShareGalleryText.saving(summary(photos: 1, videos: 0)) == "saving 1 photo to cobalt")
        #expect(ShareGalleryText.saving(nil) == "saving everything to cobalt")
    }

    @Test func theLocalNotificationCarriesTheSameWords() {
        let request = Notifications.instantSavingRequest(job: UUID(), title: "saving 10 photos to cobalt", body: "making a gallery image · x · @a")
        #expect(request.content.title == "saving 10 photos to cobalt" && request.content.body == "making a gallery image · x · @a")
        #expect(request.content.userInfo["url"] as? String == Notifications.openURL)
        let plain = Notifications.instantSavingRequest(job: UUID(), label: "instagram · Dc2QA4ng-US")
        #expect(plain.content.title == "saving to cobalt" && plain.content.body == "instagram · Dc2QA4ng-US")
    }

    @Test func theTitleIsTheServiceAndHandle() {
        let x = LinkInfo(URL(string: "https://x.com/ilokineedsleep/status/2106850389551374806?s=20")!)!
        #expect(InstantShareEngine.label(for: x) == "x · @ilokineedsleep")
        #expect(InstantShareEngine.label(for: igLink) == igTitle)
    }

    @Test func theBudgetsArePinned() {
        let t = ShareGalleryTiming.standard
        #expect(t.showAfter == .milliseconds(700) && t.giveUpAfter == .seconds(8) && t.wakingAfter == .milliseconds(2500))
    }
}
