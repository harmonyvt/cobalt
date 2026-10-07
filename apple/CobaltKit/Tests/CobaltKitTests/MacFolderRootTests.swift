import Foundation
import Testing
@testable import CobaltKit

// The Mac's visible root (CONTRACT-OFFLINE.md 13.1, 13.4 to 13.6): the folder is the root whether or not it is reachable,
// an unplugged disk changes nothing, another disk at the same path is not the folder, choosing another folder moves the
// kept files safely. Temp directories only; "unplugging" is renaming a directory.

private let instagram = URL(string: "https://www.instagram.com/reel/DeHC9jcpfQW/")!

@MainActor
private func save(
    _ store: OfflineStore, _ name: String = "clip", bytes: Int = 1_000, session: String? = nil, keep: Bool = true,
    role: GalleryRole? = nil, itemIndex: Int? = nil, mediaID: String? = nil, libraryID: String? = nil, postItems: Int? = nil,
    link: URL? = nil
) async throws -> StoredVideo {
    let file = try makeTempFile("\(name).mp4", bytes: bytes)
    let info = MediaInfo(name: name, duration: 1, width: 10, height: 10, bytes: nil, isImage: false)
    return try await store.add(
        file: file, kind: .original, media: info, sessionID: session ?? name, link: link, remoteURL: nil, move: true, mediaID: mediaID,
        keep: keep, role: role, itemIndex: itemIndex, libraryID: libraryID, postItems: postItems)
}

@MainActor
struct MacFolderRootTests {
    @Test func theRootIsTheChosenFolderWhetherOrNotItIsReachableAndNothingIsMadeThere() throws {
        let rig = try MacRig(folderName: "Volumes/Archive/cobalt", createFolder: false)
        try rig.commit()
        rig.ledger.choose(path: rig.folder.path, bookmark: nil, isDefault: false)
        let store = rig.store()
        #expect(store.visibleRoot?.standardizedFileURL.path == rig.folder.standardizedFileURL.path, "the root, though the disk is not there")
        #expect(store.rootState == .unreachable(path: rig.folder.path))
        #expect(store.canKeep, "the Mac keeps for the life of the app")
        #expect(!FileManager.default.fileExists(atPath: rig.folder.path), "a chosen folder is never made")
    }

    @Test func aStoreInDocumentsModeIsNeverNotReady() throws {
        let rig = try OfflineRig()
        let store = rig.store()
        #expect(store.rootMode == .documents && store.rootState == .ready)
    }

    @Test func anUnpluggedDiskChangesNothingNewSavesWaitAndEverythingResumesWhenItIsBack() async throws {
        let rig = try MacRig(folderName: "Volumes/Archive/cobalt")
        try rig.commit()
        rig.ledger.choose(path: rig.folder.path, bookmark: nil, isDefault: false)
        let first = rig.store()
        let a = try await save(first, "a", session: "SA")
        let kept = try #require(rig.record(a.id)?.visiblePath)
        #expect(rig.exists(kept))

        // unplug
        let disk = rig.base.appendingPathComponent("Volumes/Archive", isDirectory: true)
        let gone = rig.base.appendingPathComponent("Volumes/Archive.unplugged", isDirectory: true)
        try FileManager.default.moveItem(at: disk, to: gone)

        let store = rig.store()                                           // a launch with the disk away
        #expect(store.rootState == .unreachable(path: rig.folder.path))
        await store.reload()
        #expect(rig.record(a.id)?.visiblePath == kept && rig.record(a.id)?.keep == true, "a missing root is never every file deleted")
        #expect(await store.scanVisibleRoot().rootMissing)
        #expect(!(await store.removeOfflineCopy(a.id)), "a file on a disk that is not there is not removed")
        #expect(rig.record(a.id)?.visiblePath == kept)

        // a save while it is away waits, kept, in the hidden folder
        let b = try await save(store, "b", session: "SB")
        var waiting = try #require(rig.record(b.id))
        #expect(waiting.keep == true && waiting.fileName != nil && waiting.visiblePath == nil)
        #expect(!FileManager.default.fileExists(atPath: rig.folder.path), "nothing is created where the disk was")
        await store.reload()
        waiting = try #require(rig.record(b.id))
        #expect(waiting.fileName != nil, "still waiting")

        // plug back
        try FileManager.default.moveItem(at: gone, to: disk)
        await store.reload()
        #expect(store.rootState == .ready)
        waiting = try #require(rig.record(b.id))
        #expect(waiting.visiblePath != nil && waiting.fileName == nil && rig.exists(waiting.visiblePath ?? ""), "moved in when the disk came back")
        #expect(rig.record(a.id)?.visiblePath == kept && rig.exists(kept))
    }

