import Foundation
import Synchronization
import Testing
@testable import CobaltKit

// CONTRACT-OFFLINE.md 13.8, 13.9, 13.13.2: the Mac's pull of saves made anywhere. The library is a scripted list the rig pages
// through like the server does (cursor = an index), the engine's session is the fake you drive by hand, the store is a real
// `.macFolder` store over temp directories, the clock is virtual. Nothing here touches the real home folder.

private let apiBase = URL(string: "https://api.capybaraharmony.com")!
private let link = URL(string: "https://www.instagram.com/reel/DeHC9jcpfQW/")!
private let galleryLink = URL(string: "https://www.instagram.com/p/DeKlsGCGZmx/")!

private func pullWebpURL(_ name: String) -> URL { URL(string: "https://media.capybaraharmony.com/\(name).webp")! }

/// A world: a Mac (store, folder, ledgers, engine, pull) and a library the server would list.
@MainActor
final class PullRig {
    let mac: MacRig
    let store: OfflineStore
    let transport = FakeOfflineTransport()
    let queue: OfflineQueue
    let ledger: PullLedger
    let clock = VirtualClock()
    let client = HTTPCobaltClient(baseURL: apiBase, apiKey: { "KEY-1234" })
    let engine: OfflineDownloads
    private(set) var pull: SavePull!

    // what the server and the app say
    var library: [LibraryPost] = []
    var requests: [(cursor: String?, limit: Int)] = []
    var pageError: Error?
    var pageDelay: (@MainActor () async -> Void)?
    var gate: CheckedContinuation<Void, Never>?
    var keepOn = true
    var caps: Capabilities
    var held: Set<String> = []
    var uploading = false
    var own: [String] = []
    var token: String? = "KEY-1234"
    var serverID = apiBase.absoluteString
    /// free bytes on the folder's disk (nil: unknown)
    var free: Int64?
    var added: [(video: StoredVideo, origin: AddOrigin)] = []

    /// `massLimit` is unbounded by default: most of these tests walk long libraries and expect every save fetched; the brake's own
    /// tests pass `SavePull.defaultMassLimit`.
    init(maxPages: Int = SavePull.defaultMaxPages, unplugged: Bool = false, massLimit: Int = .max) throws {
        mac = try MacRig(folderName: "Movies/cobalt", createFolder: !unplugged)
        try mac.commit()
        if unplugged { mac.ledger.choose(path: mac.folder.path, bookmark: nil, isDefault: false) }
        store = mac.store()
        queue = OfflineQueue(directory: mac.sync)
        ledger = PullLedger(directory: mac.sync)
        var c = Capabilities.unknown
        c.kind = .fork
        c.key = .valid
        c.library = true
        c.mediaBaseURL = URL(string: "https://media.capybaraharmony.com/")
        caps = c
        engine = OfflineDownloads(store: store, queue: queue, transport: transport, clock: clock, client: { [client] in client })
        store.onAdd = { [weak self] video, origin in self?.added.append((video, origin)) }
        pull = SavePull(
            store: store, ledger: ledger, downloads: engine, clock: clock, scheduler: ClockScheduler(clock: clock), maxPages: maxPages,
            massLimit: massLimit)
        pull.wire(environment())
    }

    func environment() -> SavePull.Environment {
        SavePull.Environment(
            capabilities: { [unowned self] in caps },
            keepOn: { [unowned self] in keepOn },
            page: { [unowned self] cursor, limit in
                requests.append((cursor, limit))
                if let pageDelay { await pageDelay() }
                if let pageError { throw pageError }
                let from = cursor.flatMap(Int.init) ?? 0
                let slice = Array(library.dropFirst(from).prefix(limit))
                let next = from + limit < library.count ? String(from + limit) : nil
                return LibraryPage(posts: slice, postCount: library.count, fileCount: 0, publicBytes: 0, privateBytes: 0, next: next)
            },
            holdsSession: { [unowned self] id in held.contains(id) },
            uploadsInFlight: { [unowned self] in uploading },
            ownUploads: { [unowned self] in own },
            serverID: { [unowned self] in serverID },
            apiToken: { [unowned self] in token },
            freeBytes: { [unowned self] in free })
    }

    var session: FakeOfflineTransport.Session? { transport.session(OfflineDownloads.sessionIdentifier) }
    var tasks: [FakeOfflineTransport.Session.Task] { session?.tasks ?? [] }

    /// Seconds after the virtual epoch.
    func at(_ seconds: Double) -> Date { clock.epoch.addingTimeInterval(seconds) }

    func check() async { await pull.check() }

    // MARK: library fixtures

    func file(
        _ id: String, kind: LibraryFile.Kind = .private, source: LibraryFile.Source = .saved, name: String = "instagram_DeHC9jcpfQW.mp4",
        type: String = "video/mp4", at seconds: Double, url: URL? = nil, visibility: Visibility? = .private, role: GalleryRole? = nil,
        index: Int? = nil, madeSpec: String? = nil, mediaName: String? = nil, bytes: Int64 = 2_000
    ) -> LibraryFile {
        var f = LibraryFile(
            id: id, kind: kind, source: source, name: name, url: url, contentType: type, bytes: bytes, width: 720, height: 1280,
            duration: 5, createdAt: at(seconds), mediaName: mediaName, deletable: kind == .public)
        f.wireVisibility = visibility
        f.galleryRole = role
        f.itemIndex = index
        f.madeSpec = madeSpec.flatMap { MadeSpec(data: Data($0.utf8)) }
        return f
    }

    func webp(_ id: String, name: String, at seconds: Double) -> LibraryFile {
        file(id, kind: .public, source: .webp, name: "\(name).webp", type: "image/webp", at: seconds, url: pullWebpURL(name), visibility: .public, mediaName: "\(name).webp")
    }

