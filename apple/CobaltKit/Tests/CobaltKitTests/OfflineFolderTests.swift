import Foundation
import Testing
@testable import CobaltKit

// CONTRACT-OFFLINE.md, wave 1: the two tiers, the visible folder, the identity tag, the eviction rules and the
// scan with decision 6's table. Every Files edit is a real file system operation in a temp dir.

@MainActor
private final class AddLog {
    var entries: [(id: String, origin: AddOrigin)] = []
}

// MARK: - the store

@MainActor
struct OfflineStoreTierTests {
    @Test func aKeptAddLandsInTheVisibleRootTaggedWithNoCacheFile() async throws {
        let rig = try OfflineRig()
        let store = rig.store()
        let v = try await rig.save(store, "clip", session: "S1", link: OfflineRig.instagram)

        #expect(v.place == .offline && v.keep && v.isOffline)
        #expect(rig.visibleFiles() == ["instagram · DeHC9jcpfQW.mp4"])
        let url = try #require(v.fileURL)
        #expect(url.resolvingSymlinksInPath().path == rig.url("instagram · DeHC9jcpfQW.mp4").resolvingSymlinksInPath().path)
        let tag = try #require(OfflineTag.read(at: url))
        #expect(tag.id == v.id && tag.media == v.mediaID && tag.kind == .original && tag.session == "S1")
        #expect(tag.link == OfflineRig.instagram.absoluteString)
        #expect(OfflineTag.read(at: url)?.encoded().count ?? 1_000 < OfflineTag.maxBytes)
        let record = try #require(rig.record(v.id))
        #expect(record.fileName == nil && record.visiblePath == "instagram · DeHC9jcpfQW.mp4" && record.keep == true)
        #expect(record.givenName == "instagram · DeHC9jcpfQW.mp4")
        #expect(rig.cacheFiles().isEmpty)
        rig.checkInvariants()
    }

    @Test func anUnkeptAddStaysInTheCacheAndTheVisibleFolderStaysEmpty() async throws {
        let rig = try OfflineRig()
        let store = rig.store()
        let v = try await rig.save(store, keep: false)
        #expect(v.place == .cache && !v.keep && !v.isOffline && v.fileURL != nil)
        #expect(rig.visibleFiles().isEmpty && rig.cacheFiles().count == 1)
        #expect(rig.record(v.id)?.keep == false)
    }

    @Test func withoutAVisibleRootAKeptFileWaitsInTheCacheFolderAndReloadPromotesIt() async throws {
        let rig = try OfflineRig()
        let extensionStore = rig.store(visible: false)
        let v = try await rig.save(extensionStore, "clip", session: "S1", link: OfflineRig.instagram)
        #expect(v.place == .cache && v.keep && v.isOffline, "kept, waiting")
        #expect(rig.visibleFiles().isEmpty && rig.cacheFiles().count == 1)
        #expect(rig.record(v.id)?.fileName != nil)

        let app = rig.store()
        await app.reload()
        let moved = try #require(app.videos.first { $0.id == v.id })
        #expect(moved.place == .offline && moved.isOffline)
        #expect(rig.visibleFiles() == ["instagram · DeHC9jcpfQW.mp4"] && rig.cacheFiles().isEmpty)
        #expect(OfflineTag.read(at: rig.url("instagram · DeHC9jcpfQW.mp4"))?.id == v.id)
        rig.checkInvariants()
    }

    @Test func theExtensionNeverTouchesTheVisiblePathAndSeesNoFileURL() async throws {
        let rig = try OfflineRig()
        let app = rig.store()
        let v = try await rig.save(app, "clip", session: "S1", link: OfflineRig.instagram)
        let before = rig.record(v.id)
        let extensionStore = rig.store(visible: false)
        await extensionStore.reload()
        let seen = try #require(extensionStore.videos.first { $0.id == v.id })
        #expect(seen.fileURL == nil && seen.place == .offline && seen.isOffline)
        #expect(rig.record(v.id) == before, "reconciled() leaves visiblePath to the app's scan")
        #expect(extensionStore.offlineUsage.offline.count == 1)
        #expect(await extensionStore.removeOfflineCopy(v.id) == false, "an extension cannot delete the app's file")
        #expect(rig.visibleFiles().count == 1)
    }

    @Test func promotionSkipsRecordsInUseAndRecordsOfAHeldSession() async throws {
        let rig = try OfflineRig()
        let extensionStore = rig.store(visible: false)
        let inUse = try await rig.save(extensionStore, "a", session: "S1")
        let held = try await rig.save(extensionStore, "b", session: "S2")
        let free = try await rig.save(extensionStore, "c", session: "S3")

        let app = rig.store()
        app.sessionIsHeld = { $0 == "S2" }
        app.pin(inUse.id)                                        // the store read the index when it opened
        await app.reload()
        func place(_ id: String) -> StoredVideo.Place? { app.videos.first { $0.id == id }?.place }
        #expect(place(free.id) == .offline)
        #expect(place(inUse.id) == .cache && place(held.id) == .cache, "both wait")

        app.unpin(inUse.id)
        await app.reload()
        #expect(place(inUse.id) == .offline && place(held.id) == .cache, "the held session still waits")
        app.sessionIsHeld = nil
        await app.reload()
        #expect(place(held.id) == .offline)
        rig.checkInvariants()
    }

