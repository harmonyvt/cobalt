import Foundation
import Testing
@testable import CobaltKit

// Regression tests for the adversarial review of the offline wave 1 commit (CONTRACT-OFFLINE.md "review fixes",
// 2026-10-06). Each test is a proof the review made with a throwaway test, kept: it fails on the code that
// shipped in 8121f0659 and passes on the fix. Real file system operations in temp dirs; the case-sensitive
// proofs mount a case-sensitive APFS disk image.

// MARK: - B1: deletes by remembered path, without an identity check

@MainActor
struct OfflineDeleteIdentityTests {
    /// "remove offline copy" went by the path the record remembered. The owner renamed cobalt's file in Files and
    /// dropped their own file under the old name before any scan: the remove deleted the owner's file.
    @Test func removeOfflineCopyNeverDeletesTheOwnersFileAtAStalePath() async throws {
        let rig = try OfflineRig()
        let store = rig.store()
        let v = try await rig.save(store, "clip", session: "S1", link: OfflineRig.instagram)
        let path = try #require(rig.record(v.id)?.visiblePath)
        try FileManager.default.moveItem(at: rig.url(path), to: rig.url("mine now.mp4"))
        try Data(repeating: 1, count: 33).write(to: rig.url(path))
        #expect(OfflineTag.read(at: rig.url(path)) == nil, "the file at the old path is the owner's, untagged")

        let removed = await store.removeOfflineCopy(v.id)

        #expect(FileManager.default.fileExists(atPath: rig.url(path).path), "the owner's file survived")
        #expect(try Data(contentsOf: rig.url(path)).count == 33)
        #expect(!FileManager.default.fileExists(atPath: rig.url("mine now.mp4").path), "cobalt's own file, found by its tag, went")
        #expect(removed)
        #expect(rig.record(v.id)?.keep == false && rig.record(v.id)?.visiblePath == nil)
        let report = await store.scanVisibleRoot()
        #expect(report.rebuilt == 0 && report.adopted == 0, "the remove stays removed")
        #expect(rig.record(v.id)?.keep == false)
    }

    /// The same blind delete through "remove from this iphone": the owner swapped two names in Files.
    @Test func removeMediaFollowsTheTagWhenTwoNamesWereSwapped() async throws {
        let rig = try OfflineRig()
        let store = rig.store()
        let a = try await rig.save(store, "a", session: "SA", link: URL(string: "https://www.instagram.com/reel/AAAA/")!)
        let b = try await rig.save(store, "b", session: "SB", link: URL(string: "https://www.instagram.com/reel/BBBB/")!)
        let pa = try #require(rig.record(a.id)?.visiblePath)
        let pb = try #require(rig.record(b.id)?.visiblePath)
        try FileManager.default.moveItem(at: rig.url(pa), to: rig.url("tmp.mp4"))
        try FileManager.default.moveItem(at: rig.url(pb), to: rig.url(pa))
        try FileManager.default.moveItem(at: rig.url("tmp.mp4"), to: rig.url(pb))

        let removed = await store.removeMedia(a.mediaID)

        #expect(removed)
        #expect(rig.record(a.id) == nil, "A's record is gone")
        let kept = try #require(rig.record(b.id))
        #expect(kept.keep == true && kept.visiblePath != nil, "B's kept file was not touched")
        let path = try #require(kept.visiblePath)
        #expect(OfflineTag.read(at: rig.url(path))?.id == b.id)
        #expect(rig.visibleFiles().count == 1)
        rig.checkInvariants()
    }

    /// `remove(_:)` (the single record) goes through the same check.
    @Test func removeByIDNeverDeletesAFileThatIsNotTheRecords() async throws {
        let rig = try OfflineRig()
        let store = rig.store()
        let v = try await rig.save(store, "clip", session: "S1", link: OfflineRig.instagram)
        let path = try #require(rig.record(v.id)?.visiblePath)
        try FileManager.default.moveItem(at: rig.url(path), to: rig.url("moved out of the way.mp4"))
        try Data(repeating: 2, count: 21).write(to: rig.url(path))

        await store.remove(v.id)

        #expect(try Data(contentsOf: rig.url(path)).count == 21, "the owner's untagged file is still there")
        #expect(rig.record(v.id) == nil)
    }

