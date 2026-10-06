import Foundation
import Observation
import Synchronization
import Testing
@testable import CobaltKit

// The offline storage limit (CONTRACT-LIVE.md section 4): temp dirs, fake sizes, an injected clock.

/// Posters of a chosen size (or none) and no decoding.
private struct FakeTools: MediaTools {
    var posterBytes = 0
    func probe(file: URL) async -> MediaInfo? { nil }
    func frames(of input: FrameInput, duration: Double?, count: Int) -> AsyncThrowingStream<Frame, Error> {
        AsyncThrowingStream { $0.finish() }
    }
    func poster(for file: URL, isImage: Bool, to destination: URL) async -> Bool {
        guard posterBytes > 0 else { return false }
        try? FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        return (try? Data(repeating: 9, count: posterBytes).write(to: destination)) != nil
    }
}

/// A clock that moves one second on every read, so stamps are strictly increasing even across stores.
private final class TickClock: Sendable {
    private let t = Mutex(1_800_000_000.0)
    func now() -> Date { Date(timeIntervalSince1970: t.withLock { $0 += 1; return $0 }) }
}

private func freshDefaults() -> UserDefaults {
    let suite = "cobalt.storage.test.\(UUID().uuidString)"
    let d = UserDefaults(suiteName: suite) ?? .standard
    d.removePersistentDomain(forName: suite)
    return d
}

private let media = MediaInfo(name: "n", duration: 1, width: 1, height: 1, bytes: nil, isImage: false)

@MainActor
private struct Rig {
    let root: URL
    let defaults: UserDefaults
    let clock = TickClock()
    let store: OfflineStore

    init(limit: Int64?, posterBytes: Int = 0, root: URL? = nil, defaults: UserDefaults? = nil, clock: TickClock? = nil) throws {
        let root = try root ?? makeTempDirectory()
        let defaults = defaults ?? freshDefaults()
        LimitDefaults.write(limit, to: defaults)
        self.root = root
        self.defaults = defaults
        let tick = clock ?? self.clock
        self.store = OfflineStore(root: root, tools: FakeTools(posterBytes: posterBytes), defaults: defaults, now: { tick.now() })
    }

    @discardableResult
    func add(_ bytes: Int, kind: StoredVideo.Kind = .original, store other: OfflineStore? = nil) async throws -> StoredVideo {
        let target = other ?? store
        return try await target.add(
            file: try makeTempFile(kind == .webp ? "f.webp" : "f.mp4", bytes: bytes), kind: kind, media: media,
            sessionID: nil, link: nil, remoteURL: nil, move: true)
    }

    func addMany(_ n: Int, bytes: Int) async throws -> [StoredVideo] {
        var out: [StoredVideo] = []
        for _ in 0..<n { out.append(try await add(bytes)) }
        return out
    }

    /// Sum of the files in `files/` and `posters/` on disk, and how many files are in `files/`.
    func disk() -> (bytes: Int64, files: Int, posters: Int) {
        let fm = FileManager.default
        func list(_ sub: String) -> [URL] {
            (try? fm.contentsOfDirectory(at: root.appendingPathComponent(sub), includingPropertiesForKeys: nil)) ?? []
        }
        func size(_ u: URL) -> Int64 { ((try? fm.attributesOfItem(atPath: u.path)[.size]) as? NSNumber)?.int64Value ?? 0 }
        let files = list("files"), posters = list("posters")
        return (files.reduce(0) { $0 + size($1) } + posters.reduce(0) { $0 + size($1) }, files.count, posters.count)
    }

    func exists(_ v: StoredVideo) -> Bool { v.fileURL.map { FileManager.default.fileExists(atPath: $0.path) } ?? false }
}

// MARK: - pure pieces

struct StorageLimitValueTests {
    @Test func theChoicesAreDecimalGigabytes() {
        #expect(StorageLimit.allCases == [.gb1, .gb2, .gb5, .gb10, .gb20, .unlimited])
        #expect(StorageLimit.allCases.map(\.bytes) == [1_000_000_000, 2_000_000_000, 5_000_000_000, 10_000_000_000, 20_000_000_000, nil])
        #expect(StorageLimit.default == .gb5)
        #expect(StorageLimit.gb5.rawValue == "gb5" && StorageLimit(rawValue: "unlimited") == .unlimited)
    }