    @Test func setKeepFlagsMovesAndReportsWhatNeedsADownload() async throws {
        let rig = try OfflineRig()
        let store = rig.store()
        let cached = try await rig.save(store, "cached", keep: false)
        let evicted = try await rig.save(store, "evicted", keep: false)
        #expect(await store.removeOfflineCopy(evicted.id))

        let needs = await store.setKeep(true, ids: [cached.id, evicted.id, "nope"])
        #expect(needs == [evicted.id], "no file at all: the caller downloads it")
        let moved = try #require(store.videos.first { $0.id == cached.id })
        #expect(moved.place == .offline && moved.isOffline)
        let wanted = try #require(store.videos.first { $0.id == evicted.id })
        #expect(wanted.keep && wanted.place == nil && !wanted.isOffline, "kept, nothing here yet")
        rig.checkInvariants()

        // and back: a record with a file is a removeOfflineCopy, one without only clears the wish
        _ = await store.setKeep(false, ids: [cached.id, evicted.id])
        #expect(store.videos.allSatisfy { !$0.keep && $0.place == nil })
        #expect(rig.visibleFiles().isEmpty)
        rig.checkInvariants()
    }

    @Test func removeOfflineCopyDeletesTheFileKeepsRecordAndPosterAndRefusesWhileInUse() async throws {
        let rig = try OfflineRig()
        let store = rig.store()
        let v = try await rig.save(store, session: "S1", link: OfflineRig.instagram)
        store.pin(v.id)
        #expect(await store.removeOfflineCopy(v.id) == false)
        #expect(rig.visibleFiles().count == 1)
        store.unpin(v.id)

        #expect(await store.removeOfflineCopy(v.id))
        #expect(rig.visibleFiles().isEmpty, "removeItem, not the trash")
        #expect(!FileManager.default.fileExists(atPath: rig.visible.appendingPathComponent(".Trash").path))
        let after = try #require(store.videos.first { $0.id == v.id })
        #expect(after.place == nil && !after.keep && after.posterURL.map { FileManager.default.fileExists(atPath: $0.path) } == true)
        #expect(await store.removeOfflineCopy(v.id) == false, "nothing left to remove")
        #expect(await store.evict("unknown") == false)
        // evict(_:) is the same call
        let w = try await rig.save(store, "w")
        #expect(await store.evict(w.id) && rig.visibleFiles().isEmpty)
    }

    @Test func clearCacheDropsOnlyCacheFilesAndKeepsEveryRecordPosterAndKeptFile() async throws {
        let rig = try OfflineRig()
        let store = rig.store()
        let kept = try await rig.save(store, "kept")
        let waiting = try await rig.save(rig.store(visible: false), "waiting")                // kept, still in files/
        let cached = try await rig.save(store, "cached", keep: false)
        await store.reload()                                                                  // promotes `waiting`
        let cached2 = try await rig.save(store, "cached2", keep: false)

        await store.clearCache()
        #expect(store.videos.count == 4)
        #expect(store.videos.first { $0.id == kept.id }?.place == .offline)
        #expect(store.videos.first { $0.id == waiting.id }?.place == .offline)
        #expect(store.videos.first { $0.id == cached.id }?.place == nil)
        #expect(store.videos.first { $0.id == cached2.id }?.place == nil)
        #expect(store.videos.allSatisfy { $0.posterURL.map { FileManager.default.fileExists(atPath: $0.path) } == true })
        #expect(rig.visibleFiles().count == 2 && rig.cacheFiles().isEmpty)
        rig.checkInvariants()
    }

    @Test func removingAMediaOrEverythingAlsoRemovesTheVisibleFiles() async throws {
        let rig = try OfflineRig()
        let store = rig.store()
        let a = try await rig.save(store, "a", session: "S1")
        let b = try await rig.save(store, "b", session: "S2")
        #expect(rig.visibleFiles().count == 2)
        #expect(await store.removeMedia(a.mediaID))
        #expect(rig.visibleFiles().count == 1 && store.videos.map(\.id) == [b.id])
        // a tag with no record would be rebuilt by the scan: none is left
        #expect((await store.scanVisibleRoot()).rebuilt == 0)
        await store.remove(b.id)
        #expect(rig.visibleFiles().isEmpty)
        let c = try await rig.save(store, "c")
        _ = c
        await store.clearAll()
        #expect(rig.visibleFiles().isEmpty && store.videos.isEmpty && rig.index().isEmpty)
    }