    @Test func aDeletedDefaultFolderIsRecreatedAndItsRecordsStopBeingOffline() async throws {
        let rig = try MacRig()
        try rig.commit()
        let store = rig.store()
        let a = try await save(store, "a", session: "SA")
        #expect(rig.record(a.id)?.visiblePath != nil)
        try FileManager.default.removeItem(at: rig.folder)
        await store.reload()
        #expect(FileManager.default.fileExists(atPath: rig.folder.path), "the default folder is made again")
        #expect(store.rootState == .ready)
        let after = try #require(rig.record(a.id))
        #expect(after.visiblePath == nil && after.keep == false, "the owner deleted their files: decision 6")
    }

    @Test func anotherDiskOrAnotherFolderAtTheSamePathIsNotTheFolder() async throws {
        let rig = try MacRig(folderName: "Volumes/Archive/cobalt")
        try rig.commit()
        let real = FolderDestination.identity(of: rig.folder)
        let volume = try #require(real.volume)
        let fileID = try #require(real.fileID)

        // recorded on another volume
        rig.ledger.choose(path: rig.folder.path, bookmark: nil, isDefault: false, volume: "NOT-THIS-DISK", fileID: fileID)
        let wrongDisk = rig.store()
        #expect(wrongDisk.rootState == .wrongFolder(path: rig.folder.path))
        // recorded with another folder id (the folder was deleted and made again, or another disk with the same name)
        rig.ledger.choose(path: rig.folder.path, bookmark: nil, isDefault: false, volume: volume, fileID: fileID &+ 1)
        // `choose` keeps the section but replaces the record; the identity above is the new one
        let wrongFolder = rig.store()
        #expect(wrongFolder.rootState == .wrongFolder(path: rig.folder.path))

        // nothing is scanned, adopted, promoted or pulled
        #expect(await wrongFolder.scanVisibleRoot().rootMissing)
        let waiting = try await save(wrongFolder, "w", session: "SW")
        #expect(rig.record(waiting.id)?.fileName != nil && rig.files().isEmpty, "the save waits; nothing is written there")
        await wrongFolder.reload()
        #expect(rig.files().isEmpty && rig.record(waiting.id)?.fileName != nil)

        // the right identity is ready, and a record from 1.14.x (neither field) learns it after a scan
        rig.ledger.choose(path: rig.folder.path, bookmark: nil, isDefault: false, volume: volume, fileID: fileID)
        let right = rig.store()
        #expect(right.rootState == .ready)
        rig.ledger.choose(path: rig.folder.path, bookmark: nil, isDefault: false)
        #expect(rig.ledger.destination?.volume == nil)
        let legacy = rig.store()
        await legacy.reload()
        #expect(legacy.rootState == .ready)
        #expect(rig.ledger.destination?.volume == volume && rig.ledger.destination?.fileID == fileID, "recorded after the first successful scan")
        #expect(rig.record(waiting.id)?.visiblePath != nil, "and what waited moves in")
    }

    @Test func aFolderInICloudDriveIsRefusedWithoutReadingIt() async throws {
        let home = FolderDestination.realHome()
        let drive = home.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs/cobalt", isDirectory: true)
        #expect(FolderDestination.isInICloudDrive(drive))
        let rig = try MacRig()
        #expect(!FolderDestination.isInICloudDrive(rig.folder))
        try rig.commit()
        let store = rig.store()
        let macFolder = MacFolder(store: store, ledger: rig.ledger)
        #expect(await macFolder.chooseFolder(drive) == .refusedICloud)
        #expect(rig.ledger.destination == nil, "nothing changed")
    }