    @Test func bytesFormatReachesGigabytes() {
        #expect(Format.bytes(999_999_999) == "1000.0 MB")        // below 1e9: unchanged from before
        #expect(Format.bytes(1_000_000_000) == "1.0 GB")
        #expect(Format.bytes(1_234_000_000) == "1.2 GB")
        #expect(Format.bytes(5_000_000_000) == "5.0 GB")
        #expect(Format.bytes(4_300_000) == "4.3 MB" && Format.bytes(841_000) == "841 KB" && Format.bytes(10) == "1 KB")
    }
}

@MainActor
struct SettingsStorageLimitTests {
    @Test func defaultsToFiveGigabytesAndPersistsThroughTheAppGroupDefaults() {
        let defaults = freshDefaults()
        let settings = Settings(defaults: defaults, keychain: .memory())
        #expect(settings.storageLimit == .gb5)
        settings.storageLimit = .gb10
        #expect(defaults.string(forKey: "storageLimit") == "gb10")
        #expect(Settings(defaults: defaults, keychain: .memory()).storageLimit == .gb10)

        // the store (the app or the share extension) reads the same key
        let store = OfflineStore(root: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("cobalt-limit-\(UUID().uuidString.prefix(6))"),
                                 tools: FakeTools(), defaults: defaults)
        #expect(store.limitBytes == 10_000_000_000)
        settings.storageLimit = .unlimited
        #expect(store.limitBytes == nil)
        settings.storageLimit = .gb1
        #expect(store.limitBytes == 1_000_000_000)
    }

    @Test func choosingALimitClearsAByteOverride() {
        let defaults = freshDefaults()
        LimitDefaults.write(1234, to: defaults)
        #expect(LimitDefaults.bytes(defaults) == 1234)
        let settings = Settings(defaults: defaults, keychain: .memory())
        settings.storageLimit = .gb2
        #expect(LimitDefaults.bytes(defaults) == 2_000_000_000)
    }

    @Test func changingTheLimitNotifiesObservers() {
        let settings = Settings(defaults: freshDefaults(), keychain: .memory())
        let changed = Mutex(false)
        withObservationTracking { _ = settings.storageLimit } onChange: { changed.withLock { $0 = true } }
        settings.storageLimit = .gb20
        #expect(changed.withLock { $0 })
    }
}

// MARK: - eviction

@MainActor
struct StorageEvictionTests {
    @Test func addsPastTheLimitEvictOldestFilesFirstAndKeepTheRecords() async throws {
        let rig = try Rig(limit: 1_500)
        let added = try await rig.addMany(20, bytes: 100)                    // 2 000 bytes offered, 1 500 allowed
        let store = rig.store

        #expect(store.videos.count == 20)                                    // nothing is forgotten
        #expect(store.videos.map(\.id) == added.reversed().map(\.id))        // order is unchanged: newest first
        let withFiles = store.videos.filter { $0.fileURL != nil }
        #expect(withFiles.count == 15)
        // the five oldest lost their file; the fifteen newest kept theirs
        #expect(store.videos.suffix(5).allSatisfy { $0.fileURL == nil })
        #expect(store.videos.prefix(15).allSatisfy { rig.exists($0) })
        #expect(store.usage == StorageUsage(count: 15, bytes: 1_500))
        // the index and the disk agree
        await store.reload()
        #expect(store.usage.bytes == rig.disk().bytes && rig.disk().files == 15)
        // an evicted record is still a full record
        let evicted = try #require(store.videos.last)
        #expect(evicted.name == "n" && evicted.bytes == 100 && evicted.duration == 1)
        #expect(OfflineStore(root: rig.root, tools: FakeTools(), defaults: rig.defaults).videos.count == 20)
    }

    @Test func theNewestTwelveAndTheJustAddedSurviveEvenOverTheLimit() async throws {
        let rig = try Rig(limit: 100)
        let added = try await rig.addMany(20, bytes: 100)
        let kept = rig.store.videos.filter { rig.exists($0) }
        #expect(kept.map(\.id) == added.suffix(12).reversed().map(\.id))     // exactly the newest twelve
        #expect(rig.store.usage == StorageUsage(count: 12, bytes: 1_200))    // over the 100-byte limit, by design
        #expect(rig.store.videos.count == 20)
    }

