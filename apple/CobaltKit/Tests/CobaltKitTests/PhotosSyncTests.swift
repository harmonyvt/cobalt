import Foundation
import Testing
@testable import CobaltKit

// The photos album (CONTRACT-SYNC.md decisions 7 to 12): PhotoKit is a fake, the clock is virtual.

@MainActor
struct PhotosEnv {
    let clock = VirtualClock()
    let settings: Settings
    let store: OfflineStore
    let ledger: PhotosLedger
    let library: FakePhotoLibrary
    let sync: PhotosSync
    let directory: URL

    /// The sync starts off, so adding videos does not race the test: turn it on with `settings.photosAlbumSync`.
    init(rw: PhotosReadWrite = .authorized, addOnly: PhotosAccess = .authorized, available: Bool = true,
         library sharedLibrary: FakePhotoLibrary? = nil, directory shared: URL? = nil) throws {
        let dir = try shared ?? makeTempDirectory()
        directory = dir
        let suite = "cobalt.sync.photos.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        settings = Settings(defaults: defaults, keychain: .memory())
        library = sharedLibrary ?? FakePhotoLibrary(rw: rw, addOnly: addOnly)
        store = OfflineStore(
            root: dir.appendingPathComponent("Videos", isDirectory: true),
            tools: PreviewMediaTools(clock: clock, clip: PreviewData.long), defaults: defaults)
        ledger = PhotosLedger(directory: dir.appendingPathComponent("Sync", isDirectory: true))
        sync = PhotosSync(settings: settings, store: store, ledger: ledger, library: library, clock: clock, available: available)
    }

    /// A second sync over the same ledger, library and files (another instance, as a second launch).
    func another() throws -> PhotosEnv {
        try PhotosEnv(library: library, directory: directory, sharing: self)
    }

    private init(library: FakePhotoLibrary, directory: URL, sharing other: PhotosEnv) throws {
        self.directory = directory
        self.library = library
        self.settings = other.settings
        self.store = other.store
        self.ledger = PhotosLedger(directory: directory.appendingPathComponent("Sync", isDirectory: true))
        self.sync = PhotosSync(settings: other.settings, store: other.store, ledger: ledger, library: library, clock: other.clock, available: true)
    }

    @discardableResult
    func add(
        session: String? = nil, link: URL? = URL(string: shortLink), remote: URL? = nil, kind: StoredVideo.Kind = .original,
        name: String = "clip"
    ) async throws -> StoredVideo {
        let file = try makeTempFile("\(name)-\(UUID().uuidString.prefix(4)).\(kind == .webp ? "webp" : "mp4")", bytes: 2_000)
        let media = MediaInfo(name: name, duration: 5, width: 720, height: 1280, bytes: nil, isImage: kind == .webp)
        return try await store.add(
            file: file, kind: kind, media: media, sessionID: session, link: link, remoteURL: remote, move: true)
    }

    func turnOn() { settings.photosAlbumSync = true }
    func reconcile() async { await sync.reconcile() }
}

private let hostedWebp = URL(string: "https://media.capybaraharmony.com/aBcD.webp")!
private let pickerURL = URL(string: "https://cdn.example.com/p/1.mp4")!

// MARK: - Keys and eligibility

@MainActor
struct PhotosKeyTests {
    private func video(_ kind: StoredVideo.Kind, session: String? = nil, remote: URL? = nil, id: String = "abc") -> StoredVideo {
        StoredVideo(
            id: id, kind: kind, fileURL: nil, posterURL: nil, name: "n", duration: 5, width: 1, height: 1, bytes: 1,
            sessionID: session, link: URL(string: shortLink), remoteURL: remote, createdAt: Date())
    }

    @Test func theKeyTable() {
        #expect(PhotosKey.of(video(.original, session: "S1")) == "s:S1")
        #expect(PhotosKey.of(video(.original, session: "S1", remote: pickerURL)) == "s:S1", "a session wins over a remote url")
        #expect(PhotosKey.of(video(.original, remote: pickerURL)) == "r:https://cdn.example.com/p/1.mp4")
        #expect(PhotosKey.of(video(.webp, session: "S1", remote: hostedWebp)) == "w:https://media.capybaraharmony.com/aBcD.webp")
        #expect(PhotosKey.of(video(.webp, session: "S1")) == "i:abc", "a webp without its url is keyed by the store id")
        #expect(PhotosKey.of(video(.original)) == "i:abc", "a plain cobalt save")
        #expect(PhotosKey.original(session: "S1") == "s:S1" && PhotosKey.picker(url: pickerURL) == "r:https://cdn.example.com/p/1.mp4")
    }

