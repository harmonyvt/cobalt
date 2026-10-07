import Foundation
import Testing
@testable import CobaltKit

// The data-safety review of wave M (commits 71691c5d6 + ed3732e6e) proved each of these with a throwaway test; this is that proof
// kept as a regression test (CONTRACT-OFFLINE.md 13.7, 13.8, 13.5, 13.2). Every test runs on temp directories and a scripted
// library: nothing here names the real home folder.

private let wmGalleryLink = URL(string: "https://www.instagram.com/p/DeKlsGCGZmx/")!

@MainActor
@Suite(.serialized)
struct WaveMFixTests {

    // MARK: B1. crops accumulate (the server replaces exports only): a pulled crop never trashes another crop

    @Test func twoCropsMadeOnThePhoneBothLandOnTheMac() async throws {
        let t = try PullRig()
        await t.check()                                                   // baseline
        let items = (0..<2).map { t.file("I\($0)", name: "0\($0 + 1).jpg", type: "image/jpeg", at: -900 + Double($0), role: .item, index: $0) }
        var c0 = t.file("C0", name: "01 · crop 9:16.jpg", type: "image/jpeg", at: 200, role: .crop)
        c0.madeFrom = ["I0"]
        var c1 = t.file("C1", name: "02 · crop 9:16.jpg", type: "image/jpeg", at: 260, role: .crop)
        c1.madeFrom = ["I1"]
        t.publish([t.post("G9", files: items + [c0, c1], link: wmGalleryLink, kind: .gallery, items: 2)])
        await t.check()
        #expect(t.tasks.count == 2, "both crops are new: \(t.tasks.map { $0.request?.url?.path ?? "" })")
        #expect(await t.landAll(900))
        let crops = t.store.videos.filter { $0.role == .crop }
        #expect(crops.count == 2, "the server keeps both crops (app-routes.ts replaces exports only); the Mac kept \(crops.count)")
        #expect(t.mac.trash.items.isEmpty, "nothing of the owner's goes to the Trash")
    }

    @Test func aCropMadeOnThePhoneLeavesTheMacsOwnCropOfAnotherPhoto() async throws {
        let t = try PullRig()
        await t.check()
        let a = try await t.save("01", session: "G9", role: .item, index: 0, libraryID: "I0", postItems: 2, link: wmGalleryLink)
        _ = try await t.save("02", session: "G9", role: .item, index: 1, mediaID: a.mediaID, libraryID: "I1", postItems: 2, link: wmGalleryLink)
        let mine = try await t.save("01 · crop 9:16", session: "G9", role: .crop, mediaID: a.mediaID, libraryID: "C0", link: wmGalleryLink)
        let minePath = try #require(t.mac.record(mine.id)?.visiblePath)
        let items = (0..<2).map { t.file("I\($0)", name: "0\($0 + 1).jpg", type: "image/jpeg", at: -900 + Double($0), role: .item, index: $0) }
        var c0 = t.file("C0", name: "01 · crop 9:16.jpg", type: "image/jpeg", at: -100, role: .crop)
        c0.madeFrom = ["I0"]
        var c1 = t.file("C1", name: "02 · crop 9:16.jpg", type: "image/jpeg", at: 260, role: .crop)
        c1.madeFrom = ["I1"]
        t.publish([t.post("G9", files: items + [c0, c1], link: wmGalleryLink, kind: .gallery, items: 2)])
        await t.check()
        #expect(t.tasks.count == 1)
        #expect(await t.landAll(900))
        let crops = t.store.videos.filter { $0.role == .crop }
        #expect(crops.count == 2 && t.mac.exists(minePath) && t.mac.trash.items.isEmpty, "the server keeps C0; the Mac trashed it")
    }