    /// A post, newest file first as the server lists it; `createdAt` is its newest file's (the order the pages come in).
    func post(
        _ id: String, files: [LibraryFile], session: String? = nil, link: URL? = link, kind: MediaKind? = nil, items: Int? = nil,
        sessionOpen: Bool = true
    ) -> LibraryPost {
        var p = LibraryPost(
            id: id, service: "instagram", link: link, title: nil, duration: 5, width: 720, height: 1280,
            createdAt: files.map(\.createdAt).max() ?? at(0),
            session: session.map { LibrarySession(id: $0, status: .ready, expiresAt: at(86_400), sourceURL: apiBase.appendingPathComponent("studio/\($0)/source")) },
            files: files.sorted { $0.createdAt > $1.createdAt })
        p.kind = kind
        p.itemCount = items
        return p
    }

    /// A link save: one private original, `id` doubling as the session.
    func saved(_ id: String, at seconds: Double, visibility: Visibility = .private) -> LibraryPost {
        post(id, files: [file("F-\(id)", at: seconds, visibility: visibility)])
    }

    /// Newest first, as the server lists them.
    func publish(_ posts: [LibraryPost]) { library = posts.sorted { $0.createdAt > $1.createdAt } }

    // MARK: the store's side

    @discardableResult
    func save(
        _ name: String = "clip", session: String? = nil, keep: Bool = true, kind: StoredVideo.Kind = .original, remote: URL? = nil,
        role: GalleryRole? = nil, index: Int? = nil, mediaID: String? = nil, libraryID: String? = nil, postItems: Int? = nil,
        madeSpec: Data? = nil, link: URL? = link
    ) async throws -> StoredVideo {
        let file = try makeTempFile("\(name).\(kind == .webp ? "webp" : "mp4")", bytes: 700)
        let info = MediaInfo(name: name, duration: 1, width: 10, height: 10, bytes: nil, isImage: false)
        return try await store.add(
            file: file, kind: kind, media: info, sessionID: session, link: link, remoteURL: remote, move: true, mediaID: mediaID,
            keep: keep, role: role, itemIndex: index, madeSpec: madeSpec, libraryID: libraryID, postItems: postItems)
    }

    /// Lets every task the engine started finish with `bytes` and waits for the queue to empty.
    func landAll(_ bytes: Int = 2_000) async -> Bool {
        guard let session else { return true }
        for id in session.liveIDs.sorted() { session.respond(task: id, status: 200, body: Data(repeating: 9, count: bytes)) }
        return await eventually(15) { self.queue.all().isEmpty }
    }

    func folderFiles() -> [String] { mac.files() }
}

@MainActor
@Suite(.serialized)
struct SavePullTests {
    // MARK: the baseline: "from now on"

    @Test func anExistingLibraryOfSeventyTwoPostsFetchesNothingAndCostsOneRequestOfFive() async throws {
        let t = try PullRig()
        t.publish((0..<72).map { t.saved("P\($0)", at: -Double(($0 + 1) * 3_600)) })
        await t.check()
        #expect(t.requests.count == 1 && t.requests[0].limit == 5 && t.requests[0].cursor == nil, "a quiet check is one request of 5 posts")
        #expect(t.tasks.isEmpty && t.queue.all().isEmpty && t.store.videos.isEmpty && t.folderFiles().isEmpty)
        let f = t.ledger.read()
        #expect(f.enabledAt == t.clock.now() && f.done.isEmpty && f.server == apiBase.absoluteString)
        let status = t.pull.status
        #expect(status.available && status.paused == nil && status.pulling == 0 && status.lastChecked == t.clock.now())
    }

    @Test func aSecondQuietCheckIsOneRequestAgain() async throws {
        let t = try PullRig()
        t.publish((0..<30).map { t.saved("P\($0)", at: -Double(($0 + 1) * 3_600)) })
        await t.check()
        t.clock.jump(by: 300)
        await t.check()
        #expect(t.requests.count == 2 && t.requests[1].limit == 5 && t.requests[1].cursor == nil)
        #expect(t.tasks.isEmpty)
    }

    @Test func aFileMadeBeforeTheBaselineIsNeverFetchedEvenOnAPostWithNewFiles() async throws {
        let t = try PullRig()
        await t.check()                                                  // the baseline is now
        let old = t.file("F-OLD", at: -86_400)
        t.publish([t.post("OLD", files: [old, t.webp("W1", name: "aBcDeFgH01", at: 120)])])
        await t.check()
        #expect(t.tasks.count == 1 && t.tasks[0].request?.url == pullWebpURL("aBcDeFgH01"), "the new webp only: the old original stays on the server")
        #expect(t.ledger.read().done["F-OLD"] == nil)
    }

    // MARK: candidates and landing

    @Test func aNewWebpOnAnOldPostLandsKeptInTheMacFolderWithTheServersDateAndOriginPulled() async throws {
        let t = try PullRig()
        await t.check()
        t.publish([t.post("OLD", files: [t.file("F-OLD", at: -86_400), t.webp("W1", name: "aBcDeFgH01", at: 120)])])
        await t.check()
        let task = try #require(t.tasks.first)
        #expect(task.request?.value(forHTTPHeaderField: "Authorization") == nil, "a public webp is never sent the key")
        let entry = try #require(t.queue.all().first)
        #expect(entry.job.origin == "pulled" && entry.job.isPulled)
        #expect(t.pull.status.pulling == 1)

        #expect(await t.landAll())
        let video = try #require(t.store.videos.first)
        #expect(video.kind == .webp && video.keep && video.place == .offline && video.createdAt == t.at(120), "the server's date")
        #expect(video.remoteURL == pullWebpURL("aBcDeFgH01"))
        #expect(t.added.map(\.origin) == [.pulled])
        let relative = try #require(t.mac.record(video.id)?.visiblePath)
        #expect(t.mac.exists(relative) && t.mac.tag(relative)?.id == video.id, "tagged, in the Mac folder")
        #expect(t.ledger.read().done["W1"]?.state == .queued)
        #expect(t.pull.status.pulling == 0)
    }