    @Test func theKeyDoesNotDependOnTheIndexRecord() async throws {
        let env = try PhotosEnv()
        let a = try await env.add(session: "S9")
        let key = PhotosKey.of(a)
        _ = await env.store.evict(a.id)
        let evicted = try #require(env.store.videos.first)
        #expect(evicted.fileURL == nil && PhotosKey.of(evicted) == key, "eviction keeps the key")
        let file = try makeTempFile("refill.mp4")
        let refilled = try await env.store.attach(file: file, to: a.id, move: true)
        #expect(PhotosKey.of(refilled) == key, "a refill keeps it too")
        await env.store.clearAll()
        let again = try await env.add(session: "S9")
        #expect(PhotosKey.of(again) == key, "the same session is the same item after the whole record was removed")
    }

    @Test func whatIsEligible() async throws {
        let env = try PhotosEnv()
        let original = try await env.add(session: "S1")
        let upload = try await env.add(session: "S2", link: nil)
        let webp = try await env.add(session: "S1", remote: hostedWebp, kind: .webp)
        #expect(PhotosSync.isEligible(original, includeWebps: false))
        #expect(!PhotosSync.isEligible(upload, includeWebps: true), "no link: it came from this phone")
        #expect(!PhotosSync.isEligible(webp, includeWebps: false) && PhotosSync.isEligible(webp, includeWebps: true))
        _ = await env.store.evict(original.id)
        let evicted = try #require(env.store.videos.first { $0.id == original.id })
        #expect(!PhotosSync.isEligible(evicted, includeWebps: false), "no file on the phone: nothing to add yet")
    }

    @Test func nothingWithoutAFileIsAddedUntilARefillBringsItBack() async throws {
        let env = try PhotosEnv()
        let a = try await env.add(session: "S1")
        _ = await env.store.evict(a.id)
        env.turnOn()
        await env.reconcile()
        #expect(env.library.addCalls == 0 && env.ledger.entry("s:S1") == nil)
        _ = try await env.store.attach(file: try makeTempFile("refill.mp4"), to: a.id, move: true)
        await env.reconcile()
        #expect(env.library.addCalls == 1 && env.ledger.entry("s:S1")?.state == .done)
    }
}

// MARK: - The access matrix

@MainActor
struct PhotosAccessTests {
    @Test func theAccessMapping() {
        let table: [(PhotosReadWrite, PhotosAccess, PhotosSync.Access)] = [
            (.authorized, .authorized, .album), (.authorized, .notDetermined, .album),
            (.limited, .authorized, .libraryLimited), (.limited, .denied, .libraryLimited),
            (.denied, .authorized, .libraryAddOnly), (.notDetermined, .authorized, .libraryAddOnly),
            (.denied, .denied, .denied), (.notDetermined, .notDetermined, .notAsked),
            (.notDetermined, .denied, .denied), (.denied, .notDetermined, .denied),
        ]
        for (rw, addOnly, expected) in table {
            #expect(PhotosSync.access(of: FakePhotoLibrary(rw: rw, addOnly: addOnly)) == expected, "\(rw) / \(addOnly)")
        }
    }