    @Test func aMediaInUseIsNotRemovedAndItsVisibleFileStays() async throws {
        let rig = try OfflineRig()
        let store = rig.store()
        let a = try await rig.save(store, "a", session: "S1")
        store.pin(a.id)
        #expect(await store.removeMedia(a.mediaID) == false)
        #expect(rig.visibleFiles().count == 1 && store.videos.count == 1)
    }

    @Test func aRecordAddedTwiceForOneSessionMergesAndTheKeptFlagIsNeverLost() async throws {
        let rig = try OfflineRig()
        let store = rig.store()
        let first = try await rig.save(store, "a", session: "S1", keep: false)
        let second = try await rig.save(store, "a", session: "S1", keep: true)
        #expect(second.id == first.id && store.videos.count == 1)
        #expect(second.isOffline && second.place == .offline, "the duplicate's wish moved the file in")
        #expect(rig.visibleFiles().count == 1 && rig.cacheFiles().isEmpty)
        let third = try await rig.save(store, "a", session: "S1", keep: false)
        #expect(third.id == first.id && third.isOffline, "a later unkept duplicate does not un-keep")
        #expect(rig.visibleFiles().count == 1 && rig.cacheFiles().isEmpty)
        rig.checkInvariants()
    }

    @Test func attachRefillsAnEvictedRecordKeptOrCachedAndNeverReplacesAKeptFile() async throws {
        let rig = try OfflineRig()
        let store = rig.store()
        let v = try await rig.save(store, "a", session: "S1")
        #expect(await store.removeOfflineCopy(v.id))
        let cacheRefill = try await store.attach(file: try makeTempFile("x.mp4", bytes: 700), to: v.id, move: true, keep: false)
        #expect(cacheRefill.place == .cache && !cacheRefill.keep)
        #expect(await store.removeOfflineCopy(v.id))

        let log = AddLog()
        store.onAdd = { video, origin in log.entries.append((video.id, origin)) }
        let kept = try await store.attach(
            file: try makeTempFile("y.mp4", bytes: 800), to: v.id, move: true, keep: true, origin: .keepOffline)
        #expect(kept.place == .offline && kept.isOffline && kept.bytes == 800)
        #expect(log.entries.map(\.origin) == [.keepOffline])
        let again = try await store.attach(file: try makeTempFile("z.mp4", bytes: 900), to: v.id, move: true, keep: false)
        #expect(again.place == .offline && again.bytes == 800, "a kept file is never replaced")
        #expect(rig.visibleFiles().count == 1 && rig.cacheFiles().isEmpty)
    }

    @Test func invariantsHoldAfterEveryCallOfARandomSequence() async throws {
        let rig = try OfflineRig()
        let app = rig.store()
        let ext = rig.store(visible: false)
        var seed: UInt64 = 0xC0BA17
        func next(_ n: Int) -> Int {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Int((seed >> 33) % UInt64(n))
        }
        var sessions = 0
        for step in 0..<140 {
            await app.reload()
            let ids = rig.index().map(\.id)
            func pick() -> String? { ids.isEmpty ? nil : ids[next(ids.count)] }
            switch next(11) {
            case 0, 1: sessions += 1; try await rig.save(app, "a\(step)", session: "S\(sessions)", keep: next(2) == 0)
            case 2: sessions += 1; try await rig.save(ext, "e\(step)", session: "S\(sessions)", keep: true)
            case 3: if let id = pick() { await app.setKeep(true, ids: [id]) }
            case 4: if let id = pick() { await app.setKeep(false, ids: [id]) }
            case 5: if let id = pick() { await app.removeOfflineCopy(id) }
            case 6: if let id = pick() { await app.remove(id) }
            case 7: await app.clearCache()
            case 8: await app.scanVisibleRoot()
            case 9: await ext.reload()
            default: if let id = pick() { await app.evict(id) }
            }
            rig.checkInvariants("after step \(step)")
        }
        await app.reload()
        rig.checkInvariants("end")
    }
}

// MARK: - the storage limit

@MainActor
struct OfflineLimitTests {
    @Test func keptFilesAreNeverEvictedHoweverFarOverTheLimit() async throws {
        let rig = try OfflineRig(limit: 100)
        let app = rig.store()
        let ext = rig.store(visible: false)
        var kept: [StoredVideo] = []
        for i in 0..<20 { kept.append(try await rig.save(i % 2 == 0 ? app : ext, "k\(i)", bytes: 1_000, session: "K\(i)")) }
        for i in 0..<20 { try await rig.save(app, "c\(i)", bytes: 1_000, keep: false) }
        await app.reload()
        await app.setLimit(100)
        await app.reload()
        for k in kept {
            let now = try #require(app.videos.first { $0.id == k.id })
            #expect(now.isOffline && now.place != nil, "kept file \(k.name) survived phase 1")
        }
        #expect(app.videos.filter { !$0.keep && $0.place == .cache }.count < 20, "the cache, unlike kept files, was cut")
        rig.checkInvariants()
    }

