import CoreGraphics
import Foundation
import Synchronization
import Testing
@testable import CobaltKit

// CONTRACT-MEDIA.md section 9, the store half: one media per source, resolved inside the coordinated
// index write; the one-time legacy migration; eviction by media; removal; the merged `MediaItem`.

/// A poster of 50 bytes, no flipbook, no decoding: sizes are exactly what a test adds.
struct MediaTestTools: MediaTools {
    func probe(file: URL) async -> MediaInfo? { nil }
    func frames(of input: FrameInput, duration: Double?, count: Int) -> AsyncThrowingStream<Frame, Error> {
        AsyncThrowingStream { $0.finish() }
    }
    func poster(for file: URL, isImage: Bool, to destination: URL) async -> Bool {
        try? FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        return (try? Data(repeating: 9, count: 50).write(to: destination)) != nil
    }
}

/// An injected clock: every call is one minute after the last, so `createdAt` and `addedAt` always differ.
final class MediaStamps: Sendable {
    private let n = Mutex(0)
    let epoch = Date(timeIntervalSince1970: 1_800_000_000)
    func next() -> Date { epoch.addingTimeInterval(Double(n.withLock { v -> Int in v += 1; return v }) * 60) }
}

private let sampleInfo = MediaInfo(name: "clip", duration: 6, width: 96, height: 160, bytes: nil, isImage: false)

@MainActor
struct MediaRig {
    let root: URL
    let defaults: UserDefaults
    let stamps = MediaStamps()
    let store: OfflineStore

    init(root: URL? = nil, limit: Int64? = nil) throws {
        let suite = "cobalt.media.test.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite) ?? .standard
        defaults.removePersistentDomain(forName: suite)
        LimitDefaults.write(limit, to: defaults)
        self.defaults = defaults
        self.root = try root ?? makeTempDirectory()
        let stamps = self.stamps
        self.store = OfflineStore(root: self.root, tools: MediaTestTools(), defaults: defaults, now: { stamps.next() })
    }

    /// A second process on the same folder (the share extension) with its own clock.
    func otherProcess() -> OfflineStore {
        let stamps = self.stamps
        return OfflineStore(root: root, tools: MediaTestTools(), defaults: defaults, now: { stamps.next() })
    }

    @discardableResult
    func add(
        _ kind: StoredVideo.Kind, session: String? = nil, link: URL? = nil, url: URL? = nil, bytes: Int = 1_000,
        mediaID: String? = nil, clip: WebpClip? = nil, to target: OfflineStore? = nil
    ) async throws -> StoredVideo {
        try await (target ?? store).add(
            file: try makeTempFile(kind == .webp ? "w.webp" : "o.mp4", bytes: bytes), kind: kind, media: sampleInfo,
            sessionID: session, link: link, remoteURL: url, move: true, mediaID: mediaID, clip: clip)
    }
}

func webpURL(_ name: String) -> URL { URL(string: "https://media.capybaraharmony.com/\(name).webp")! }
let postLink = URL(string: "https://www.instagram.com/reel/Dd7P496wolG/")!

// MARK: - grouping

@MainActor
struct MediaGroupingTests {
    @Test func anOriginalAndItsWebpsOfOneSessionAreOneMedia() async throws {
        let r = try MediaRig()
        let clip = WebpClip(start: 2, length: 10, crop: CropRect(x: 0, y: 0.2, w: 1, h: 0.5), quality: .high, width: 480)
        let o = try await r.add(.original, session: "S1", link: postLink, clip: clip)         // a clip on an original is dropped
        let w1 = try await r.add(.webp, session: "S1", link: postLink, url: webpURL("AaAaAaAaA1"), clip: clip)
        let w2 = try await r.add(.webp, session: "S1", link: postLink, url: webpURL("AaAaAaAaA2"))

        #expect(r.store.media.count == 1)
        let m = try #require(r.store.media.first)
        #expect(m.id == o.id && m.original?.id == o.id && m.webps.map(\.id) == [w1.id, w2.id])
        #expect(m.face.id == w2.id)                                       // the newest webp
        #expect(m.latestAt == w2.createdAt && m.renditions.map(\.id) == [o.id, w1.id, w2.id])
        #expect([o, w1, w2].allSatisfy { $0.mediaID == o.id })
        #expect(o.clip == nil && w1.clip == clip && w2.clip == nil)
        #expect(m.title == o.name && m.link == postLink && m.sessionIDs == ["S1"] && !m.isHosted)

        #expect(r.store.media(id: o.id) == m && r.store.media(session: "S1") == m && r.store.media(containing: w2.id) == m)
        #expect(r.store.media(id: "nope") == nil && r.store.media(session: "nope") == nil && r.store.media(containing: "nope") == nil)
        #expect(r.store.latestMedia(5) == [m] && r.store.latestMedia(0).isEmpty)
        #expect(r.store.videos.count == 3)                                // records are still one per file
    }

