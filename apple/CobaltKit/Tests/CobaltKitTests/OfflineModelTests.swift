import Foundation
import Synchronization
import Testing
@testable import CobaltKit

// CONTRACT-OFFLINE.md wave 2 (K2), the model side: what a media's offline state is, the filter and the sort, what
// the screens call (`AppModel`), the `.offline` preview, the origin skip for the photos album and the Mac folder, and
// the routing of a background wake.

// MARK: - MediaItem.offline, the filter and the sort

@MainActor
struct MediaOfflineTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func video(_ id: String, kind: StoredVideo.Kind = .original, place: StoredVideo.Place?, keep: Bool, remote: URL? = nil) -> StoredVideo {
        StoredVideo(
            id: id, kind: kind, fileURL: place == nil ? nil : URL(fileURLWithPath: "/x/\(id)"), posterURL: nil, name: id, duration: 1,
            width: 1, height: 1, bytes: 100, sessionID: "S", link: nil, remoteURL: remote, createdAt: now, mediaID: "m",
            place: place, keep: keep)
    }

    private func item(_ original: StoredVideo?, _ webps: [StoredVideo] = []) throws -> MediaItem {
        let media = try #require(StoredMedia(id: "m", original: original, webps: webps))
        return try #require(MediaItem.merge(local: media, post: nil))
    }

    private func webp(_ n: Int, place: StoredVideo.Place?, keep: Bool) -> StoredVideo {
        video("w\(n)", kind: .webp, place: place, keep: keep, remote: URL(string: "https://media.capybaraharmony.com/aBcDeFgH0\(n).webp"))
    }

    @Test func allWhenEveryRenditionIsKeptSomeWhenOneIsAndNoneOtherwise() throws {
        #expect(try item(video("v", place: .offline, keep: true), [webp(1, place: .offline, keep: true)]).offline == .all)
        #expect(try item(video("v", place: .offline, keep: true), [webp(1, place: nil, keep: false)]).offline == .some, "a webp not here")
        #expect(try item(video("v", place: nil, keep: false), [webp(1, place: .offline, keep: true)]).offline == .some)
        #expect(try item(video("v", place: nil, keep: false), [webp(1, place: nil, keep: false)]).offline == .none)
        #expect(try item(video("v", place: .offline, keep: true)).offline == .all)
    }

    @Test func aCachedFileDoesNotCountAndNeitherDoesAKeepWithNoFile() throws {
        #expect(try item(video("v", place: .cache, keep: false)).offline == .none, "the cache may take it: calling it offline would be a lie")
        #expect(try item(video("v", place: .cache, keep: false), [webp(1, place: .offline, keep: true)]).offline == .some)
        #expect(try item(video("v", place: nil, keep: true)).offline == .none, "kept, but the file is not here (a download is on its way)")
        #expect(try item(video("v", place: .cache, keep: true)).offline == .all, "kept and waiting in files/ for the move into Files")
    }

    @Test func aServerOnlyWebpCountsAsARenditionToo() throws {
        let h = Harness(.offline)
        let post = try #require(h.app.library.posts.first { $0.id == "2105435404002562056" })
        let item = h.app.mediaItem(for: post)
        #expect(item.renditions.count == 2 && item.webps.first?.local == nil)
        #expect(item.offline == .some, "the video is kept; the webp lives only on the server")
    }

    @Test func theOrdering() {
        #expect(MediaOffline.none < .some && MediaOffline.some < .all)
        #expect(LibraryShow.allCases.last == .offline && LibraryShow.offline.rawValue == "offline")
        #expect(LibraryShow.allCases.dropLast().last == .uploads, "after uploads")
        #expect(LibrarySortKey.allCases.contains(.offline))
        #expect(LibrarySort(stored: "offline.desc") == LibrarySort(key: .offline, ascending: false))
    }

    @Test func theOfflineFilterPassesAllAndSomeAndNeedsTheWholeLibrary() async throws {
        let h = Harness(.offline)
        let library = h.app.library
        #expect(!library.needsWholeLibrary)
        library.show = .offline
        #expect(library.needsWholeLibrary, "like every filter")
        let rows = h.app.libraryRows
        #expect(Set(rows.map(\.id)) == ["Dd7P496wolG", "2105435404002562056"])
        #expect(Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0.offline) }) == ["Dd7P496wolG": .all, "2105435404002562056": .some])
        library.show = .everything
        #expect(h.app.libraryRows.count == 6)
    }

    @Test func theTableSortsByTheRankAllThenSomeThenNone() {
        let h = Harness(.offline)
        let library = h.app.library
        library.sort = LibrarySort(key: .offline, ascending: false)
        let down = h.app.libraryRows.map(\.offline)
        #expect(down == down.sorted(by: >))
        #expect(down.first == .all && down.last == MediaOffline.none)
        library.sort = LibrarySort(key: .offline, ascending: true)
        let up = h.app.libraryRows.map(\.offline)
        #expect(up == up.sorted(by: <) && up.first == MediaOffline.none && up.last == .all)
        #expect(library.needsWholeLibrary)
    }
}