    @Test func enablingAsksForReadWriteAndMapsTheAnswer() async throws {
        // full access: album
        let full = try PhotosEnv(rw: .notDetermined, addOnly: .notDetermined)
        full.library.rwAnswer = .authorized
        #expect(await full.sync.enable() == .on(existing: 0))
        #expect(full.settings.photosAlbumSync && full.sync.status.access == .album && full.library.count("requestReadWrite") == 1)

        // limited: library only
        let limited = try PhotosEnv(rw: .notDetermined, addOnly: .notDetermined)
        limited.library.rwAnswer = .limited
        #expect(await limited.sync.enable() == .on(existing: 0))
        #expect(limited.sync.status.access == .libraryLimited && limited.settings.photosAlbumSync)

        // read-write refused, add-only already granted: library only, add-only wording
        let addOnly = try PhotosEnv(rw: .notDetermined, addOnly: .authorized)
        addOnly.library.rwAnswer = .denied
        #expect(await addOnly.sync.enable() == .on(existing: 0))
        #expect(addOnly.sync.status.access == .libraryAddOnly && addOnly.settings.photosAlbumSync)

        // both refused: the toggle stays off
        let refused = try PhotosEnv(rw: .notDetermined, addOnly: .denied)
        refused.library.rwAnswer = .denied
        #expect(await refused.sync.enable() == .refused)
        #expect(!refused.settings.photosAlbumSync && refused.sync.status.access == .denied && !refused.sync.status.enabled)

        // already decided: the prompt is not shown again
        let known = try PhotosEnv(rw: .authorized)
        #expect(await known.sync.enable() == .on(existing: 0))
        #expect(known.library.count("requestReadWrite") == 0)

        // the Mac
        let mac = try PhotosEnv(available: false)
        #expect(await mac.sync.enable() == .refused && mac.sync.status.access == .unavailable && !mac.sync.isAvailable)
    }

    @Test func limitedAndAddOnlyAddToTheLibraryButNeverMakeAnAlbum() async throws {
        for (rw, addOnly) in [(PhotosReadWrite.limited, PhotosAccess.authorized), (.denied, .authorized)] {
            let env = try PhotosEnv(rw: rw, addOnly: addOnly)
            try await env.add(session: "S1")
            try await env.add(session: "S2")
            env.turnOn()
            await env.reconcile()
            #expect(env.library.addCalls == 2 && env.library.count("createAlbum") == 0 && env.library.count("findAlbum") == 0)
            #expect(env.ledger.entry("s:S1")?.inAlbum == .no)
            #expect(env.sync.status.added == 2)
        }
    }
}

// MARK: - Once per item

@MainActor
@Suite(.serialized)
struct PhotosOnceTests {
    @Test func aKeptOriginalGoesIntoTheAlbumOnceAndOnlyOnce() async throws {
        let env = try PhotosEnv()
        let a = try await env.add(session: "S1")
        env.turnOn()
        await env.reconcile()
        #expect(env.library.addCalls == 1 && env.library.count("createAlbum") == 1)
        let album = try #require(env.ledger.album)
        #expect(album.title == "cobalt" && env.library.members(of: album.id).count == 1)
        #expect(env.ledger.entry("s:S1")?.state == .done && env.ledger.entry("s:S1")?.inAlbum == .yes)
        await env.reconcile()
        await env.sync.refresh()
        await env.reconcile()
        #expect(env.library.addCalls == 1, "reconcile again: nothing")
        #expect(env.sync.placement(of: a) == .inAlbum)
        #expect(env.sync.status.added == 1 && env.sync.status.waiting == 0 && env.sync.status.progress == nil)
    }

    @Test func aStoreAddRunsTheSyncByItself() async throws {
        let env = try PhotosEnv()
        env.turnOn()
        try await env.add(session: "S1")                            // onAdd -> reconcile
        for _ in 0..<400 where env.library.addCalls == 0 { try? await Task.sleep(for: .milliseconds(5)) }
        await env.reconcile()
        #expect(env.library.addCalls == 1)
    }