    /// The title-follow rename moved whatever was at the remembered path.
    @Test func aTitleChangeNeverRenamesTheOwnersFileAtAStalePath() async throws {
        let rig = try OfflineRig()
        let store = rig.store()
        let v = try await rig.save(store, "clip", session: "S1", link: OfflineRig.instagram)
        let path = try #require(rig.record(v.id)?.visiblePath)
        try FileManager.default.moveItem(at: rig.url(path), to: rig.url("mine now.mp4"))
        try Data(repeating: 3, count: 40).write(to: rig.url(path))

        await store.setTitle("rome", media: v.mediaID)

        #expect(try Data(contentsOf: rig.url(path)).count == 40, "the owner's file kept its name")
        #expect(!FileManager.default.fileExists(atPath: rig.url("rome.mp4").path))
        #expect(OfflineTag.read(at: rig.url("mine now.mp4"))?.id == v.id)
    }
}

// MARK: - B2: a case-only rename on a case-sensitive volume

#if os(macOS)
/// A case-sensitive APFS disk image, mounted for one test (iOS volumes are case-sensitive; the temp dir of this Mac is not).
final class CaseSensitiveVolume: @unchecked Sendable {
    let mount: URL
    private let image: URL

    init?() {
        guard let dir = try? makeTempDirectory().resolvingSymlinksInPath() else { return nil }
        image = dir.appendingPathComponent("cs.sparseimage")
        mount = dir.appendingPathComponent("mnt", isDirectory: true)
        try? FileManager.default.createDirectory(at: mount, withIntermediateDirectories: true)
        guard Self.run(["create", "-size", "64m", "-fs", "Case-sensitive APFS", "-volname", "cobaltcs", "-type", "SPARSE", image.path]),
              Self.run(["attach", image.path, "-mountpoint", mount.path, "-nobrowse", "-quiet"])
        else { return nil }
    }

    func detach() {
        _ = Self.run(["detach", mount.path, "-force", "-quiet"])
        try? FileManager.default.removeItem(at: image.deletingLastPathComponent())
    }

    private static func run(_ arguments: [String]) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return false }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }
}

@MainActor
struct OfflineCaseOnlyRenameTests {
    private func rig(on volume: CaseSensitiveVolume) throws -> (store: OfflineStore, hidden: URL, visible: URL) {
        let base = volume.mount.appendingPathComponent("run-\(UUID().uuidString.prefix(6))")
        let hidden = base.appendingPathComponent("Videos")
        let visible = base.appendingPathComponent("Documents")
        try FileManager.default.createDirectory(at: hidden, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: visible, withIntermediateDirectories: true)
        let suite = "cobalt.casesensitive.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite) ?? .standard
        LimitDefaults.write(nil, to: defaults)
        let store = OfflineStore(
            root: hidden, tools: OfflineTools(), defaults: defaults, now: { Date() }, visibleRoot: visible,
            ops: TestFileOps(), syncDirectory: nil)
        return (store, hidden, visible)
    }

    private func keptClip(_ store: OfflineStore) async throws -> StoredVideo {
        let file = try makeTempFile("clip.mp4", bytes: 1_000)
        let info = MediaInfo(name: "clip", duration: 1, width: 10, height: 10, bytes: nil, isImage: false)
        return try await store.add(
            file: file, kind: .original, media: info, sessionID: "S1", link: OfflineRig.instagram, remoteURL: nil,
            move: true, keep: true)
    }