    @Test func aSingleFileOverTheLimitIsKept() async throws {
        let rig = try Rig(limit: 100)
        let only = try await rig.add(500)
        #expect(rig.exists(only) && rig.store.usage == StorageUsage(count: 1, bytes: 500))
        let second = try await rig.add(500)
        #expect(rig.exists(only) && rig.exists(second))                      // both in the newest twelve
    }

    @Test func keptFilesWaitingInTheCacheFolderAreNeverEvictedAndDoNotCountAgainstTheLimit() async throws {
        // decision 4: the limit becomes the cache limit; a kept file (here still in files/) is exempt
        let rig = try Rig(limit: 1_500)
        var kept: [StoredVideo] = []
        for _ in 0..<5 {
            kept.append(try await rig.store.add(
                file: try makeTempFile("k.mp4", bytes: 1_000), kind: .original, media: media, sessionID: nil, link: nil,
                remoteURL: nil, move: true, keep: true))
        }
        _ = try await rig.addMany(20, bytes: 100)                            // 2 000 cache bytes against 1 500
        #expect(kept.allSatisfy { v in rig.store.videos.first { $0.id == v.id }.map(rig.exists) == true })
        let usage = rig.store.offlineUsage
        #expect(usage.offline.bytes == 5_000 && usage.offline.count == 5)
        #expect(usage.cache.bytes <= 1_500, "the cache obeys the limit by itself")
        #expect(rig.store.usage.bytes == usage.offline.bytes + usage.cache.bytes)
    }

    @Test func unlimitedNeverEvicts() async throws {
        let rig = try Rig(limit: nil)
        _ = try await rig.addMany(30, bytes: 1_000)
        #expect(rig.store.videos.allSatisfy { rig.exists($0) })
        #expect(rig.store.usage == StorageUsage(count: 30, bytes: 30_000))
        #expect(rig.store.limitBytes == nil)
    }

    @Test func whenPostersAloneExceedTheLimitTheOldestRecordsGoToo() async throws {
        // 100-byte files with 400-byte posters: 500 each, limit 7 000
        let rig = try Rig(limit: 7_000, posterBytes: 400)
        _ = try await rig.addMany(20, bytes: 100)
        let store = rig.store
        #expect(store.videos.count == 14)                                    // six whole records went
        #expect(store.usage == StorageUsage(count: 12, bytes: 6_800))        // 12 × 500 + 2 × 400
        #expect(store.videos.prefix(12).allSatisfy { rig.exists($0) })
        let posterOnly = Array(store.videos.suffix(2))
        #expect(posterOnly.allSatisfy { $0.fileURL == nil && $0.posterURL.map { FileManager.default.fileExists(atPath: $0.path) } == true })
        let disk = rig.disk()
        #expect(disk.files == 12 && disk.posters == 14 && disk.bytes == store.usage.bytes)   // dropped posters are deleted too
    }

    @Test func loweringTheLimitEvictsExactlyWhatBytesToFreeSaid() async throws {
        let rig = try Rig(limit: nil)
        _ = try await rig.addMany(20, bytes: 100)
        let store = rig.store
        #expect(store.bytesToFree(for: nil) == 0 && store.bytesToFree(for: 5_000) == 0)
        #expect(store.bytesToFree(for: 1_500) == 500)
        #expect(store.bytesToFree(for: 100) == 800)                          // the newest twelve stay
        #expect(store.usage.bytes == 2_000)                                  // asking changes nothing

        await store.setLimit(1_500)
        #expect(store.limitBytes == 1_500)
        #expect(store.usage == StorageUsage(count: 15, bytes: 1_500))
        #expect(rig.disk().files == 15)

        // a choice the picker can make writes the picker's key; the owner's value reads back
        await store.setLimit(StorageLimit.gb1.bytes)
        #expect(rig.defaults.string(forKey: "storageLimit") == "gb1" && store.limitBytes == 1_000_000_000)
        await store.setLimit(nil)
        #expect(rig.defaults.string(forKey: "storageLimit") == "unlimited" && store.limitBytes == nil)
        #expect(store.usage.count == 15)                                     // raising it does not bring files back
    }

    @Test func theLimitIsReadInsideEveryEnforcementSoAnotherProcessAgrees() async throws {
        let rig = try Rig(limit: nil)
        _ = try await rig.addMany(20, bytes: 100)
        #expect(rig.store.usage.count == 20)
        // the app lowered the limit; the extension's store object never heard about it
        let extensionSide = OfflineStore(root: rig.root, tools: FakeTools(), defaults: rig.defaults)
        LimitDefaults.write(1_500, to: rig.defaults)
        _ = try await rig.add(100, store: extensionSide)
        #expect(extensionSide.usage == StorageUsage(count: 15, bytes: 1_500))
    }

