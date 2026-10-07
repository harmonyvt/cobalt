import Foundation
import Testing
@testable import CobaltKit

// Adopting what the Mac's FolderSync copied (CONTRACT-OFFLINE.md 13.3, 13.13.1): the owner's real folder as a fixture, then
// each row of the adoption table, the crash points, and the rules that keep the owner's own files untouched. Temp
// directories only; the Trash is a fake (`TrashBin`).

// MARK: - the owner's folder

@MainActor
struct OwnerFolderTests {
    @Test func reloadAdoptsEveryFileFolderSyncWroteAndChangesNothingElseInTheFolder() async throws {
        let owner = try OwnerFolder()
        let rig = owner.rig
        let before = snapshot(of: rig.folder)
        let store = owner.store()
        #expect(store.canKeep && store.rootMode == .macFolder && store.rootState == .ready, "the Mac keeps files in the folder")
        #expect(store.visibleRoot.map(FolderDestination.canonical) == FolderDestination.canonical(rig.folder))

        await store.reload()

        // 7 of the 8 records are kept in the folder, at the ledger's path, tagged, with no hidden copy
        for id in owner.adoptableIDs {
            let seed = try #require(owner.items.first { $0.id == id })
            let record = try #require(rig.record(id))
            let path = try #require(seed.entry?.file)
            #expect(record.visiblePath == path, "\(path)")
            #expect(record.givenName == (path as NSString).lastPathComponent)
            #expect(record.keep == true && record.fileName == nil)
            #expect(rig.tag(path)?.id == id, "tagged with the record id: \(path)")
        }
        #expect(rig.cacheFiles() == [rig.record(owner.renamedID)?.fileName ?? "?"], "only the renamed file's copy stays: \(rig.cacheFiles())")
        let renamed = try #require(rig.record(owner.renamedID))
        #expect(renamed.keep == false && renamed.visiblePath == nil, "the renamed file is the owner's: its record is cache")

        // the folder: same names, inodes, sizes and mtimes; only attributes differ
        let after = snapshot(of: rig.folder)
        #expect(Set(after.keys) == Set(before.keys), "no file added, moved or removed")
        #expect(!after.keys.contains { $0.contains("(2)") || $0.hasPrefix(".cobalt-") })
        for (name, was) in before {
            let now = try #require(after[name])
            #expect(now.inode == was.inode && now.size == was.size && now.mtime == was.mtime && now.isDirectory == was.isDirectory, "\(name)")
        }
        // the owner's files: byte-identical attribute lists
        for name in [owner.ownerAdded, owner.renamedTo] {
            #expect(after[name]?.attributes == before[name]?.attributes && after[name]?.attributeValues == before[name]?.attributeValues, "\(name)")
        }
        #expect(after[owner.galleryFolder]?.attributeValues == before[owner.galleryFolder]?.attributeValues, "the folder's own tag stays")

        // the leaked backup exclusion is cleared on the two adopted gallery files only
        for leaf in ["01.jpg", "02.mp4"] {
            #expect(!FileAttributes.isExcludedFromBackup(rig.folder.appendingPathComponent("\(owner.galleryFolder)/\(leaf)")), Comment(rawValue: leaf))
        }
        #expect(FileAttributes.isExcludedFromBackup(rig.folder.appendingPathComponent(owner.ownerAdded)), "the owner's file keeps whatever it had")

        // folder.json is byte-identical (a downgrade finds its ledger intact)
        #expect(try rig.ledgerBytes() == owner.ledgerBytes)

        // a second reload, and the legacy migration, change nothing
        let indexBefore = try Data(contentsOf: OfflineStore.indexURL(root: rig.hidden))
        await store.reload()
        await store.runMigrationIfNeeded()
        #expect(snapshot(of: rig.folder) == after)
        #expect(try Data(contentsOf: OfflineStore.indexURL(root: rig.hidden)) == indexBefore)
        #expect(try rig.ledgerBytes() == owner.ledgerBytes)

        // the marker says how it ended
        let marker = try #require(FolderAdoption.readMarker(in: rig.sync).sections[FolderLedger.defaultID])
        #expect(marker.complete && marker.adopted == 7 && marker.skipped == ["missing": 1] && marker.pendingCache.isEmpty, "\(marker)")
    }