    /// The owner's own `Rome.mp4` sat beside cobalt's `rome.mp4`; a title change to "Rome" renamed over it.
    @Test func aCaseOnlyTitleChangeNeverOverwritesADistinctFile() async throws {
        let volume = try #require(CaseSensitiveVolume(), "hdiutil could not make a case-sensitive APFS image")
        defer { volume.detach() }
        let (store, hidden, visible) = try rig(on: volume)
        let v = try await keptClip(store)
        await store.setTitle("rome", media: v.mediaID)
        #expect(OfflineStore.readRecords(root: hidden).first?.visiblePath == "rome.mp4")
        try Data(repeating: 5, count: 77).write(to: visible.appendingPathComponent("Rome.mp4"))

        await store.setTitle("Rome", media: v.mediaID)

        let owner = visible.appendingPathComponent("Rome.mp4")
        #expect(try Data(contentsOf: owner).count == 77, "the owner's Rome.mp4 was not overwritten")
        let names = try FileManager.default.contentsOfDirectory(atPath: visible.path).sorted()
        #expect(names.count == 2 && names.contains("Rome.mp4"), "both files are still there: \(names)")
        let record = try #require(OfflineStore.readRecords(root: hidden).first)
        let path = try #require(record.visiblePath)
        #expect(OfflineTag.read(at: visible.appendingPathComponent(path))?.id == v.id, "the record points at cobalt's file")
        #expect(path != "Rome.mp4")
    }

    /// With nothing in the way, a case-only change still renames (the volume tells two names apart).
    @Test func aCaseOnlyTitleChangeStillRenamesWhenNothingIsInTheWay() async throws {
        let volume = try #require(CaseSensitiveVolume(), "hdiutil could not make a case-sensitive APFS image")
        defer { volume.detach() }
        let (store, hidden, visible) = try rig(on: volume)
        let v = try await keptClip(store)
        await store.setTitle("rome", media: v.mediaID)
        await store.setTitle("Rome", media: v.mediaID)
        #expect(try FileManager.default.contentsOfDirectory(atPath: visible.path) == ["Rome.mp4"])
        #expect(OfflineStore.readRecords(root: hidden).first?.visiblePath == "Rome.mp4")
    }
}
#endif

@MainActor
struct OfflineCaseOnlyRenameDefaultVolumeTests {
    /// On a case-insensitive volume `rome.mp4` and `Rome.mp4` are one file: the rename is allowed and lands.
    @Test func aCaseOnlyTitleChangeRenamesOnTheDefaultVolume() async throws {
        let rig = try OfflineRig()
        let store = rig.store()
        let v = try await rig.save(store, "clip", session: "S1", link: OfflineRig.instagram)
        await store.setTitle("rome", media: v.mediaID)
        await store.setTitle("Rome", media: v.mediaID)
        #expect(rig.record(v.id)?.visiblePath == "Rome.mp4")
        #expect(rig.visibleFiles() == ["Rome.mp4"])
    }
}

// MARK: - S1: an index that exists but does not decode