    @Test func enforcementOnReloadCoversALimitLoweredWhileTheAppWasClosed() async throws {
        let rig = try Rig(limit: nil)
        _ = try await rig.addMany(20, bytes: 100)
        LimitDefaults.write(1_500, to: rig.defaults)
        await rig.store.reload()
        #expect(rig.store.usage == StorageUsage(count: 15, bytes: 1_500))
    }

    @Test func clearAllRemovesFilesPostersAndRecords() async throws {
        let rig = try Rig(limit: nil, posterBytes: 50)
        _ = try await rig.addMany(5, bytes: 100)
        await rig.store.clearAll()
        #expect(rig.store.videos.isEmpty && rig.store.usage == StorageUsage(count: 0, bytes: 0))
        #expect(rig.disk().files == 0 && rig.disk().posters == 0)
        #expect(OfflineStore(root: rig.root, tools: FakeTools(), defaults: rig.defaults).videos.isEmpty)
    }

    @Test func entriesInUseAreNeverEvictedNorCleared() async throws {
        let rig = try Rig(limit: 1_500)
        let added = try await rig.addMany(15, bytes: 100)
        let oldest = added[0], second = added[1]
        rig.store.pin(oldest.id)
        rig.store.pin(oldest.id)                                             // counted: two runs, one entry
        _ = try await rig.addMany(5, bytes: 100)
        let byID = Dictionary(uniqueKeysWithValues: rig.store.videos.map { ($0.id, $0) })
        #expect(rig.exists(byID[oldest.id]!))                                // skipped: the next oldest went instead
        #expect(!rig.exists(byID[second.id]!))
        #expect(rig.store.usage == StorageUsage(count: 15, bytes: 1_500))

        // lowering the limit and the "clear" button leave it too
        await rig.store.setLimit(1_000)
        #expect(rig.exists(rig.store.videos.first { $0.id == oldest.id }!))
        rig.store.unpin(oldest.id)
        await rig.store.clearAll()
        #expect(rig.exists(rig.store.videos.first { $0.id == oldest.id }!))  // still pinned once
        rig.store.unpin(oldest.id)
        await rig.store.clearAll()
        #expect(rig.store.videos.isEmpty)
    }

    @Test func removingAnEntryWhileOthersAreEvictedKeepsTheIndexConsistent() async throws {
        let rig = try Rig(limit: 1_500)
        let added = try await rig.addMany(20, bytes: 100)
        await rig.store.remove(added[0].id)                                  // an evicted one
        await rig.store.remove(added[19].id)                                 // the newest
        #expect(rig.store.videos.count == 18)
        await rig.store.reload()
        #expect(rig.store.usage.bytes == rig.disk().bytes)
    }
}

// MARK: - attach (refilling an evicted entry)

@MainActor
struct StorageAttachTests {
    @Test func attachRefillsAnEvictedEntryAndMakesItTheNewestForEviction() async throws {
        let rig = try Rig(limit: 1_500)
        let added = try await rig.addMany(20, bytes: 100)
        let store = rig.store
        let target = try #require(store.videos.first { $0.id == added[0].id })
        #expect(target.fileURL == nil)                                       // evicted
        let positionBefore = try #require(store.videos.firstIndex { $0.id == target.id })

        let fresh = try makeTempFile("again.mp4", bytes: 100)
        let refilled = try await store.attach(file: fresh, to: target.id, move: true)
        #expect(refilled.id == target.id && refilled.name == "n" && rig.exists(refilled))
        #expect(!FileManager.default.fileExists(atPath: fresh.path))         // moved
        #expect(store.videos.count == 20)                                    // no duplicate record
        #expect(store.videos.firstIndex { $0.id == target.id } == positionBefore)   // the orbit's order does not change
        #expect(store.videos.filter { $0.id == target.id }.count == 1)

        // it counts again: the next oldest file made room, and the refilled one is protected as the newest
        #expect(store.usage == StorageUsage(count: 15, bytes: 1_500))
        let sixth = try #require(store.videos.first { $0.id == added[5].id })
        #expect(sixth.fileURL == nil)
        // adding more evicts the others before it
        _ = try await rig.addMany(3, bytes: 100)
        #expect(rig.exists(try #require(store.videos.first { $0.id == target.id })))
        await store.reload()
        #expect(store.usage.bytes == rig.disk().bytes)
    }