    @Test func twoInstancesOverOneLedgerAddOnce() async throws {
        let first = try PhotosEnv()
        let second = try first.another()
        for n in 1...3 { try await first.add(session: "S\(n)") }
        first.library.slowAdds(by: 0.02)
        first.turnOn()
        async let a: Void = first.reconcile()
        async let b: Void = second.reconcile()
        _ = await (a, b)
        #expect(first.library.addCalls == 3, "each item once, whoever got there first")
        #expect(first.library.assets.count == 3 && first.library.count("createAlbum") == 1)
        for n in 1...3 { #expect(first.ledger.entry("s:S\(n)")?.state == .done) }
    }

    @Test func aDeletedAssetIsNeverReAdded() async throws {
        let env = try PhotosEnv()
        try await env.add(session: "S1")
        env.turnOn()
        await env.reconcile()
        let id = try #require(env.ledger.entry("s:S1")?.asset)
        env.library.deleteAsset(id)
        await env.sync.refresh()
        await env.reconcile()
        await env.reconcile()
        #expect(env.library.addCalls == 1 && env.library.assets.isEmpty, "the owner deleted it: nothing re-checks in order to re-add")
    }

    @Test func evictionAndClearAllMakeNoPhotosCalls() async throws {
        let env = try PhotosEnv()
        let a = try await env.add(session: "S1")
        try await env.add(session: "S2")
        env.turnOn()
        await env.reconcile()
        let before = env.library.log
        _ = await env.store.evict(a.id)
        await env.store.clearAll()
        await env.reconcile()
        #expect(env.library.log == before, "Photos is not told: eviction deletes only cobalt's file")
        #expect(env.library.assets.count == 2)
        // and what was cleared never comes back through the same session
        let back = try await env.add(session: "S1")
        _ = back
        await env.reconcile()
        #expect(env.library.addCalls == 2)
    }

    @Test func aClaimInDoubtIsSettledByAccess() async throws {
        // read access, the asset landed: done, not added again
        let landed = try PhotosEnv()
        try await landed.add(session: "S1")
        landed.library.seedAsset("X")
        #expect(landed.ledger.claim("s:S1", now: landed.clock.now()) == .claimed)
        landed.ledger.recordAsset("s:S1", "X")
        landed.clock.jump(by: 200)
        landed.turnOn()
        await landed.reconcile()
        #expect(landed.library.addCalls == 0 && landed.ledger.entry("s:S1")?.state == .done && landed.ledger.entry("s:S1")?.asset == "X")

        // read access, the asset is missing: tried again
        let missing = try PhotosEnv()
        try await missing.add(session: "S1")
        _ = missing.ledger.claim("s:S1", now: missing.clock.now())
        missing.ledger.recordAsset("s:S1", "GONE")
        missing.clock.jump(by: 200)
        missing.turnOn()
        await missing.reconcile()
        #expect(missing.library.addCalls == 1 && missing.ledger.entry("s:S1")?.state == .done && missing.ledger.entry("s:S1")?.asset != "GONE")

        // a claim that never got as far as an id, with read access: tried again
        let noID = try PhotosEnv()
        try await noID.add(session: "S1")
        _ = noID.ledger.claim("s:S1", now: noID.clock.now())
        noID.clock.jump(by: 200)
        noID.turnOn()
        await noID.reconcile()
        #expect(noID.library.addCalls == 1)

        // add-only cannot tell: never twice beats maybe-missing
        let addOnly = try PhotosEnv(rw: .denied, addOnly: .authorized)
        try await addOnly.add(session: "S1")
        _ = addOnly.ledger.claim("s:S1", now: addOnly.clock.now())
        addOnly.ledger.recordAsset("s:S1", "MAYBE")
        addOnly.clock.jump(by: 200)
        addOnly.turnOn()
        await addOnly.reconcile()
        #expect(addOnly.library.addCalls == 0 && addOnly.ledger.entry("s:S1")?.state == .done)

        // a fresh claim is somebody else's work in progress
        let fresh = try PhotosEnv()
        try await fresh.add(session: "S1")
        _ = fresh.ledger.claim("s:S1", now: fresh.clock.now())
        fresh.clock.jump(by: 30)
        fresh.turnOn()
        await fresh.reconcile()
        #expect(fresh.library.addCalls == 0 && fresh.ledger.entry("s:S1")?.state == .claimed)
    }

    @Test func theLedgerSurvivesAnotherProcessReadingIt() async throws {
        let env = try PhotosEnv()
        try await env.add(session: "S1")
        env.turnOn()
        await env.reconcile()
        let other = PhotosLedger(directory: env.directory.appendingPathComponent("Sync", isDirectory: true))
        #expect(other.entry("s:S1")?.state == .done && other.album?.title == "cobalt")
        other.recordManual("s:S2", asset: "M", inAlbum: .no, now: env.clock.now())
        #expect(env.ledger.entry("s:S2")?.origin == .manual, "the cache notices the other writer")
    }
}

// MARK: - The album

@MainActor
struct PhotosAlbumTests {
    @Test func theAlbumIsFoundByIDThenByTitleAndOtherwiseCreatedOnce() async throws {
        // by id
        let byID = try PhotosEnv()
        let mine = byID.library.seedAlbum(title: "cobalt")
        byID.library.seedAlbum(title: "cobalt")                       // another one with the same name
        byID.ledger.setAlbum(PhotosAlbumRecord(id: mine, title: "cobalt"))
        try await byID.add(session: "S1")
        byID.turnOn()
        await byID.reconcile()
        #expect(byID.library.count("createAlbum") == 0 && byID.library.members(of: mine).count == 1)

        // renamed by the owner: cobalt keeps using it
        let renamed = try PhotosEnv()
        let theirs = renamed.library.seedAlbum(title: "holiday")
        renamed.ledger.setAlbum(PhotosAlbumRecord(id: theirs, title: "cobalt"))
        try await renamed.add(session: "S1")
        renamed.turnOn()
        await renamed.reconcile()
        #expect(renamed.library.count("createAlbum") == 0 && renamed.library.members(of: theirs).count == 1)

        // by title: the remembered one is gone
        let byTitle = try PhotosEnv()
        byTitle.ledger.setAlbum(PhotosAlbumRecord(id: "ALBUM-DELETED", title: "cobalt"))
        let found = byTitle.library.seedAlbum(title: "cobalt")
        try await byTitle.add(session: "S1")
        byTitle.turnOn()
        await byTitle.reconcile()
        #expect(byTitle.library.count("createAlbum") == 0 && byTitle.library.members(of: found).count == 1)
        #expect(byTitle.ledger.album?.id == found, "the ledger follows")

        // neither: created, once, even with two instances racing
        let none = try PhotosEnv()
        let other = try none.another()
        for n in 1...4 { try await none.add(session: "S\(n)") }
        none.library.slowAdds(by: 0.01)
        none.turnOn()
        async let a: Void = none.reconcile()
        async let b: Void = other.reconcile()
        _ = await (a, b)
        #expect(none.library.count("createAlbum") == 1)
        #expect(none.library.members(of: try #require(none.ledger.album).id).count == 4)
    }

