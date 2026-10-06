import Foundation
import Testing
@testable import CobaltKit

// CONTRACT-OFFLINE.md section 2: the first launch of the offline build moves what the 1.10 store kept into the
// visible folder. Fixtures are real 1.10 indexes (no keep, visiblePath or givenName) with real files.

/// A 1.10 store on disk: kept files, an evicted record, a record whose file is missing, webps, an upload, a GIF
/// proxy, two saves of one link.
@MainActor
struct LegacyStore {
    struct Entry {
        var key: String
        var record: OfflineStore.Record
        var content: Data?
    }

    let rig: OfflineRig
    var entries: [String: Entry] = [:]

    init(_ rig: OfflineRig) throws {
        self.rig = rig
        let fm = FileManager.default
        try fm.createDirectory(at: rig.hidden.appendingPathComponent("files"), withIntermediateDirectories: true)
        try fm.createDirectory(at: rig.hidden.appendingPathComponent("posters"), withIntermediateDirectories: true)
        let epoch = Date(timeIntervalSince1970: 1_790_000_000)
        var n = 0
        func make(
            _ key: String, kind: StoredVideo.Kind = .original, fileSuffix: String? = nil, session: String?, link: String?,
            remote: String? = nil, media: String? = nil, name: String, present: Bool = true, evicted: Bool = false
        ) throws -> Entry {
            n += 1
            let id = "00000000-0000-4000-8000-\(String(format: "%012d", n))"
            let ext = kind == .webp ? "webp" : "mp4"
            let fileName = evicted ? nil : "\(id)\(fileSuffix ?? "").\(ext)"
            var content: Data?
            if let fileName, present {
                content = Data(repeating: UInt8(n), count: 1_000 + n * 111)
                try content!.write(to: rig.hidden.appendingPathComponent("files/\(fileName)"))
            }
            try Data(repeating: 9, count: 40).write(to: rig.hidden.appendingPathComponent("posters/\(id).jpg"))
            let record = OfflineStore.Record(
                id: id, kind: kind, fileName: fileName, posterName: "\(id).jpg", name: name, duration: 5, width: 100, height: 100,
                bytes: Int64(1_000 + n * 111), sessionID: session, link: link.flatMap(URL.init(string:)),
                remoteURL: remote.flatMap(URL.init(string:)), createdAt: epoch.addingTimeInterval(Double(n) * 60),
                addedAt: epoch.addingTimeInterval(Double(n) * 60), posterBytes: 40, mediaID: media)
            return Entry(key: key, record: record, content: content)
        }
        let orig = try make("orig", session: "S1", link: "https://www.instagram.com/reel/DeHC9jcpfQW/", name: "orig")
        let list: [Entry] = [
            orig,
            try make("gif", fileSuffix: "-play", session: "S2", link: "https://www.instagram.com/reel/GIFgifGIFgif/", name: "gif"),
            try make("webp", kind: .webp, session: "S1", link: "https://www.instagram.com/reel/DeHC9jcpfQW/",
                     remote: "https://media.example/w1.webp", media: orig.record.id, name: "orig.webp"),
            try make("upload", session: "S3", link: nil, name: "my upload"),
            try make("evicted", session: "S4", link: "https://www.instagram.com/reel/EvictedEvict/", name: "evicted", evicted: true),
            try make("missing", session: "S5", link: "https://www.instagram.com/reel/MissingMissi/", name: "missing", present: false),
            try make("plain", session: nil, link: "https://www.tiktok.com/@someone/video/7123456789", name: "plain"),
            try make("twin", session: nil, link: "https://www.instagram.com/reel/DeHC9jcpfQW/", name: "twin"),
        ]
        for e in list { entries[e.key] = e }
        try JSONEncoder().encode(list.map(\.record).reversed()).write(to: OfflineStore.indexURL(root: rig.hidden))
    }

    /// The keys that had a file on disk: the migration moves exactly these.
    var withFile: [String] { entries.filter { $0.value.content != nil }.map(\.key).sorted() }
    func id(_ key: String) -> String { entries[key]!.record.id }
}

@MainActor
struct OfflineMigrationTests {
    private func indexBytes(_ rig: OfflineRig) throws -> Data { try Data(contentsOf: OfflineStore.indexURL(root: rig.hidden)) }