    @Test func theStatusReadsTheStoresRoot() async throws {
        let rig = try MacRig()
        try rig.commit()
        let away = rig.base.appendingPathComponent("Volumes/Archive/cobalt", isDirectory: true)       // a chosen folder, not there
        rig.ledger.choose(path: away.path, bookmark: nil, isDefault: false)
        let store = rig.store()
        let macFolder = MacFolder(store: store, ledger: rig.ledger)
        #expect(macFolder.status.available && macFolder.status.problem == .unreachable && !macFolder.status.isDefault)
        let plain = try MacRig()
        try plain.commit()
        let ready = MacFolder(store: plain.store(), ledger: plain.ledger)
        #expect(ready.status.available && ready.status.problem == nil && ready.status.isDefault)
        let documents = try OfflineRig()
        #expect(!MacFolder(store: documents.store(), ledger: FolderLedger(directory: documents.sync)).status.available)
    }
}

// MARK: - choosing another folder (13.5)

@MainActor
struct MacFolderRelocationTests {
    private struct World {
        let rig: MacRig
        let store: OfflineStore
        let macFolder: MacFolder
        let other: URL
        let ids: [String]
    }

    /// Kept files in the default folder: `flat` plain saves and a gallery of two items (in its folder), all through the
    /// store; another empty folder next to it.
    private func world(flat: Int = 3, ops: TestFileOps? = nil) async throws -> World {
        let rig = try MacRig()
        try rig.commit()
        let store = rig.store(ops: ops)
        var ids: [String] = []
        for n in 0..<flat { ids.append(try await save(store, "clip\(n)", bytes: 500 + n, session: "S\(n)", link: instagram).id) }
        let media = "gallery-media"
        for n in 0..<2 {
            ids.append(try await save(
                store, "item\(n)", bytes: 700 + n, session: "G1", role: .item, itemIndex: n, mediaID: n == 0 ? nil : media, libraryID: "lib\(n)",
                postItems: 2, link: URL(string: "https://www.instagram.com/p/DeKlsGCGZmx/")).id)
        }
        let other = rig.base.appendingPathComponent("Other/cobalt", isDirectory: true)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        return World(rig: rig, store: store, macFolder: MacFolder(store: store, ledger: rig.ledger), other: other, ids: ids)
    }

    private func keptPaths(_ w: World) -> [String: String] {
        Dictionary(uniqueKeysWithValues: w.rig.index().compactMap { r in r.visiblePath.map { (r.id, $0) } })
    }

    @Test func choosingAskssToMoveAndCancelChangesNothing() async throws {
        let w = try await world()
        let before = snapshot(of: w.rig.folder)
        let outcome = await w.macFolder.chooseFolder(w.other)
        #expect(outcome == .askMove(count: 5))
        #expect(w.rig.ledger.destination == nil && w.store.visibleRoot.map(FolderDestination.canonical) == FolderDestination.canonical(w.rig.folder), "not switched yet")
        let result = await w.macFolder.answerMove(nil)
        #expect(result.moved == 0 && result.stayed == 0)
        #expect(snapshot(of: w.rig.folder) == before && w.rig.ledger.destination == nil)
        #expect(await w.macFolder.chooseFolder(w.rig.folder) == .unchanged)
    }

    @Test func moveCarriesEveryKeptFileIntoTheNewFolderByTag() async throws {
        let w = try await world()
        let oldPaths = keptPaths(w)
        #expect(w.rig.files().contains { $0.contains("/") }, "the gallery has its folder")
        #expect(await w.macFolder.chooseFolder(w.other) == .askMove(count: 5))
        let result = await w.macFolder.answerMove(true)
        #expect(result.moved == 5 && result.stayed == 0)

        let left = ((try? FileManager.default.contentsOfDirectory(atPath: w.rig.folder.path)) ?? []).filter { !$0.hasPrefix(".") }
        #expect(w.rig.files().isEmpty && left.isEmpty, "the old folder is empty, the gallery's folder with it: \(left)")
        #expect(w.store.visibleRoot.map(FolderDestination.canonical) == FolderDestination.canonical(w.other))
        #expect(w.store.rootState == .ready)
        let now = keptPaths(w)
        #expect(now == oldPaths, "the same names, in the new root")
        for (id, path) in now {
            #expect(w.rig.exists(path, in: w.other) && w.rig.tag(path, in: w.other)?.id == id, Comment(rawValue: path))
            #expect(w.rig.record(id)?.keep == true)
        }
        let recorded = try #require(w.rig.ledger.destination)
        #expect(FolderDestination.canonical(URL(fileURLWithPath: recorded.path)) == FolderDestination.canonical(w.other) && recorded.bookmark != nil)
        #expect(w.macFolder.status.path.hasSuffix("Other/cobalt") && !w.macFolder.status.isDefault)
        #expect(w.macFolder.status.moving == nil)
        await w.store.reload()
        #expect(keptPaths(w) == oldPaths, "a scan of the new root agrees")
    }