    @Test func aMediaWithKeptFilesIsNeverDroppedInThePosterAndRecordPass() async throws {
        // the bug the contract pins: phase 2 drops media whose records all have fileName == nil, which is true
        // of every kept media once its file lives in the visible folder
        let rig = try OfflineRig(limit: 1_000)
        let store = rig.store(posterBytes: 400)
        var kept: [StoredVideo] = []
        for i in 0..<15 { kept.append(try await rig.save(store, "k\(i)", bytes: 100, session: "K\(i)")) }
        for i in 0..<20 { try await rig.save(store, "c\(i)", bytes: 100, keep: false) }
        await store.reload()

        for k in kept {
            let now = try #require(store.videos.first { $0.id == k.id }, "the record of \(k.name) is still there")
            #expect(now.isOffline && now.fileURL.map { FileManager.default.fileExists(atPath: $0.path) } == true)
            #expect(now.posterURL.map { FileManager.default.fileExists(atPath: $0.path) } == true, "and its poster")
        }
        #expect(store.videos.count == 15 + 12, "the cache media past the newest twelve were dropped, no kept one")
        rig.checkInvariants()
    }

    @Test func aMediaWithOneKeptRenditionLosesNeitherRecordWhenTheOtherIsEvicted() async throws {
        let rig = try OfflineRig(limit: 1)
        let store = rig.store(posterBytes: 400)
        let original = try await rig.save(store, "m", bytes: 100, session: "M", keep: false)
        let webp = try await rig.save(
            store, "m", bytes: 100, kind: .webp, session: "M", remote: URL(string: "https://media.example/w.webp"),
            keep: true, mediaID: original.mediaID)
        for i in 0..<14 { try await rig.save(store, "c\(i)", bytes: 100, keep: false) }
        await store.reload()

        let o = try #require(store.videos.first { $0.id == original.id }, "the media's other record stays with it")
        let w = try #require(store.videos.first { $0.id == webp.id })
        #expect(o.place == nil && o.posterURL != nil, "the cache original went, record and poster stay")
        #expect(w.isOffline && w.fileURL.map { FileManager.default.fileExists(atPath: $0.path) } == true)
        #expect(store.media.contains { $0.id == original.mediaID })
    }

    @Test func bytesToFreeCountsTheCacheOnly() async throws {
        let rig = try OfflineRig()
        let store = rig.store(posterBytes: 0)
        for i in 0..<3 { try await rig.save(store, "k\(i)", bytes: 10_000) }                 // 30 000 kept
        for i in 0..<14 { try await rig.save(store, "c\(i)", bytes: 100, keep: false) }       // 1 400 cache
        let usage = store.offlineUsage
        #expect(usage.offline.bytes == 30_000 && usage.offline.count == 3)
        #expect(usage.cache.bytes == 1_400 && usage.cache.count == 14)
        #expect(store.usage.bytes == 31_400, "usage keeps its total meaning")
        // the two oldest cache files are outside the newest twelve: 200 bytes are all the limit can free
        #expect(store.bytesToFree(for: 1_000) == 200)
        #expect(store.bytesToFree(for: 100) == 200)
        #expect(store.bytesToFree(for: nil) == 0)
        #expect(store.bytesToFree(for: 100_000) == 0, "kept bytes are not the cache's to count")
    }

    @Test func offlineUsageMatchesTheBytesOnDiskAfterAScan() async throws {
        let rig = try OfflineRig()
        let app = rig.store(posterBytes: 0)
        let ext = rig.store(visible: false, posterBytes: 0)
        try await rig.save(app, "a", bytes: 4_000, session: "A")
        try await rig.save(ext, "b", bytes: 3_000, session: "B")                              // kept, waiting
        try await rig.save(app, "c", bytes: 500, keep: false)
        try await rig.save(app, "d", bytes: 2_000, kind: .webp, remote: URL(string: "https://media.example/d.webp"))
        await app.reload()
        _ = await app.scanVisibleRoot()
        let usage = app.offlineUsage
        #expect(usage.offline.bytes == rig.bytesOnDisk(rig.visible) + rig.bytesOnDisk(rig.hidden.appendingPathComponent("files")) - 500)
        #expect(usage.cache.bytes == 500)
        #expect(usage.offline.bytes + usage.cache.bytes == rig.bytesOnDisk(rig.visible) + rig.bytesOnDisk(rig.hidden.appendingPathComponent("files")))
    }

    @Test func twoStoreInstancesAddingConcurrentlyKeepTheInvariants() async throws {
        let rig = try OfflineRig()
        let app = rig.store()
        let ext = rig.store(visible: false)
        async let a: Void = {
            for i in 0..<8 { try await rig.save(app, "a\(i)", session: "A\(i)", keep: i % 2 == 0) }
        }()
        async let b: Void = {
            for i in 0..<8 { try await rig.save(ext, "b\(i)", session: "B\(i)", keep: true) }
        }()
        _ = try await (a, b)
        await app.reload()
        #expect(app.videos.count == 16 && rig.index().count == 16)
        rig.checkInvariants()
        #expect(app.videos.filter(\.isOffline).count == 12)
        #expect(app.videos.filter { $0.isOffline && $0.place == .cache }.isEmpty, "the extension's kept files moved in")
        #expect(Set(rig.visibleFiles()).count == 12)
    }
}