    /// The prediction for the owner's real Mac (13.3): nothing renamed, nothing added: 8 of 8 adopted, 8 hidden copies gone,
    /// no file added or renamed, folder.json untouched.
    @Test func withNothingTouchedByTheOwnerAllEightAreAdoptedAndEveryHiddenCopyGoes() async throws {
        let owner = try OwnerFolder(renamed: false, ownerFile: false)
        let rig = owner.rig
        let before = snapshot(of: rig.folder)
        await owner.store().reload()
        #expect(rig.index().filter { $0.visiblePath != nil && $0.keep == true && $0.fileName == nil }.count == 8)
        #expect(rig.cacheFiles().isEmpty && rig.index().allSatisfy { $0.keep == true })
        let after = snapshot(of: rig.folder)
        #expect(Set(after.keys) == Set(before.keys))
        for (name, was) in before {
            let now = try #require(after[name])
            #expect(now.inode == was.inode && now.size == was.size && now.mtime == was.mtime, Comment(rawValue: name))
        }
        #expect(try rig.ledgerBytes() == owner.ledgerBytes)
        let marker = try #require(FolderAdoption.readMarker(in: rig.sync).sections[FolderLedger.defaultID])
        #expect(marker.complete && marker.adopted == 8 && marker.skipped.isEmpty)
    }

    @Test func aNewItemOfTheOwnersGalleryGoesIntoItsFolderByItsTag() async throws {
        let owner = try OwnerFolder()
        let store = owner.store()
        await store.reload()
        let file = try makeTempFile("src.jpg", bytes: 800)
        let info = MediaInfo(name: "03", duration: nil, width: 10, height: 10, bytes: nil, isImage: true)
        let added = try await store.add(
            file: file, kind: .original, media: info, sessionID: OwnerFolder.gallerySession, link: nil, remoteURL: nil, move: true,
            mediaID: owner.galleryMedia, keep: true, role: .item, itemIndex: 2, libraryID: "lib-2", postItems: 3)
        let record = try #require(owner.rig.record(added.id))
        #expect(record.visiblePath == "\(owner.galleryFolder)/03.jpg", "\(record.visiblePath ?? "nil")")
        #expect(owner.rig.tag("\(owner.galleryFolder)/03.jpg")?.id == added.id)
        #expect(owner.rig.files().filter { $0.hasPrefix(owner.galleryFolder) }.count == 3, "no second folder")
    }

    @Test func removingAnAdoptedFileGoesToTheTrashAndATombstoneKeepsItFromComingBack() async throws {
        let owner = try OwnerFolder()
        let rig = owner.rig
        let store = owner.store()
        await store.reload()
        let id = owner.items[0].id
        let path = try #require(rig.record(id)?.visiblePath)
        #expect(await store.removeOfflineCopy(id))
        #expect(rig.trash.items.map(\.lastPathComponent) == [(path as NSString).lastPathComponent], "sent to the Trash, not deleted")
        #expect(!rig.exists(path))
        let after = try #require(rig.record(id))
        #expect(after.visiblePath == nil && after.keep == false)
        #expect(OfflineTombstones.ids(root: rig.hidden).contains(id))

        // the owner puts it back from the Trash: it carries the removed id, so it is theirs, never adopted again
        let trashed = try #require(try FileManager.default.contentsOfDirectory(at: rig.trash.folder, includingPropertiesForKeys: nil).first)
        try FileManager.default.moveItem(at: trashed, to: rig.folder.appendingPathComponent(path))
        await store.reload()
        #expect(rig.record(id)?.visiblePath == nil && rig.record(id)?.keep == false, "not re-adopted")
        #expect(rig.exists(path), "and left where it is")
    }