    @Test func aNewWebpOnAnOldMediaMakesItTheNewestAndTheFaceFallsBack() async throws {
        let r = try MediaRig()
        let first = try await r.add(.original, session: "S1")
        let second = try await r.add(.original, session: "S2")
        #expect(r.store.media.map(\.id) == [second.id, first.id])         // latest activity first
        let w = try await r.add(.webp, session: "S1", url: webpURL("BbBbBbBbB1"))
        #expect(r.store.media.map(\.id) == [first.id, second.id])
        #expect(r.store.media[0].face.id == w.id && r.store.media[1].face.id == second.id)
        // a media without webps has the video for its face
        #expect(r.store.media[1].webps.isEmpty && r.store.media[1].original?.id == second.id)
    }

    @Test func aWebpAddedBeforeItsOriginalStillMakesOneMedia() async throws {
        let r = try MediaRig()
        let w = try await r.add(.webp, session: "S1", url: webpURL("CcCcCcCcC1"))      // keep-original lands late
        #expect(r.store.media.count == 1 && r.store.media[0].original == nil && r.store.media[0].id == w.id)
        #expect(r.store.media[0].title == "clip" && r.store.media[0].face.id == w.id)
        let o = try await r.add(.original, session: "S1")
        #expect(r.store.media.count == 1)
        let m = try #require(r.store.media.first)
        #expect(m.id == w.id && m.original?.id == o.id && o.mediaID == w.id && m.webps.map(\.id) == [w.id])
    }

    @Test func anExplicitMediaFromAReopenedSessionJoinsAndASecondOriginalIsItsOwnMedia() async throws {
        let r = try MediaRig()
        let o = try await r.add(.original, session: "SESSION-A", link: postLink)
        let m = o.mediaID
        // the session expired; the library reopened the video as SESSION-B and a webp was made from it
        let reopened = try await r.add(.webp, session: "SESSION-B", url: webpURL("DdDdDdDdD1"), mediaID: m)
        #expect(reopened.mediaID == m && r.store.media.count == 1)
        #expect(r.store.media[0].sessionIDs == ["SESSION-A", "SESSION-B"])
        // an original aimed at a media that already has one: its own media (at most one original per media)
        let second = try await r.add(.original, session: "SESSION-C", mediaID: m)
        #expect(second.mediaID == second.id && r.store.media.count == 2)
        #expect(r.store.media(id: m)?.original?.id == o.id)
        // the same rule keeps an original that shares a session with such a media out of it
        let again = try await r.add(.original, session: "SESSION-B", link: postLink)
        #expect(again.mediaID == again.id && r.store.media(id: m)?.original?.id == o.id)
        // an explicit media that no longer exists falls through to the session / a new media
        let orphan = try await r.add(.webp, session: nil, url: webpURL("DdDdDdDdD2"), mediaID: "gone")
        #expect(orphan.mediaID == orphan.id)
    }

    @Test func twoProcessesAddingOneSessionConcurrentlyNeverSplitTheMedia() async throws {
        let r = try MediaRig()
        let ext = r.otherProcess()
        for i in 0..<8 {
            let sid = "RACE\(i)"
            async let a: StoredVideo = r.add(.original, session: sid, link: postLink, to: r.store)
            async let b: StoredVideo = r.add(.webp, session: sid, link: postLink, url: webpURL("EeEeEeEeE\(i)"), to: ext)
            let (original, webp) = try await (a, b)
            #expect(original.mediaID == webp.mediaID, "round \(i): the extension and the app agree on one media")
        }
        await r.store.reload()
        await ext.reload()
        for store in [r.store, ext, r.otherProcess()] {
            #expect(store.media.count == 8 && store.media.allSatisfy { $0.original != nil && $0.webps.count == 1 })
        }
    }

    @Test func recordsOfOnePostWithoutASessionStayApart() async throws {
        let r = try MediaRig()
        // two plain saves of one link are two copies the owner asked for: two media
        let a = try await r.add(.original, link: postLink)
        let b = try await r.add(.original, link: postLink)
        #expect(a.mediaID == a.id && b.mediaID == b.id && r.store.media.count == 2)
        #expect(r.store.usage.mediaCount == 2)
    }

    @Test func removingTheNewestWebpFallsBackToTheNextThenToTheVideo() async throws {
        let r = try MediaRig()
        let o = try await r.add(.original, session: "S1")
        let w1 = try await r.add(.webp, session: "S1", url: webpURL("FfFfFfFfF1"))
        let w2 = try await r.add(.webp, session: "S1", url: webpURL("FfFfFfFfF2"))
        #expect(r.store.media[0].face.id == w2.id)
        await r.store.remove(w2.id)
        #expect(r.store.media[0].face.id == w1.id)
        await r.store.remove(w1.id)
        #expect(r.store.media[0].face.id == o.id && r.store.media[0].webps.isEmpty)
        await r.store.remove(o.id)
        #expect(r.store.media.isEmpty)
    }