@MainActor
struct OfflineUndecodableIndexTests {
    private func plantUnknownKind(_ rig: OfflineRig) throws -> (url: URL, bytes: Data) {
        let url = rig.hidden.appendingPathComponent("index.json")
        var json = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [[String: Any]])
        var future = json[0]
        future["id"] = "future"
        future["kind"] = "gif"                              // a later build's new Kind: this build cannot decode it
        json.append(future)
        try JSONSerialization.data(withJSONObject: json).write(to: url)
        return (url, try Data(contentsOf: url))
    }

    private func preservedCopies(_ rig: OfflineRig) -> [URL] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: rig.hidden.path)) ?? []
        return names.filter { $0.hasPrefix("index.unreadable-") }.map { rig.hidden.appendingPathComponent($0) }
    }

    @Test func theLaunchScanNeverWritesOverAnIndexItCannotDecode() async throws {
        let rig = try OfflineRig()
        let store = rig.store()
        try await rig.save(store, "kept", session: "S1", link: OfflineRig.instagram)
        try await rig.save(store, "cached", session: "S2", keep: false)
        let (url, before) = try plantUnknownKind(rig)

        let fresh = rig.store()                    // a launch
        await fresh.reload()

        #expect(try Data(contentsOf: url) == before, "the index was not rewritten")
        let copies = preservedCopies(rig)
        #expect(copies.count == 1, "a copy was kept beside it")
        #expect(try copies.first.map { try Data(contentsOf: $0) } == before)
        #expect(rig.cacheFiles().count == 1, "the cache file of the unreadable index is still there")
        #expect(rig.visibleFiles().count == 1)
        await fresh.reload()                       // and a second pass changes nothing, not even the copies
        #expect(try Data(contentsOf: url) == before)
        #expect(preservedCopies(rig).count == 1)
    }

    @Test func aScanReportsItAndChangesNothing() async throws {
        let rig = try OfflineRig()
        let store = rig.store()
        try await rig.save(store, "kept", session: "S1", link: OfflineRig.instagram)
        let (url, before) = try plantUnknownKind(rig)
        let report = await rig.store().scanVisibleRoot()
        #expect(report.indexUnreadable && report.rebuilt == 0 && report.followed == 0)
        #expect(try Data(contentsOf: url) == before)
    }

    @Test func aWriteIsRefusedWhileTheIndexCannotBeDecoded() async throws {
        let rig = try OfflineRig()
        let store = rig.store()
        try await rig.save(store, "kept", session: "S1", link: OfflineRig.instagram)
        let (url, before) = try plantUnknownKind(rig)
        let fresh = rig.store()
        await #expect(throws: (any Error).self) { try await rig.save(fresh, "another", session: "S3") }
        #expect(try Data(contentsOf: url) == before, "nothing was written over it")
        #expect(rig.cacheFiles().isEmpty, "and the file the add placed was taken back")
    }

    /// An index that is simply missing is a new store, not a damaged one.
    @Test func aMissingIndexIsStillAFreshStore() async throws {
        let rig = try OfflineRig()
        let store = rig.store()
        let v = try await rig.save(store, "kept", session: "S1", link: OfflineRig.instagram)
        try FileManager.default.removeItem(at: rig.hidden.appendingPathComponent("index.json"))
        let fresh = rig.store()
        await fresh.reload()
        #expect(rig.record(v.id)?.keep == true, "the tag rebuilt the record")
        #expect(preservedCopies(rig).isEmpty)
    }
}

// MARK: - S4: a tag that cannot be read is not "no tag"

@MainActor
struct OfflineUnreadableTagTests {
    @Test func anUnreadableTagChangesNothing() async throws {
        let rig = try OfflineRig(limit: 1)
        let store = rig.store()
        let v = try await rig.save(store, "clip", session: "S1", link: OfflineRig.instagram)
        let path = try #require(rig.record(v.id)?.visiblePath)
        let before = rig.record(v.id)
        chmod(rig.url(path).path, 0)                       // getxattr fails with EACCES: a locked file stands in
        defer { chmod(rig.url(path).path, 0o644) }

        let report = await store.scanVisibleRoot()

        #expect(report.rootMissing, "a scan that cannot read a tag stops, as an unreadable root does")
        #expect(report.unkept == 0 && report.rebuilt == 0 && report.adopted == 0)
        #expect(rig.record(v.id) == before, "the record is exactly as it was")
        #expect(rig.record(v.id)?.keep == true)
    }

    @Test func onlyAMissingAttributeMeansUntagged() throws {
        let dir = try makeTempDirectory()
        let url = dir.appendingPathComponent("owner.mp4")
        try Data(repeating: 1, count: 10).write(to: url)
        guard case .untagged = OfflineTag.probe(at: url) else { Issue.record("a file with no attribute is untagged"); return }
        chmod(url.path, 0)
        defer { chmod(url.path, 0o644) }
        guard case .unreadable = OfflineTag.probe(at: url) else { Issue.record("EACCES is not \"no tag\""); return }
    }

    @Test func aRemoveRefusesWhenTheTagCannotBeRead() async throws {
        let rig = try OfflineRig()
        let store = rig.store()
        let v = try await rig.save(store, "clip", session: "S1", link: OfflineRig.instagram)
        let path = try #require(rig.record(v.id)?.visiblePath)
        chmod(rig.url(path).path, 0)
        defer { chmod(rig.url(path).path, 0o644) }
        let removed = await store.removeOfflineCopy(v.id)
        #expect(!removed, "refused: identity could not be checked")
        chmod(rig.url(path).path, 0o644)
        #expect(FileManager.default.fileExists(atPath: rig.url(path).path))
        #expect(rig.record(v.id)?.keep == true)
    }
}