    @Test func twoPhoneCropsLandingOneAfterTheOther() async throws {
        let t = try PullRig()
        await t.check()
        let items = (0..<2).map { t.file("I\($0)", name: "0\($0 + 1).jpg", type: "image/jpeg", at: -900 + Double($0), role: .item, index: $0) }
        var c0 = t.file("C0", name: "01 · crop 9:16.jpg", type: "image/jpeg", at: 200, role: .crop)
        c0.madeFrom = ["I0"]
        t.publish([t.post("G9", files: items + [c0], link: wmGalleryLink, kind: .gallery, items: 2)])
        await t.check()
        #expect(await t.landAll(900))
        var c1 = t.file("C1", name: "02 · crop 9:16.jpg", type: "image/jpeg", at: 400, role: .crop)
        c1.madeFrom = ["I1"]
        t.clock.jump(by: 600)
        t.publish([t.post("G9", files: items + [c0, c1], link: wmGalleryLink, kind: .gallery, items: 2)])
        await t.check()
        #expect(await t.landAll(900))
        let crops = t.store.videos.filter { $0.role == .crop }
        #expect(crops.count == 2 && t.mac.trash.items.isEmpty, "crops \(crops.count), trash \(t.mac.trash.items.map(\.lastPathComponent))")
    }

    // MARK: S1. "remove from this mac" stays removed when the post later gets a new file

    @Test func removedFromThisMacIsNotPulledAgainWhenThePostGetsANewFile() async throws {
        let t = try PullRig()
        await t.check()                                                   // baseline at 0
        let p = t.post("P1", files: [t.file("F1", at: 60)])
        t.publish([p])
        t.clock.jump(by: 120)
        await t.check()
        #expect(t.tasks.count == 1)
        #expect(await t.landAll(1_000))
        let media = try #require(t.store.media.first)
        #expect(await t.store.removeMedia(media.id), "remove from this mac")
        #expect(t.store.videos.isEmpty)

        // two days of other saves: the watermark moves on
        t.clock.jump(by: 2 * 86_400)
        t.publish([p, t.post("Q1", files: [t.file("FQ", name: "q.mp4", at: 2 * 86_400)])])
        await t.check()
        #expect(await t.landAll(1_000))
        #expect(t.ledger.read().done["F1"] != nil, "the owner's decision does not age out")

        // the phone makes a webp of P1: the post comes to the top again
        t.clock.jump(by: 86_400)
        let bumped = t.post("P1", files: [t.file("F1", at: 60), t.webp("W9", name: "zZzZzZzZ01", at: 3 * 86_400)])
        t.publish([bumped, t.post("Q1", files: [t.file("FQ", name: "q.mp4", at: 2 * 86_400)])])
        let before = t.tasks.count
        await t.check()
        let new = t.tasks.dropFirst(before).compactMap { $0.request?.url?.path }
        #expect(!new.contains { $0.contains("F1") }, "F1 was removed from this Mac and is fetched again: \(new)")
        #expect(new.contains { $0.contains("zZzZzZzZ01") }, "the new webp itself still comes: \(new)")
    }

    // MARK: S2. a Mac clock behind the server does not fetch what the library already held

    @Test func aClockOneHourBehindFetchesNothingOfTheExistingLibraryOnTheFirstCheck() async throws {
        let t = try PullRig()
        // the library as the server dates it: saves made in the last hour of server time are "in the future" for this Mac
        t.publish((0..<6).map { t.saved("S\($0)", at: 3_600 - Double($0) * 600) } + (0..<70).map { t.saved("OLD\($0)", at: -Double($0 + 1) * 3_600) })
        await t.check()
        #expect(t.tasks.isEmpty, "first run fetched \(t.tasks.count) existing saves")
        #expect(t.requests.count == 1, "one request: the calibration reuses the walk's first page")
        let f = t.ledger.read()
        #expect(f.enabledAt == t.at(3_600), "the baseline is the newest file the library holds, not the Mac's now")
    }

    @Test func aSaveMadeAfterTheCalibratedBaselineStillComes() async throws {
        let t = try PullRig()
        t.publish([t.saved("S0", at: 3_600), t.saved("OLD", at: -3_600)])
        await t.check()
        #expect(t.tasks.isEmpty)
        t.clock.jump(by: 300)
        t.publish([t.saved("NEW", at: 3_700), t.saved("S0", at: 3_600), t.saved("OLD", at: -3_600)])
        await t.check()
        #expect(t.tasks.count == 1 && t.tasks[0].request?.url?.path.contains("F-NEW") == true)
    }

