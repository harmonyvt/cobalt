import Foundation
import Testing
@testable import CobaltKit

// The Mac's "save to a folder": naming and de-dupe, the ledger's never-twice, a file the owner deleted
// staying deleted, a kill mid-copy, the bookmark round trip, the backfill offer. Real files in temp
// directories; no clock but the one a test injects.

private struct FixedClock: PipelineClock {
    let at: Date
    func now() -> Date { at }
    func sleep(seconds: Double) async throws {}
}

private let hostedWebp1 = URL(string: "https://media.capybaraharmony.com/aBcD000001.webp")!
private let hostedWebp2 = URL(string: "https://media.capybaraharmony.com/aBcD000002.webp")!
private let igLink = URL(string: "https://www.instagram.com/reel/DeHC9jcpfQW/")!

// MARK: - Naming

struct FolderNamingTests {
    private func video(
        kind: StoredVideo.Kind = .original, id: String = "v1", name: String = "clip", file: String? = "x.mp4",
        link: URL? = igLink, title: String? = nil, remote: URL? = nil
    ) -> StoredVideo {
        StoredVideo(
            id: id, kind: kind, fileURL: file.map { URL(fileURLWithPath: "/store/\($0)") }, posterURL: nil, name: name,
            duration: 5, width: 1, height: 1, bytes: 10, sessionID: "S1", link: link, remoteURL: remote,
            createdAt: Date(timeIntervalSince1970: 1_000), title: title)
    }

    @Test func aLinkSaveIsServiceDotRef() {
        let v = video()
        #expect(FolderNaming.fileName(for: v, in: nil) == "instagram · DeHC9jcpfQW.mp4")
    }

    @Test func aCustomTitleWinsAndAFileKeepsItsName() {
        #expect(FolderNaming.fileName(for: video(title: "cat on a keyboard"), in: nil) == "cat on a keyboard.mp4")
        let picked = video(name: "IMG_0412.MOV", file: "y.mov", link: nil)
        #expect(FolderNaming.fileName(for: picked, in: nil) == "IMG_0412.mov", "the file's name without its media extension, the file's own extension")
        let bare = video(name: "", link: nil)
        #expect(FolderNaming.fileName(for: bare, in: nil) == "cobalt.mp4")
    }

    @Test func aWebpIsTitleDotWebpAndItsNumber() throws {
        let original = video()
        let w1 = video(kind: .webp, id: "w1", name: "a.webp", file: "w1.webp", remote: hostedWebp1)
        let w2 = video(kind: .webp, id: "w2", name: "b.webp", file: "w2.webp", remote: hostedWebp2)
        let media = try #require(StoredMedia(id: "m", original: original, webps: [w1, w2]))
        #expect(FolderNaming.fileName(for: w1, in: media) == "instagram · DeHC9jcpfQW · webp 1.webp")
        #expect(FolderNaming.fileName(for: w2, in: media) == "instagram · DeHC9jcpfQW · webp 2.webp")
        #expect(FolderNaming.fileName(for: original, in: media) == "instagram · DeHC9jcpfQW.mp4")
        var titled = w2
        titled.title = "party"
        let renamed = try #require(StoredMedia(id: "m", original: nil, webps: [titled]))
        #expect(FolderNaming.fileName(for: titled, in: renamed) == "party · webp 1.webp", "the webp's own place among the media's webps")
    }

    @Test func theNameIsOnePathComponent() {
        let evil = video(link: nil, title: "a/b:c\\d\u{0}e\n..")
        let name = FolderNaming.fileName(for: evil, in: nil)
        #expect(!name.contains("/") && !name.contains(":") && !name.contains("\\") && !name.contains("\n") && !name.contains("\u{0}"))
        #expect(!name.hasPrefix("."))
        #expect(FolderNaming.assemble(stem: "...", ext: "mp4") == "cobalt.mp4")
        #expect(FolderNaming.assemble(stem: ".hidden", ext: "mp4").hasPrefix("_hidden"), "never a hidden file")
        #expect(FolderNaming.assemble(stem: "fin. ", ext: "mp4") == "fin.mp4", "no trailing dot or space before the extension")
    }