    @Test func aRemovedAlbumGetsNewItemsOnlyAndNeverTheOldOnes() async throws {
        let env = try PhotosEnv()
        try await env.add(session: "S1")
        env.turnOn()
        await env.reconcile()
        let first = try #require(env.ledger.album)
        env.library.deleteAlbum(first.id)
        try await env.add(session: "S2")
        await env.reconcile()
        let second = try #require(env.ledger.album)
        #expect(second.id != first.id && env.library.count("createAlbum") == 2)
        #expect(env.library.members(of: second.id).count == 1, "only the new item: the old one is not copied again")
        #expect(env.library.addCalls == 2)
    }

    @Test func upgradingToFullAccessMovesLibraryItemsIntoTheAlbumAndSkipsMissingOnes() async throws {
        let env = try PhotosEnv(rw: .limited)
        for n in 1...3 { try await env.add(session: "S\(n)") }
        env.turnOn()
        await env.reconcile()
        #expect(env.library.addCalls == 3 && env.library.count("createAlbum") == 0)
        let gone = try #require(env.ledger.entry("s:S2")?.asset)
        env.library.deleteAsset(gone)
        env.library.setAccess(rw: .authorized)
        await env.sync.refresh()
        #expect(env.sync.status.access == .album)
        await env.reconcile()
        let album = try #require(env.ledger.album)
        #expect(env.library.count("createAlbum") == 1 && env.library.members(of: album.id).count == 2)
        #expect(env.ledger.entry("s:S1")?.inAlbum == .yes && env.ledger.entry("s:S3")?.inAlbum == .yes)
        #expect(env.ledger.entry("s:S2")?.inAlbum == .gone, "the deleted one is not resurrected")
        #expect(env.library.addCalls == 3 && env.library.assets.count == 2)

        // what the owner then takes out of the album stays out
        let moved = try #require(env.ledger.entry("s:S1")?.asset)
        env.library.removeFromAlbum(moved, album: album.id)
        let calls = env.library.count("addToAlbum")
        await env.reconcile()
        #expect(env.library.count("addToAlbum") == calls && !env.library.members(of: album.id).contains(moved))
    }
}

// MARK: - Backfill, webps, the manual button

@MainActor
struct PhotosBackfillTests {
    @Test func existingVideosWaitForTheOwnersAnswer() async throws {
        // "only new ones"
        let env = try PhotosEnv(rw: .notDetermined, addOnly: .notDetermined)
        env.library.rwAnswer = .authorized
        try await env.add(session: "S1")
        try await env.add(session: "S2")
        let evicted = try await env.add(session: "S3")
        _ = await env.store.evict(evicted.id)
        #expect(await env.sync.enable() == .on(existing: 2), "only items whose file is on this phone are counted")
        await env.reconcile()
        #expect(env.library.addCalls == 0, "nothing is added before the answer")
        await env.sync.includeExisting(false)
        #expect(env.library.addCalls == 0)
        try await env.add(session: "S4")
        await env.reconcile()
        #expect(env.library.addCalls == 1 && env.ledger.entry("s:S4")?.state == .done)
        #expect(env.ledger.entry("s:S1")?.skip == .preexisting)

        // "add 2"
        let all = try PhotosEnv()
        try await all.add(session: "S1")
        try await all.add(session: "S2")
        #expect(await all.sync.enable() == .on(existing: 2))
        await all.sync.includeExisting(true)
        #expect(all.library.addCalls == 2 && all.sync.status.added == 2)
    }