// MARK: - the scan: one test per row of decision 6's table

@MainActor
struct OfflineScanTests {
    private func kept(_ rig: OfflineRig, _ store: OfflineStore, _ name: String = "clip") async throws -> (StoredVideo, String) {
        let v = try await rig.save(store, name, session: "S-\(name)", link: OfflineRig.instagram)
        return (v, try #require(rig.record(v.id)?.visiblePath))
    }

    @Test func aDeletedFileIsNotOfflineAnymoreButKeepsItsRecordAndPosterAndIsNeverRestoredByTheScan() async throws {
        let rig = try OfflineRig()
        let store = rig.store()
        let (v, path) = try await kept(rig, store)
        try FileManager.default.removeItem(at: rig.url(path))

        let report = await store.scanVisibleRoot()
        #expect(report == OfflineScanReport(unkept: 1))
        let after = try #require(store.videos.first { $0.id == v.id })
        #expect(after.place == nil && !after.keep && !after.isOffline)
        #expect(after.posterURL.map { FileManager.default.fileExists(atPath: $0.path) } == true)
        #expect(rig.record(v.id)?.visiblePath == nil)
        #expect(await store.scanVisibleRoot() == OfflineScanReport(), "settled: a second scan finds nothing")
        rig.checkInvariants()
    }

    @Test func aFileRestoredFromTheTrashIsAdoptedAgain() async throws {
        let rig = try OfflineRig()
        let store = rig.store()
        let (v, path) = try await kept(rig, store)
        let trash = rig.visible.appendingPathComponent(".Trash", isDirectory: true)
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: rig.url(path), to: trash.appendingPathComponent(path))
        #expect(await store.scanVisibleRoot().unkept == 1, ".Trash is never read as kept")

        try FileManager.default.moveItem(at: trash.appendingPathComponent(path), to: rig.url("restored.mp4"))
        let report = await store.scanVisibleRoot()
        #expect(report.adopted == 1 && report.unkept == 0)
        let back = try #require(store.videos.first { $0.id == v.id })
        #expect(back.isOffline && back.place == .offline)
        #expect(rig.record(v.id)?.visiblePath == "restored.mp4")
    }

    @Test func aRenamedFileIsFollowedAndTheTitleIsNotTouched() async throws {
        let rig = try OfflineRig()
        let store = rig.store()
        let (v, path) = try await kept(rig, store)
        let titleBefore = store.media(containing: v.id)?.title
        try FileManager.default.moveItem(at: rig.url(path), to: rig.url("my own name.mp4"))

        #expect(await store.scanVisibleRoot() == OfflineScanReport(followed: 1))
        #expect(rig.record(v.id)?.visiblePath == "my own name.mp4" && rig.record(v.id)?.keep == true)
        #expect(store.media(containing: v.id)?.title == titleBefore && store.videos.first?.title == nil)
        #expect(store.videos.first?.fileURL?.lastPathComponent == "my own name.mp4")
    }

    @Test func aFileMovedIntoASubfolderIsFollowed() async throws {
        let rig = try OfflineRig()
        let store = rig.store()
        let (v, path) = try await kept(rig, store)
        try FileManager.default.createDirectory(at: rig.url("trips/2026"), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: rig.url(path), to: rig.url("trips/2026/\(path)"))

        #expect(await store.scanVisibleRoot().followed == 1)
        #expect(rig.record(v.id)?.visiblePath == "trips/2026/\(path)")
        let url = try #require(store.videos.first { $0.id == v.id }?.fileURL)
        #expect(FileManager.default.fileExists(atPath: url.path))
        #expect(OfflineTag.read(at: url)?.id == v.id, "the tag survived the move")
    }

    @Test func theTagSurvivesRenamesAndMovesThatFilesMakes() async throws {
        let rig = try OfflineRig()
        let store = rig.store()
        let (v, path) = try await kept(rig, store)
        let original = try #require(OfflineTag.read(at: rig.url(path)))
        let fm = FileManager.default
        try fm.moveItem(at: rig.url(path), to: rig.url("one.mp4"))
        try fm.createDirectory(at: rig.url("a/b"), withIntermediateDirectories: true)
        try fm.moveItem(at: rig.url("one.mp4"), to: rig.url("a/b/two.mp4"))
        try fm.moveItem(at: rig.url("a/b/two.mp4"), to: rig.url("three.mp4"))
        #expect(OfflineTag.read(at: rig.url("three.mp4")) == original && original.id == v.id)
    }