    @Test func leavingThemMakesThemNotOfflineAndDeletesNothing() async throws {
        let w = try await world()
        let files = w.rig.files()
        _ = await w.macFolder.chooseFolder(w.other)
        let result = await w.macFolder.answerMove(false)
        #expect(result.moved == 0)
        #expect(w.rig.files() == files, "every file is where it was, tagged")
        #expect(w.rig.index().allSatisfy { $0.visiblePath == nil && $0.keep == false }, "not offline here any more; nothing is downloaded again")
        #expect(w.rig.files(in: w.other).isEmpty)
        // dragged into the new folder, a file is adopted again by its tag
        let first = try #require(files.first { !$0.contains("/") })
        try FileManager.default.moveItem(at: w.rig.folder.appendingPathComponent(first), to: w.other.appendingPathComponent(first))
        await w.store.reload()
        #expect(w.rig.index().filter { $0.visiblePath == first }.count == 1)
    }

    @Test func aMoveToAnotherDiskCopiesWholeThenRenamesThenDeletesTheSource() async throws {
        var ops = TestFileOps()
        let w0 = try await world(ops: nil)
        ops.crossVolumeFrom = w0.rig.folder
        // a second store over the same disk, whose renames out of the old folder fail with EXDEV
        let store = w0.rig.store(ops: ops)
        let macFolder = MacFolder(store: store, ledger: w0.rig.ledger)
        #expect(await macFolder.chooseFolder(w0.other) == .askMove(count: 5))
        let result = await macFolder.answerMove(true)
        #expect(result.moved == 5 && result.stayed == 0)
        #expect(w0.rig.files().isEmpty, "the sources went only after their copies were whole")
        #expect(w0.rig.files(in: w0.other).count == 5 && !w0.rig.files(in: w0.other).contains { $0.hasPrefix(".cobalt-") })
        #expect(store.videos.filter(\.isOffline).count == 5)
    }

    @Test func oneFileThatIsNotProvablyItsOwnStaysInTheOldFolder() async throws {
        let w = try await world()
        let victim = try #require(keptPaths(w).first { !$0.value.contains("/") })
        // the owner replaced it with a file of their own (no tag)
        let url = w.rig.folder.appendingPathComponent(victim.value)
        try FileManager.default.removeItem(at: url)
        try Data(repeating: 1, count: 33).write(to: url)
        _ = await w.macFolder.chooseFolder(w.other)
        let result = await w.macFolder.answerMove(true)
        #expect(result.moved == 4 && result.stayed == 1)
        let kept = try Data(contentsOf: url).count
        #expect(w.rig.exists(victim.value) && kept == 33, "the owner's file is untouched")
        #expect(w.rig.record(victim.key)?.visiblePath == nil && w.rig.record(victim.key)?.keep == false)
    }

    @Test func aCrashMidMoveLosesNoFileAndTheNextLaunchOpensOnTheNewFolder() async throws {
        let rig = try MacRig()
        try rig.commit()
        let store = rig.store()
        for n in 0..<25 { _ = try await save(store, "c\(n)", bytes: 300 + n, session: "S\(n)", link: instagram) }
        let other = rig.base.appendingPathComponent("Other/cobalt", isDirectory: true)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)

        // the move, with file operations that die after the first batch of 20 is indexed
        let dying = rig.store(ops: TestFileOps(crashAt: .indexed))
        rig.ledger.choose(path: other.path, bookmark: nil, isDefault: false)
        let provider = MacRootProvider(ledger: rig.ledger, defaultFolder: rig.folder)
        let result = await dying.switchRoot(to: provider.resolve(), move: true)
        #expect(result.interrupted != nil && result.moved == 20)
        #expect(rig.files(in: other).count == 20 && rig.files().count == 5, "20 moved, 5 not")