// MARK: - The `.offline` preview and the screens' calls

@MainActor
@Suite(.serialized)
struct OfflineAppModelTests {
    /// The two renditions `.offline` seeds into the queue: the one downloading and the one that failed.
    static let seededKeys = ["f:PrEvIeWitem000002", "f:PrEvIeWitem000011"]

    private func item(_ h: Harness, post id: String) throws -> MediaItem {
        let post = try #require(h.app.library.posts.first { $0.id == id })
        return h.app.mediaItem(for: post)
    }

    private func orbitItem(_ h: Harness, _ record: String) throws -> MediaItem {
        let media = try #require(h.app.store.media.first { $0.renditions.contains { $0.id == record } })
        return h.app.mediaItem(for: media)
    }

    @Test func thePreviewShowsEveryStateTheScreensDraw() async throws {
        let h = Harness(.offline)
        let app = h.app
        // all
        let all = try item(h, post: "Dd7P496wolG")
        #expect(app.offlineState(of: all).offline == .all && app.offlineState(of: all).downloading == nil && !app.offlineState(of: all).failed)
        #expect(app.offlineState(of: try #require(all.video)) == .offline(bytes: 4_331_778))
        #expect(all.renditions.count == 4 && all.renditions.allSatisfy { if case .offline = app.offlineState(of: $0) { true } else { false } })
        // some: the video kept, the webp on the server only
        let some = try item(h, post: "2105435404002562056")
        #expect(app.offlineState(of: some).offline == .some)
        #expect(app.offlineState(of: try #require(some.video)) == .offline(bytes: 256_000))
        #expect(app.offlineState(of: try #require(some.webps.first)) == .none)
        // downloading, 40 %
        let downloading = try item(h, post: "Dd55fEyN1Yy")
        #expect(app.offlineState(of: try #require(downloading.video)) == .downloading(TransferProgress(bytes: 3_320_000, total: 8_300_000)))
        let summary = app.offlineState(of: downloading)
        #expect(summary.offline == .none && summary.downloading == TransferProgress(bytes: 3_320_000, total: 8_300_000) && !summary.failed)
        // failed: gone
        let failed = try item(h, post: "2105358343657427103")
        #expect(app.offlineState(of: try #require(failed.video)) == .failed(.gone))
        let failedSummary = app.offlineState(of: failed)
        #expect(failedSummary.failed && failedSummary.downloading == nil && failedSummary.offline == .none)
        // unavailable: a plain save with no file and no server copy
        let plain = try orbitItem(h, "preview-orbit-5")
        #expect(app.offlineState(of: try #require(plain.video)) == .unavailable)
        // cached: the file is here and the limit may take it
        let cached = try orbitItem(h, "preview-orbit-3")
        let cachedVideo = try #require(cached.video)
        #expect(app.offlineState(of: cachedVideo) == .cached(bytes: 70_000) && cached.offline == .none)
        // kept, and the only copy
        let only = try orbitItem(h, "preview-orbit-7")
        #expect(app.offlineState(of: try #require(only.video)) == .offline(bytes: 1_800_000))
        let onlyVideo = try #require(only.video), allVideo = try #require(all.video), plainVideo = try #require(plain.video)
        #expect(app.isOnlyCopy(onlyVideo) && !app.isOnlyCopy(allVideo) && !app.isOnlyCopy(plainVideo))
    }