    @Test func aDuplicateKeepsTheRecordedPathAndIsAdoptedLaterIfTheOriginalGoes() async throws {
        let rig = try OfflineRig()
        let store = rig.store()
        let (v, path) = try await kept(rig, store)
        try FileManager.default.copyItem(at: rig.url(path), to: rig.url("copy of it.mp4"))
        #expect(OfflineTag.read(at: rig.url("copy of it.mp4"))?.id == v.id, "a Files duplicate carries the tag")

        #expect(await store.scanVisibleRoot() == OfflineScanReport(), "the recorded path wins, the copy is left alone")
        #expect(rig.record(v.id)?.visiblePath == path)
        #expect(rig.visibleFiles().count == 2)

        try FileManager.default.removeItem(at: rig.url(path))
        let report = await store.scanVisibleRoot()
        #expect(report.unkept == 0 && report.followed + report.adopted == 1)
        #expect(rig.record(v.id)?.visiblePath == "copy of it.mp4" && store.videos.first { $0.id == v.id }?.isOffline == true)
    }

    @Test func aFileMovedOutOfTheFolderIsADelete() async throws {
        let rig = try OfflineRig()
        let store = rig.store()
        let (v, path) = try await kept(rig, store)
        let elsewhere = try makeTempDirectory().appendingPathComponent("moved.mp4")
        try FileManager.default.moveItem(at: rig.url(path), to: elsewhere)
        #expect(await store.scanVisibleRoot().unkept == 1)
        #expect(store.videos.first { $0.id == v.id }?.isOffline == false)
    }