    @Test func aMediaIsHostedWhenItsOriginalWasShared() async throws {
        let r = try MediaRig()
        let o = try await r.add(.original, session: "S1")
        #expect(r.store.setPublicURL(webpURL("GgGgGgGgG1"), forSession: "S1") == 1)
        #expect(r.store.media(id: o.mediaID)?.isHosted == true)
    }
}

// MARK: - flipbooks of media

/// Makes frames and says which file it was asked for, in order.
private struct LoggingFrameTools: MediaTools {
    let log: Log<String>
    func probe(file: URL) async -> MediaInfo? { nil }
    func frames(of input: FrameInput, duration: Double?, count: Int) -> AsyncThrowingStream<Frame, Error> {
        AsyncThrowingStream { $0.finish() }
    }
    func poster(for file: URL, isImage: Bool, to destination: URL) async -> Bool { false }
    func previewFrames(of file: URL, animatedImage: Bool, count: Int, maxEdge: CGFloat) async -> [CGImage] {
        log.add(file.lastPathComponent)
        return (0..<3).compactMap { _ in PreviewMedia.gradient(width: 48, height: 32) }
    }
}

@MainActor
struct MediaBackfillTests {
    @Test func theBackfillMakesTheFacesOfTheNewestMediaFirstThenTheirOriginals() async throws {
        let r = try MediaRig()                                         // no frames made at add
        let oldVideo = try await r.add(.original, session: "A")
        let oldWebp = try await r.add(.webp, session: "A", url: webpURL("TtTtTtTtT1"))
        let newVideo = try await r.add(.original, session: "B")
        let newWebp = try await r.add(.webp, session: "B", url: webpURL("TtTtTtTtT2"))
        #expect(r.store.videos.allSatisfy { $0.previewFrameURLs.isEmpty })
        let log = Log<String>()
        let stamps = r.stamps
        let store = OfflineStore(root: r.root, tools: LoggingFrameTools(log: log), defaults: r.defaults, now: { stamps.next() })
        await store.backfillPreviewFrames()
        let names = [newWebp, oldWebp, newVideo, oldVideo].map { $0.fileURL?.lastPathComponent ?? "" }
        #expect(log.all == names, "faces newest media first, then their originals")
        #expect(store.videos.allSatisfy { $0.previewFrameURLs.count == 3 })
    }
}

// MARK: - removeMedia

@MainActor
struct RemoveMediaTests {
    private func exists(_ url: URL?) -> Bool { url.map { FileManager.default.fileExists(atPath: $0.path) } ?? false }

    @Test func removeMediaRemovesEveryRecordFileAndPoster() async throws {
        let r = try MediaRig()
        let o = try await r.add(.original, session: "S1")
        let w = try await r.add(.webp, session: "S1", url: webpURL("HhHhHhHhH1"))
        let other = try await r.add(.original, session: "S2")
        let files = [o, w].compactMap(\.fileURL) + [o, w].compactMap(\.posterURL)
        #expect(files.count == 4 && files.allSatisfy { exists($0) })
        #expect(await r.store.removeMedia(o.mediaID))
        #expect(r.store.videos.map(\.id) == [other.id] && r.store.media.map(\.id) == [other.id])
        #expect(files.allSatisfy { !exists($0) } && exists(other.fileURL))
        #expect(r.otherProcess().videos.map(\.id) == [other.id])                          // written to the index
        #expect(await r.store.removeMedia("unknown") == false)
    }

    @Test func removeMediaRefusesWhenARenditionIsPinned() async throws {
        let r = try MediaRig()
        let o = try await r.add(.original, session: "S1")
        let w = try await r.add(.webp, session: "S1", url: webpURL("IiIiIiIiI1"))
        r.store.pin(w.id)                                              // a run reads frames from it
        #expect(await r.store.removeMedia(o.mediaID) == false)
        #expect(r.store.videos.count == 2 && exists(o.fileURL) && exists(w.fileURL))
        r.store.unpin(w.id)
        #expect(await r.store.removeMedia(o.mediaID))
        #expect(r.store.videos.isEmpty)
    }
}

// MARK: - eviction by media

@MainActor
struct MediaEvictionTests {
    @Test func theNewestTwelveMediaAreProtectedWholeAndOlderOnesLoseFilesThenGoWhole() async throws {
        let r = try MediaRig()                                          // no limit while adding
        var firstTwo: [String] = []
        for i in 0..<14 {                                              // 14 media of 2 records, oldest first
            let o = try await r.add(.original, session: "S\(i)", bytes: 1_000)
            let w = try await r.add(.webp, session: "S\(i)", url: webpURL("JjJjJjJj\(String(format: "%02d", i))"), bytes: 500)
            if i < 2 { firstTwo += [o.id, w.id] }
        }
        #expect(r.store.media.count == 14 && r.store.usage.mediaCount == 14 && r.store.usage.count == 28)
        await r.store.setLimit(10)                                      // far under what the 12 protected media cost
        #expect(r.store.media.count == 12)                              // phase 2 dropped the two oldest media whole
        #expect(firstTwo.allSatisfy { id in !r.store.videos.contains { $0.id == id } })
        #expect(r.store.videos.count == 24 && r.store.videos.allSatisfy { $0.fileURL != nil })   // every file of the 12 kept
        #expect(r.store.usage.mediaCount == 12 && r.store.usage.count == 24)
    }