    @Test func theSettingsNumbersAreTheContractsAndSurviveTheScan() async throws {
        let h = Harness(.offline)
        let usage = h.app.store.offlineUsage
        #expect(usage.offline == StorageUsage(count: 24, bytes: 3_100_000_000, mediaCount: 24))
        #expect(usage.cache == StorageUsage(count: 3, bytes: 210_000_000, mediaCount: 3))
        #expect(h.app.store.limitBytes == 5_000_000_000, "\"3 videos · 210 MB of 5 GB\"")
        let summary = h.app.offlineDownloads.summary
        #expect(summary.left == 1 && summary.bytes == 3_320_000 && summary.total == 8_300_000, "the downloading row: 1 left")
        // the kept files are real and tagged, so a foreground's scan keeps them
        await h.app.store.reload()
        #expect(h.app.store.videos.filter(\.isOffline).count == 6)
        #expect(h.app.store.offlineUsage.offline == usage.offline)
        let all = try item(h, post: "Dd7P496wolG")
        #expect(all.offline == .all)
    }

    @Test func stopDownloadingClearsTheStateAndTheEntry() throws {
        let h = Harness(.offline)
        let downloading = try item(h, post: "Dd55fEyN1Yy")
        h.app.stopDownloading(downloading)
        #expect(h.app.offlineState(of: try #require(downloading.video)) == .none)
        #expect(h.app.offlineDownloads.summary.left == 0 && h.app.offlineDownloads.queue.all().filter(\.isLive).isEmpty)
    }

    @Test func keepOfflineOnACachedFileKeepsAndMovesItWithoutADownload() async throws {
        let h = Harness(.offline)
        let cached = try orbitItem(h, "preview-orbit-3")
        let before = h.app.offlineDownloads.queue.all().count
        h.app.keepOffline(cached)
        #expect(await eventually { h.app.store.videos.first { $0.id == "preview-orbit-3" }?.place == .offline })
        let moved = try #require(h.app.store.videos.first { $0.id == "preview-orbit-3" })
        #expect(moved.place == .offline && moved.fileURL?.path.contains("Documents") == true)
        #expect(h.app.offlineDownloads.queue.all().count == before, "nothing was queued")
        #expect(h.app.offlineState(of: try orbitItem(h, "preview-orbit-3")).offline == .all)
    }