// MARK: - S2 and S3: kept files nobody can promote

@MainActor
struct OfflineUnpromotableStoreTests {
    /// The extension with no app group (the owner's phone): its store is its own, the app never promotes from it,
    /// and eviction skips kept files, so every share would stay forever.
    @Test func aStoreNobodyPromotesFromTakesNothingAsKept() async throws {
        let rig = try OfflineRig(limit: 2_000)
        let ext = rig.store(visible: false, shared: false)
        for i in 0..<20 { try await rig.save(ext, "s\(i)", bytes: 1_000, session: "E\(i)") }
        await ext.reload()
        #expect(rig.index().allSatisfy { $0.keep == false }, "cache semantics")
        #expect(rig.cacheFiles().count == OfflineStore.protectedNewest, "the limit holds: only the newest media stay")
    }

    /// A store with no visible root and no app group (the extension on a phone; wave 1's Mac, which wave M replaced with
    /// `.macFolder`, where `canKeep` is true) takes nothing as kept: the hidden copy is a cache.
    @Test func aStoreWithNoRootToMoveToKeepsNothingInTheHiddenFolder() async throws {
        let rig = try OfflineRig(limit: 2_000)
        let mac = rig.store(visible: false, shared: false)
        let v = try await rig.save(mac, "clip", session: "S1", keep: true)
        #expect(!v.keep && v.place == .cache)
        let cached = try await rig.save(mac, "other", session: "S2", keep: false)
        let wanted = await mac.setKeep(true, ids: [cached.id])
        #expect(wanted.isEmpty, "nothing to download: keeping has no meaning here yet")
        #expect(rig.record(cached.id)?.keep == false)
        let refilled = try #require(rig.record(v.id))
        #expect(refilled.keep == false)
        // attach with keep: true is the same
        await mac.removeOfflineCopy(v.id)
        let file = try makeTempFile("again.mp4", bytes: 500)
        let attached = try await mac.attach(file: file, to: v.id, move: true, keep: true)
        #expect(!attached.keep)
    }

    /// The group extension still keeps: the app promotes its files.
    @Test func anExtensionSharingTheStoreWithTheAppStillKeeps() async throws {
        let rig = try OfflineRig()
        let ext = rig.store(visible: false, shared: true)
        let v = try await rig.save(ext, "clip", session: "S1")
        #expect(v.keep && rig.record(v.id)?.keep == true)
    }

    /// A store an earlier build filled with kept files that can never move: they become cache at the next reload.
    @Test func reloadReleasesKeptFilesAStoreCanNeverPromote() async throws {
        let rig = try OfflineRig(limit: 2_000)
        let ext = rig.store(visible: false, shared: true)
        for i in 0..<20 { try await rig.save(ext, "s\(i)", bytes: 1_000, session: "E\(i)") }
        #expect(rig.index().allSatisfy { $0.keep == true })
        let mac = rig.store(visible: false, shared: false)
        await mac.reload()
        #expect(rig.index().allSatisfy { $0.keep == false })
        #expect(rig.cacheFiles().count == OfflineStore.protectedNewest)
    }
}

// MARK: - S5: removing a copy against a promotion