    @Test func phaseOneDropsFilesOldestFirstAndKeepsTheRecordsOfAPartlyKeptMedia() async throws {
        let r = try MediaRig()
        let old = try await r.add(.original, session: "OLD", bytes: 1_000)
        let oldWebp = try await r.add(.webp, session: "OLD", url: webpURL("KkKkKkKkK1"), bytes: 1_000)
        for i in 0..<12 { try await r.add(.original, session: "N\(i)", bytes: 100) }            // 12 newer media
        r.store.pin(oldWebp.id)                                         // a run holds the old webp
        // room for the 12 newer ones (100 + 50 poster each) and the pinned webp, not the old original
        await r.store.setLimit(12 * 150 + 1_050 + 50)
        let o = try #require(r.store.videos.first { $0.id == old.id })
        let w = try #require(r.store.videos.first { $0.id == oldWebp.id })
        #expect(o.fileURL == nil && o.posterURL != nil)                 // the original's file went; record and poster stay
        #expect(w.fileURL != nil)                                       // pinned: never evicted
        #expect(r.store.media(id: old.mediaID)?.renditions.count == 2)  // a media with a kept file keeps all its records
        #expect(r.store.usage.mediaCount == 13)                         // the old media still has one file
    }

    @Test func phaseTwoNeverDropsAMediaThatStillHasAFileOrIsPinned() async throws {
        let r = try MediaRig()
        let a = try await r.add(.original, session: "A", bytes: 1_000)                // the oldest media...
        let aWebp = try await r.add(.webp, session: "A", url: webpURL("LlLlLlLlL1"), bytes: 1_000)
        let b = try await r.add(.original, session: "B", bytes: 1_000)                // ...and a plain old one
        for i in 0..<12 { try await r.add(.original, session: "N\(i)", bytes: 100) }
        r.store.pin(aWebp.id)
        await r.store.setLimit(10)
        #expect(r.store.videos.contains { $0.id == a.id } && r.store.videos.contains { $0.id == aWebp.id })   // kept whole (pinned file)
        #expect(!r.store.videos.contains { $0.id == b.id })             // file-less and unprotected: dropped whole
        #expect(r.store.videos.first { $0.id == a.id }?.fileURL == nil)
        #expect(r.store.videos.first { $0.id == aWebp.id }?.fileURL != nil)
        r.store.unpin(aWebp.id)
    }

    @Test func aRefilledMediaCountsAsRecentForEviction() async throws {
        let r = try MediaRig()
        let old = try await r.add(.original, session: "OLD", bytes: 1_000)
        for i in 0..<12 { try await r.add(.original, session: "N\(i)", bytes: 100) }
        await r.store.setLimit(12 * 150 + 50)                           // only the old one's file has to go
        #expect(r.store.videos.first { $0.id == old.id }.map { $0.fileURL == nil } == true)
        let refilled = try await r.store.attach(file: try makeTempFile("again.mp4", bytes: 1_000), to: old.id, move: true)
        #expect(refilled.fileURL != nil)
        await r.store.enforceLimit()                                    // protected as one of the newest 12 media now
        #expect(r.store.videos.first { $0.id == old.id }?.fileURL != nil)
    }

    @Test func usageCountsMediaWithAFileNotRecords() async throws {
        let r = try MediaRig()
        let o = try await r.add(.original, session: "S1", bytes: 1_000)
        try await r.add(.webp, session: "S1", url: webpURL("MmMmMmMmM1"), bytes: 500)
        try await r.add(.webp, session: "S1", url: webpURL("MmMmMmMmM2"), bytes: 500)
        try await r.add(.original, session: "S2", bytes: 100)
        #expect(r.store.usage.count == 4 && r.store.usage.mediaCount == 2)
        #expect(r.store.usage == StorageUsage(count: 4, bytes: 2_100 + 4 * 50, mediaCount: 2))
        r.store.usageBase = StorageUsage(count: 13, bytes: 54_000_000)  // previews: "13 videos"
        #expect(r.store.usage.mediaCount == 15 && r.store.usage.count == 17)
        #expect(StorageUsage(count: 3, bytes: 1).mediaCount == 3)       // one record per media unless said
        _ = o
    }
}

// MARK: - migration of an index written before media existed

@MainActor
struct MediaMigrationTests {
    private func record(
        _ id: String, _ kind: String, session: String? = nil, link: String? = nil, url: String? = nil, at: Double,
        file: Bool = false
    ) -> [String: Any] {
        var d: [String: Any] = ["id": id, "kind": kind, "name": id, "bytes": 100, "createdAt": at]
        if let session { d["sessionID"] = session }
        if let link { d["link"] = link }
        if let url { d["remoteURL"] = url }
        if file {
            d["fileName"] = "\(id).mp4"
            d["posterName"] = "\(id).jpg"
            d["posterBytes"] = 10
        }
        return d
    }