    @Test func theLegacyMigrationNeverRunsOnTheMac() async throws {
        let rig = try MacRig()
        // a legacy record (keep absent) with a hidden file and nothing in the folder: iOS would move it in; the Mac does not
        try rig.seed(SeedItem(id: "L1", key: "s:L1", session: "L1", cacheData: rig.data(3, count: 900), keep: nil))
        try rig.commit()
        let store = rig.store()
        await store.runMigrationIfNeeded()
        #expect(rig.files().isEmpty && rig.record("L1")?.keep == nil && rig.record("L1")?.fileName != nil)
        await store.reload()
        #expect(rig.files().isEmpty, "adoption has no section to read, so nothing is kept or moved either")
        #expect(rig.record("L1")?.keep == false, "a legacy record is cache on the Mac, never 'legacy, keep it'")
        #expect(rig.cacheFiles().count == 1)
    }
}

// MARK: - each row of 13.3

@MainActor
struct FolderAdoptionTests {
    /// One item with its folder file, hidden copy and ledger entry; `tweak` changes the seed before it is written.
    private func rigWithOne(
        name: String = "a.mp4", size: Int = 1_000, tweak: (inout SeedItem) -> Void = { _ in }
    ) throws -> (MacRig, SeedItem) {
        let rig = try MacRig()
        var seed = SeedItem(
            id: "R1", key: "s:S1", session: "S1", link: nil, folderFile: name, cacheData: rig.data(1, count: size), keep: nil)
        seed.entry = rig.done(name, bytes: size)
        tweak(&seed)
        let placed = try rig.seed(seed)
        try rig.commit()
        return (rig, placed)
    }

    /// Everything about the folder is as it was: names, inodes, sizes, mtimes and attributes.
    private func untouched(_ rig: MacRig, since before: [String: FolderEntrySnapshot], sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(snapshot(of: rig.folder) == before, "the owner's folder is exactly as it was", sourceLocation: sourceLocation)
    }

    @Test func anUntouchedFileIsAdoptedAndItsHiddenCopyGoes() async throws {
        let (rig, _) = try rigWithOne()
        let ledger = try rig.ledgerBytes()
        let store = rig.store()
        await store.reload()
        let r = try #require(rig.record("R1"))
        #expect(r.visiblePath == "a.mp4" && r.keep == true && r.fileName == nil && r.givenName == "a.mp4")
        #expect(rig.tag("a.mp4")?.id == "R1" && rig.cacheFiles().isEmpty)
        #expect(try rig.ledgerBytes() == ledger)
        #expect(store.videos.first?.place == .offline && store.videos.first?.fileURL?.lastPathComponent == "a.mp4")
    }

    @Test func sameNameAndSizeButOtherBytesIsNotAdopted() async throws {
        let (rig, _) = try rigWithOne { $0.folderData = Data(repeating: 9, count: 1_000) }
        let before = snapshot(of: rig.folder)
        await rig.store().reload()
        #expect(rig.record("R1")?.visiblePath == nil && rig.record("R1")?.keep == false && rig.cacheFiles().count == 1)
        #expect(rig.tag("a.mp4") == nil)
        untouched(rig, since: before)
        #expect(FolderAdoption.readMarker(in: rig.sync).sections["default"]?.skipped == ["changed": 1])
    }

    @Test func anotherSizeIsNotAdopted() async throws {
        let (rig, _) = try rigWithOne { $0.folderData = rig_data(1, count: 1_001) }
        let before = snapshot(of: rig.folder)
        await rig.store().reload()
        #expect(rig.record("R1")?.visiblePath == nil && rig.tag("a.mp4") == nil)
        untouched(rig, since: before)
    }