    @Test func aLongTitleKeepsItsExtensionAndFitsAName() {
        let emoji = String(repeating: "🎬", count: 80)                       // 4 bytes each: 320 bytes
        let name = FolderNaming.fileName(for: video(title: emoji), in: nil)
        #expect(name.hasSuffix(".mp4"))
        #expect(name.utf8.count <= 255 - 5, "room is left for ' (99)'")
    }

    @Test func aClashGetsACounterBeforeTheExtension() {
        var taken: Set<String> = ["a.mp4", "a (2).mp4"]
        #expect(FolderNaming.unique("b.mp4") { taken.contains($0) } == "b.mp4")
        #expect(FolderNaming.unique("a.mp4") { taken.contains($0) } == "a (3).mp4")
        taken.insert("a (3).mp4")
        #expect(FolderNaming.unique("a.mp4") { taken.contains($0) } == "a (4).mp4")
        #expect(FolderNaming.unique("noext") { $0 == "noext" } == "noext (2)")
    }

    @Test func theExtensionIsTheFilesOwn() {
        #expect(FolderNaming.fileExtension(of: video(file: "z.MOV")) == "mov")
        #expect(FolderNaming.fileExtension(of: video(file: nil)) == "mp4")
        #expect(FolderNaming.fileExtension(of: video(kind: .webp, file: nil)) == "webp")
        #expect(FolderNaming.fileExtension(of: video(file: "weird")) == "mp4", "no extension: the kind's")
    }
}

// MARK: - The ledger

struct FolderLedgerTests {
    private func ledger() throws -> FolderLedger { FolderLedger(directory: try makeTempDirectory()) }
    private let now = Date(timeIntervalSince1970: 5_000)

    @Test func anItemIsClaimedOnceAndDoneIsForever() throws {
        let l = try ledger()
        #expect(l.claim("default", "s:1", now: now) == .claimed)
        #expect(l.claim("default", "s:1", now: now) == .inFlight, "this launch is already on it")
        l.finish("default", "s:1", file: "a.mp4", now: now)
        #expect(l.claim("default", "s:1", now: now.addingTimeInterval(86_400 * 30)) == .alreadyDone, "never twice, however long ago")
        #expect(l.entry("default", "s:1")?.file == "a.mp4")
    }

    @Test func aClaimFromAnotherLaunchIsInDoubtAtOnce() throws {
        let l = try ledger()
        _ = l.claim("default", "s:1", now: now)
        // a process that died: its launch id is not this one
        let url = l.url
        var f = try JSONDecoder().decode(FolderStateFile.self, from: Data(contentsOf: url))
        f.sections["default"]?.items["s:1"]?.by = "another-launch"
        try JSONEncoder().encode(f).write(to: url)
        guard case .doubt = l.claim("default", "s:1", now: now.addingTimeInterval(1)) else {
            Issue.record("a dead launch's claim must be settled, not waited out")
            return
        }
    }

    @Test func aStaleClaimOfThisLaunchIsInDoubtToo() throws {
        let l = try ledger()
        _ = l.claim("default", "s:1", now: now)
        guard case .doubt = l.claim("default", "s:1", now: now.addingTimeInterval(FolderLedger.staleClaim + 1)) else {
            Issue.record("a copy that took longer than the limit is in doubt")
            return
        }
    }

    @Test func releaseGoesBackToNotTriedAndThreeFailuresGiveUp() throws {
        let l = try ledger()
        _ = l.claim("default", "s:1", now: now)
        l.release("default", "s:1")
        #expect(l.entry("default", "s:1") == nil)
        for n in 1...3 {
            #expect(l.claim("default", "s:2", now: now) == .claimed)
            let state = l.fail("default", "s:2", code: 9, now: now)
            #expect(state == (n < 3 ? .failed : .skipped))
        }
        #expect(l.claim("default", "s:2", now: now) == .skipped)
        #expect(l.entry("default", "s:2")?.skip == .gaveUp)
    }

    @Test func preexistingIsMarkedOnlyWhenThereIsNoEntryAndCanBeUnmarked() throws {
        let l = try ledger()
        _ = l.claim("default", "s:1", now: now)
        l.finish("default", "s:1", file: "a.mp4", now: now)
        l.skipPreexisting("default", ["s:1", "s:2"], path: "/p", now: now)
        #expect(l.entry("default", "s:1")?.state == .done, "an entry is kept")
        #expect(l.entry("default", "s:2")?.skip == .preexisting)
        l.unskipPreexisting("default", ["s:1", "s:2"])
        #expect(l.entry("default", "s:1")?.state == .done && l.entry("default", "s:2") == nil)
    }