    @Test func attachKeepsThePosterTheEvictionLeftBehind() async throws {
        let rig = try Rig(limit: 1_700, posterBytes: 30)           // 14 × 130 = 1 820 offered: two files go, posters stay
        let added = try await rig.addMany(14, bytes: 100)
        let target = try #require(rig.store.videos.first { $0.id == added[0].id })
        let poster = try #require(target.posterURL)
        #expect(target.fileURL == nil && FileManager.default.fileExists(atPath: poster.path))
        let refilled = try await rig.store.attach(file: try makeTempFile("x.mp4", bytes: 100), to: target.id, move: true)
        #expect(refilled.posterURL == poster && rig.exists(refilled))
    }

    @Test func attachForAnUnknownEntryThrowsAndLeavesNothingBehind() async throws {
        let rig = try Rig(limit: nil)
        _ = try await rig.add(100)
        let before = rig.disk()
        await #expect(throws: OfflineStoreError.notFound) {
            _ = try await rig.store.attach(file: try makeTempFile("x.mp4", bytes: 100), to: "nope", move: true)
        }
        #expect(rig.disk().files == before.files && rig.store.videos.count == 1)
    }

    @Test func attachingToAnEntryAnotherProcessRemovedCleansUp() async throws {
        let rig = try Rig(limit: nil)
        let one = try await rig.add(100)
        let other = OfflineStore(root: rig.root, tools: FakeTools(), defaults: rig.defaults)
        await other.remove(one.id)
        // this store still lists it; the index no longer does
        await #expect(throws: OfflineStoreError.notFound) {
            _ = try await rig.store.attach(file: try makeTempFile("x.mp4", bytes: 100), to: one.id, move: true)
        }
        #expect(rig.disk().files == 0)
    }

    @Test func attachingToAnEntryThatStillHasAFileReplacesIt() async throws {
        let rig = try Rig(limit: nil)
        let one = try await rig.add(100)
        let old = try #require(one.fileURL)
        let refilled = try await rig.store.attach(file: try makeTempFile("x.mp4", bytes: 250), to: one.id, move: true)
        #expect(!FileManager.default.fileExists(atPath: old.path) && rig.exists(refilled) && refilled.bytes == 250)
        #expect(rig.store.usage == StorageUsage(count: 1, bytes: 250) && rig.disk().files == 1)
    }
}

// MARK: - the index on disk