    private let l1 = "https://www.instagram.com/reel/AAA/"
    private let l2 = "https://www.instagram.com/reel/BBB/"
    private let l3 = "https://www.instagram.com/reel/CCC/"
    private let l4 = "https://www.instagram.com/reel/DDD/"

    /// Newest first, the way an index is written.
    private func fixture() -> [[String: Any]] {
        [
            record("orphan", "webp", session: "s6", url: "https://media.capybaraharmony.com/OrphanWebp.webp", at: 700),
            record("pick2", "original", link: l4, at: 610),
            record("pick1", "original", link: l4, at: 600),
            record("w3", "webp", session: "s5", link: l3, url: "https://media.capybaraharmony.com/AmbiguousW.webp", at: 520),
            record("c2", "original", session: "s4", link: l3, at: 510),
            record("c1", "original", session: "s3", link: l3, at: 500),
            record("reopened", "webp", session: "s9", link: l2, url: "https://media.capybaraharmony.com/ReopenedWb.webp", at: 400),
            record("b-w", "webp", session: "s2", link: l2, url: "https://media.capybaraharmony.com/BBBBBBBBBB.webp", at: 310),
            record("b", "original", session: "s2", link: l2, at: 300),
            record("a-w2", "webp", session: "s1", link: l1, url: "https://media.capybaraharmony.com/AAAAAAAAA2.webp", at: 220, file: true),
            record("a-w1", "webp", session: "s1", link: l1, url: "https://media.capybaraharmony.com/AAAAAAAAA1.webp", at: 210, file: true),
            record("a", "original", session: "s1", link: l1, at: 200, file: true),
        ]
    }

    private func install(_ records: [[String: Any]], in root: URL) throws {
        let fm = FileManager.default
        for d in records where d["fileName"] != nil {
            for (sub, key) in [("files", "fileName"), ("posters", "posterName")] {
                let dir = root.appendingPathComponent(sub, isDirectory: true)
                try fm.createDirectory(at: dir, withIntermediateDirectories: true)
                try Data(repeating: 5, count: 20).write(to: dir.appendingPathComponent(d[key] as! String))
            }
        }
        try JSONSerialization.data(withJSONObject: records).write(to: root.appendingPathComponent("index.json"))
    }

    private func indexData(_ root: URL) throws -> Data { try Data(contentsOf: root.appendingPathComponent("index.json")) }

    private func ids(_ store: OfflineStore) -> [String: String] {
        Dictionary(uniqueKeysWithValues: store.videos.map { ($0.id, $0.mediaID) })
    }

    @Test func aLegacyIndexIsGroupedByTheContractsRules() async throws {
        let root = try makeTempDirectory()
        try install(fixture(), in: root)
        let store = OfflineStore(root: root, tools: MediaTestTools(), defaults: UserDefaults(suiteName: "cobalt.media.mig.\(UUID().uuidString)") ?? .standard)
        let m = ids(store)
        #expect(m["a"] == "a" && m["a-w1"] == "a" && m["a-w2"] == "a")                  // one session: the original leads
        #expect(m["b"] == "b" && m["b-w"] == "b")
        #expect(m["reopened"] == "b", "a reopened session's webp joins the one original with its link")
        #expect(m["c1"] == "c1" && m["c2"] == "c2")                                      // two originals: two media
        #expect(m["w3"] == "w3", "the same link on two originals is ambiguous: it stays apart")
        #expect(m["pick1"] == "pick1" && m["pick2"] == "pick2")                          // no session: each its own
        #expect(m["orphan"] == "orphan")                                                 // a webp with no original and no link
        #expect(store.media.count == 8)
        #expect(Set(store.media.map(\.id)) == ["a", "b", "c1", "c2", "w3", "pick1", "pick2", "orphan"])
    }

    @Test func theMigrationOnlyAddsMediaIDsAndNeverReordersOrTouchesAFile() async throws {
        let root = try makeTempDirectory()
        let before = fixture()
        try install(before, in: root)
        let filesBefore = try ["files/a.mp4", "files/a-w1.mp4", "posters/a.jpg", "posters/a-w2.jpg"].map { path -> Data in
            try Data(contentsOf: root.appendingPathComponent(path))
        }
        let store = OfflineStore(root: root, tools: MediaTestTools(), defaults: UserDefaults(suiteName: "cobalt.media.mig2.\(UUID().uuidString)") ?? .standard)
        #expect(store.videos.map(\.id) == before.map { $0["id"] as! String })              // never reordered
        let after = try #require(try JSONSerialization.jsonObject(with: indexData(root)) as? [[String: Any]])
        #expect(after.count == before.count)
        for (old, new) in zip(before, after) {
            var stripped = new
            #expect(stripped.removeValue(forKey: "mediaID") is String, "\(old["id"] ?? "")")
            #expect(NSDictionary(dictionary: stripped).isEqual(to: old), "only mediaID was added to \(old["id"] ?? "")")
        }
        // no file touched: the same bytes are still where they were
        let filesAfter = try ["files/a.mp4", "files/a-w1.mp4", "posters/a.jpg", "posters/a-w2.jpg"].map { path -> Data in
            try Data(contentsOf: root.appendingPathComponent(path))
        }
        #expect(filesBefore == filesAfter)
        #expect(store.videos.first { $0.id == "a" }?.fileURL != nil)
    }