    @Test func eachFolderHasItsOwnSectionAndAKnownFolderComesBack() throws {
        let l = try ledger()
        let a = l.choose(path: "/Volumes/A/cobalt", bookmark: Data([1]), isDefault: false)
        _ = l.claim(a, "s:1", now: now)
        l.finish(a, "s:1", file: "a.mp4", now: now)
        let back = l.choose(path: "/somewhere", bookmark: nil, isDefault: true)
        #expect(back == FolderLedger.defaultID && l.destination == nil)
        #expect(l.entry(back, "s:1") == nil, "another folder has its own list")
        let again = l.choose(path: "/Volumes/A/cobalt", bookmark: Data([2]), isDefault: false)
        #expect(again == a && l.entry(again, "s:1")?.state == .done, "choosing a folder the ledger knows brings its list back")
        #expect(l.destination?.bookmark == Data([2]))
    }

    @Test func theFileSurvivesARelaunch() throws {
        let dir = try makeTempDirectory()
        let a = FolderLedger(directory: dir)
        _ = a.claim("default", "s:1", now: now)
        a.finish("default", "s:1", file: "a.mp4", now: now)
        let b = FolderLedger(directory: dir)
        #expect(b.entry("default", "s:1")?.state == .done)
    }
}

// MARK: - The bookmark

struct FolderBookmarkTests {
    @Test func aBookmarkResolvesToTheSameFolder() throws {
        let dir = try makeTempDirectory().appendingPathComponent("chosen", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let data = try FolderDestination.makeBookmark(for: dir)
        let resolved = try #require(FolderDestination.resolve(bookmark: data))
        defer { resolved.access.stop() }
        #expect(FolderDestination.canonical(resolved.access.url) == FolderDestination.canonical(dir))
        #expect(!resolved.stale)
        // and it is a folder cobalt can write into
        let probe = resolved.access.url.appendingPathComponent("probe.txt")
        try Data("x".utf8).write(to: probe)
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("probe.txt").path))
    }

    @Test func aBookmarkFollowsAFolderTheOwnerRenamed() throws {
        let root = try makeTempDirectory()
        let before = root.appendingPathComponent("before", isDirectory: true)
        let after = root.appendingPathComponent("after", isDirectory: true)
        try FileManager.default.createDirectory(at: before, withIntermediateDirectories: true)
        let data = try FolderDestination.makeBookmark(for: before)
        try FileManager.default.moveItem(at: before, to: after)
        let resolved = try #require(FolderDestination.resolve(bookmark: data))
        defer { resolved.access.stop() }
        #expect(FolderDestination.canonical(resolved.access.url) == FolderDestination.canonical(after))
    }

    @Test func openingTheDestinationFollowsTheLedgerAndNeverRecreatesAChosenFolder() throws {
        let root = try makeTempDirectory()
        let l = FolderLedger(directory: root.appendingPathComponent("Sync"))
        let fallback = root.appendingPathComponent("Movies/cobalt", isDirectory: true)

        // default: made on demand
        guard case .ready(let a, let id, _) = FolderDestination.open(ledger: l, defaultFolder: fallback) else { Issue.record("default not ready"); return }
        #expect(id == FolderLedger.defaultID && FileManager.default.fileExists(atPath: fallback.path))
        a.stop()

        // chosen: through its bookmark
        let chosen = root.appendingPathComponent("chosen", isDirectory: true)
        try FileManager.default.createDirectory(at: chosen, withIntermediateDirectories: true)
        l.choose(path: chosen.path, bookmark: try FolderDestination.makeBookmark(for: chosen), isDefault: false)
        guard case .ready(let b, let chosenID, _) = FolderDestination.open(ledger: l, defaultFolder: fallback) else { Issue.record("chosen not ready"); return }
        #expect(chosenID == l.destinationID && FolderDestination.canonical(b.url) == FolderDestination.canonical(chosen))
        b.stop()

        // chosen, then deleted: reported missing, not re-made
        try FileManager.default.removeItem(at: chosen)
        guard case .missing = FolderDestination.open(ledger: l, defaultFolder: fallback) else { Issue.record("a deleted folder must read as missing"); return }
        #expect(!FileManager.default.fileExists(atPath: chosen.path))
    }
}