    @Test func anEditInPlaceUpdatesTheBytes() async throws {
        let rig = try OfflineRig()
        let store = rig.store()
        let (v, path) = try await kept(rig, store)
        let handle = try FileHandle(forWritingTo: rig.url(path))
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(repeating: 1, count: 234))
        try handle.close()
        let report = await store.scanVisibleRoot()
        #expect(report.followed == 0 && report.unkept == 0)
        #expect(rig.record(v.id)?.bytes == 1_234 && store.videos.first { $0.id == v.id }?.bytes == 1_234)
        #expect(store.offlineUsage.offline.bytes == 1_234)
    }

    @Test func anUntaggedFileIsLeftAloneNeverShownMovedOrDeleted() async throws {
        let rig = try OfflineRig()
        let store = rig.store()
        let (_, path) = try await kept(rig, store)
        let mine = rig.url("holiday.mov")
        try Data(repeating: 5, count: 321).write(to: mine)
        try FileManager.default.createDirectory(at: rig.url("my stuff"), withIntermediateDirectories: true)
        try Data(repeating: 6, count: 99).write(to: rig.url("my stuff/notes.txt"))

        let report = await store.scanVisibleRoot()
        #expect(report == OfflineScanReport(untracked: 2))
        #expect(store.videos.count == 1)
        #expect(try Data(contentsOf: mine).count == 321 && FileManager.default.fileExists(atPath: rig.url("my stuff/notes.txt").path))
        #expect(rig.record(store.videos[0].id)?.visiblePath == path)
        await store.reload()
        #expect(try Data(contentsOf: mine).count == 321, "a reload does not touch it either")
    }

    @Test func aFileReplacedByAnotherOfTheSameNameIsTheOwnersAndTheRecordIsNotOffline() async throws {
        let rig = try OfflineRig()
        let store = rig.store()
        let (v, path) = try await kept(rig, store)
        try FileManager.default.removeItem(at: rig.url(path))
        try Data(repeating: 3, count: 77).write(to: rig.url(path))

        let report = await store.scanVisibleRoot()
        #expect(report.unkept == 1 && report.untracked == 1)
        #expect(store.videos.first { $0.id == v.id }?.isOffline == false)
        #expect(try Data(contentsOf: rig.url(path)).count == 77, "the new file is the owner's")
    }

    @Test func aLostIndexIsRebuiltFromTheTagsAsAdoptedRecords() async throws {
        let rig = try OfflineRig()
        let store = rig.store()
        let original = try await rig.save(store, "orig", session: "S1", link: OfflineRig.instagram)
        let webp = try await rig.save(
            store, "orig", kind: .webp, session: "S1", link: OfflineRig.instagram,
            remote: URL(string: "https://media.example/w.webp"), mediaID: original.mediaID)
        try FileManager.default.removeItem(at: OfflineStore.indexURL(root: rig.hidden))     // lost, or rolled back

        let fresh = rig.store()
        #expect(fresh.videos.isEmpty)
        let log = AddLog()
        fresh.onAdd = { video, origin in log.entries.append((video.id, origin)) }
        let report = await fresh.scanVisibleRoot()
        #expect(report.rebuilt == 2)
        #expect(Set(log.entries.map(\.id)) == [original.id, webp.id] && log.entries.allSatisfy { $0.origin == .adopted })
        let o = try #require(fresh.videos.first { $0.id == original.id })
        let w = try #require(fresh.videos.first { $0.id == webp.id })
        #expect(o.isOffline && o.place == .offline && o.sessionID == "S1" && o.link == OfflineRig.instagram)
        #expect(w.kind == .webp && w.remoteURL == URL(string: "https://media.example/w.webp") && w.isOffline)
        #expect(o.mediaID == w.mediaID, "the media is rebuilt as one")
        #expect(o.posterURL.map { FileManager.default.fileExists(atPath: $0.path) } == true, "the poster file was still on disk")
        rig.checkInvariants()
        #expect(await fresh.scanVisibleRoot() == OfflineScanReport())
    }

    @Test func aMissingRootChangesNothingAtAll() async throws {
        let rig = try OfflineRig()
        let store = rig.store()
        let (v, path) = try await kept(rig, store)
        let before = rig.index()
        let away = rig.base.appendingPathComponent("unplugged")
        try FileManager.default.moveItem(at: rig.visible, to: away)

        let report = await store.scanVisibleRoot()
        #expect(report.rootMissing && report.unkept == 0)
        #expect(rig.index() == before && store.videos.first { $0.id == v.id }?.isOffline == true)

        try FileManager.default.moveItem(at: away, to: rig.visible)
        #expect(await store.scanVisibleRoot() == OfflineScanReport(), "plugged back in: nothing was lost")
        #expect(FileManager.default.fileExists(atPath: rig.url(path).path))
    }

    @Test func partFilesAndHiddenEntriesAreIgnoredAndStalePartsAreSwept() async throws {
        let rig = try OfflineRig()
        let store = rig.store()
        let (v, _) = try await kept(rig, store)
        let tag = OfflineTag(id: "ghost", media: "ghost", kind: .original, created: 1)
        let fresh = rig.visible.appendingPathComponent(".cobalt-ghost.part")
        let stale = rig.visible.appendingPathComponent(".cobalt-old.part")
        let hidden = rig.visible.appendingPathComponent(".hidden.mp4")
        for url in [fresh, stale, hidden] {
            try Data(repeating: 1, count: 10).write(to: url)
            try SystemFileOps().setTag(tag, at: url)
        }
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-2 * 3_600)], ofItemAtPath: stale.path)

        #expect(await store.scanVisibleRoot() == OfflineScanReport())
        #expect(store.videos.map(\.id) == [v.id], "nothing was rebuilt from them")
        #expect(FileManager.default.fileExists(atPath: fresh.path) && FileManager.default.fileExists(atPath: hidden.path))
        #expect(!FileManager.default.fileExists(atPath: stale.path), "a part older than an hour is a dead copy")
    }

    @Test func afterAnOlderBuildOverwritesTheIndexTheScanReattachesEverythingById() async throws {
        let rig = try OfflineRig()
        let store = rig.store()
        let a = try await rig.save(store, "a", session: "A", link: OfflineRig.instagram)
        let b = try await rig.save(store, "b", kind: .webp, remote: URL(string: "https://media.example/b.webp"), mediaID: a.mediaID)
        let c = try await rig.save(store, "c", keep: false)
        let namesBefore = rig.visibleFiles()

        // an older build rewrites index.json: it knows neither keep, visiblePath nor givenName
        let url = OfflineStore.indexURL(root: rig.hidden)
        var json = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [[String: Any]])
        for i in json.indices { for key in ["keep", "visiblePath", "givenName"] { json[i].removeValue(forKey: key) } }
        try JSONSerialization.data(withJSONObject: json).write(to: url)

        let upgraded = rig.store()
        let ids = Set([a.id, b.id])
        #expect(upgraded.videos.filter { ids.contains($0.id) }.allSatisfy { $0.place == nil }, "it sees evicted records")
        await upgraded.reload()
        for id in ids {
            let v = try #require(upgraded.videos.first { $0.id == id })
            #expect(v.isOffline && v.place == .offline)
        }
        #expect(rig.visibleFiles().filter(namesBefore.contains) == namesBefore, "nothing moved or duplicated")
        #expect(rig.visibleFiles().count == namesBefore.count + 1, "the one cache file is a legacy record to the new build: it migrates")
        #expect(upgraded.videos.first { $0.id == c.id }?.isOffline == true)
        rig.checkInvariants()
    }

    @Test func theWatcherRescansWhenTheRootChangesWhileCobaltIsInFront() async throws {
        let rig = try OfflineRig()
        let store = rig.store()
        let (v, path) = try await kept(rig, store)
        store.startWatching()
        defer { store.stopWatching() }
        try FileManager.default.removeItem(at: rig.url(path))
        for _ in 0..<60 {
            if store.videos.first(where: { $0.id == v.id })?.isOffline == false { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(store.videos.first { $0.id == v.id }?.isOffline == false)
    }
}

// MARK: - names follow the media's title (decision 8)

@MainActor
struct OfflineRenameFollowTests {
    @Test func anUntouchedFileFollowsTheTitleAndARenamedOneNeverDoes() async throws {
        let rig = try OfflineRig()
        let store = rig.store()
        let original = try await rig.save(store, "clip", session: "S1", link: OfflineRig.instagram)
        let webp = try await rig.save(
            store, "clip", kind: .webp, session: "S1", link: OfflineRig.instagram,
            remote: URL(string: "https://media.example/w.webp"), mediaID: original.mediaID)
        #expect(rig.visibleFiles() == ["instagram · DeHC9jcpfQW · webp 1.webp", "instagram · DeHC9jcpfQW.mp4"])

        await store.setTitle("my dog", media: original.mediaID)
        #expect(rig.visibleFiles() == ["my dog · webp 1.webp", "my dog.mp4"])
        #expect(rig.record(original.id)?.givenName == "my dog.mp4" && rig.record(webp.id)?.givenName == "my dog · webp 1.webp")
        #expect(OfflineTag.read(at: rig.url("my dog.mp4"))?.id == original.id)

        // the owner renames the video in Files; the webp keeps following
        try FileManager.default.moveItem(at: rig.url("my dog.mp4"), to: rig.url("dog, the film.mp4"))
        _ = await store.scanVisibleRoot()
        await store.setTitle("my cat", media: original.mediaID)
        #expect(rig.visibleFiles() == ["dog, the film.mp4", "my cat · webp 1.webp"])
        #expect(rig.record(original.id)?.visiblePath == "dog, the film.mp4")
        rig.checkInvariants()
    }

    @Test func aClashGetsATwoAndNeverOverwritesTheOwnersFile() async throws {
        let rig = try OfflineRig()
        let store = rig.store()
        let v = try await rig.save(store, "clip", session: "S1", link: OfflineRig.instagram)
        try Data(repeating: 4, count: 12).write(to: rig.url("Second.mp4"))                // case differs: still a clash
        await store.setTitle("second", media: v.mediaID)
        #expect(rig.visibleFiles() == ["Second.mp4", "second (2).mp4"])
        #expect(try Data(contentsOf: rig.url("Second.mp4")).count == 12)
    }

    @Test func aFileInASubfolderFollowsInsideItsFolder() async throws {
        let rig = try OfflineRig()
        let store = rig.store()
        let v = try await rig.save(store, "clip", session: "S1", link: OfflineRig.instagram)
        let name = try #require(rig.record(v.id)?.visiblePath)
        try FileManager.default.createDirectory(at: rig.url("trips"), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: rig.url(name), to: rig.url("trips/\(name)"))
        _ = await store.scanVisibleRoot()
        await store.setTitle("rome", media: v.mediaID)
        #expect(rig.visibleFiles() == ["trips/rome.mp4"])
        #expect(rig.record(v.id)?.visiblePath == "trips/rome.mp4" && rig.record(v.id)?.givenName == "rome.mp4")
    }

    @Test func clearingTheTitleGoesBackToTheDefaultName() async throws {
        let rig = try OfflineRig()
        let store = rig.store()
        let v = try await rig.save(store, "clip", session: "S1", link: OfflineRig.instagram)
        await store.setTitle("rome", media: v.mediaID)
        await store.setTitle(nil, media: v.mediaID)
        #expect(rig.visibleFiles() == ["instagram · DeHC9jcpfQW.mp4"])
    }
}

// MARK: - the photos album default (owner, 2026-10-06)

@MainActor
struct PhotosAlbumDefaultTests {
    private func settings(_ defaults: UserDefaults? = nil) -> (Settings, UserDefaults) {
        let suite = "cobalt.album.default.\(UUID().uuidString)"
        let d = defaults ?? UserDefaults(suiteName: suite)!
        if defaults == nil { d.removePersistentDomain(forName: suite) }
        return (Settings(defaults: d, keychain: .memory()), d)
    }

    @Test func aFreshInstallHasTheAlbumOffAndEverythingElseUnchanged() {
        let (s, _) = settings()
        #expect(s.photosAlbumSync == false)
        #expect(s.keepVideosOnDevice == true, "new saves are kept offline by default")
        #expect(s.photosSyncWebps == true)
    }

    @Test func anInstallThatNeverTouchedTheToggleHadItOnByDefaultAndNowReadsOff() {
        // the old default was "no stored value reads on": that install has no stored value
        let (s, d) = settings()
        #expect(d.object(forKey: "photosAlbumSync") == nil)
        #expect(s.photosAlbumSync == false)
    }

    @Test func anExplicitOnStaysOnAndAnExplicitOffStaysOff() {
        let (s, d) = settings()
        s.photosAlbumSync = true                                  // what PhotosSync.enable() stores: the owner's tap
        #expect(d.object(forKey: "photosAlbumSync") as? Bool == true)
        #expect(Settings(defaults: d, keychain: .memory()).photosAlbumSync == true, "another process (the extension) reads the same")
        s.photosAlbumSync = false
        #expect(Settings(defaults: d, keychain: .memory()).photosAlbumSync == false)
    }

    @Test func theKeyIsStillASettingSoItCanBeSwitchedBackOn() {
        let (s, d) = settings()
        #expect(s.photosAlbumSync == false)
        s.photosAlbumSync = true
        #expect(s.photosAlbumSync && d.bool(forKey: "photosAlbumSync"))
    }
}