    /// Every file that was kept is now exactly once in the visible folder with its own bytes and a tag; the cache
    /// folder is empty; the index names the files.
    private func expectMigrated(_ legacy: LegacyStore, sourceLocation: SourceLocation = #_sourceLocation) throws {
        let rig = legacy.rig
        #expect(rig.cacheFiles().isEmpty, "nothing is left in files/", sourceLocation: sourceLocation)
        #expect(rig.visibleFiles().count == legacy.withFile.count, sourceLocation: sourceLocation)
        for key in legacy.withFile {
            let id = legacy.id(key)
            let record = try #require(rig.record(id), sourceLocation: sourceLocation)
            let path = try #require(record.visiblePath, "\(key) has a visible path", sourceLocation: sourceLocation)
            // a file adopted by its tag (crash recovery, downgrade) has no given name: cobalt cannot tell whether the
            // owner chose the one it has, so it is never renamed after
            #expect(record.fileName == nil && record.keep == true
                    && (record.givenName == nil || record.givenName == (path as NSString).lastPathComponent),
                    sourceLocation: sourceLocation)
            #expect(try Data(contentsOf: rig.url(path)) == legacy.entries[key]?.content, "\(key) arrived whole", sourceLocation: sourceLocation)
            #expect(OfflineTag.read(at: rig.url(path))?.id == id, sourceLocation: sourceLocation)
        }
        rig.checkInvariants(sourceLocation: sourceLocation)
    }

    @Test(arguments: OfflineLayout.allCases)
    func aOneTenStoreMovesIntoTheVisibleFolderWithFriendlyNames(layout: OfflineLayout) async throws {
        let rig = try OfflineRig(layout: layout)
        let legacy = try LegacyStore(rig)
        let store = rig.store()
        await store.reload()

        try expectMigrated(legacy)
        let files = rig.visibleFiles()
        #expect(files.contains("instagram · DeHC9jcpfQW.mp4"))
        #expect(files.contains("instagram · DeHC9jcpfQW (2).mp4"), "two saves of one link: a clash gets (2)")
        #expect(files.contains("instagram · DeHC9jcpfQW · webp 1.webp"))
        #expect(files.contains("my upload.mp4"), "an upload keeps its own name")
        #expect(files.contains { $0.hasPrefix("instagram · GIFgifGIFgif") && $0.hasSuffix(".mp4") }, "the GIF proxy is an mp4")
        #expect(files.count == 6)

        // evicted and missing stay file-less and untouched (their poster stays)
        for key in ["evicted", "missing"] {
            let record = try #require(rig.record(legacy.id(key)))
            #expect(record.fileName == nil && record.visiblePath == nil && record.keep == nil && record.posterName != nil)
        }
        // the store shows it
        let orig = try #require(store.videos.first { $0.id == legacy.id("orig") })
        #expect(orig.isOffline && orig.place == .offline && orig.keep)
        #expect(store.videos.first { $0.id == legacy.id("evicted") }?.place == nil)
        #expect(store.offlineUsage.offline.count == 6 && store.offlineUsage.cache.count == 0)
        #expect(store.migratedAt != nil, "the marker exists for telemetry and the footnote")
        #expect(FileManager.default.fileExists(atPath: rig.sync.appendingPathComponent("offline.json").path))
    }

    @Test func aSecondRunFindsNothingAndChangesNoByte() async throws {
        let rig = try OfflineRig()
        let legacy = try LegacyStore(rig)
        let store = rig.store()
        await store.reload()
        let index = try indexBytes(rig)
        let files = rig.visibleFiles(includingHidden: true)

        await store.reload()
        await store.runMigrationIfNeeded()
        let relaunched = rig.store()
        await relaunched.reload()
        #expect(try indexBytes(rig) == index)
        #expect(rig.visibleFiles(includingHidden: true) == files)
        #expect(await relaunched.scanVisibleRoot() == OfflineScanReport())
        try expectMigrated(legacy)
    }

    @Test func recordsInUseWaitForTheNextReload() async throws {
        let rig = try OfflineRig()
        let legacy = try LegacyStore(rig)
        let store = rig.store()
        store.pin(legacy.id("plain"))
        await store.reload()
        #expect(rig.cacheFiles().count == 1 && rig.visibleFiles().count == legacy.withFile.count - 1)
        #expect(rig.record(legacy.id("plain"))?.fileName != nil)

        store.unpin(legacy.id("plain"))
        await store.reload()
        try expectMigrated(legacy)
    }

    @Test func withoutAVisibleRootNothingMoves() async throws {
        let rig = try OfflineRig()
        let legacy = try LegacyStore(rig)
        let before = try indexBytes(rig)
        let store = rig.store(visible: false)
        await store.runMigrationIfNeeded()
        await store.reload()
        #expect(rig.visibleFiles().isEmpty && rig.cacheFiles().count == legacy.withFile.count)
        #expect(try indexBytes(rig) == before || rig.index().allSatisfy { $0.visiblePath == nil && $0.fileName != nil || $0.fileName == nil })
        #expect(rig.index().allSatisfy { $0.keep == nil }, "the extension and the Mac do not migrate")
    }

    // MARK: crash points

    /// The next launch after a crash at `step`: no file is lost or doubled, and the run finishes.
    @Test(arguments: [
        (OfflineMoveStep.tagged, false), (.renamed, false), (.indexed, false),
        (.tagged, true), (.copied, true), (.copyRenamed, true), (.renamed, true), (.indexed, true),
    ])
    func aCrashAtAnyPointLeavesAStateTheNextLaunchSettles(step: OfflineMoveStep, crossVolume: Bool) async throws {
        let rig = try OfflineRig()
        let legacy = try LegacyStore(rig)
        let crashing = rig.store(ops: TestFileOps(crashAt: step, crossVolume: crossVolume))
        await crashing.reload()                                           // dies at `step`

        // whatever state it left: every file's bytes exist, in the cache or in the folder, at most one of each
        // (the copy path may leave a whole second copy until the next launch)
        func holders(_ content: Data) -> Int {
            let all = rig.cacheFiles().map { rig.hidden.appendingPathComponent("files/\($0)") }
                + rig.visibleFiles(includingHidden: true).map { rig.url($0) }
            return all.filter { (try? Data(contentsOf: $0)) == content }.count
        }
        for key in legacy.withFile {
            #expect(holders(legacy.entries[key]!.content!) >= 1, "\(key) is not lost after a crash at \(step)")
        }

        let next = rig.store(ops: TestFileOps(crossVolume: crossVolume))
        await next.reload()
        try expectMigrated(legacy)
        #expect(rig.visibleFiles(includingHidden: true).allSatisfy { !$0.hasSuffix(".part") } || step == .copied,
                "no half copy is left behind (a fresh one waits out its hour only after a `copied` crash)")
        for key in legacy.withFile { #expect(holders(legacy.entries[key]!.content!) == 1, "\(key) exists once") }

        let settled = try indexBytes(rig)
        await next.reload()
        let third = rig.store()
        await third.reload()
        #expect(try indexBytes(rig) == settled, "the re-run is a no-op")
        try expectMigrated(legacy)
    }

    @Test func aCopyAcrossVolumesNeverDeletesTheSourceBeforeTheDestinationIsWhole() async throws {
        let rig = try OfflineRig()
        let legacy = try LegacyStore(rig)
        let store = rig.store(ops: TestFileOps(crossVolume: true))
        await store.reload()
        try expectMigrated(legacy)
        #expect(rig.visibleFiles(includingHidden: true).allSatisfy { !$0.hasSuffix(".part") })
    }

    @Test func aStalePartFromACrashedCopyIsSweptAndAFreshOneIsNot() async throws {
        let rig = try OfflineRig()
        _ = try LegacyStore(rig)
        let stale = rig.visible.appendingPathComponent(".cobalt-aaaa.part")
        let fresh = rig.visible.appendingPathComponent(".cobalt-bbbb.part")
        for url in [stale, fresh] { try Data(repeating: 1, count: 5).write(to: url) }
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-3 * 3_600)], ofItemAtPath: stale.path)
        await rig.store().reload()
        #expect(!FileManager.default.fileExists(atPath: stale.path))
        #expect(FileManager.default.fileExists(atPath: fresh.path))
    }

    // MARK: downgrade

    @Test func downgradeThenUpgradeReattachesEveryMovedFileById() async throws {
        let rig = try OfflineRig()
        let legacy = try LegacyStore(rig)
        await rig.store().reload()
        let files = rig.visibleFiles()

        // the older build knows nothing of the new keys and sees every moved record as evicted
        let url = OfflineStore.indexURL(root: rig.hidden)
        var json = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [[String: Any]])
        for i in json.indices { for key in ["keep", "visiblePath", "givenName"] { json[i].removeValue(forKey: key) } }
        try JSONSerialization.data(withJSONObject: json).write(to: url)
        let old = rig.store(visible: false)
        let movedIDs = Set(legacy.withFile.map { legacy.id($0) })
        #expect(old.videos.filter { movedIDs.contains($0.id) }.allSatisfy { $0.place == nil })

        let upgraded = rig.store()
        await upgraded.reload()
        #expect(rig.visibleFiles() == files, "nothing moved, nothing doubled")
        try expectMigrated(legacy)
    }
}