    @Test func aFileTaggedWithAnotherIdIsNeverTouched() async throws {
        let (rig, _) = try rigWithOne()
        try XAttr.set(OfflineTag.attribute, OfflineTag(id: "OTHER", media: "M", kind: .original, created: 1).encoded(), at: rig.folder.appendingPathComponent("a.mp4"))
        let before = snapshot(of: rig.folder)
        await rig.store().reload()
        #expect(rig.record("R1")?.visiblePath == nil && rig.cacheFiles().count == 1)
        untouched(rig, since: before)
        #expect(FolderAdoption.readMarker(in: rig.sync).sections["default"]?.skipped == ["tagConflict": 1])
    }

    @Test func aFileTaggedWithTheSameIdIsAdoptedAfterACrashBetweenTagAndIndex() async throws {
        let (rig, _) = try rigWithOne()
        let tag = OfflineTag(id: "R1", media: "R1", kind: .original, session: "S1", created: 1)
        try XAttr.set(OfflineTag.attribute, tag.encoded(), at: rig.folder.appendingPathComponent("a.mp4"))
        await rig.store().reload()
        #expect(rig.record("R1")?.visiblePath == "a.mp4" && rig.cacheFiles().isEmpty)
    }

    @Test func anEvictedCopyAdoptsOnlyAFileNotNewerThanTheEntry() async throws {
        // mtime older than the entry (FolderSync's copyItem keeps the cache file's mtime): adopted
        let (older, _) = try rigWithOne { $0.cacheData = nil; $0.folderData = rig_data(1, count: 1_000); $0.mtime = Date(timeIntervalSince1970: 1_000) }
        await older.store().reload()
        #expect(older.record("R1")?.visiblePath == "a.mp4" && older.tag("a.mp4")?.id == "R1")
        // mtime newer than the entry: the owner changed it since; theirs
        let (newer, _) = try rigWithOne {
            $0.cacheData = nil; $0.folderData = rig_data(1, count: 1_000); $0.mtime = Date(timeIntervalSince1970: 1_790_100_000 + 3_600)
        }
        let before = snapshot(of: newer.folder)
        await newer.store().reload()
        #expect(newer.record("R1")?.visiblePath == nil && newer.tag("a.mp4") == nil)
        untouched(newer, since: before)
    }

    @Test func severalRecordsForOneKeyAdoptTheOneWhoseCopyMatchesElseTheOldest() async throws {
        let rig = try MacRig()
        let bytes = rig.data(1, count: 1_000)
        var entry = rig.done("a.mp4", bytes: 1_000)
        entry.at = Date(timeIntervalSince1970: 1_790_100_000)
        var a = SeedItem(id: "OLD", key: "s:S1", session: "S1", folderFile: "a.mp4", cacheData: rig.data(2, count: 800), folderData: bytes, keep: nil, entry: entry)
        a.mtime = Date(timeIntervalSince1970: 1_000)
        let b = SeedItem(id: "MATCH", key: "s:S1", session: "S1", folderFile: nil, cacheData: bytes, keep: nil, mtime: Date(timeIntervalSince1970: 2_000))
        try rig.seed(a)
        try rig.seed(b)
        try rig.commit()
        await rig.store().reload()
        #expect(rig.record("MATCH")?.visiblePath == "a.mp4", "the record whose hidden copy matches the entry's size")
        #expect(rig.record("OLD")?.visiblePath == nil && rig.record("OLD")?.fileName != nil)
    }

    @Test func anEntryWithNoRecordLeavesTheFileTheOwners() async throws {
        let rig = try MacRig()
        try Data(count: 500).write(to: rig.folder.appendingPathComponent("lonely.mp4"))
        var s = SeedItem(id: "GHOST", key: "s:GHOST")
        s.entry = rig.done("lonely.mp4", bytes: 500)
        try rig.seed(s)
        try rig.commit()
        let before = snapshot(of: rig.folder)
        await rig.store().reload()
        untouched(rig, since: before)
        #expect(FolderAdoption.readMarker(in: rig.sync).sections["default"]?.skipped == ["noRecord": 1])
        #expect(rig.tag("lonely.mp4") == nil)
    }