@MainActor
struct OfflineRemoveVersusPromotionTests {
    /// The cache-tier removal did not take the gate: it ran between a promotion's move and its index write, and the
    /// write put the record back to kept, pointing at a file the owner had asked to remove.
    @Test func aRemoveDuringAMoveStaysRemoved() async throws {
        let rig = try OfflineRig()
        let ext = rig.store(visible: false)
        let v = try await rig.save(ext, "clip", session: "S1", link: OfflineRig.instagram)
        #expect(rig.record(v.id)?.fileName != nil)

        let box = StoreBox()
        var ops = TestFileOps()
        let id = v.id
        ops.onCheckpoint = { @Sendable step in
            guard step == .renamed else { return }
            Task { @MainActor in await box.store?.removeOfflineCopy(id) }
            Thread.sleep(forTimeInterval: 0.4)             // the remove gets its chance to run before the index write
        }
        let app = rig.store(ops: ops)
        box.store = app
        await app.reload()
        // the remove that waited for the gate runs once the promotion is done
        for _ in 0..<50 where rig.record(v.id)?.keep == true { try await Task.sleep(for: .milliseconds(50)) }

        #expect(rig.record(v.id)?.keep == false, "the owner's remove won")
        #expect(rig.record(v.id)?.visiblePath == nil && rig.record(v.id)?.fileName == nil)
        #expect(rig.visibleFiles().isEmpty && rig.cacheFiles().isEmpty)
        rig.checkInvariants()
    }

    /// Whoever else changed the record while the file moved (here: a write that took the keep away), the
    /// promotion's index write does not undo it, and the file it moved goes back out of the owner's folder.
    @Test func aPromotionNeverRevivesARecordThatIsNoLongerKept() async throws {
        let rig = try OfflineRig()
        let ext = rig.store(visible: false)
        let v = try await rig.save(ext, "clip", session: "S1", link: OfflineRig.instagram)
        let hidden = rig.hidden
        let id = v.id
        var ops = TestFileOps()
        ops.onCheckpoint = { @Sendable step in
            guard step == .renamed else { return }
            _ = try? OfflineStore.mutate(root: hidden) { records in
                guard let i = records.firstIndex(where: { $0.id == id }) else { return }
                records[i].keep = false
                records[i].fileName = nil
            }
        }
        let app = rig.store(ops: ops)
        await app.reload()
        let record = try #require(rig.record(v.id))
        #expect(record.keep == false && record.visiblePath == nil && record.fileName == nil)
        #expect(rig.visibleFiles().isEmpty, "the moved file did not stay behind")
        rig.checkInvariants()
    }
}

@MainActor
private final class StoreBox { var store: OfflineStore? }

// MARK: - S6: a Files duplicate carries the tag

@MainActor
struct OfflineRemovedMediaStaysRemovedTests {
    @Test func aDuplicateDoesNotResurrectAMediaTheOwnerRemoved() async throws {
        let rig = try OfflineRig()
        let store = rig.store()
        let v = try await rig.save(store, "clip", session: "S1", link: OfflineRig.instagram)
        let path = try #require(rig.record(v.id)?.visiblePath)
        try FileManager.default.copyItem(at: rig.url(path), to: rig.url("copy.mp4"))
        #expect(OfflineTag.read(at: rig.url("copy.mp4"))?.id == v.id)

        await store.removeMedia(v.mediaID)
        #expect(!FileManager.default.fileExists(atPath: rig.url(path).path))
        let report = await store.scanVisibleRoot()
        let again = rig.store()
        await again.reload()

        #expect(rig.index().isEmpty, "the media did not come back")
        #expect(report.rebuilt == 0 && report.untracked == 1, "the duplicate is an owner file now: \(report)")
        #expect(FileManager.default.fileExists(atPath: rig.url("copy.mp4").path), "and it is left alone")
        #expect(again.videos.isEmpty)
    }

    @Test func aDuplicateDoesNotUndoRemoveOfflineCopy() async throws {
        let rig = try OfflineRig()
        let store = rig.store()
        let v = try await rig.save(store, "clip", session: "S1", link: OfflineRig.instagram)
        let path = try #require(rig.record(v.id)?.visiblePath)
        try FileManager.default.copyItem(at: rig.url(path), to: rig.url("copy.mp4"))

        #expect(await store.removeOfflineCopy(v.id))
        await store.scanVisibleRoot()

        let record = try #require(rig.record(v.id))
        #expect(record.keep == false && record.visiblePath == nil, "the copy was not adopted back")
        #expect(FileManager.default.fileExists(atPath: rig.url("copy.mp4").path))

        // keeping it again is the owner's new wish: the tombstone is lifted and the new file counts
        let file = try makeTempFile("fresh.mp4", bytes: 800)
        let attached = try await store.attach(file: file, to: v.id, move: true, keep: true)
        #expect(attached.keep && attached.place == .offline)
        let again = try #require(rig.record(v.id))
        #expect(again.visiblePath != nil && again.keep == true)
        let report = await store.scanVisibleRoot()
        #expect(report.unkept == 0)
        #expect(rig.record(v.id)?.keep == true)
    }