// MARK: - The sync, end to end

@MainActor
struct FolderEnv {
    let settings: Settings
    let store: OfflineStore
    let ledger: FolderLedger
    let sync: FolderSync
    let root: URL
    let folder: URL

    /// `existing` saves are in the store before the sync starts (older than its launch). With
    /// `launchedLongAgo` the sync "started" before everything the test adds.
    init(existing: Int = 0, launchedLongAgo: Bool = false, root shared: URL? = nil, available: Bool = true, defaultsOn: Bool = true) async throws {
        root = try shared ?? makeTempDirectory()
        folder = root.appendingPathComponent("Movies/cobalt", isDirectory: true)
        let suite = "cobalt.folder.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        settings = Settings(defaults: defaults, keychain: .memory())
        if !defaultsOn { settings.folderSync = false }
        store = OfflineStore(
            root: root.appendingPathComponent("Videos", isDirectory: true),
            tools: PreviewMediaTools(clock: VirtualClock(), clip: PreviewData.long), defaults: defaults)
        ledger = FolderLedger(directory: root.appendingPathComponent("Sync", isDirectory: true))
        for n in 0..<existing {
            _ = try await Self.add(to: store, session: "OLD\(n)", name: "old\(n)")
        }
        let launch = Date().addingTimeInterval(launchedLongAgo ? -3_600 : 3_600)
        sync = FolderSync(
            settings: settings, store: store, ledger: ledger, clock: FixedClock(at: launch), available: available,
            defaultFolder: folder)
    }

    @discardableResult
    static func add(
        to store: OfflineStore, session: String? = nil, link: URL? = URL(string: shortLink), remote: URL? = nil,
        kind: StoredVideo.Kind = .original, name: String = "clip", mediaID: String? = nil
    ) async throws -> StoredVideo {
        let file = try makeTempFile("\(name)-\(UUID().uuidString.prefix(4)).\(kind == .webp ? "webp" : "mp4")", bytes: 2_000)
        let media = MediaInfo(name: name, duration: 5, width: 720, height: 1280, bytes: nil, isImage: kind == .webp)
        return try await store.add(
            file: file, kind: kind, media: media, sessionID: session, link: link, remoteURL: remote, move: true, mediaID: mediaID)
    }

    @discardableResult
    func add(
        session: String? = nil, link: URL? = URL(string: shortLink), remote: URL? = nil, kind: StoredVideo.Kind = .original,
        name: String = "clip"
    ) async throws -> StoredVideo {
        try await Self.add(to: store, session: session, link: link, remote: remote, kind: kind, name: name)
    }

    var listing: [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).sorted()
    }
    var visible: [String] { listing.filter { !$0.hasPrefix(".") } }
}

@MainActor
struct FolderSyncTests {
    @Test func aSaveIsCopiedOnceIntoTheCreatedFolderWithAFriendlyName() async throws {
        let env = try await FolderEnv(launchedLongAgo: true)
        #expect(!FileManager.default.fileExists(atPath: env.folder.path), "nothing is made before something is saved")
        let v = try await env.add(session: "S1")
        await env.sync.reconcile()
        #expect(env.visible == ["x · 2105435404002562056.mp4"])
        #expect(FileManager.default.fileExists(atPath: v.fileURL!.path), "copied, not moved: the store keeps its own file")
        let copy = env.folder.appendingPathComponent(env.visible[0])
        #expect(try Data(contentsOf: copy) == Data(contentsOf: v.fileURL!))
        #expect(env.sync.status.saved == 1 && env.sync.status.waiting == 0 && env.sync.hasCopy(v))
        await env.sync.reconcile()
        await env.sync.reconcile()
        #expect(env.visible.count == 1, "never twice")
        #expect(env.listing.allSatisfy { !$0.hasSuffix(".part") }, "no partial file is left")
    }