    @Test func aSecondInstanceAndASecondRunGiveTheSameIdsAndWriteNothingMore() async throws {
        let rootA = try makeTempDirectory()
        let rootB = try makeTempDirectory()
        try install(fixture(), in: rootA)
        try install(fixture(), in: rootB)
        let defaults = UserDefaults(suiteName: "cobalt.media.mig3.\(UUID().uuidString)") ?? .standard
        let first = OfflineStore(root: rootA, tools: MediaTestTools(), defaults: defaults)
        let written = try indexData(rootA)
        let second = OfflineStore(root: rootA, tools: MediaTestTools(), defaults: defaults)          // another process
        await second.reload()
        let elsewhere = OfflineStore(root: rootB, tools: MediaTestTools(), defaults: defaults)       // another run, same input
        #expect(ids(first) == ids(second) && ids(first) == ids(elsewhere))
        #expect(try indexData(rootA) == written, "an index that already has its media ids is not rewritten")
    }

    @Test func aRecordAnOlderBuildWroteLaterJoinsTheMediaOfItsSession() async throws {
        let root = try makeTempDirectory()
        let defaults = UserDefaults(suiteName: "cobalt.media.mig4.\(UUID().uuidString)") ?? .standard
        try install(fixture(), in: root)
        let store = OfflineStore(root: root, tools: MediaTestTools(), defaults: defaults)          // migrated
        // an old build of the share extension appends a webp of session s2 with no media id
        var index = try #require(try JSONSerialization.jsonObject(with: indexData(root)) as? [[String: Any]])
        index.insert(record("late", "webp", session: "s2", link: l2, url: "https://media.capybaraharmony.com/LateWebpAA.webp", at: 800), at: 0)
        try JSONSerialization.data(withJSONObject: index).write(to: root.appendingPathComponent("index.json"))
        await store.reload()
        #expect(ids(store)["late"] == "b" && store.media(id: "b")?.webps.map(\.id).contains("late") == true)
    }

    @Test func recordsCodableRoundTripAndAnOldRecordDecodes() throws {
        let clip = WebpClip(start: 1.5, length: 8, crop: CropRect(x: 0.1, y: 0.2, w: 0.5, h: 0.6), quality: .low, width: 320)
        let v = StoredVideo(
            id: "x", kind: .webp, fileURL: nil, posterURL: nil, name: "n.webp", duration: 8, width: 320, height: 240,
            bytes: 10, sessionID: "S", link: postLink, remoteURL: webpURL("NnNnNnNnN1"),
            createdAt: Date(timeIntervalSince1970: 1_800_000_000), mediaID: "M", clip: clip)
        let data = try JSONEncoder().encode(v)
        #expect(try JSONDecoder().decode(StoredVideo.self, from: data) == v)
        // an entry written before media existed: no keys, and the media id reads as its own id
        var object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        object.removeValue(forKey: "mediaID")
        object.removeValue(forKey: "clip")
        let old = try JSONDecoder().decode(StoredVideo.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(old.mediaID == "x" && old.clip == nil && old.name == "n.webp")
        #expect(StoredVideo(id: "y", kind: .original, fileURL: nil, posterURL: nil, name: "", duration: nil, width: nil, height: nil,
                            bytes: 0, sessionID: nil, link: nil, remoteURL: nil, createdAt: .now, mediaID: "").mediaID == "y")
    }
}

// MARK: - photos ledger keys