    @Test func nothingToAskWhenNothingIsThere() async throws {
        let env = try PhotosEnv()
        #expect(await env.sync.enable() == .on(existing: 0))
        try await env.add(session: "S1")
        await env.reconcile()
        #expect(env.library.addCalls == 1)
    }

    @Test func turningWebpsOnMarksTheExistingOnesSkipped() async throws {
        let env = try PhotosEnv()
        try await env.add(session: "S1")
        let old = try await env.add(session: "S1", remote: hostedWebp, kind: .webp)
        env.turnOn()
        await env.reconcile()
        #expect(env.library.addCalls == 1, "webps are off by default")
        env.sync.setIncludeWebps(true)
        #expect(env.settings.photosSyncWebps)
        #expect(env.ledger.entry(PhotosKey.of(old))?.skip == .preexisting, "marked skipped, no prompt")
        let fresh = try await env.add(session: "S2", remote: URL(string: "https://media.capybaraharmony.com/fReSh.webp")!, kind: .webp)
        await env.reconcile()
        #expect(env.library.addCalls == 2 && env.ledger.entry(PhotosKey.of(fresh))?.state == .done)
        #expect(env.library.assets.values.filter(\.isImage).count == 1, "the new webp went in as a picture")
    }
}

@MainActor
struct PhotosManualSaveTests {
    @Test func aManualSaveRecordsItsKeyAndTheAlbumModeAppPutsItInTheAlbum() async throws {
        let env = try PhotosEnv()
        env.turnOn()
        let file = try makeTempFile("clip.mp4")
        try await env.sync.manualSave(fileURL: file, isImage: false, key: "s:S1", saver: FakePhotos())
        let album = try #require(env.ledger.album)
        let asset = try #require(env.ledger.entry("s:S1"))
        #expect(asset.state == .done && asset.origin == .manual && asset.inAlbum == .yes)
        #expect(env.library.members(of: album.id).count == 1)
        #expect(env.sync.placement(key: "s:S1") == .inAlbum)
        // the same item arriving in the store later is not added again
        let stored = try await env.add(session: "S1")
        await env.reconcile()
        #expect(env.library.addCalls == 1 && env.sync.placement(of: stored) == .inAlbum)
    }

    @Test func withoutTheAlbumItGoesToTheLibraryAndIsRecordedThere() async throws {
        let env = try PhotosEnv(rw: .denied, addOnly: .authorized)
        env.turnOn()
        let saver = FakePhotos()
        try await env.sync.manualSave(fileURL: try makeTempFile("clip.mp4"), isImage: false, key: "s:S1", saver: saver)
        #expect(saver.saved.count == 1 && env.library.count("createAlbum") == 0)
        #expect(env.ledger.entry("s:S1")?.inAlbum == .no && env.sync.placement(key: "s:S1") == .inLibrary)
    }