    @Test func aDeleteInFilesStillRestoresFromRecentlyDeleted() async throws {
        // The owner's own delete is not a tombstone: restoring a file puts it back (decision 6).
        let rig = try OfflineRig()
        let store = rig.store()
        let v = try await rig.save(store, "clip", session: "S1", link: OfflineRig.instagram)
        let path = try #require(rig.record(v.id)?.visiblePath)
        let held = rig.base.appendingPathComponent("held.mp4")
        try FileManager.default.moveItem(at: rig.url(path), to: held)
        await store.scanVisibleRoot()
        #expect(rig.record(v.id)?.keep == false)
        try FileManager.default.moveItem(at: held, to: rig.url(path))
        let report = await store.scanVisibleRoot()
        #expect(report.adopted == 1 && rig.record(v.id)?.keep == true)
    }

    @Test func theTombstonesAreBoundedAndPersist() throws {
        let dir = try makeTempDirectory()
        let ids = (0..<(OfflineTombstones.limit + 40)).map { "id-\($0)" }
        for id in ids { OfflineTombstones.add([id], root: dir, now: Date(timeIntervalSince1970: 1_000 + Double(Int(id.dropFirst(3))!))) }
        let kept = OfflineTombstones.ids(root: dir)
        #expect(kept.count == OfflineTombstones.limit)
        #expect(kept.contains("id-\(OfflineTombstones.limit + 39)") && !kept.contains("id-0"), "the oldest go first")
        OfflineTombstones.remove(["id-100"], root: dir)
        #expect(!OfflineTombstones.ids(root: dir).contains("id-100"))
    }
}

// MARK: - nits

@MainActor
struct OfflineReviewNitTests {
    /// A record whose cache file is gone and whose tagged copy sits in the visible root takes the visible copy.
    @Test func aRecordWithNoCacheFileAdoptsTheVisibleCopy() async throws {
        let rig = try OfflineRig()
        let store = rig.store()
        let v = try await rig.save(store, "clip", session: "S1", link: OfflineRig.instagram)
        let path = try #require(rig.record(v.id)?.visiblePath)
        _ = try OfflineStore.mutate(root: rig.hidden) { records in
            guard let i = records.firstIndex(where: { $0.id == v.id }) else { return }
            records[i].visiblePath = nil
            records[i].fileName = "gone-from-the-cache.mp4"        // the hidden file is not there
        }
        // the scan reads the index itself (the store's own `reconciled` would have cleared the missing name first)
        let result = await OfflineFolder.scan(hiddenRoot: rig.hidden, visibleRoot: rig.visible, now: Date(), ops: TestFileOps())
        #expect(result.report.adopted == 1)
        let record = try #require(rig.record(v.id))
        #expect(record.visiblePath == path && record.fileName == nil && record.keep == true)
        rig.checkInvariants()
    }

    /// `Dictionary(uniqueKeysWithValues:)` trapped on an index that names one id twice.
    @Test func keepingSurvivesAnIndexThatNamesAnIDTwice() async throws {
        let rig = try OfflineRig()
        let store = rig.store()
        let v = try await rig.save(store, "clip", session: "S1", keep: false)
        let url = rig.hidden.appendingPathComponent("index.json")
        var json = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [[String: Any]])
        json.append(json[0])
        try JSONSerialization.data(withJSONObject: json).write(to: url)
        let fresh = rig.store()
        let missing = await fresh.setKeep(true, ids: [v.id, v.id])
        #expect(missing.isEmpty)
    }
}