@MainActor
struct StorageIndexTests {
    @Test func anIndexWrittenBeforeTheLimitExistedStillDecodes() async throws {
        let root = try makeTempDirectory()
        let fm = FileManager.default
        try fm.createDirectory(at: root.appendingPathComponent("files"), withIntermediateDirectories: true)
        try fm.createDirectory(at: root.appendingPathComponent("posters"), withIntermediateDirectories: true)
        try Data(repeating: 1, count: 700).write(to: root.appendingPathComponent("files/old.mp4"))
        try Data(repeating: 2, count: 300).write(to: root.appendingPathComponent("posters/old.jpg"))
        // no addedAt, no posterBytes: what the first builds wrote
        let legacy = """
        [{"id":"old","kind":"original","fileName":"old.mp4","posterName":"old.jpg","name":"clip","duration":5,
          "width":720,"height":1280,"bytes":700,"link":"https://x.com/i/status/1","createdAt":790000000.5}]
        """
        try Data(legacy.utf8).write(to: root.appendingPathComponent("index.json"))

        let store = OfflineStore(root: root, tools: FakeTools(), defaults: freshDefaults())
        #expect(store.videos.count == 1 && store.videos[0].name == "clip" && store.videos[0].bytes == 700)
        // the poster was measured once ...
        #expect(store.usage == StorageUsage(count: 1, bytes: 1_000))
        // ... and stored, so the next load stats nothing
        let stored = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("index.json"))) as? [[String: Any]])
        #expect(stored[0]["posterBytes"] as? Int == 300)
    }

    @Test func anOldEntryWithoutAddedAtIsOrderedByItsCreationDate() async throws {
        let root = try makeTempDirectory()
        let fm = FileManager.default
        try fm.createDirectory(at: root.appendingPathComponent("files"), withIntermediateDirectories: true)
        var rows: [String] = []
        for i in 0..<15 {                                                    // index order: newest first
            let name = "f\(i).mp4"
            try Data(repeating: 1, count: 100).write(to: root.appendingPathComponent("files/\(name)"))
            rows.append(#"{"id":"e\#(i)","kind":"original","fileName":"\#(name)","name":"n","bytes":100,"createdAt":\#(800_000_000 - i * 1_000)}"#)
        }
        try Data("[\(rows.joined(separator: ","))]".utf8).write(to: root.appendingPathComponent("index.json"))
        let defaults = freshDefaults()
        let store = OfflineStore(root: root, tools: FakeTools(), defaults: defaults)
        LimitDefaults.write(1_300, to: defaults)
        await store.reload()
        // 1 500 bytes, 1 300 allowed: the two oldest by createdAt (e14, e13) lose their files
        let evicted = Set(store.videos.filter { $0.fileURL == nil }.map(\.id))
        #expect(evicted == ["e14", "e13"] && store.usage == StorageUsage(count: 13, bytes: 1_300))
    }

    @Test func usageFromTheIndexEqualsTheBytesOnDiskAfterAReconcile() async throws {
        let rig = try Rig(limit: 2_000, posterBytes: 77)
        _ = try await rig.addMany(18, bytes: 150)
        await rig.store.reload()
        let disk = rig.disk()
        #expect(rig.store.usage.bytes == disk.bytes)
        #expect(rig.store.usage.count == disk.files)
        // a manual clean-up behind the store's back is forgotten, not pointed at
        let victim = try #require(rig.store.videos.first { $0.fileURL != nil })
        try FileManager.default.removeItem(at: try #require(victim.fileURL))
        let reopened = OfflineStore(root: rig.root, tools: FakeTools(), defaults: rig.defaults)
        #expect(reopened.usage.bytes == rig.disk().bytes && reopened.usage.count == rig.disk().files)
    }

    @Test func theInboxDoesNotCount() async throws {
        let rig = try Rig(limit: 100)
        let inbox = rig.store.inboxURL(for: "incoming.mov")
        try Data(repeating: 1, count: 5_000).write(to: inbox)
        #expect(rig.store.usage == StorageUsage(count: 0, bytes: 0))
        _ = try await rig.add(50)
        #expect(rig.store.usage == StorageUsage(count: 1, bytes: 50))
    }

    @Test func previewStoresStillShowTheirCannedUsage() {
        let app = AppModel.preview(.happy)
        #expect(app.store.usage == StorageUsage(count: 13, bytes: 54_000_000))
    }
}

// MARK: - two processes

@MainActor
struct StorageConcurrencyTests {
    @Test func twoStoresAddingConcurrentlyEndWithinTheLimitAndLoseNothing() async throws {
        let rig = try Rig(limit: 1_500)
        let app = rig.store
        let tick = rig.clock
        let extensionSide = OfflineStore(root: rig.root, tools: FakeTools(), defaults: rig.defaults, now: { tick.now() })

        let ids = await withTaskGroup(of: [String].self) { group in
            for (store, tag) in [(app, 0), (extensionSide, 1)] {
                group.addTask {
                    var mine: [String] = []
                    for i in 0..<25 {
                        let file = try? makeTempFile("c\(tag)-\(i).mp4", bytes: 100)
                        guard let file,
                              let v = try? await store.add(file: file, kind: .original, media: media, sessionID: nil,
                                                           link: nil, remoteURL: nil, move: true)
                        else { continue }
                        mine.append(v.id)
                    }
                    return mine
                }
            }
            var all: [String] = []
            for await part in group { all += part }
            return all
        }
        #expect(ids.count == 50)

        await app.reload()
        await extensionSide.reload()
        for store in [app, extensionSide] {
            #expect(Set(store.videos.map(\.id)) == Set(ids))                 // no lost records
            #expect(store.usage.bytes <= 1_500)                              // within the limit
            #expect(store.usage.bytes == rig.disk().bytes)
            for v in store.videos { if let url = v.fileURL { #expect(FileManager.default.fileExists(atPath: url.path), "\(v.id) points at a missing file") } }
        }
        #expect(rig.disk().files == app.usage.count)                         // and no orphan files
        #expect(OfflineStore(root: rig.root, tools: FakeTools(), defaults: rig.defaults).videos.count == 50)
    }

    @Test func aReaderNeverSeesARecordPointingAtADeletedFile() async throws {
        // the index is written before the files go: read the index right after every add
        let rig = try Rig(limit: 500)
        let reader = OfflineStore(root: rig.root, tools: FakeTools(), defaults: rig.defaults)
        for _ in 0..<30 {
            try await rig.add(100)
            await reader.reload()
            for v in reader.videos { if let url = v.fileURL { #expect(FileManager.default.fileExists(atPath: url.path)) } }
        }
    }
}

// MARK: - pins from the pipeline, and the re-download path

@MainActor
struct StoragePipelineTests {
    @Test func theFrameSourceIsPinnedUntilTheNextRunBegins() async throws {
        let h = Harness(.happy)
        let store = h.ctx.store
        let video = try await store.add(
            file: try makeTempFile("src.mp4", bytes: 100), kind: .original, media: media, sessionID: "sid-pin",
            link: nil, remoteURL: nil, move: true)
        guard case .local = h.pipeline.sourceInput(session: "sid-pin") else { Issue.record("expected the local file"); return }
        #expect(store.pinnedIDs == [video.id])
        h.pipeline.begin(input: nil)
        #expect(store.pinnedIDs.isEmpty)
        // a file the store does not have pins nothing
        guard case .remote = h.pipeline.sourceInput(session: "other") else { Issue.record("expected the server source"); return }
        #expect(store.pinnedIDs.isEmpty)
    }

    private func evictedLibrary(keep: Bool = true, scenario: PreviewScenario = .happy) -> (AppModel, Log<RemoteFile>) {
        let app = AppModel.makePreview(scenario, timeScale: 1, clock: SystemClock())
        app.settings.keepVideosOnDevice = keep
        let calls = Log<RemoteFile>()
        var stub = ScriptedClient(base: app.ctx.client)
        stub.downloadHook = { file, dest in
            calls.add(file)
            try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(repeating: 3, count: 4_096).write(to: dest)
            return dest
        }
        app.ctx.client = stub
        return (app, calls)
    }

    @Test func aLibraryCopyOfAnEvictedVideoDownloadsAgainAndRefillsTheSameRecord() async throws {
        let (app, calls) = evictedLibrary()
        let library = app.library
        let store = app.store
        let file = library.posts[0].files[1]                                 // private copy of Dd55fEyN1Yy
        let seeded = try #require(store.videos.first { $0.id == "preview-orbit-1" })
        #expect(seeded.fileURL == nil && seeded.link == library.posts[0].link)   // the orbit entry is evicted
        let count = store.videos.count

        let url = try await library.localCopy(file)
        #expect(calls.all.count == 1)
        #expect(FileManager.default.fileExists(atPath: url.path))
        #expect(url.path.hasPrefix(store.root.appendingPathComponent("files").path))     // in the store, not a temp copy
        let refilled = try #require(store.videos.first { $0.id == "preview-orbit-1" })
        #expect(refilled.fileURL == url)
        #expect(store.videos.count == count)                                 // no duplicate entry
        #expect(store.videos.filter { $0.link == library.posts[0].link }.count == 1)

        // now it is local: no second download
        let again = try await library.localCopy(file)
        #expect(again == url && calls.all.count == 1)
    }

    @Test func withKeepingTurnedOffTheCopyStaysATemporaryFile() async throws {
        let (app, calls) = evictedLibrary(keep: false)
        let url = try await app.library.localCopy(app.library.posts[0].files[1])
        #expect(calls.all.count == 1 && FileManager.default.fileExists(atPath: url.path))
        #expect(!url.path.hasPrefix(app.store.root.appendingPathComponent("files").path))
        #expect(app.store.videos.first { $0.id == "preview-orbit-1" }?.fileURL == nil)
    }

    @Test func aPostWithNoStoredEntryDownloadsATemporaryCopyAsBefore() async throws {
        // `.coldStart` seeds the orbit only: `.happy` also holds Dd7P496wolG (the media with three webps)
        let (app, calls) = evictedLibrary(scenario: .coldStart)
        let url = try await app.library.localCopy(app.library.posts[1].files[1])   // Dd7P496wolG: not in the orbit
        #expect(calls.all.count == 1 && !url.path.hasPrefix(app.store.root.appendingPathComponent("files").path))
        #expect(app.store.videos.count == 7)
    }
}