    @Test func twoEntriesNamingOneFileTagItOnceForTheFirstOnly() async throws {
        let rig = try MacRig()
        let bytes = rig.data(1, count: 700)
        var first = SeedItem(id: "R1", key: "s:S1", session: "S1", folderFile: "a.mp4", cacheData: bytes, keep: nil)
        first.entry = rig.done("a.mp4", bytes: 700)
        var second = SeedItem(id: "R2", key: "s:S2", session: "S2", folderFile: nil, cacheData: bytes, keep: nil)
        second.entry = rig.done("a.mp4", bytes: 700)
        try rig.seed(first)
        try rig.seed(second)
        try rig.commit()
        await rig.store().reload()
        #expect(rig.tag("a.mp4")?.id == "R1" && rig.record("R1")?.visiblePath == "a.mp4")
        #expect(rig.record("R2")?.visiblePath == nil && rig.record("R2")?.fileName != nil)
    }

    @Test func aSymlinkOrAFileOutsideTheFolderIsNeverAdopted() async throws {
        let (rig, _) = try rigWithOne()
        let target = rig.base.appendingPathComponent("elsewhere.mp4")
        try FileManager.default.moveItem(at: rig.folder.appendingPathComponent("a.mp4"), to: target)
        try FileManager.default.createSymbolicLink(at: rig.folder.appendingPathComponent("a.mp4"), withDestinationURL: target)
        await rig.store().reload()
        #expect(rig.record("R1")?.visiblePath == nil)
        #expect(OfflineTag.read(at: target) == nil, "the file behind the link is not touched")
    }

    @Test func aRecordInUseWaitsAndIsAdoptedOnTheNextReload() async throws {
        let (rig, _) = try rigWithOne()
        let store = rig.store()
        store.pin("R1")
        await store.reload()
        #expect(rig.record("R1")?.visiblePath == nil && rig.tag("a.mp4") == nil && rig.cacheFiles().count == 1)
        #expect(FolderAdoption.readMarker(in: rig.sync).sections["default"]?.complete == false, "busy is not final")
        store.unpin("R1")
        await store.reload()
        #expect(rig.record("R1")?.visiblePath == "a.mp4" && rig.cacheFiles().isEmpty)
        #expect(FolderAdoption.readMarker(in: rig.sync).sections["default"]?.complete == true)
    }

    @Test func aHeldSessionWaitsToo() async throws {
        let (rig, _) = try rigWithOne()
        let store = rig.store()
        store.sessionIsHeld = { $0 == "S1" }
        await store.reload()
        #expect(rig.record("R1")?.visiblePath == nil && rig.tag("a.mp4") == nil)
        store.sessionIsHeld = nil
        await store.reload()
        #expect(rig.record("R1")?.visiblePath == "a.mp4")
    }

    @Test func skippedEntriesStayCacheAndTheirFilesAreUntouched() async throws {
        for skip in [FolderEntry.Skip.preexisting, .gaveUp] {
            let (rig, _) = try rigWithOne { seed in
                var e = FolderEntry(state: .skipped, at: Date(timeIntervalSince1970: 1_790_100_000))
                e.skip = skip
                seed.entry = e
                seed.folderFile = nil
            }
            await rig.store().reload()
            let r = try #require(rig.record("R1"))
            #expect(r.keep == false && r.fileName != nil && r.visiblePath == nil, "\(skip)")
            #expect(rig.files().isEmpty, "nothing is added to the folder: \(skip)")
        }
    }