    @Test func keepOfflineOnAMediaFetchesEveryRenditionNotYetKeptAndLandsThemJoined() async throws {
        let h = Harness(.offline)
        let before = try item(h, post: "Dd5JFkMDt4N")                    // a local webp with no file, and a private original on the server
        #expect(before.renditions.count == 2 && before.offline == .none)
        h.app.keepOffline(before)
        for r in before.renditions { #expect(h.app.offlineState(of: r) == .waiting, "visible at once") }
        #expect(h.app.offlineState(of: before).downloading != nil)
        await h.drive { (try? self.item(h, post: "Dd5JFkMDt4N"))?.offline == .all }
        #expect(await eventually { h.app.offlineDownloads.queue.all().map(\.key).sorted() == Self.seededKeys })
        let after = try item(h, post: "Dd5JFkMDt4N")
        #expect(after.offline == .all && after.renditions.count == 2, "joined to the media it was started from")
        #expect(after.local?.id == before.local?.id, "no second media")
        #expect(h.app.offlineState(of: after).downloading == nil)
    }

    @Test func aFailedRenditionIsRetriedByTheSameAction() async throws {
        let h = Harness(.offline)
        let failed = try item(h, post: "2105358343657427103")
        #expect(h.app.offlineState(of: try #require(failed.video)) == .failed(.gone))
        h.app.keepOffline(failed, rendition: failed.video)
        #expect(h.app.offlineState(of: try #require(failed.video)) == .waiting)
        await h.drive { (try? self.item(h, post: "2105358343657427103"))?.offline == .some }
        #expect(await eventually { h.app.offlineDownloads.queue.all().map(\.key) == ["f:PrEvIeWitem000002"] })
        #expect(try item(h, post: "2105358343657427103").offline == .some, "the video is kept now; its webp is still on the server only")
    }

    @Test func keepOfflineLeavesWhatCannotBeFetchedAlone() throws {
        let h = Harness(.offline)
        let plain = try orbitItem(h, "preview-orbit-5")
        let before = h.app.offlineDownloads.queue.all().count
        h.app.keepOffline(plain)
        let plainVideo = try #require(plain.video)
        #expect(h.app.offlineDownloads.queue.all().count == before && h.app.offlineState(of: plainVideo) == .unavailable)
        let all = try item(h, post: "Dd7P496wolG")
        h.app.keepOffline(all)
        #expect(h.app.offlineDownloads.queue.all().count == before, "everything is kept already")
    }

    @Test func removeOfflineCopyDeletesTheFilesAndKeepsTheRecords() async throws {
        let h = Harness(.offline)
        let all = try item(h, post: "Dd7P496wolG")
        let root = try #require(h.app.store.visibleRoot)
        let filesBefore = (try? FileManager.default.contentsOfDirectory(atPath: root.path))?.count ?? 0
        #expect(filesBefore == 6)
        #expect(await h.app.removeOfflineCopy(all))
        let after = try item(h, post: "Dd7P496wolG")
        #expect(after.offline == .none && after.renditions.count == 4, "the planet and its renditions stay")
        for r in after.renditions { #expect(h.app.offlineState(of: r) == .none || h.app.offlineState(of: r) == .unavailable) }
        let ids = all.renditions.compactMap { $0.local?.id }
        #expect(ids.count == 4 && ids.allSatisfy { id in h.app.store.videos.first { $0.id == id }.map { $0.place == nil && !$0.keep } == true })
        #expect(((try? FileManager.default.contentsOfDirectory(atPath: root.path))?.count ?? 0) == 2, "the other media's files are untouched")
        #expect(!(await h.app.removeOfflineCopy(all)), "nothing left to remove")
    }

    @Test func removingOneRenditionLeavesTheOthersKept() async throws {
        let h = Harness(.offline)
        let all = try item(h, post: "Dd7P496wolG")
        let webp = try #require(all.webps.first)
        #expect(await h.app.removeOfflineCopy(all, rendition: webp))
        let after = try item(h, post: "Dd7P496wolG")
        #expect(after.offline == .some)
    }

    @Test func removeOfflineCopyAlsoStopsADownloadInFlight() async throws {
        let h = Harness(.offline)
        let downloading = try item(h, post: "Dd55fEyN1Yy")
        #expect(!(await h.app.removeOfflineCopy(downloading)), "there was no file")
        #expect(h.app.offlineState(of: try #require(downloading.video)) == .none, "but the download is stopped")
    }

    @Test func theFilesUrlIsTheSchemeWithAPercentEncodedPath() {
        let url = AppModel.filesURL(for: URL(fileURLWithPath: "/var/mobile/Containers/Data/Application/AB CD-12/Documents/some folder"))
        #expect(url?.absoluteString == "shareddocuments:///var/mobile/Containers/Data/Application/AB%20CD-12/Documents/some%20folder")
        #expect(url?.scheme == "shareddocuments")
        let h = Harness(.offline)
        #if os(iOS)
        #expect(h.app.showInFilesURL(nil) != nil)
        OfflineDownloads.showInFilesVerified = false
        #expect(h.app.showInFilesURL(nil) == nil, "one switch if gate G-O fails")
        OfflineDownloads.showInFilesVerified = true
        #else
        #expect(h.app.showInFilesURL(nil) == nil, "iOS only")
        #endif
    }

    @Test func publicAPICompilesAsPinned() {
        let h = Harness(.offline)
        let _: OfflineDownloads = h.app.offlineDownloads
        let _: [String: RenditionOffline] = h.app.offlineDownloads.states
        let _: (left: Int, bytes: Int64, total: Int64?) = h.app.offlineDownloads.summary
        let _: (Rendition) -> RenditionOffline = h.app.offlineState(of:)
        let _: (MediaItem) -> (offline: MediaOffline, downloading: TransferProgress?, failed: Bool) = h.app.offlineState(of:)
        let _: (MediaItem, Rendition?) -> Void = h.app.keepOffline(_:rendition:)
        let _: (MediaItem, Rendition?) -> Void = h.app.stopDownloading(_:rendition:)
        let _: (MediaItem, Rendition?) async -> Bool = h.app.removeOfflineCopy(_:rendition:)
        let _: (Rendition) -> Bool = h.app.isOnlyCopy(_:)
        let _: (MediaItem?) -> URL? = h.app.showInFilesURL(_:)
        let _: (Rendition) -> String = OfflineKey.of(_:)
        let _: [OfflineFailure] = [.gone, .unreachable, .auth, .full, .other(500)]
        let _: PreviewScenario = .offline
        let _: LibraryRow? = nil
        #expect(h.app.library.posts.isEmpty == false)
    }
}

// MARK: - A keep-offline download is not a new save

@MainActor
@Suite(.serialized)
struct OfflineOriginTests {
    private func info(_ name: String = "clip") -> MediaInfo { MediaInfo(name: name, duration: 5, width: 1, height: 1, bytes: nil, isImage: false) }

    @Test func thePhotosAlbumCopiesANewSaveButNotWhatKeepOfflineAdoptedOrMigratedAdds() async throws {
        for origin in [AddOrigin.keepOffline, .adopted, .migrated] {
            let env = try PhotosEnv()
            env.turnOn()
            _ = try await env.store.add(
                file: try makeTempFile("a.mp4"), kind: .original, media: info(), sessionID: "OLD1", link: nil, remoteURL: nil, move: true,
                keep: true, origin: origin)
            await env.reconcile()
            #expect(env.library.addCalls == 0, "\(origin)")
            let entry = env.ledger.entry("s:OLD1")
            #expect(entry?.state == .skipped && entry?.skip == .preexisting, "\(origin)")
            // a save that follows is still the album's
            _ = try await env.add(session: "NEW1")
            await env.reconcile()
            #expect(env.library.addCalls == 1 && env.ledger.entry("s:NEW1")?.state == .done, "\(origin)")
        }
        let env = try PhotosEnv()
        env.turnOn()
        _ = try await env.store.add(
            file: try makeTempFile("a.mp4"), kind: .original, media: info(), sessionID: "SAVE1", link: nil, remoteURL: nil, move: true,
            keep: true, origin: .save)
        await env.reconcile()
        #expect(env.library.addCalls == 1, "an ordinary save is copied")
    }

    @Test func aRefillWithTheKeepOfflineOriginIsNotCopiedEither() async throws {
        let env = try PhotosEnv()
        let a = try await env.add(session: "S1")
        _ = await env.store.evict(a.id)
        env.turnOn()
        _ = try await env.store.attach(file: try makeTempFile("refill.mp4"), to: a.id, move: true, keep: true, origin: .keepOffline)
        await env.reconcile()
        #expect(env.library.addCalls == 0 && env.ledger.entry("s:S1")?.skip == .preexisting)
    }

    @Test func anItemTheAlbumAlreadyHasKeepsItsEntry() async throws {
        let env = try PhotosEnv()
        env.turnOn()
        let a = try await env.add(session: "S1")
        await env.reconcile()
        #expect(env.ledger.entry("s:S1")?.state == .done)
        env.sync.markNotNew(["s:S1"])
        #expect(env.ledger.entry("s:S1")?.state == .done, "an entry is never overwritten")
        _ = a
    }

    @Test func theEngineMarksTheKeysBeforeTheFileLandsSoNothingRacesIt() async throws {
        let env = try PhotosEnv()
        env.turnOn()
        let t = try DownloadRig(store: env.store)
        t.engine.markNotNew = { keys in env.sync.markNotNew(keys) }
        t.engine.enqueue([t.newJob(sources: [.libraryItem(id: "N1")], session: "OLDPOST")])
        t.session?.respond(task: 1, status: 200, body: Data(repeating: 1, count: 500))
        #expect(await eventually { env.store.videos.contains { $0.sessionID == "OLDPOST" && $0.isOffline } && t.queue.all().isEmpty })
        await env.reconcile()
        #expect(env.library.addCalls == 0, "an old library post kept offline must not reach Photos")
        #expect(env.ledger.entry("s:OLDPOST")?.skip == .preexisting)
    }
}

// MARK: - Wakes

@MainActor
@Suite(.serialized)
struct OfflineWakeTests {
    @Test func theOfflineSessionsWakeGoesToTheEngineAndEveryOtherToTheOriginalsFetcher() async throws {
        let h = Harness(.shortClip)
        let t = try DownloadRig(store: h.ctx.store)
        let originals = FakeBackgroundTransport()
        h.ctx.originals = OriginalFetcher(
            identifier: BackgroundSessionID.app, transport: originals, pending: PendingOriginals(directory: t.rig.sync),
            store: h.ctx.store, clock: h.clock)
        let client = h.ctx.client
        let app = AppModel(context: h.ctx, library: LibraryModel(context: h.ctx), offlineDownloads: t.engine, makeClient: { _ in client })

        t.engine.enqueue([t.newJob(session: "WAKE1")])
        t.session?.respond(task: 1, status: 200, body: Data(repeating: 3, count: 800))
        await app.handleBackgroundDownloads(identifier: OfflineDownloads.sessionIdentifier)
        #expect(await eventually { h.ctx.store.videos.contains { $0.sessionID == "WAKE1" && $0.isOffline } && t.queue.all().isEmpty })
        #expect(t.transport.created == [OfflineDownloads.sessionIdentifier])
        #expect(originals.created.isEmpty, "the share-sheet fetcher heard nothing")

        await app.handleBackgroundDownloads(identifier: BackgroundSessionID.app)
        #expect(originals.created == [BackgroundSessionID.app])
        #expect(t.transport.created == [OfflineDownloads.sessionIdentifier], "and the engine heard nothing")
        let share = BackgroundSessionID.share(job: UUID())
        await app.handleBackgroundDownloads(identifier: share)
        #expect(originals.created.contains(share) && t.transport.created.count == 1)
    }

    @Test func aWakeLandsWhatArrivedAndTheForegroundReconcileHandsTheEngineToo() async throws {
        let h = Harness(.shortClip)
        let t = try DownloadRig(store: h.ctx.store)
        let client = h.ctx.client
        let app = AppModel(context: h.ctx, library: LibraryModel(context: h.ctx), offlineDownloads: t.engine, makeClient: { _ in client })
        t.engine.enqueue([t.newJob(session: "FG1")])
        // a file the delegate moved while nobody was looking
        let inbox = h.ctx.store.inboxURL(for: "clip.mp4")
        try Data(repeating: 4, count: 900).write(to: inbox)
        t.queue.update("f:N1", now: h.clock.now()) { $0.state = .arrived(file: inbox) }
        await app.pickUpSharedJobs()
        #expect(h.ctx.store.videos.contains { $0.sessionID == "FG1" && $0.isOffline })
        #expect(t.queue.all().isEmpty)
    }

    @Test func aWakeIgnoresAnIdentifierThatIsNotItsOwn() async throws {
        let t = try DownloadRig()
        await t.engine.handleWake(identifier: BackgroundSessionID.app)
        #expect(t.transport.created.isEmpty)
    }
}