    @Test func aWebpGoesInToo() async throws {
        let env = try await FolderEnv(launchedLongAgo: true)
        try await env.add(session: "S1")
        try await env.add(session: "S1", remote: hostedWebp1, kind: .webp, name: "w1")
        try await env.add(session: "S1", remote: hostedWebp2, kind: .webp, name: "w2")
        await env.sync.reconcile()
        #expect(env.visible == [
            "x · 2105435404002562056 · webp 1.webp", "x · 2105435404002562056 · webp 2.webp", "x · 2105435404002562056.mp4",
        ])
    }

    @Test func twoSavesWithTheSameNameGetACounter() async throws {
        let env = try await FolderEnv(launchedLongAgo: true)
        try await env.add(session: "S1", link: nil, name: "holiday")
        try await env.add(session: "S2", link: nil, name: "holiday")
        try await env.add(session: "S3", link: nil, name: "holiday")
        await env.sync.reconcile()
        #expect(env.visible == ["holiday (2).mp4", "holiday (3).mp4", "holiday.mp4"])
    }

    @Test func aFileTheOwnerDeletedIsNeverPutBack() async throws {
        let env = try await FolderEnv(launchedLongAgo: true)
        try await env.add(session: "S1")
        await env.sync.reconcile()
        let name = try #require(env.visible.first)
        try FileManager.default.removeItem(at: env.folder.appendingPathComponent(name))
        await env.sync.reconcile()
        try await env.add(session: "S2", link: URL(string: "https://x.com/i/status/2")!)
        await env.sync.reconcile()
        #expect(env.visible == ["x · 2.mp4"], "the deleted one stays deleted; the new one comes")
        #expect(env.ledger.entry(FolderLedger.defaultID, "s:S1")?.state == .done)
    }

    @Test func aRenamedFileIsNotCopiedAgainAndANewTitleDoesNotRenameIt() async throws {
        let env = try await FolderEnv(launchedLongAgo: true)
        let v = try await env.add(session: "S1")
        await env.sync.reconcile()
        let name = try #require(env.visible.first)
        try FileManager.default.moveItem(at: env.folder.appendingPathComponent(name), to: env.folder.appendingPathComponent("mine.mp4"))
        await env.store.setTitle("a new title", media: v.mediaID)
        await env.sync.reconcile()
        #expect(env.visible == ["mine.mp4"], "neither a Finder rename nor a rename in cobalt makes a second copy or renames the file")
    }

    @Test func evictionAndARefillNeverBringAnItemBack() async throws {
        let env = try await FolderEnv(launchedLongAgo: true)
        let v = try await env.add(session: "S1")
        await env.sync.reconcile()
        let name = try #require(env.visible.first)
        try FileManager.default.removeItem(at: env.folder.appendingPathComponent(name))
        _ = await env.store.evict(v.id)
        _ = try await env.store.attach(file: try makeTempFile("refill.mp4"), to: v.id, move: true)
        await env.sync.reconcile()
        #expect(env.visible.isEmpty)
    }

    @Test func theFolderIsRemadeWhenTheOwnerDeletedTheDefaultOne() async throws {
        let env = try await FolderEnv(launchedLongAgo: true)
        try await env.add(session: "S1")
        await env.sync.reconcile()
        try FileManager.default.removeItem(at: env.folder)
        try await env.add(session: "S2", link: URL(string: "https://x.com/i/status/3")!)
        await env.sync.reconcile()
        #expect(env.visible == ["x · 3.mp4"], "the default folder is made again; what was in it is not copied back")
    }

    @Test func offStopsCopiesAndOnOffersWhatWasSavedMeanwhile() async throws {
        let env = try await FolderEnv(launchedLongAgo: true)
        try await env.add(session: "S1")
        await env.sync.reconcile()
        env.sync.disable()
        try await env.add(session: "S2", link: URL(string: "https://x.com/i/status/4")!)
        try await env.add(session: "S3", link: URL(string: "https://x.com/i/status/5")!)
        await env.sync.reconcile()
        #expect(env.visible.count == 1 && !env.settings.folderSync)
        let offered = await env.sync.enable()
        #expect(offered == 2, "the two saved while it was off are offered, not copied")
        #expect(env.visible.count == 1 && env.sync.status.existing == 2)
        await env.sync.includeExisting(true)
        #expect(env.visible.count == 3 && env.sync.status.existing == 0)
    }

    @Test func nothingHappensWhereThereIsNoFolderFeature() async throws {
        let env = try await FolderEnv(launchedLongAgo: true, available: false)
        try await env.add(session: "S1")
        await env.sync.reconcile()
        #expect(!FileManager.default.fileExists(atPath: env.folder.path) && !env.sync.isAvailable)
    }

    @Test func theStoreSaveStillReachesAnEarlierListener() async throws {
        let env = try await FolderEnv(launchedLongAgo: true)
        var heard = 0
        let ours = env.store.onAdd
        env.store.onAdd = { v in ours?(v); heard += 1 }
        try await env.add(session: "S1")
        #expect(heard == 1)
        await env.sync.reconcile()
        #expect(env.visible.count == 1)
    }
}