    @Test func claimedFailedAndNoEntryAreMovedInWhileFolderSyncWasOn() async throws {
        for state in [FolderEntry.State.claimed, .failed, .skipped] {
            // `.skipped` here stands for "no entry at all"
            let (rig, _) = try rigWithOne { seed in
                seed.folderFile = nil
                seed.entry = state == .skipped ? nil : FolderEntry(state: state, at: Date(timeIntervalSince1970: 1_790_100_000))
            }
            // FolderSync had worked in this folder: another item of it is done (a section with no entries is a folder it never used)
            var anchor = SeedItem(id: "A1", key: "s:ANCHOR", session: "ANCHOR", folderFile: "anchor.mp4", cacheData: rig.data(5, count: 600), keep: nil)
            anchor.entry = rig.done("anchor.mp4", bytes: 600)
            try rig.seed(anchor)
            try rig.commit()
            let store = rig.store()
            await store.reload()
            let r = try #require(rig.record("R1"))
            #expect(r.keep == true && r.visiblePath != nil && r.fileName == nil, "\(state)")
            #expect(rig.files().count == 2 && rig.tag(r.visiblePath ?? "")?.id == "R1", "moved into the folder: \(state)")
        }
    }

    @Test func noEntryIsLeftAloneWhenTheOwnerHadTurnedFolderSyncOff() async throws {
        let (rig, _) = try rigWithOne { $0.folderFile = nil; $0.entry = nil }
        var anchor = SeedItem(id: "A1", key: "s:ANCHOR", session: "ANCHOR", folderFile: "anchor.mp4", cacheData: rig.data(5, count: 600), keep: nil)
        anchor.entry = rig.done("anchor.mp4", bytes: 600)
        try rig.seed(anchor)
        try rig.commit()
        rig.defaults.set(false, forKey: "folderSync")
        await rig.store().reload()
        let r = try #require(rig.record("R1"))
        #expect(r.keep == false && r.visiblePath == nil && rig.files() == ["anchor.mp4"])
        // but a claimed entry was on its way whatever the switch says
        let (claimed, _) = try rigWithOne { $0.folderFile = nil; $0.entry = FolderEntry(state: .claimed, at: Date(timeIntervalSince1970: 1_790_100_000)) }
        claimed.defaults.set(false, forKey: "folderSync")
        await claimed.store().reload()
        #expect(claimed.record("R1")?.visiblePath != nil)
    }

    @Test func aSaveAfterTheFirstAdoptionIsNotSweptIntoTheFolderBecauseItHasNoEntry() async throws {
        let (rig, _) = try rigWithOne()
        let store = rig.store()
        await store.reload()
        // saved with "keep new saves offline" off: cache, and it stays cache
        let v = try await store.add(
            file: try makeTempFile("later.mp4", bytes: 700), kind: .original,
            media: MediaInfo(name: "later", duration: 1, width: 1, height: 1, bytes: nil, isImage: false),
            sessionID: "LATER", link: nil, remoteURL: nil, move: true, keep: false)
        await store.reload()
        let r = try #require(rig.record(v.id))
        #expect(r.keep == false && r.fileName != nil && r.visiblePath == nil)
    }
}

// MARK: - crashes

@MainActor
struct FolderAdoptionCrashTests {
    private func rig() throws -> (MacRig, [String: FolderEntrySnapshot], Data) {
        let rig = try MacRig()
        var items: [SeedItem] = []
        for n in 0..<3 {
            var seed = SeedItem(
                id: "C\(n)", key: "s:S\(n)", session: "S\(n)", folderFile: "c\(n).mp4", cacheData: rig.data(UInt8(n + 1), count: 900 + n), keep: nil)
            seed.entry = rig.done("c\(n).mp4", bytes: 900 + n)
            items.append(seed)
        }
        for item in items { try rig.seed(item) }
        let ledger = try rig.commit()
        return (rig, snapshot(of: rig.folder), ledger)
    }

    /// Runs adoption on a store whose file operations die at `step`, then "relaunches": a new store, normal operations.
    private func crash(at step: OfflineMoveStep) async throws -> (MacRig, [String: FolderEntrySnapshot], Data) {
        let (rig, before, ledger) = try rig()
        let dying = rig.store(ops: TestFileOps(crashAt: step))
        await dying.adoptFolderSyncFiles()
        return (rig, before, ledger)
    }