    @Test func aNewOriginalComesFromTheAuthenticatedRouteWhateverItsVisibility() async throws {
        for visibility in [Visibility.private, .public] {
            let t = try PullRig()
            await t.check()
            var f = t.file("F1", at: 60, visibility: visibility)
            if visibility == .public { f.url = URL(string: "https://media.capybaraharmony.com/xYz.mp4") }
            t.publish([t.post("P1", files: [f])])
            await t.check()
            let task = try #require(t.tasks.first)
            #expect(task.request?.url?.path == "/library/items/F1/file", "the keyed route first, \(visibility)")
            #expect(task.request?.value(forHTTPHeaderField: "Authorization") == "Api-Key KEY-1234")
            #expect(await t.landAll())
            let video = try #require(t.store.videos.first)
            #expect(video.kind == .original && video.keep && video.sessionID == "P1" && video.link == link)
            #expect(t.added.map(\.origin) == [.pulled])
        }
    }

    @Test func aWebpMadeSwitchedPrivateIsFetchedFromThePrivateRoute() async throws {
        let t = try PullRig()
        await t.check()
        var w = t.webp("W1", name: "pRiVaTe001", at: 60)
        w.url = nil
        w.wireVisibility = .private
        w.canToggleVisibility = true
        t.publish([t.post("P1", files: [t.file("F-P1", at: -100), w])])
        await t.check()
        let task = try #require(t.tasks.first)
        #expect(task.request?.url?.path == "/library/items/W1/file" && task.request?.value(forHTTPHeaderField: "Authorization") == "Api-Key KEY-1234")
    }

    @Test func aNewGalleryLandsItsItemsInTheGalleryFolder() async throws {
        let t = try PullRig()
        await t.check()
        let items = (0..<3).map {
            t.file("I\($0)", name: "0\($0 + 1).jpg", type: "image/jpeg", at: 60 + Double($0), role: .item, index: $0)
        }
        t.publish([t.post("G1", files: items, link: galleryLink, kind: .gallery, items: 3)])
        await t.check()
        #expect(t.tasks.count == 3 && t.tasks.allSatisfy { $0.request?.url?.path.hasPrefix("/library/items/I") == true })
        #expect(await t.landAll(900))
        #expect(t.store.videos.count == 3 && t.store.videos.allSatisfy { $0.role == .item && $0.keep && $0.sessionID == "G1" })
        let files = t.folderFiles()
        #expect(files.count == 3 && files.allSatisfy { $0.contains("/") }, "inside a folder, not flat: \(files)")
        #expect(Set(files.map { ($0 as NSString).lastPathComponent }) == ["01.jpg", "02.jpg", "03.jpg"])
        #expect(Set(files.map { ($0 as NSString).deletingLastPathComponent }).count == 1, "one folder for the gallery")
        #expect(Set(t.added.map(\.origin)) == [.pulled])
    }