// MARK: - Existing items and a change of folder

@MainActor
struct FolderBackfillTests {
    @Test func theFirstRunOffersWhatCobaltHoldsAndCopiesNothingOfIt() async throws {
        let env = try await FolderEnv(existing: 3)
        await env.sync.reconcile()
        #expect(env.visible.isEmpty, "what was already in cobalt is not copied behind the owner's back")
        #expect(env.sync.status.existing == 3 && env.sync.status.saved == 0 && env.sync.status.waiting == 0)
        await env.sync.includeExisting(false)
        #expect(env.visible.isEmpty && env.sync.status.existing == 3, "the offer stays until it is answered yes or the items go")
        await env.sync.includeExisting(true)
        #expect(env.visible.count == 3 && env.sync.status.saved == 3 && env.sync.status.existing == 0)
    }

    @Test func aSaveAfterLaunchIsCopiedEvenOnTheFirstRun() async throws {
        let env = try await FolderEnv(existing: 2)
        await env.sync.reconcile()
        try await env.add(session: "NEW", link: URL(string: "https://x.com/i/status/9")!)
        await env.sync.reconcile()
        #expect(env.visible == ["x · 9.mp4"] && env.sync.status.existing == 2)
    }

    @Test func evictedItemsAreNotCountedInTheOffer() async throws {
        let env = try await FolderEnv(existing: 3)
        let evicted = try #require(env.store.videos.first)
        _ = await env.store.evict(evicted.id)
        await env.sync.reconcile()
        #expect(env.sync.status.existing == 2)
        await env.sync.includeExisting(true)
        #expect(env.visible.count == 2)
        _ = try await env.store.attach(file: try makeTempFile("refill.mp4"), to: evicted.id, move: true)
        await env.sync.reconcile()
        #expect(env.visible.count == 2, "refilling an old video is not a new save")
    }

    @Test func changingTheFolderOffersWhatCobaltHoldsAndTheOldFolderIsLeftAlone() async throws {
        let env = try await FolderEnv(launchedLongAgo: true)
        try await env.add(session: "S1")
        try await env.add(session: "S2", link: URL(string: "https://x.com/i/status/6")!)
        await env.sync.reconcile()
        #expect(env.visible.count == 2)

        let chosen = env.root.appendingPathComponent("elsewhere", isDirectory: true)
        try FileManager.default.createDirectory(at: chosen, withIntermediateDirectories: true)
        let outcome = await env.sync.chooseFolder(chosen)
        #expect(outcome == .chosen(existing: 2))
        #expect(env.sync.status.isDefault == false && env.sync.status.path.hasSuffix("elsewhere"))
        let there = { ((try? FileManager.default.contentsOfDirectory(atPath: chosen.path)) ?? []).filter { !$0.hasPrefix(".") }.sorted() }
        #expect(there().isEmpty && env.visible.count == 2, "nothing is copied until the owner says so; the old folder keeps its files")

        try await env.add(session: "S3", link: URL(string: "https://x.com/i/status/7")!)
        await env.sync.reconcile()
        #expect(there() == ["x · 7.mp4"], "new saves go to the new folder")
        await env.sync.includeExisting(true)
        #expect(there().count == 3)

        // and back: the default folder's own list comes back, nothing is copied twice
        let back = await env.sync.resetToDefault()
        #expect(back == .chosen(existing: 0) || back == .chosen(existing: 1))
        #expect(env.sync.status.isDefault)
        await env.sync.includeExisting(true)
        let names = env.visible
        #expect(names.filter { $0.hasPrefix("x · 2105435404002562056") }.count == 1, "S1 is in the default folder once")
        #expect(names.contains("x · 6.mp4"))
    }