    @Test func aDeletedAssetIsNotInYourPhotosAnymoreAndMayBeSavedAgain() async throws {
        let env = try PhotosEnv()
        env.turnOn()
        try await env.sync.manualSave(fileURL: try makeTempFile("clip.mp4"), isImage: false, key: "s:S1", saver: FakePhotos())
        let first = try #require(env.ledger.entry("s:S1")?.asset)
        env.library.deleteAsset(first)
        env.clock.jump(by: 10)                                     // the existence check is cached for a moment
        #expect(env.sync.placement(key: "s:S1") == .none, "the button is the normal save again")
        try await env.sync.manualSave(fileURL: try makeTempFile("clip.mp4"), isImage: false, key: "s:S1", saver: FakePhotos())
        let second = try #require(env.ledger.entry("s:S1")?.asset)
        #expect(second != first && env.sync.placement(key: "s:S1") == .inAlbum, "recorded as a new asset")
    }

    @Test func theContextRecordsTheExtensionsSaveInTheSharedLedger() async throws {
        let h = Harness(.shortClip)
        let ledger = PhotosLedger(directory: try makeTempDirectory())
        h.ctx.photosLedger = ledger
        let file = try makeTempFile("clip.mp4")
        let ctx = h.ctx
        final class Flag: @unchecked Sendable { var done = false }
        let one = Flag()
        let first = Task { try await ctx.savePhoto(fileURL: file, isImage: false, key: "s:S7"); one.done = true }
        await h.drive { one.done }                                  // the preview saver takes 0.3 virtual seconds
        try await first.value
        #expect(ledger.entry("s:S7")?.state == .done && ledger.entry("s:S7")?.inAlbum == .no)
        #expect(h.ctx.photosPlacement(forKey: "s:S7") == .inLibrary)
        let two = Flag()
        let second = Task { try await ctx.savePhoto(fileURL: file, isImage: false, key: nil); two.done = true }   // no key: nothing recorded
        await h.drive { two.done }
        try await second.value
        #expect(ledger.snapshot().items.count == 1)
    }

    @Test func pickerSavesRecordTheirKeysAndTheirStoreEntriesShareThem() async throws {
        let h = Harness(.picker)
        let ledger = PhotosLedger(directory: try makeTempDirectory())
        h.ctx.photosLedger = ledger
        h.pipeline.start(link: URL(string: shortLink)!)
        await h.driveToSettled()
        guard case .picker(let items) = h.pipeline.state else { Issue.record("expected the picker"); return }
        h.pipeline.saveAllPickerItemsToPhotos()
        await h.drive { h.pipeline.photos == .done }
        let video = try #require(items.first { $0.type == .video })
        let photo = try #require(items.first { $0.type == .photo })
        #expect(ledger.entry(PhotosKey.picker(url: video.url))?.state == .done)
        #expect(ledger.entry(PhotosKey.picker(url: photo.url)) == nil, "stills are not part of the album")
        // the store entry the picker video leaves has the same key, so the sync would never add it again
        let stored = try #require(h.ctx.store.videos.first { $0.remoteURL == video.url })
        #expect(PhotosKey.of(stored) == PhotosKey.picker(url: video.url))
    }

    @Test func aRunsPlacementFollowsItsOwnSaveAndThePreviewPin() async throws {
        let h = Harness(.shortClip)
        h.ctx.photosLedger = PhotosLedger(directory: try makeTempDirectory())
        let p = h.pipeline
        p.start(link: URL(string: shortLink)!)
        await h.driveToSettled()
        #expect(p.photosPlacement == .none)
        p.saveToPhotos()
        await h.drive { p.photos == .done }
        #expect(p.photosPlacement == .inLibrary, "saved in this run: the button says so")
        p.previewPhotosPlacement(.inAlbum)
        #expect(p.photosPlacement == .inAlbum)
        p.previewPhotosPlacement(nil)
        #expect(p.photosPlacement == .inLibrary)
    }
}

// MARK: - Problems and the stop switches

@MainActor
struct PhotosProblemTests {
    private func photosError(_ code: Int) -> NSError { NSError(domain: "PHPhotosErrorDomain", code: code) }