@MainActor
struct MediaPhotosKeyTests {
    @Test func photosKeysStayPerFileWhateverTheMediaIs() async throws {
        let r = try MediaRig()
        let o = try await r.add(.original, session: "S1", link: postLink)
        let w = try await r.add(.webp, session: "S1", url: webpURL("OoOoOoOoO1"))
        let reopened = try await r.add(.webp, session: "S2", url: webpURL("OoOoOoOoO2"), mediaID: o.mediaID)
        let picker = try await r.add(.original, link: postLink, url: URL(string: "https://api.capybaraharmony.com/tunnel?id=p0"))
        let plain = try await r.add(.original, link: postLink)
        let bare = try await r.add(.webp, session: "S3")
        #expect(PhotosKey.of(o) == "s:S1")
        #expect(PhotosKey.of(w) == "w:https://media.capybaraharmony.com/OoOoOoOoO1.webp")
        #expect(PhotosKey.of(reopened) == "w:https://media.capybaraharmony.com/OoOoOoOoO2.webp")
        #expect(PhotosKey.of(picker) == "r:https://api.capybaraharmony.com/tunnel?id=p0")
        #expect(PhotosKey.of(plain) == "i:\(plain.id)" && PhotosKey.of(bare) == "i:\(bare.id)")
        // the key does not move with the record being re-read after a migration or a reload
        await r.store.reload()
        for v in r.store.videos { #expect(PhotosKey.of(v) == PhotosKey.of(kind: v.kind, sessionID: v.sessionID, remoteURL: v.remoteURL, storeID: v.id)) }
        #expect(r.store.videos.first { $0.id == o.id }.map(PhotosKey.of) == "s:S1")
    }
}

// MARK: - MediaItem.merge

private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

private func sv(
    _ id: String, _ kind: StoredVideo.Kind, session: String? = nil, url: URL? = nil, at: Double, link: URL? = postLink,
    mediaID: String = "M", clip: WebpClip? = nil, publicURL: URL? = nil
) -> StoredVideo {
    StoredVideo(
        id: id, kind: kind, fileURL: nil, posterURL: nil, name: kind == .webp ? "x.webp" : "x", duration: 10, width: 480, height: 854,
        bytes: 1_000, sessionID: session, link: link, remoteURL: url, createdAt: t0.addingTimeInterval(at),
        publicURL: publicURL, mediaID: mediaID, clip: clip)
}

private func lf(
    _ id: String, _ kind: LibraryFile.Kind, name: String, url: URL?, type: String, at: Double, mediaName: String? = nil,
    deletable: Bool = false
) -> LibraryFile {
    LibraryFile(
        id: id, kind: kind, source: kind == .private ? .saved : .studio, name: name, url: url, contentType: type, bytes: 2_000,
        width: 480, height: 854, duration: 10, createdAt: t0.addingTimeInterval(at), mediaName: mediaName, deletable: deletable)
}

private func post(
    id: String = "POST", session: String? = nil, files: [LibraryFile], link: URL? = postLink
) -> LibraryPost {
    LibraryPost(
        id: id, service: "instagram", link: link, title: "instagram_Dd7P496wolG", duration: 14.77, width: 720, height: 1280,
        createdAt: t0, session: session.map { LibrarySession(id: $0, status: .ready, expiresAt: t0.addingTimeInterval(86_400), sourceURL: URL(string: "https://x/s")!) },
        files: files)
}

struct MediaItemMergeTests {
    @Test func aLocalWebpAndAPostFileWithOneURLAreOneRendition() throws {
        let url = webpURL("PpPpPpPpP1")
        let local = try #require(StoredMedia(id: "M", original: sv("o", .original, session: "S1", at: 0), webps: [sv("w", .webp, session: "S1", url: url, at: 10)]))
        let file = lf("F1", .public, name: "x.webp", url: url, type: "image/webp", at: 11, mediaName: "PpPpPpPpP1.webp", deletable: true)
        let item = try #require(MediaItem.merge(local: local, post: post(files: [file])))
        #expect(item.renditions.map(\.id) == ["video", "w"])
        let webp = item.renditions[1]
        #expect(webp.local?.id == "w" && webp.file?.id == "F1" && webp.publicURL == url && webp.kind == .webp(number: 1))
        #expect(webp.deletableName == "PpPpPpPpP1.webp" && webp.createdAt == t0.addingTimeInterval(11))   // the server's time
        #expect(item.id == "M" && item.face.id == "w" && item.webpCount == 1 && item.service == "instagram" && item.ref == "Dd7P496wolG")
        #expect(item.rendition(id: "w") == webp && item.rendition(id: "zzz") == nil)
    }

    @Test func theVideoRenditionMergesTheLocalCopyThePrivateCopyAndTheHostedLink() throws {
        let hostedURL = URL(string: "https://media.capybaraharmony.com/HhHhHhHhHh.mp4")!
        let local = try #require(StoredMedia(id: "M", original: sv("o", .original, session: "S1", at: 5), webps: []))
        let priv = lf("PRIV", .private, name: "x", url: nil, type: "video/mp4", at: 1)
        let host = lf("HOST", .public, name: "x.mp4", url: hostedURL, type: "video/mp4", at: 2, mediaName: "HhHhHhHhHh.mp4")
        let item = try #require(MediaItem.merge(local: local, post: post(files: [priv, host])))
        let video = try #require(item.video)
        #expect(item.renditions.count == 1 && video.id == "video" && video.kind == .video)
        #expect(video.local?.id == "o" && video.file?.id == "PRIV" && video.hosted?.id == "HOST" && video.publicURL == hostedURL)
        #expect(video.deletableName == nil && video.clip == nil)
        #expect(item.face.id == "video" && item.webpCount == 0 && item.hasServerCopy)
        // the local original's own public link counts when the library does not list the hosted file yet
        let shared = try #require(StoredMedia(id: "M", original: sv("o", .original, at: 5, publicURL: hostedURL), webps: []))
        #expect(MediaItem.merge(local: shared, post: nil)?.video?.publicURL == hostedURL)
        // a post without a local copy still has its video tab
        let serverOnly = try #require(MediaItem.merge(local: nil, post: post(files: [priv])))
        #expect(serverOnly.id == "post:POST" && serverOnly.video?.local == nil && serverOnly.video?.file?.id == "PRIV")
    }