    @Test func turningTheSettingBackOnWithAClockBehindFetchesNothingExisting() async throws {
        let t = try PullRig()
        t.publish([t.saved("S0", at: 3_000), t.saved("S1", at: 3_300)])
        await t.check()
        #expect(t.tasks.isEmpty)
        t.pull.keepChanged(false)
        t.pull.keepChanged(true)
        #expect(await eventually(5) { t.requests.count >= 2 })
        #expect(await eventually(2) { t.ledger.read().enabledAt == t.at(3_300) })
        #expect(t.tasks.isEmpty, "the setting going on again is a new baseline too")
    }

    // MARK: S3. the folder the owner is leaving is the one the move reads, whatever resolved in between

    @Test func aResolveBetweenChooseAndTheMoveStillMovesTheKeptFilesOutOfTheOldFolder() async throws {
        let rig = try MacRig()
        try rig.commit()
        let store = rig.store()
        await store.reload()
        let kept = try await store.add(
            file: try makeTempFile("clip.mp4", bytes: 800), kind: .original,
            media: MediaInfo(name: "clip", duration: 1, width: 10, height: 10, bytes: nil, isImage: false),
            sessionID: "S1", link: nil, remoteURL: nil, move: true, keep: true)
        #expect(rig.record(kept.id)?.visiblePath != nil)
        let newFolder = rig.base.appendingPathComponent("Elsewhere", isDirectory: true)
        try FileManager.default.createDirectory(at: newFolder, withIntermediateDirectories: true)
        // MacFolder.apply: the old folder is read first, then the ledger names the new one ...
        let old = store.rootBox.current
        rig.ledger.choose(path: newFolder.path, bookmark: nil, isDefault: false)
        // ... and a landing's promote (or the watcher's scan) resolves the root before switchRoot enters the gate
        await store.resolveRoot()
        let provider = MacRootProvider(ledger: rig.ledger, defaultFolder: rig.folder)
        let result = await store.switchRoot(to: provider.resolve(), move: true, from: old)
        await store.reload()
        #expect(result.moved == 1, "the owner said move; moved \(result.moved), stayed \(result.stayed)")
        #expect(rig.files(in: newFolder).count == 1 && rig.files().isEmpty, "old \(rig.files()); new \(rig.files(in: newFolder))")
    }

    // MARK: S4. the store is never a folder, and a scan never deletes the only copy

    @Test func aChosenFolderThatHoldsTheStoreNeverDeletesTheOnlyCopy() async throws {
        let rig = try MacRig()
        // a hidden file whose promote failed after step 1 (tag at the source, the rename refused): still tagged in files/
        let item = try rig.seed(SeedItem(id: "11111111-0000-4000-8000-000000000001", key: "s:S1", session: "S1", cacheData: rig.data(5, count: 4_000), keep: true))
        try rig.commit()
        let cache = rig.hidden.appendingPathComponent("files/\(item.id).mp4")
        let record = try #require(rig.record(item.id))
        try XAttr.set(OfflineTag.attribute, OfflineTag(record: record).encoded(), at: cache)
        // a root that contains Application Support (here the rig's base)
        let store = rig.store(provider: false, root: rig.base)
        _ = await store.scanVisibleRoot()
        let after = rig.record(item.id)
        #expect(FileManager.default.fileExists(atPath: cache.path), "the only copy was deleted as a redundant cache copy of itself")
        #expect(after?.fileName != nil || FileManager.default.fileExists(atPath: rig.base.appendingPathComponent(after?.visiblePath ?? "-").path))
    }

    // MARK: nit. replaceMade leaves a made file the owner edited in place