    private func settled(_ rig: MacRig, before: [String: FolderEntrySnapshot], ledger: Data) async throws {
        let store = rig.store()
        await store.reload()
        for n in 0..<3 {
            let r = try #require(rig.record("C\(n)"))
            #expect(r.visiblePath == "c\(n).mp4" && r.keep == true && r.fileName == nil, "C\(n)")
            #expect(rig.tag("c\(n).mp4")?.id == "C\(n)")
        }
        #expect(rig.cacheFiles().isEmpty, "every hidden copy went, once: \(rig.cacheFiles())")
        let after = snapshot(of: rig.folder)
        #expect(Set(after.keys) == Set(before.keys))
        for (name, was) in before {
            let now = try #require(after[name])
            #expect(now.inode == was.inode && now.size == was.size && now.mtime == was.mtime, Comment(rawValue: name))
        }
        #expect(try rig.ledgerBytes() == ledger)
        let marker = try #require(FolderAdoption.readMarker(in: rig.sync).sections[FolderLedger.defaultID])
        #expect(marker.complete && marker.pendingCache.isEmpty)
        // and a further reload is a no-op
        await store.reload()
        #expect(snapshot(of: rig.folder) == after)
    }

    @Test func aCrashAfterTaggingLeavesOnlyTagsAndTheNextRunFinishes() async throws {
        let (rig, before, ledger) = try await crash(at: .adoptTagged)
        #expect(rig.index().allSatisfy { $0.visiblePath == nil && $0.fileName != nil }, "the index was not written")
        #expect(rig.cacheFiles().count == 3)
        #expect(rig.tag("c0.mp4")?.id == "C0", "tagged")
        #expect(FolderAdoption.readMarker(in: rig.sync).sections.isEmpty, "no marker yet")
        try await settled(rig, before: before, ledger: ledger)
    }

    @Test func aCrashAfterNamingTheCopiesButBeforeTheIndexDeletesNothing() async throws {
        let (rig, before, ledger) = try await crash(at: .adoptMarked)
        #expect(rig.index().allSatisfy { $0.visiblePath == nil && $0.fileName != nil })
        #expect(rig.cacheFiles().count == 3, "nothing is deleted before the index names the folder file")
        #expect(FolderAdoption.readMarker(in: rig.sync).sections[FolderLedger.defaultID]?.pendingCache.count == 3)
        try await settled(rig, before: before, ledger: ledger)
    }

    @Test func aCrashAfterTheIndexWriteLeavesTheCopiesTheNextRunDeletes() async throws {
        let (rig, before, ledger) = try await crash(at: .adoptIndexed)
        #expect(rig.index().allSatisfy { $0.visiblePath != nil && $0.fileName == nil }, "the index names the folder files")
        #expect(rig.cacheFiles().count == 3, "the hidden copies are still there")
        #expect(FolderAdoption.readMarker(in: rig.sync).sections[FolderLedger.defaultID]?.pendingCache.count == 3)
        try await settled(rig, before: before, ledger: ledger)
    }

    @Test func aPendingCopyIsKeptWhenTheFolderFileIsNoLongerWhole() async throws {
        let (rig, _, _) = try await crash(at: .adoptIndexed)
        // the owner replaced a folder file by a shorter one before the next launch: its copy is the only whole one left
        try Data(count: 5).write(to: rig.folder.appendingPathComponent("c1.mp4"))
        await rig.store().reload()
        #expect(rig.cacheFiles().count == 1, "only the copy whose folder file is not whole stays: \(rig.cacheFiles())")
    }
}

/// `MacRig.data` without a rig, for seeds built inside a tweak closure.
func rig_data(_ seed: UInt8, count: Int) -> Data {
    var bytes = [UInt8](repeating: 0, count: count)
    var x = UInt32(seed) &* 2654435761 &+ 1
    for i in 0..<count { x = x &* 1664525 &+ 1013904223; bytes[i] = UInt8(truncatingIfNeeded: x >> 24) }
    return Data(bytes)
}