    @Test func aMadeFileReplacesThisMacsOlderOneOfTheSameKindBeforeItLands() async throws {
        let t = try PullRig()
        await t.check()
        // this Mac holds the gallery's two items and an older slideshow webp, all kept
        let spec = Data(#"{"format":"webp","items":[0,1]}"#.utf8)
        let a = try await t.save("01", session: "G1", role: .item, index: 0, libraryID: "I0", postItems: 2)
        _ = try await t.save("02", session: "G1", role: .item, index: 1, mediaID: a.mediaID, libraryID: "I1", postItems: 2)
        let old = try await t.save(
            "slide", session: "G1", kind: .webp, role: .slideshow, mediaID: a.mediaID, libraryID: "OLD-SS", madeSpec: spec)
        let oldPath = try #require(t.mac.record(old.id)?.visiblePath)
        #expect((oldPath as NSString).lastPathComponent == "slideshow.webp")

        // the server's library has the remade slideshow (a new row) and no longer the old one
        let items = [
            t.file("I0", name: "01.jpg", type: "image/jpeg", at: -500, role: .item, index: 0),
            t.file("I1", name: "02.jpg", type: "image/jpeg", at: -499, role: .item, index: 1),
        ]
        let remade = t.file(
            "NEW-SS", name: "slideshow.webp", type: "image/webp", at: 300, role: .slideshow, madeSpec: #"{"format":"webp","items":[0,1]}"#)
        t.publish([t.post("G1", files: items + [remade], link: galleryLink, kind: .gallery, items: 2)])
        await t.check()
        #expect(t.tasks.count == 1 && t.tasks[0].request?.url?.path == "/library/items/NEW-SS/file", "only the new row; the items are here already")
        guard case .new(let n)? = t.queue.all().first?.job.target else { Issue.record("expected a new record"); return }
        #expect(n.role == .slideshow && n.libraryID == "NEW-SS" && n.mediaID == a.mediaID && n.sessionID == "G1")

        #expect(await t.landAll(1_500))
        let slides = t.store.videos.filter { $0.role == .slideshow }
        #expect(slides.count == 1 && slides[0].libraryID == "NEW-SS", "the old record is gone, the new one stands")
        #expect(t.mac.trash.items.count == 1 && t.mac.trash.items[0].lastPathComponent == "slideshow.webp", "the old file went to the Trash")
        let landed = try #require(t.mac.record(slides[0].id)?.visiblePath)
        #expect(landed == oldPath, "the new file took the free name, not `slideshow (2).webp`")
        #expect(t.mac.exists(landed))
    }

    @Test func aNewMadeFileWithNothingOlderLandsAndAnotherMediasSlideshowIsLeftAlone() async throws {
        let t = try PullRig()
        await t.check()
        let spec = Data(#"{"format":"webp","items":[0]}"#.utf8)
        let other = try await t.save(
            "other", session: "OTHER", kind: .webp, role: .slideshow, libraryID: "OTHER-SS", madeSpec: spec, link: galleryLink)
        let remade = t.file("NEW-SS", name: "slideshow.webp", type: "image/webp", at: 300, role: .slideshow, madeSpec: #"{"format":"webp","items":[0]}"#)
        t.publish([t.post("G2", files: [remade], link: galleryLink, kind: .gallery, items: 1)])
        await t.check()
        #expect(await t.landAll(1_500))
        #expect(t.store.videos.contains { $0.id == other.id }, "another post's slideshow stays")
        #expect(t.store.videos.filter { $0.role == .slideshow }.count == 2 && t.mac.trash.items.isEmpty)
    }

    // MARK: not pulling what this Mac has (13.8, 13.9)

    @Test func aLocalRecordWithAFileAndOneWithoutAreNeverPulledAndTheDecisionIsKept() async throws {
        let t = try PullRig()
        await t.check()
        let withFile = try await t.save("a", session: "PA")
        let evicted = try await t.save("b", session: "PB")
        #expect(await t.store.removeOfflineCopy(evicted.id))
        #expect(t.store.videos.first { $0.id == evicted.id }?.place == nil, "a record, no file")
        t.publish([t.saved("PA", at: 60), t.saved("PB", at: 120)])
        await t.check()
        #expect(t.tasks.isEmpty && t.queue.all().isEmpty)
        let done = t.ledger.read().done
        #expect(done["F-PA"] == PullDone(at: t.at(60), state: .skipped, why: "local"))
        #expect(done["F-PB"] == PullDone(at: t.at(120), state: .skipped, why: "local"))
        _ = withFile
    }

    @Test func aRecordMadeLaterNeverFlipsAnEarlierDecision() async throws {
        let t = try PullRig()
        await t.check()
        _ = try await t.save("a", session: "PA")
        t.publish([t.saved("PA", at: 60)])
        await t.check()
        #expect(t.ledger.read().done["F-PA"]?.state == .skipped)
        // the record goes (the owner removed the media from this Mac): the file is still not fetched
        for video in t.store.videos { await t.store.removeOfflineCopy(video.id) }
        t.clock.jump(by: 300)
        await t.check()
        #expect(t.tasks.isEmpty)
    }

    @Test func aHeldSessionIsDeferredNotDecidedAndNotPulledOnceItsSaveLands() async throws {
        let t = try PullRig()
        await t.check()
        t.held = ["S9"]
        t.publish([t.saved("S9", at: 60)])
        t.clock.jump(by: 300)
        await t.check()
        #expect(t.tasks.isEmpty && t.ledger.read().done["F-S9"] == nil, "deferred: nothing decided")
        let watermark = try #require(t.ledger.read().watermark)
        #expect(watermark < t.at(60), "the watermark never passes a held save")

        // the save lands here and the run lets go
        _ = try await t.save("clip", session: "S9")
        t.held = []
        t.clock.jump(by: 300)
        await t.check()
        #expect(t.tasks.isEmpty, "this Mac's own save is a local record: not pulled")
        #expect(t.ledger.read().done["F-S9"]?.state == .skipped)
        #expect(try #require(t.ledger.read().watermark) >= t.at(60), "and the watermark moves on")
    }

    @Test func aHeldSessionThatNeverLandsIsPulledOnceItIsLetGo() async throws {
        let t = try PullRig()
        await t.check()
        t.held = ["S9"]
        t.publish([t.saved("S9", at: 60)])
        t.clock.jump(by: 300)
        await t.check()
        #expect(t.tasks.isEmpty)
        t.held = []                                                       // the run ended with nothing kept here
        t.clock.jump(by: 300)
        await t.check()
        #expect(t.tasks.count == 1, "nothing is held and nothing is here: it is a save to pull")
    }

    @Test func aSessionHeldByTheUploadsPostKeyOrItsSessionDefersBoth() async throws {
        let t = try PullRig()
        await t.check()
        t.held = ["SID"]
        let upload = t.file("UP1", source: .upload, name: "clip.mp4", at: 60)
        t.publish([t.post("UP1", files: [upload], session: "SID")])
        t.clock.jump(by: 60)
        await t.check()
        #expect(t.tasks.isEmpty && t.ledger.read().done["UP1"] == nil, "post `UP1` carries session `SID`, which a run holds")
    }

    // MARK: an upload made on this Mac (13.9, the lane's check)

    @Test func anImageUploadedFromThisMacLeavesNoRecordSoItsIdIsRememberedAndItIsNotPulledBack() async throws {
        let t = try PullRig()
        await t.check()
        t.own = ["UP1"]
        t.publish([t.post("UP1", files: [t.file("UP1", source: .upload, name: "photo.png", type: "image/png", at: 60)], link: nil)])
        await t.check()
        #expect(t.tasks.isEmpty && t.queue.all().isEmpty)
        #expect(t.ledger.read().done["UP1"] == PullDone(at: t.at(60), state: .skipped, why: "own"))
        #expect(t.ledger.read().own["UP1"] != nil, "remembered across relaunches")
    }

    @Test func theSameUploadFromAnotherDeviceIsPulled() async throws {
        let t = try PullRig()
        await t.check()
        t.publish([t.post("UP1", files: [t.file("UP1", source: .upload, name: "photo.png", type: "image/png", at: 60)], link: nil)])
        await t.check()
        #expect(t.tasks.count == 1 && t.tasks[0].request?.url?.path == "/library/items/UP1/file", "the control: `own`, not `upload`, keeps it out")
    }

    @Test func aVideoUploadJoinsItsPostThroughTheSessionWhileItIsOpenAndIsNotPulledBack() async throws {
        let t = try PullRig()
        await t.check()
        // `PUT /studio/upload` made library row `UP2` (the post's key) and adopted it into session `SID`; the run keeps the
        // original under the session
        _ = try await t.save("clip", session: "SID", link: nil)
        let upload = t.file("UP2", source: .upload, name: "clip.mp4", at: 60)
        t.publish([t.post("UP2", files: [upload], session: "SID", link: nil)])
        await t.check()
        #expect(t.tasks.isEmpty)
        #expect(t.ledger.read().done["UP2"]?.why == "local")
    }

    @Test func anUploadWhileItsFileIsStillOnTheWireIsDeferredThenSettledAsOwn() async throws {
        let t = try PullRig()
        await t.check()
        t.uploading = true
        t.publish([t.post("UP3", files: [t.file("UP3", source: .upload, name: "photo.png", type: "image/png", at: 60)], link: nil)])
        t.clock.jump(by: 90)
        await t.check()
        #expect(t.tasks.isEmpty && t.ledger.read().done["UP3"] == nil, "the row is listed before the run is told its id: wait")
        t.uploading = false
        t.own = ["UP3"]
        t.clock.jump(by: 300)
        await t.check()
        #expect(t.tasks.isEmpty && t.ledger.read().done["UP3"]?.why == "own")
    }

    @Test func aSavedFileIsNotHeldBackByAnUploadInFlight() async throws {
        let t = try PullRig()
        await t.check()
        t.uploading = true
        t.publish([t.saved("P1", at: 60)])
        await t.check()
        #expect(t.tasks.count == 1, "only an upload's own row waits for the run's answer")
    }

    @Test func theOneGapAVideoUploadWhoseSessionExpiredBeforeAnyRunHeardOfItIsFetchedAgain() async throws {
        // MEASURED, not wished away: a video upload joins its post only through the session (the record keeps the session id,
        // the post's id is the upload row's). Once the session is over (7 days) the post lists none, nothing joins, and with
        // no run of this process to have noted the upload's id the row looks like any save. It takes a Mac that was closed for
        // more than a week after uploading, and a baseline older than the upload.
        let t = try PullRig()
        await t.check()
        _ = try await t.save("clip", session: "SID", link: nil)
        t.publish([t.post("UP2", files: [t.file("UP2", source: .upload, name: "clip.mp4", at: 60)], session: nil, link: nil)])
        await t.check()
        #expect(t.tasks.count == 1, "the gap")
        // and the same run, heard while it lived, is closed
        let u = try PullRig()
        await u.check()
        _ = try await u.save("clip", session: "SID", link: nil)
        u.own = ["UP2"]
        u.publish([u.post("UP2", files: [u.file("UP2", source: .upload, name: "clip.mp4", at: 60)], session: nil, link: nil)])
        await u.check()
        #expect(u.tasks.isEmpty)
    }

    // MARK: the ledger: done is forever

    @Test func aCancelledPullIsNeverQueuedAgain() async throws {
        let t = try PullRig()
        await t.check()
        t.publish([t.saved("P1", at: 60)])
        await t.check()
        #expect(t.tasks.count == 1)
        t.engine.cancel(keys: ["f:F-P1"])                                  // "stop downloading"
        #expect(t.queue.all().isEmpty && t.store.videos.isEmpty)
        for _ in 0..<3 {
            t.clock.jump(by: 300)
            await t.check()
        }
        #expect(t.tasks.count == 1 && t.queue.all().isEmpty, "decided, whatever happened after")
        #expect(t.ledger.read().done["F-P1"]?.state == .queued)
    }

    @Test func aFileRemovedOrDeletedInFinderAfterItLandedIsNeverFetchedAgain() async throws {
        let t = try PullRig()
        await t.check()
        t.publish([t.saved("P1", at: 60), t.saved("P2", at: 120)])
        await t.check()
        #expect(await t.landAll())
        let first = try #require(t.store.videos.first { $0.sessionID == "P1" })
        let second = try #require(t.store.videos.first { $0.sessionID == "P2" })
        #expect(await t.store.removeOfflineCopy(first.id), "the owner's `remove offline copy`")
        let path = try #require(t.mac.record(second.id)?.visiblePath)
        try FileManager.default.removeItem(at: t.mac.folder.appendingPathComponent(path))            // deleted in Finder
        await t.store.scanVisibleRoot()
        t.clock.jump(by: 300)
        await t.check()
        #expect(t.tasks.count == 2 && t.queue.all().isEmpty, "no third download")
    }

    @Test func aDownloadThatEndsGoneIsWrittenSkipped() async throws {
        let t = try PullRig()
        await t.check()
        t.publish([t.saved("P1", at: 60)])
        await t.check()
        t.session?.respond(task: 1, status: 404, body: Data())
        #expect(await eventually(15) { t.engine.states["f:F-P1"] == .failed(.gone) })
        #expect(t.ledger.read().done["F-P1"] == PullDone(at: t.at(60), state: .skipped, why: "gone"))
        t.clock.jump(by: 300)
        await t.check()
        #expect(t.tasks.count == 1, "and it stays gone")
    }

    @Test func aRelaunchOverTheSameLedgerKnowsWhatWasDecided() async throws {
        let t = try PullRig()
        await t.check()
        t.publish([t.saved("P1", at: 60)])
        await t.check()
        let again = SavePull(
            store: t.store, ledger: PullLedger(directory: t.mac.sync), downloads: t.engine, clock: t.clock, scheduler: nil,
            environment: t.environment())
        #expect(again.status.pulling == 1, "the queue's pulled entry is found at launch")
        t.clock.jump(by: 300)
        await again.check()
        #expect(t.tasks.count == 1)
    }

    @Test func twoChecksBeforeALandingQueueOneDownload() async throws {
        let t = try PullRig()
        await t.check()
        t.publish([t.saved("P1", at: 60)])
        await t.check()
        await t.check()
        #expect(t.tasks.count == 1 && t.queue.all().count == 1)
    }

    // MARK: the walk

    @Test func theWalkPaginatesAndStopsAtTheWatermarkCountingRequests() async throws {
        let t = try PullRig(maxPages: 3)
        await t.check()
        t.publish((0..<100).map { t.saved("P\($0)", at: 1_200 * Double(100 - $0)) })
        await t.check()
        // the baseline's own request was the first: the next three are 5, 30, 30 (the budget)
        let walk = t.requests.dropFirst()
        #expect(walk.map(\.limit) == [5, 30, 30] && walk.map(\.cursor) == [nil, "5", "35"])
        #expect(t.queue.all().count == 65 && t.ledger.read().backlog == [PullSegment(cursor: "65", floor: t.ledger.read().enabledAt!)])

        let before = t.requests.count
        t.clock.jump(by: 300)
        await t.check()
        let second = t.requests.dropFirst(before)
        #expect(second.map(\.limit) == [5, 30, 30] && second.map(\.cursor) == [nil, "65", "95"], "the quiet top, then the backlog")
        #expect(t.queue.all().count == 100 && t.ledger.read().backlog.isEmpty)

        let again = t.requests.count
        t.clock.jump(by: 300)
        await t.check()
        #expect(t.requests.count == again + 1 && t.requests.last?.limit == 5, "caught up: one request of 5")
        #expect(t.queue.all().count == 100)
    }

    @Test func aWalkNeverFetchesMoreThanItsPageBudgetAndTheNewestComeFirst() async throws {
        let t = try PullRig(maxPages: 2)
        await t.check()
        t.publish((0..<60).map { t.saved("P\($0)", at: 1_200 * Double(60 - $0)) })
        await t.check()
        #expect(t.requests.count == 3, "the baseline's, then at most 2")
        let queued = t.queue.all().map(\.key)
        #expect(queued.first == "f:F-P0" && queued.count == 35, "newest first: P0...P34")
    }

    @Test func aPostInsertedOutOfOrderWithinTheOverlapIsStillFound() async throws {
        let t = try PullRig()
        await t.check()
        t.publish([t.saved("P1", at: 3_000)])
        await t.check()
        #expect(t.tasks.count == 1)
        // a save that reached the server late, dated 5 minutes before the newest one
        t.publish([t.saved("P1", at: 3_000), t.saved("LATE", at: 2_700)])
        t.clock.jump(by: 300)
        await t.check()
        #expect(t.tasks.count == 2 && t.tasks[1].request?.url?.path == "/library/items/F-LATE/file")
    }

    @Test func aPostOlderThanTheOverlapBelowTheWatermarkIsOutOfReachByDesign() async throws {
        let t = try PullRig()
        await t.check()
        t.publish([t.saved("P1", at: 3_000)])
        await t.check()
        t.publish([t.saved("P1", at: 3_000), t.saved("TOO-LATE", at: 2_000)])
        t.clock.jump(by: 300)
        await t.check()
        #expect(t.tasks.count == 1, "10 minutes of overlap, as 13.8 says")
    }

    @Test func aHeldSaveInTheBacklogIsRevisitedAfterItIsLetGo() async throws {
        let t = try PullRig(maxPages: 2)
        await t.check()
        // 40 saves; the one at the bottom of the backlog is held
        t.publish((0..<40).map { t.saved("P\($0)", at: 1_200 * Double(40 - $0)) })
        t.held = ["P35"]
        t.clock.jump(by: 100)
        await t.check()                                                  // 5 + 30 posts: P0...P34
        t.clock.jump(by: 300)
        await t.check()                                                  // the backlog: P35 held, P36...P39 queued
        #expect(t.queue.all().count == 39 && t.ledger.read().done["F-P35"] == nil)
        #expect(t.ledger.read().backlog.count == 1, "a segment that resumes at the page holding it")
        t.held = []
        t.clock.jump(by: 300)
        await t.check()
        #expect(t.queue.all().count == 40 && t.ledger.read().backlog.isEmpty)
    }

    // MARK: pauses

    @Test func keepOffMakesNoRequestAndForgetsTheBaseline() async throws {
        let t = try PullRig()
        await t.check()
        #expect(t.ledger.read().enabledAt != nil)
        t.keepOn = false
        let before = t.requests.count
        await t.check()
        #expect(t.requests.count == before && t.pull.status.paused == .keepOff)
        #expect(t.ledger.read().enabledAt == nil, "the next on is a new baseline")
    }

    @Test func turningItOnAgainRebaselinesSoSavesMadeWhileOffAreNotFetched() async throws {
        let t = try PullRig()
        t.keepOn = false
        await t.check()
        #expect(t.requests.isEmpty)
        t.clock.jump(by: 600)
        t.publish([t.saved("WHILE-OFF", at: 300)])                          // made at +300 while it was off
        t.clock.jump(by: 600)                                               // now +1200
        t.keepOn = true
        t.pull.keepChanged(true)
        #expect(t.ledger.read().enabledAt == t.clock.now(), "a new baseline, at the moment it was turned on")
        #expect(await eventually(15) { t.requests.count == 1 }, "and it checks")
        #expect(await eventually(15) { t.pull.status.lastChecked != nil })
        #expect(t.tasks.isEmpty && t.ledger.read().done.isEmpty)
        t.publish([t.saved("NEW", at: 1_300), t.saved("WHILE-OFF", at: 300)])
        t.clock.jump(by: 300)
        await t.check()
        #expect(t.tasks.count == 1 && t.tasks[0].request?.url?.path == "/library/items/F-NEW/file")
    }

    @Test func turningItOffThroughTheModelForgetsTheBaselineAtOnce() async throws {
        let t = try PullRig()
        await t.check()
        t.pull.keepChanged(false)
        #expect(t.ledger.read().enabledAt == nil)
    }

    @Test func anUnreachableFolderPausesWithoutRequestsAndTheBaselineStillStands() async throws {
        let t = try PullRig(unplugged: true)
        #expect(t.store.rootState == .unreachable(path: t.mac.folder.path))
        await t.check()
        #expect(t.requests.isEmpty && t.pull.status.paused == .folderUnreachable)
        let baseline = try #require(t.ledger.read().enabledAt)
        // it is back
        try FileManager.default.createDirectory(at: t.mac.folder, withIntermediateDirectories: true)
        await t.store.reload()
        #expect(t.store.rootState == .ready)
        t.publish([t.saved("P1", at: 60)])
        t.clock.jump(by: 300)
        await t.check()
        #expect(t.pull.status.paused == nil && t.tasks.count == 1)
        #expect(t.ledger.read().enabledAt == baseline, "not a new baseline")
    }

    @Test func aRefusedKeyPausesUntilTheKeyChangesAndThenAsksAgain() async throws {
        let t = try PullRig()
        await t.check()
        t.pageError = CobaltError.api(code: "error.api.auth.key.invalid", httpStatus: 401)
        t.clock.jump(by: 300)
        await t.check()
        #expect(t.pull.status.paused == .auth)
        #expect(t.pull.status.lastChecked == t.at(0), "the failed check is not a check")
        let asked = t.requests.count

        t.pageError = nil
        for _ in 0..<3 {
            t.clock.jump(by: 300)
            await t.check()
        }
        #expect(t.requests.count == asked, "no retry while the key is the same")

        t.token = "KEY-NEW"
        t.pull.capabilitiesChanged()
        #expect(await eventually(15) { t.requests.count == asked + 1 })
        #expect(await eventually(15) { t.pull.status.paused == nil && t.pull.status.lastChecked != t.at(0) })
    }

    @Test func settingsBeingOpenedLiftsAnAuthPauseWithTheSameKey() async throws {
        let t = try PullRig()
        t.pageError = CobaltError.invalidResponse(httpStatus: 403)
        await t.check()
        #expect(t.pull.status.paused == .auth)
        t.pageError = nil
        await t.pull.resume()
        #expect(t.pull.status.paused == nil && t.pull.status.lastChecked != nil)
    }

    @Test func aKeyTheAppKnowsIsRefusedPausesWithoutAsking() async throws {
        let t = try PullRig()
        t.caps.key = .invalid
        await t.check()
        #expect(t.requests.isEmpty && t.pull.status.paused == .auth)
    }

    @Test func noServerMeansNoKeyOrNothingKnownOrNoLibraryAndNoRequest() async throws {
        let t = try PullRig()
        t.caps = .unknown
        await t.check()
        #expect(t.requests.isEmpty && t.pull.status.paused == .noServer, "capabilities unknown")
        t.caps = PullRigCaps.fork
        t.caps.key = .missing
        await t.check()
        #expect(t.requests.isEmpty && t.pull.status.paused == .noServer, "no key")
        t.caps.key = .valid
        t.caps.library = false
        await t.check()
        #expect(t.requests.isEmpty && t.pull.status.paused == .noServer, "a server with no library")
        t.caps.library = true
        t.pull.capabilitiesChanged()
        #expect(await eventually(15) { t.requests.count == 1 }, "the server answered: a check that waited runs")
    }

    @Test func aNetworkFailureIsNotAPauseAndTheNextTickTriesAgain() async throws {
        let t = try PullRig()
        t.pageError = CobaltError.network(.notConnectedToInternet)
        await t.check()
        #expect(t.pull.status.paused == nil && t.pull.status.lastChecked == nil)
        #expect(t.ledger.read().problem == "network")
        t.pageError = CobaltError.api(code: "error.api.generic", httpStatus: 503)
        await t.check()
        #expect(t.ledger.read().problem == "server 503" && t.pull.status.paused == nil)
        t.pageError = nil
        t.clock.jump(by: 300)
        await t.check()
        #expect(t.pull.status.lastChecked != nil && t.ledger.read().problem == nil)
    }

    @Test func anotherServerIsAnotherLibraryAndTakesANewBaseline() async throws {
        let t = try PullRig()
        t.publish([t.saved("P1", at: -100)])
        await t.check()
        let first = try #require(t.ledger.read().enabledAt)
        t.clock.jump(by: 3_600)
        t.serverID = "https://other.example"
        t.publish([t.saved("OTHER", at: 60)])                                // old for the first baseline, older than the new one
        t.pull.serverChanged()
        #expect(t.ledger.read().enabledAt == t.clock.now() && t.ledger.read().enabledAt != first)
        await t.check()
        #expect(t.tasks.isEmpty, "nothing the other library already held is fetched")
        // and a launch that finds a different server in the settings does the same
        t.clock.jump(by: 3_600)
        t.serverID = "https://third.example"
        await t.check()
        #expect(t.ledger.read().server == "https://third.example" && t.ledger.read().enabledAt == t.clock.now())
    }

    @Test func onlyOneCheckRunsAtATime() async throws {
        let t = try PullRig()
        t.pageDelay = { [t] in await withCheckedContinuation { t.gate = $0 } }
        let first = Task { await t.check() }
        #expect(await eventually(15) { t.gate != nil })
        await t.check()                                                   // returns at once
        #expect(t.requests.count == 1)
        t.pageDelay = nil
        t.gate?.resume()
        t.gate = nil
        await first.value
        #expect(t.requests.count == 1 && t.pull.status.lastChecked != nil)
    }

    @Test func aSwitchOffDuringTheRequestWritesNothing() async throws {
        let t = try PullRig()
        await t.check()
        t.publish([t.saved("P1", at: 60)])
        t.pageDelay = { [t] in
            t.keepOn = false                                               // the owner turns it off while the request runs
        }
        t.clock.jump(by: 300)
        await t.check()
        #expect(t.tasks.isEmpty && t.ledger.read().done.isEmpty && t.pull.status.lastChecked == t.at(0))
    }

    // MARK: status

    @Test func statusCountsWhatThePullIsDownloadingAndLeavesOtherKeepOfflineDownloadsAlone() async throws {
        let t = try PullRig()
        await t.check()
        t.publish([t.saved("P1", at: 60), t.saved("P2", at: 120)])
        await t.check()
        // an owner's "keep offline" download of something else is not this pull's
        t.engine.enqueue([OfflineJob(
            key: "f:OWN", aliases: ["f:OWN"], target: .existing(id: "nope"), sources: [.libraryItem(id: "OWN")], expectedBytes: 1,
            fileName: "x.mp4")])
        #expect(t.pull.status.pulling == 2)
        let s = try #require(t.session)
        s.respond(task: 1, status: 200, body: Data(repeating: 9, count: 500))
        #expect(await eventually(15) { t.pull.status.pulling == 1 })
    }

    @Test func aPreviewPullNeverChecks() async throws {
        let pull = SavePull.preview(.init(available: true, paused: .keepOff))
        await pull.check()
        pull.keepChanged(true)
        pull.start()
        #expect(pull.status == SavePull.Status(available: true, paused: .keepOff))
        pull.setPreviewStatus(.init(available: true, lastChecked: Date(timeIntervalSince1970: 5), pulling: 2))
        #expect(pull.status.pulling == 2 && pull.isAvailable)
    }

    @Test func aDocumentsStoreIsNotAvailableAndNeverChecks() async throws {
        let rig = try OfflineRig()
        let store = rig.store()
        let ledger = PullLedger(directory: rig.sync)
        let pull = SavePull(store: store, ledger: ledger, environment: nil)
        #expect(!pull.status.available && !pull.isAvailable)
        await pull.check()
        #expect(ledger.read().enabledAt == nil)
    }

    // MARK: the tick

    @Test func theTickIsEveryFiveMinutesOnTheVirtualClockAndStopsWhenStopped() async throws {
        #expect(SavePull.interval == 300 && SavePull.tolerance == 60)
        let t = try PullRig()
        t.pull.start()
        t.pull.start()                                                    // idempotent
        #expect(await eventually(15) { t.clock.pending == 1 })
        #expect(t.requests.isEmpty, "nothing checks before the first interval")
        for n in 1...3 {
            #expect(t.clock.advance())
            #expect(await eventually(15) { t.requests.count == n }, "tick \(n)")
            #expect(await eventually(15) { t.clock.pending == 1 })
        }
        #expect(t.clock.elapsed == 900)
        t.pull.stop()
        #expect(await eventually(15) { t.clock.pending == 0 })
        #expect(t.requests.count == 3)
    }

    @Test func theSystemTimerFiresAndCancels() async throws {
        let count = Mutex(0)
        let tick = TimerScheduler().start(interval: 0.05, tolerance: 0.01) { count.withLock { $0 += 1 } }
        #expect(await eventually(15) { count.withLock { $0 } >= 2 })
        tick.cancel()
        let n = count.withLock { $0 }
        try? await Task.sleep(for: .milliseconds(250))
        #expect(count.withLock { $0 } <= n + 1)
    }

    @Test func aFailureOnATickDoesNotStopTheNextOne() async throws {
        let t = try PullRig()
        t.pull.start()
        t.pageError = CobaltError.network(.timedOut)
        #expect(await eventually(15) { t.clock.pending == 1 })
        #expect(t.clock.advance())
        #expect(await eventually(15) { t.requests.count == 1 })
        t.pageError = nil
        #expect(await eventually(15) { t.clock.pending == 1 })
        #expect(t.clock.advance())
        #expect(await eventually(15) { t.requests.count == 2 && t.pull.status.lastChecked != nil })
    }

    // MARK: resume and Photos

    @Test func aPulledDownloadTheSystemInterruptedResumesFromItsResumeData() async throws {
        let t = try PullRig()
        await t.check()
        t.publish([t.saved("P1", at: 60)])
        await t.check()
        let s = try #require(t.session)
        let resume = Data("RESUME-DATA".utf8)
        s.fail(task: 1, code: NSURLErrorNetworkConnectionLost, resumeData: resume)
        #expect(await eventually(15) { t.queue.entry("f:F-P1")?.state == .queued })
        await t.engine.reconcile()
        #expect(s.tasks.count == 2 && s.tasks[1].resumeData == resume && s.tasks[1].request == nil)
        s.respond(task: 2, status: 206, body: Data(repeating: 9, count: 2_000))
        #expect(await eventually(15) { t.queue.all().isEmpty && t.store.videos.count == 1 })
        #expect(t.added.map(\.origin) == [.pulled])
        t.clock.jump(by: 300)
        await t.check()
        #expect(t.tasks.count == 2, "not restarted, not queued again")
    }

    @Test func aPulledLandingIsNotANewSaveForThePhotosAlbum() async throws {
        let env = try PhotosEnv()
        env.turnOn()
        let file = try makeTempFile("pulled.mp4")
        _ = try await env.store.add(
            file: file, kind: .original, media: MediaInfo(name: "pulled", duration: 1, width: 10, height: 10, bytes: nil, isImage: false),
            sessionID: "S1", link: link, remoteURL: nil, move: true, publicURL: nil, mediaID: nil, clip: nil, keep: true,
            createdAt: nil, origin: .pulled)
        await env.reconcile()
        #expect(env.library.addCalls == 0 && env.ledger.entry("s:S1")?.skip == .preexisting, "`PhotosSync` ignores every origin but a save")
    }
}

/// A usable server's capabilities, for the cases that start from nothing.
@MainActor
enum PullRigCaps {
    static var fork: Capabilities {
        var c = Capabilities.unknown
        c.kind = .fork
        c.key = .valid
        c.library = true
        return c
    }
}