    @Test func replaceMadeLeavesAnEditedMadeFile() async throws {
        let rig = try MacRig()
        try rig.commit()
        let store = rig.store()
        await store.reload()
        let made = try await store.add(
            file: try makeTempFile("slideshow.webp", bytes: 900), kind: .webp,
            media: MediaInfo(name: "slideshow", duration: 1, width: 10, height: 10, bytes: nil, isImage: false),
            sessionID: "G1", link: nil, remoteURL: nil, move: true, keep: true, role: .slideshow,
            madeSpec: Data(#"{"format":"webp"}"#.utf8), libraryID: "OLD")
        let path = try #require(rig.record(made.id)?.visiblePath)
        let url = rig.folder.appendingPathComponent(path)
        // the owner edits it in place (an editor that writes the same file: the tag stays)
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(repeating: 1, count: 5_000))
        try handle.close()
        #expect(OfflineTag.read(at: url)?.id == made.id)
        #expect(await store.replaceMade(made.id))
        #expect(FileManager.default.fileExists(atPath: url.path), "the owner's edit went to the Trash")
        #expect(rig.trash.items.isEmpty)
        #expect(OfflineTag.read(at: url) == nil, "left in place, untagged: the owner's now")
    }

    // MARK: S1, belt and braces. A ledger that has lost the entry (a cap, an older build) still never brings the file back

    @Test func aFileOlderThanTheWalksStopLineIsNeverACandidateEvenWithNoLedgerEntry() async throws {
        let t = try PullRig()
        await t.check()
        let p = t.post("P1", files: [t.file("F1", at: 60)])
        t.publish([p])
        t.clock.jump(by: 120)
        await t.check()
        #expect(await t.landAll(1_000))
        #expect(await t.store.removeMedia(try #require(t.store.media.first).id))
        t.clock.jump(by: 2 * 86_400)
        t.publish([p, t.post("Q1", files: [t.file("FQ", name: "q.mp4", at: 2 * 86_400)])])
        await t.check()
        #expect(await t.landAll(1_000))

        // the ledger forgets everything it decided
        var file = t.ledger.read()
        file.done = [:]
        try JSONEncoder().encode(file).write(to: t.ledger.url, options: .atomic)
        #expect(t.ledger.read().done.isEmpty)

        t.clock.jump(by: 86_400)
        t.publish([t.post("P1", files: [t.file("F1", at: 60), t.webp("W9", name: "zZzZzZzZ01", at: 3 * 86_400)]), t.post("Q1", files: [t.file("FQ", name: "q.mp4", at: 2 * 86_400)])])
        let before = t.tasks.count
        await t.check()
        let new = t.tasks.dropFirst(before).compactMap { $0.request?.url?.path }
        #expect(new.count == 1 && new[0].contains("zZzZzZzZ01"), "only the new webp: \(new)")
    }

    // MARK: S5. the mass-pull brake

    private func newSaves(_ t: PullRig, _ n: Int, from first: Int = 0, at start: Double = 60) -> [LibraryPost] {
        (first..<(first + n)).map { t.saved("P\($0)", at: start + Double($0)) }
    }

    @Test func moreThanTwentyNewSavesInOneCheckAreHeldBackAndNothingIsDownloaded() async throws {
        let t = try PullRig(massLimit: SavePull.defaultMassLimit)
        await t.check()                                                   // baseline
        t.publish(newSaves(t, 21))
        t.clock.jump(by: 300)
        await t.check()
        #expect(t.tasks.isEmpty && t.queue.all().isEmpty, "nothing is fetched unasked")
        let status = t.pull.status
        #expect(status.paused == .waiting && status.waiting == 21, "\(status)")
        let file = t.ledger.read()
        #expect(file.done.isEmpty && file.watermark == nil, "no decision and no watermark: the same saves are found again")
        #expect(file.brake?.saves == 21 && file.brake?.choice == nil)

        // paused: the next ticks ask the server nothing
        let asked = t.requests.count
        t.clock.jump(by: 300)
        await t.check()
        #expect(t.requests.count == asked && t.tasks.isEmpty)
    }

    @Test func exactlyTwentyNewSavesAreFetchedWithoutAsking() async throws {
        let t = try PullRig(massLimit: SavePull.defaultMassLimit)
        await t.check()
        t.publish(newSaves(t, 20))
        t.clock.jump(by: 300)
        await t.check()
        #expect(t.tasks.count == 20 && t.pull.status.waiting == 0 && t.pull.status.paused == nil)
    }

    @Test func aGalleryOfThirtyPhotosIsOneSaveNotThirty() async throws {
        let t = try PullRig(massLimit: SavePull.defaultMassLimit)
        await t.check()
        let items = (0..<30).map { t.file("I\($0)", name: "\($0 + 1).jpg", type: "image/jpeg", at: 60 + Double($0), role: .item, index: $0) }
        t.publish([t.post("G1", files: items, link: wmGalleryLink, kind: .gallery, items: 30)])
        t.clock.jump(by: 300)
        await t.check()
        #expect(t.tasks.count == 30 && t.pull.status.waiting == 0, "one post is one save: \(t.tasks.count) tasks")
    }

    @Test func downloadThemFetchesEverythingHeldBackAndClearsTheBrake() async throws {
        let t = try PullRig(massLimit: SavePull.defaultMassLimit)
        await t.check()
        t.publish(newSaves(t, 25))
        t.clock.jump(by: 300)
        await t.check()
        #expect(t.pull.status.waiting == 25)
        await t.pull.downloadWaiting()
        #expect(t.tasks.count == 25, "tasks \(t.tasks.count)")
        #expect(t.pull.status.waiting == 0 && t.pull.status.paused == nil)
        let file = t.ledger.read()
        #expect(file.brake == nil && file.done.count == 25 && file.watermark != nil)
        // and they are not asked about again
        let before = t.tasks.count
        t.clock.jump(by: 300)
        await t.check()
        #expect(t.tasks.count == before)
    }

    @Test func skipLeavesWhatWasHeldBackOnTheServerButStillFetchesAnythingNewer() async throws {
        let t = try PullRig(massLimit: SavePull.defaultMassLimit)
        await t.check()
        t.publish(newSaves(t, 25))
        t.clock.jump(by: 300)
        await t.check()
        #expect(t.pull.status.waiting == 25)
        // a save made after the check that held the others back
        t.publish(newSaves(t, 25) + [t.saved("LATE", at: 1_000)])
        await t.pull.skipWaiting()
        #expect(t.tasks.count == 1 && t.tasks[0].request?.url?.path.contains("F-LATE") == true, "only the later save: \(t.tasks.count)")
        let file = t.ledger.read()
        #expect(file.brake == nil && t.pull.status.waiting == 0)
        #expect(file.done.values.filter { $0.state == .skipped && $0.why == "owner" }.count == 25)
        #expect(t.store.videos.isEmpty && t.folderFiles().isEmpty)
    }

    @Test func theBrakeSurvivesARelaunchAndTurningTheSettingOffForgetsIt() async throws {
        let t = try PullRig(massLimit: SavePull.defaultMassLimit)
        await t.check()
        t.publish(newSaves(t, 22))
        t.clock.jump(by: 300)
        await t.check()
        let relaunched = SavePull(
            store: t.store, ledger: t.ledger, downloads: t.engine, clock: t.clock, scheduler: ClockScheduler(clock: t.clock),
            massLimit: SavePull.defaultMassLimit)
        relaunched.wire(t.environment())
        #expect(relaunched.status.waiting == 22 && relaunched.status.paused == .waiting)

        t.pull.keepChanged(false)
        #expect(t.pull.status.waiting == 0 && t.ledger.read().brake == nil, "off forgets the baseline and the held saves with it")
    }

    // MARK: nit. the pull pauses on a nearly full disk

    @Test func theFoldersDiskUnderTwoGigabytesPausesThePullAndItResumesWithTheSpace() async throws {
        let t = try PullRig()
        t.free = 1_000_000_000
        await t.check()                                                   // the baseline is taken all the same
        #expect(t.ledger.read().enabledAt != nil)
        t.publish([t.saved("P1", at: 60)])
        t.clock.jump(by: 300)
        let asked = t.requests.count
        await t.check()
        #expect(t.pull.status.paused == .diskLow && t.requests.count == asked && t.tasks.isEmpty)

        t.free = 5_000_000_000
        t.clock.jump(by: 300)
        await t.check()
        #expect(t.pull.status.paused == nil)
        #expect(t.tasks.count == 1, "the save made while it was paused comes now: the watermark never moved")
    }

    // MARK: nit. a volume with no Trash keeps the file and says so

    @Test func aVolumeWithNoTrashKeepsTheFileAndTheOwnerIsTold() async throws {
        let rig = try MacRig()
        try rig.commit()
        var ops = TestFileOps()
        ops.noTrash = true
        let store = rig.store(ops: ops)
        await store.reload()
        let kept = try await store.add(
            file: try makeTempFile("clip.mp4", bytes: 800), kind: .original,
            media: MediaInfo(name: "clip", duration: 1, width: 10, height: 10, bytes: nil, isImage: false),
            sessionID: "S1", link: nil, remoteURL: nil, move: true, keep: true)
        let path = try #require(rig.record(kept.id)?.visiblePath)
        let macFolder = MacFolder(store: store, ledger: rig.ledger)
        #expect(macFolder.status.problem == nil)

        #expect(await store.removeOfflineCopy(kept.id) == false, "refused")
        #expect(rig.exists(path), "never silently hard-deleted")
        #expect(rig.tag(path)?.id == kept.id, "and still the record's")
        #expect(rig.record(kept.id)?.visiblePath == path && rig.record(kept.id)?.keep == true)
        #expect(store.trashRefused && macFolder.status.problem == .noTrash)

        #expect(await store.removeMedia(kept.mediaID) == false, "remove from this mac refuses too")
        #expect(rig.exists(path) && rig.record(kept.id) != nil)
    }

    @Test func replaceMadeOnAVolumeWithNoTrashLeavesTheOldMadeFile() async throws {
        let rig = try MacRig()
        try rig.commit()
        var ops = TestFileOps()
        ops.noTrash = true
        let store = rig.store(ops: ops)
        await store.reload()
        let made = try await store.add(
            file: try makeTempFile("slideshow.webp", bytes: 900), kind: .webp,
            media: MediaInfo(name: "slideshow", duration: 1, width: 10, height: 10, bytes: nil, isImage: false),
            sessionID: "G1", link: nil, remoteURL: nil, move: true, keep: true, role: .slideshow,
            madeSpec: Data(#"{"format":"webp"}"#.utf8), libraryID: "OLD")
        let path = try #require(rig.record(made.id)?.visiblePath)
        #expect(await store.replaceMade(made.id) == false)
        #expect(rig.exists(path) && rig.record(made.id) != nil && store.trashRefused)
    }

    // MARK: nit. a made file edited with the same size is still the owner's

    @Test func replaceMadeLeavesAMadeFileTheOwnerRewroteAtTheSameSize() async throws {
        let rig = try MacRig()
        try rig.commit()
        let store = rig.store()
        await store.reload()
        let made = try await store.add(
            file: try makeTempFile("slideshow.webp", bytes: 900), kind: .webp,
            media: MediaInfo(name: "slideshow", duration: 1, width: 10, height: 10, bytes: nil, isImage: false),
            sessionID: "G1", link: nil, remoteURL: nil, move: true, keep: true, role: .slideshow,
            madeSpec: Data(#"{"format":"webp"}"#.utf8), libraryID: "OLD")
        let path = try #require(rig.record(made.id)?.visiblePath)
        let url = rig.folder.appendingPathComponent(path)
        #expect(rig.record(made.id)?.placed?.bytes == 900, "the landing remembers what it placed")
        // rewritten byte for byte in size, an hour later
        try Data(repeating: 7, count: 900).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(3_600)], ofItemAtPath: url.path)
        try XAttr.set(OfflineTag.attribute, OfflineTag(record: try #require(rig.record(made.id))).encoded(), at: url)
        #expect(await store.replaceMade(made.id))
        #expect(FileManager.default.fileExists(atPath: url.path) && rig.trash.items.isEmpty)
    }

    // MARK: the evidence run. a ledger section for another folder adopts nothing, so it changes nothing

    @Test func legacyRecordsStayExactlyAsTheyWereWhileTheLedgerNamesAnotherFolder() async throws {
        let rig = try MacRig()
        for n in 0..<3 {
            try rig.seed(SeedItem(id: "L\(n)", key: "s:L\(n)", session: "L\(n)", cacheData: rig.data(UInt8(n), count: 600 + n), keep: nil))
        }
        try rig.commit()                                                  // the ledger's one section names `rig.folder`
        let chosen = rig.base.appendingPathComponent("Archive/cobalt", isDirectory: true)
        try FileManager.default.createDirectory(at: chosen, withIntermediateDirectories: true)

        let elsewhere = rig.store(provider: false, root: chosen)
        await elsewhere.reload()
        await elsewhere.reload()
        #expect(rig.index().allSatisfy { $0.keep == nil && $0.fileName != nil && $0.visiblePath == nil }, "keep untouched: \(rig.index().map(\.keep))")
        #expect(rig.files(in: chosen).isEmpty && rig.cacheFiles().count == 3)

        // the adoption that matches runs: now they settle (cache on the Mac, never "legacy, keep it")
        let matching = rig.store()
        await matching.reload()
        #expect(rig.index().allSatisfy { $0.keep == false }, "\(rig.index().map(\.keep))")
    }

    // MARK: S4. choosing a folder that holds the store is refused

    @Test func aFolderThatHoldsOrIsInsideTheStoreIsRefusedAndNothingChanges() async throws {
        let rig = try MacRig()
        try rig.commit()
        let store = rig.store()
        let macFolder = MacFolder(store: store, ledger: rig.ledger)
        let before = try rig.ledgerBytes()
        for folder in [rig.base, rig.hidden.deletingLastPathComponent(), rig.hidden, rig.hidden.appendingPathComponent("files"), rig.sync] {
            #expect(await macFolder.chooseFolder(folder) == .refusedStore, "\(folder.path)")
        }
        #expect(try rig.ledgerBytes() == before && rig.ledger.destination == nil, "nothing changed")
        #expect(store.rootState == .ready && store.visibleRoot == rig.folder)
    }

    @Test func theScanNeverTakesAHiddenCopyThatIsTheFolderFileForRedundant() throws {
        // reconcile, given an entry that is the cache file itself (a link, a spelling the path filter does not see)
        let rig = try MacRig()
        let item = try rig.seed(SeedItem(id: "11111111-0000-4000-8000-000000000002", key: "s:S2", session: "S2", cacheData: rig.data(6, count: 2_000), keep: true))
        try rig.commit()
        let cache = rig.hidden.appendingPathComponent("files/\(item.id).mp4")
        let record = try #require(rig.record(item.id))
        try XAttr.set(OfflineTag.attribute, OfflineTag(record: record).encoded(), at: cache)
        var records = [record]
        let relative = "Application Support/Videos/files/\(item.id).mp4"
        let entry = VisibleEntry(path: relative, size: 2_000, tag: OfflineTag(record: record), excludedFromBackup: false)
        let out = OfflineFolder.reconcile(&records, entries: [entry], hiddenRoot: rig.hidden, now: Date(), visibleRoot: rig.base)
        #expect(out.dropCache.isEmpty, "the only copy is not redundant: \(out.dropCache)")
        #expect(records[0].fileName != nil && records[0].visiblePath == nil, "and the record is left as it was")
        // a genuine second copy is still dropped
        let copy = rig.folder.appendingPathComponent("copy.mp4")
        try FileManager.default.copyItem(at: cache, to: copy)
        try XAttr.set(OfflineTag.attribute, OfflineTag(record: record).encoded(), at: copy)
        var again = [record]
        let second = OfflineFolder.reconcile(
            &again, entries: [VisibleEntry(path: "Movies/cobalt/copy.mp4", size: 2_000, tag: OfflineTag(record: record), excludedFromBackup: false)],
            hiddenRoot: rig.hidden, now: Date(), visibleRoot: rig.base)
        #expect(second.dropCache == ["\(item.id).mp4"])
    }
}