    @Test func aFullPhotoLibraryLeavesTheEntriesWaitingAndTriesAgain() async throws {
        let env = try PhotosEnv()
        try await env.add(session: "S1")
        try await env.add(session: "S2")
        env.library.failNext(photosError(3305))
        env.turnOn()
        await env.reconcile()
        #expect(env.sync.status.problem == .outOfSpace)
        #expect(env.sync.status.waiting == 2 && env.sync.status.added == 0 && env.sync.status.gaveUp == 0)
        #expect(env.library.addCalls == 1, "the pass stops: the second item would fail the same way")
        #expect(env.ledger.entry("s:S1") == nil, "released, not counted as a failure")
        await env.reconcile()
        #expect(env.sync.status.problem == nil && env.sync.status.added == 2 && env.sync.status.waiting == 0)
    }

    @Test func anUnavailableLibraryRetriesOnTheNextForeground() async throws {
        let env = try PhotosEnv()
        try await env.add(session: "S1")
        env.library.failNext(PhotosError.failed(code: 3114))
        env.turnOn()
        await env.reconcile()
        #expect(env.sync.status.problem == .libraryUnavailable && env.sync.status.waiting == 1)
        await env.sync.refresh()
        await env.reconcile()
        #expect(env.sync.status.added == 1 && env.sync.status.problem == nil)
    }

    @Test func threeFailuresGiveUp() async throws {
        let env = try PhotosEnv()
        try await env.add(session: "S1")
        env.library.failNext(photosError(3300), times: 3)
        env.turnOn()
        for pass in 1...3 {
            await env.reconcile()
            #expect(env.ledger.entry("s:S1")?.tries == pass)
        }
        #expect(env.ledger.entry("s:S1")?.state == .skipped && env.ledger.entry("s:S1")?.skip == .gaveUp)
        #expect(env.sync.status.gaveUp == 1 && env.sync.status.waiting == 0)
        await env.reconcile()
        #expect(env.library.addCalls == 3, "a given-up item is left alone")
    }

    @Test func disablingStopsNewAddsAndKeepOffPauses() async throws {
        let env = try PhotosEnv()
        try await env.add(session: "S1")
        env.turnOn()
        await env.reconcile()
        #expect(env.library.addCalls == 1)
        env.sync.disable()
        #expect(!env.settings.photosAlbumSync && !env.sync.status.enabled)
        try await env.add(session: "S2")
        await env.reconcile()
        #expect(env.library.addCalls == 1)

        env.turnOn()
        env.settings.keepVideosOnDevice = false
        #expect(env.sync.status.paused && env.sync.status.enabled)
        await env.reconcile()
        #expect(env.library.addCalls == 1, "paused: the album is filled from what cobalt keeps")
        env.settings.keepVideosOnDevice = true
        await env.reconcile()
        #expect(env.library.addCalls == 2 && !env.sync.status.paused)
    }

    @Test func revokedAccessStopsThePassWithoutLosingTheItem() async throws {
        let env = try PhotosEnv()
        try await env.add(session: "S1")
        env.library.failNext(PhotosError.denied)
        env.turnOn()
        await env.reconcile()
        #expect(env.ledger.entry("s:S1") == nil && env.library.addCalls == 1)
        await env.reconcile()
        #expect(env.ledger.entry("s:S1")?.state == .done)
    }

    @Test func aPreviewSyncNeverTouchesPhotoKitAndMovesItsStatus() async throws {
        let sync = PhotosSync.preview(.init(access: .denied, enabled: false))
        #expect(sync.isAvailable && sync.status.access == .denied)
        #expect(await sync.enable() == .on(existing: 3))
        #expect(sync.status.enabled && sync.status.access == .album)
        await sync.includeExisting(true)
        #expect(sync.status.waiting == 3)
        sync.disable()
        #expect(!sync.status.enabled)
        sync.setPreviewStatus(.init(access: .unavailable, enabled: false))
        #expect(!sync.isAvailable)
        await sync.reconcile()
        await sync.refresh()
        #expect(sync.placement(of: StoredVideo(
            id: "x", kind: .original, fileURL: nil, posterURL: nil, name: "n", duration: nil, width: nil, height: nil, bytes: 1,
            sessionID: "S", link: nil, remoteURL: nil, createdAt: Date())) == .none)
    }
}