        // next launch: the ledger names the new folder
        let relaunched = rig.store(ops: nil, ledgerOverride: rig.ledger)
        #expect(relaunched.visibleRoot.map(FolderDestination.canonical) == FolderDestination.canonical(other))
        await relaunched.reload()
        let index = rig.index()
        #expect(index.filter { $0.visiblePath != nil }.count == 20 && index.allSatisfy { $0.fileName == nil })
        for r in index.filter({ $0.visiblePath != nil }) { #expect(rig.exists(r.visiblePath ?? "", in: other)) }
        #expect(index.filter { $0.visiblePath == nil }.count == 5 && rig.files().count == 5,
                "the five that did not move are still in the old folder, the owner's, tagged")
        #expect(rig.files().allSatisfy { OfflineTag.read(at: rig.folder.appendingPathComponent($0)) != nil })
    }
}

// MARK: - the DEBUG sandbox (-cobaltSandboxRoot)

struct SandboxRootTests {
    @Test func theFlagNamesTheFolderAndMakesIt() throws {
        let dir = try makeTempDirectory().appendingPathComponent("sandbox", isDirectory: true)
        let url = try #require(AppGroup.sandboxRoot(arguments: ["cobalt", "-cobaltSandboxRoot", dir.path, "-other", "x"]))
        #expect(url.standardizedFileURL.path == dir.standardizedFileURL.path)
        #expect(FileManager.default.fileExists(atPath: dir.path))
        #expect(AppGroup.sandboxRoot(arguments: ["cobalt"]) == nil)
        #expect(AppGroup.sandboxRoot(arguments: ["cobalt", "-cobaltSandboxRoot"]) == nil, "no value")
        #expect(AppGroup.sandboxRoot(arguments: ["cobalt", "-cobaltSandboxRoot", "-other"]) == nil, "the next flag is not a folder")
    }

    @Test func withoutTheFlagTheRealFolderIsTheDefaultAndNeverASandbox() {
        #expect(AppGroup.sandboxRoot == nil, "the test process is not run with the flag")
        #expect(FolderDestination.defaultURL.path.hasSuffix("Movies/cobalt"))
    }
}

// MARK: - what the screens build against (13.14)

@MainActor
struct MacFolderPublicAPITests {
    @Test func theModelCarriesTheMacFolderAndThePullInPlaceOfTheOldCopier() {
        let app = AppModel.preview(.happy)
        #expect(app.macFolder.isAvailable == MacFolder.platformHasFolder)
        #expect(app.savePull.status.available == MacFolder.platformHasFolder && app.savePull.status.paused == nil)
        app.macFolder.setPreviewStatus(.init(path: "/Volumes/Archive/cobalt", isDefault: false, problem: .unreachable))
        #expect(app.macFolder.status.problem == .unreachable && !app.macFolder.status.isDefault)
        #expect(MacFolder.Status().path == "~/Movies/cobalt" && MacFolder.Status(available: false).available == false)
    }

    @Test func keepNewSavesWritesTheSettingAndASessionInFlightIsHeld() async {
        let app = AppModel.preview(.happy)
        app.setKeepNewSaves(false)
        #expect(!app.settings.keepVideosOnDevice)
        app.setKeepNewSaves(true)
        #expect(app.settings.keepVideosOnDevice)
        #expect(!app.holdsSession("nope"))
        app.store.sessionIsHeld = { $0 == "HELD" }
        #expect(app.holdsSession("HELD") && !app.holdsSession("OTHER"))
        await app.savePull.check()                       // the stub does nothing
        #expect(app.savePull.status.lastChecked == nil)
    }

    @Test func aPreviewMacFolderAnswersWithoutTouchingTheDisk() async {
        let preview = MacFolder.preview(.init())
        #expect(await preview.chooseFolder(URL(fileURLWithPath: "/nowhere")) == .askMove(count: 24))
        #expect(await preview.answerMove(true).moved == 24)
        #expect(await preview.resetToDefault() == .askMove(count: 24))
        #expect(preview.displayFolder(of: StoredVideo(id: "x", kind: .original, fileURL: nil, posterURL: nil, name: "n", duration: nil, width: nil, height: nil, bytes: 1, sessionID: nil, link: nil, remoteURL: nil, createdAt: Date())) == preview.status.path)
    }
}