    @Test func webpsAreNumberedByCreatedAtAndOneSidedWebpsAreKept() throws {
        let a = webpURL("QqQqQqQqQ1"), b = webpURL("QqQqQqQqQ2"), c = webpURL("QqQqQqQqQ3")
        let localOnly = sv("loc", .webp, url: webpURL("QqQqQqQqQ4"), at: 40)        // not in the library yet
        let localA = sv("la", .webp, url: a, at: 5)                                   // local clock says A is older...
        let localB = sv("lb", .webp, url: b, at: 6)
        let local = try #require(StoredMedia(id: "M", original: nil, webps: [localA, localB, localOnly]))
        let files = [
            lf("FB", .public, name: "x.webp", url: b, type: "image/webp", at: 10, mediaName: "QqQqQqQqQ2.webp", deletable: true),
            lf("FA", .public, name: "x.webp", url: a, type: "image/webp", at: 20, mediaName: "QqQqQqQqQ1.webp", deletable: true),   // ...the server says B first
            lf("FC", .public, name: "x.webp", url: c, type: "image/webp", at: 30, mediaName: "QqQqQqQqQ3.webp", deletable: false),   // another device's
        ]
        let item = try #require(MediaItem.merge(local: local, post: post(files: files)))
        #expect(item.renditions.map(\.id) == ["lb", "la", "f:FC", "loc"])
        #expect(item.renditions.map(\.kind) == [.webp(number: 1), .webp(number: 2), .webp(number: 3), .webp(number: 4)])
        #expect(item.renditions.map(\.deletableName) == ["QqQqQqQqQ2.webp", "QqQqQqQqQ1.webp", nil, "QqQqQqQqQ4.webp"],
                "a server file says what is deletable; a webp the library does not list yet uses its own link's name")
        #expect(item.video == nil && item.face.id == "loc" && item.webpCount == 4)
        #expect(item.rendition(id: "f:FC")?.local == nil && item.rendition(id: "loc")?.file == nil)
        // a local webp that was never hosted has no link and no name
        let bare = try #require(StoredMedia(id: "M", original: nil, webps: [sv("bare", .webp, at: 1)]))
        let bareItem = try #require(MediaItem.merge(local: bare, post: nil))
        #expect(bareItem.renditions[0].publicURL == nil && bareItem.renditions[0].deletableName == nil && !bareItem.hasServerCopy)
    }

    @Test func theClipOfAWebpMadeHereRidesAlong() throws {
        let clip = WebpClip(start: 2, length: 10, crop: CropRect(x: 0, y: 0.2, w: 1, h: 0.5), quality: .med, width: 480)
        let local = try #require(StoredMedia(id: "M", original: nil, webps: [sv("w", .webp, url: webpURL("RrRrRrRrR1"), at: 1, clip: clip)]))
        #expect(MediaItem.merge(local: local, post: nil)?.renditions[0].clip == clip)
        #expect(clip.range == TrimRange(start: 2, end: 12))
    }

    @Test func aLocalMediaAndAPostJoinBySessionOrByWebpURLNeverByLinkAlone() throws {
        let url = webpURL("SsSsSsSsS1")
        let bySession = try #require(StoredMedia(id: "M", original: sv("o", .original, session: "S1", at: 0), webps: []))
        #expect(MediaItem.joins(bySession, post(id: "S1", files: [])))                                     // post id == session
        #expect(MediaItem.joins(bySession, post(id: "other", session: "S1", files: [])))                  // post.session.id
        #expect(!MediaItem.joins(bySession, post(id: "other", session: "S9", files: [])))
        let byURL = try #require(StoredMedia(id: "M2", original: nil, webps: [sv("w", .webp, session: "S7", url: url, at: 0)]))
        let file = lf("F", .public, name: "x.webp", url: url, type: "image/webp", at: 1, mediaName: "SsSsSsSsS1.webp", deletable: true)
        #expect(MediaItem.joins(byURL, post(id: "elsewhere", files: [file])))
        // the same link and nothing else: a post shared again later is a new media
        let sameLink = try #require(StoredMedia(id: "M3", original: sv("x", .original, session: "OLD", at: 0), webps: []))
        #expect(!MediaItem.joins(sameLink, post(id: "NEW", session: "NEWER", files: [])))
        #expect(MediaItem.merge(local: nil, post: nil) == nil)
    }

    @Test func aPostWithOnlyUnknownFilesStillHasATab() throws {
        let odd = lf("ODD", .public, name: "x", url: URL(string: "https://x/y.png"), type: "image/png", at: 0)
        let item = try #require(MediaItem.merge(local: nil, post: post(files: [odd])))
        #expect(item.renditions.count == 1 && item.video?.publicURL == URL(string: "https://x/y.png"))
        let empty = try #require(MediaItem.merge(local: nil, post: post(files: [])))
        #expect(empty.renditions.count == 1 && empty.face.id == "video" && empty.face.width == 720 && empty.hasServerCopy)
    }
}