    @Test func theSameFolderChosenAgainChangesNothing() async throws {
        let env = try await FolderEnv(launchedLongAgo: true)
        try await env.add(session: "S1")
        await env.sync.reconcile()
        #expect(await env.sync.chooseFolder(env.folder) == .unchanged)
        #expect(await env.sync.resetToDefault() == .unchanged)
        #expect(await env.sync.chooseFolder(env.root.appendingPathComponent("nope", isDirectory: true)) == .failed, "not a folder")
    }

    @Test func aChosenFolderThatWentAwayIsReportedAndNeverMadeAgain() async throws {
        let env = try await FolderEnv(launchedLongAgo: true)
        let chosen = env.root.appendingPathComponent("usb", isDirectory: true)
        try FileManager.default.createDirectory(at: chosen, withIntermediateDirectories: true)
        _ = await env.sync.chooseFolder(chosen)
        try FileManager.default.removeItem(at: chosen)
        try await env.add(session: "S1")
        await env.sync.reconcile()
        #expect(env.sync.status.problem == .folderMissing && !FileManager.default.fileExists(atPath: chosen.path))
        #expect(env.sync.status.waiting == 1, "it waits for the folder to come back")
        try FileManager.default.createDirectory(at: chosen, withIntermediateDirectories: true)
        await env.sync.reconcile()
        #expect(env.sync.status.problem == nil && env.sync.status.saved == 1)
    }
}

// MARK: - Kill mid-copy

@MainActor
struct FolderKillTests {
    @Test func aCopyThatDiedBeforeTheRenameIsDoneAgainWithoutADuplicate() async throws {
        let env = try await FolderEnv(launchedLongAgo: true)
        let v = try await env.add(session: "S1")
        let id = FolderLedger.defaultID
        try FileManager.default.createDirectory(at: env.folder, withIntermediateDirectories: true)
        // the dead launch: claimed, planned a name, wrote half a part file, never renamed
        _ = env.ledger.claim(id, "s:S1", now: Date())
        env.ledger.recordPlan(id, "s:S1", file: "x · 2105435404002562056.mp4", bytes: 2_000)
        try Data(count: 700).write(to: env.folder.appendingPathComponent(".cobalt-deadbeef-12345678.part"))
        try markClaimAsFromAnotherLaunch(env.ledger)
        env.ledger.ensureSection(id, path: env.folder.path)
        await env.sync.reconcile()
        #expect(env.visible == ["x · 2105435404002562056.mp4"])
        #expect(env.listing.allSatisfy { !$0.hasSuffix(".part") }, "the stray part file of the dead launch is removed")
        #expect(try Data(contentsOf: env.folder.appendingPathComponent(env.visible[0])) == Data(contentsOf: v.fileURL!))
    }

    @Test func aCopyThatDiedAfterTheRenameIsFinishedNotRepeated() async throws {
        let env = try await FolderEnv(launchedLongAgo: true)
        let v = try await env.add(session: "S1")
        let id = FolderLedger.defaultID
        try FileManager.default.createDirectory(at: env.folder, withIntermediateDirectories: true)
        _ = env.ledger.claim(id, "s:S1", now: Date())
        env.ledger.recordPlan(id, "s:S1", file: "chosen name.mp4", bytes: 2_000)
        try FileManager.default.copyItem(at: v.fileURL!, to: env.folder.appendingPathComponent("chosen name.mp4"))
        try markClaimAsFromAnotherLaunch(env.ledger)
        env.ledger.ensureSection(id, path: env.folder.path)
        await env.sync.reconcile()
        #expect(env.visible == ["chosen name.mp4"], "the whole file was there: it is marked done, not copied a second time")
        #expect(env.ledger.entry(id, "s:S1")?.state == .done)
    }

    private func markClaimAsFromAnotherLaunch(_ ledger: FolderLedger) throws {
        var f = try JSONDecoder().decode(FolderStateFile.self, from: Data(contentsOf: ledger.url))
        for key in f.sections["default"]?.items.keys.map({ $0 }) ?? [] { f.sections["default"]?.items[key]?.by = "dead" }
        try JSONEncoder().encode(f).write(to: ledger.url)
    }
}
