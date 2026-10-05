import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import Observation
import Synchronization
import Testing
@testable import CobaltKit

// The orbit's flipbook: ~12 small frames per video, made at `add` and backfilled lazily.

/// Counts and times the calls the flipbook makes, and optionally makes none at all (an index
/// written before flipbooks existed).
private final class Probe: Sendable {
    let calls = Mutex(0)
    private let running = Mutex(0)
    let peak = Mutex(0)

    func begin() {
        calls.withLock { $0 += 1 }
        running.withLock { r in
            r += 1
            peak.withLock { $0 = max($0, r) }
        }
    }
    func end() { running.withLock { $0 -= 1 } }
}

private struct CountingTools: MediaTools {
    let probe: Probe
    var makesFrames = true
    private let inner = SystemMediaTools()

    init(probe: Probe, makesFrames: Bool = true) {
        self.probe = probe
        self.makesFrames = makesFrames
    }

    func probe(file: URL) async -> MediaInfo? { await inner.probe(file: file) }
    func imageInfo(file: URL) -> MediaInfo? { inner.imageInfo(file: file) }
    func frames(of input: FrameInput, duration: Double?, count: Int) -> AsyncThrowingStream<Frame, Error> {
        inner.frames(of: input, duration: duration, count: count)
    }
    func poster(for file: URL, isImage: Bool, to destination: URL) async -> Bool {
        await inner.poster(for: file, isImage: isImage, to: destination)
    }
    func previewFrames(of file: URL, animatedImage: Bool, count: Int, maxEdge: CGFloat) async -> [CGImage] {
        guard makesFrames else { return [] }
        probe.begin()
        defer { probe.end() }
        try? await Task.sleep(for: .milliseconds(40))             // widen any overlap
        return await inner.previewFrames(of: file, animatedImage: animatedImage, count: count, maxEdge: maxEdge)
    }
}

/// Instant, synthetic frames, for tests about files and bookkeeping rather than decoding.
private struct SyntheticTools: MediaTools {
    func probe(file: URL) async -> MediaInfo? { nil }
    func frames(of input: FrameInput, duration: Double?, count: Int) -> AsyncThrowingStream<Frame, Error> {
        AsyncThrowingStream { $0.finish() }
    }
    func poster(for file: URL, isImage: Bool, to destination: URL) async -> Bool { false }
    func previewFrames(of file: URL, animatedImage: Bool, count: Int, maxEdge: CGFloat) async -> [CGImage] {
        (0..<3).compactMap { _ in PreviewMedia.gradient(width: 48, height: 32) }
    }
}

private let clipMedia = MediaInfo(name: "clip", duration: 6, width: 96, height: 160, bytes: nil, isImage: false)

private func decode(_ url: URL) -> CGImage? {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
    return CGImageSourceCreateImageAtIndex(source, 0, nil)
}

private func isJPEG(_ url: URL) -> Bool {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return false }
    return CGImageSourceGetType(source) as String? == "public.jpeg"
}

private func previewFiles(in root: URL) -> [String] {
    ((try? FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("previews").path)) ?? []).sorted()
}

private func size(_ url: URL) -> Int64 {
    ((try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? NSNumber)?.int64Value ?? 0
}

@MainActor
struct PreviewFramesTests {
    private func addClip(_ store: OfflineStore) async throws -> StoredVideo {
        try await store.add(
            file: try await TestVideo.clip(), kind: .original, media: clipMedia, sessionID: nil, link: nil,
            remoteURL: nil, move: false)
    }

    private func addWebP(_ store: OfflineStore) async throws -> StoredVideo {
        let webp = try makeTempDirectory().appendingPathComponent("made.webp")
        try TestImages.animatedWebP.write(to: webp)
        return try await store.add(
            file: webp, kind: .webp,
            media: MediaInfo(name: "made.webp", duration: nil, width: nil, height: nil, bytes: nil, isImage: false),
            sessionID: nil, link: nil, remoteURL: nil, move: false)
    }

    // MARK: generation

    @Test func addingAVideoMakesTwelveSmallOrderedFrames() async throws {
        let root = try makeTempDirectory()
        let store = OfflineStore(root: root)
        let stored = try await addClip(store)

        #expect(stored.previewFrameURLs.count == 12)
        #expect(Set(stored.previewFrameURLs.map(\.lastPathComponent)).count == 12)
        for url in stored.previewFrameURLs {
            #expect(url.deletingLastPathComponent().lastPathComponent == "previews")
            #expect(isJPEG(url))
            let image = try #require(decode(url))
            #expect(max(image.width, image.height) <= 160 && image.height > image.width)   // portrait clip stays portrait
            #expect(size(url) > 0 && size(url) < 20_000)                                    // tiny
        }
        // the clip goes red to blue: the flipbook plays in time order
        let firstURL = try #require(stored.previewFrameURLs.first)
        let lastURL = try #require(stored.previewFrameURLs.last)
        let first = TestImages.meanColor(try #require(decode(firstURL)))
        let last = TestImages.meanColor(try #require(decode(lastURL)))
        #expect(first.b > last.b + 100 && last.r > first.r + 100)
        #expect(store.videos.first?.previewFrameURLs == stored.previewFrameURLs)
        #expect(previewFiles(in: root).count == 12)
    }

    @Test func aWideVideoNeverExceedsTheLongEdge() async throws {
        let wide = try makeTempDirectory().appendingPathComponent("wide.mp4")
        try await TestVideo.make(at: wide, seconds: 2, width: 640, height: 360)
        let store = OfflineStore(root: try makeTempDirectory())
        let stored = try await store.add(
            file: wide, kind: .original, media: MediaInfo(name: "w", duration: 2, width: 640, height: 360, bytes: nil, isImage: false),
            sessionID: nil, link: nil, remoteURL: nil, move: true)
        #expect(stored.previewFrameURLs.count == 12)
        for url in stored.previewFrameURLs {
            let image = try #require(decode(url))
            #expect(image.width <= 160 && image.height <= 160 && image.width > image.height)
        }
    }

    @Test func anAnimatedWebpGetsItsDecodedFrames() async throws {
        let store = OfflineStore(root: try makeTempDirectory())
        let stored = try await addWebP(store)
        // the sample has three frames: fewer than twelve means all of them
        #expect(stored.previewFrameURLs.count == 3)
        let images = stored.previewFrameURLs.compactMap(decode)
        #expect(images.count == 3)
        let colors = images.map(TestImages.meanColor)
        #expect(colors[0].r > 200 && colors[0].g < 80)           // red
        #expect(colors[1].g > 200 && colors[1].r < 80)           // green
        #expect(colors[2].b > 200 && colors[2].r < 80)           // blue
        for url in stored.previewFrameURLs {
            let image = try #require(decode(url))
            #expect(max(image.width, image.height) <= 160)
        }
    }

    @Test func stillImagesGetNoFlipbook() async throws {
        let root = try makeTempDirectory()
        let store = OfflineStore(root: root)
        let png = try makeTempDirectory().appendingPathComponent("still.png")
        try TestImages.png(width: 300, height: 200).write(to: png)
        let stored = try await store.add(
            file: png, kind: .original, media: MediaInfo(name: "still", duration: nil, width: 300, height: 200, bytes: nil, isImage: true),
            sessionID: nil, link: nil, remoteURL: nil, move: false)
        #expect(stored.previewFrameURLs.isEmpty && stored.posterURL != nil)
        await store.ensurePreviewFrames(for: stored)
        #expect(store.videos.first?.previewFrameURLs.isEmpty == true)
        #expect(previewFiles(in: root).isEmpty)
    }

    // MARK: backfill

    @Test func backfillMakesFramesForAnEntryThatHasNoneAndIsIdempotent() async throws {
        let root = try makeTempDirectory()
        let old = OfflineStore(root: root, tools: CountingTools(probe: Probe(), makesFrames: false))
        let stored = try await addClip(old)
        #expect(stored.previewFrameURLs.isEmpty)

        let probe = Probe()
        let store = OfflineStore(root: root, tools: CountingTools(probe: probe))
        let entry = try #require(store.videos.first)
        #expect(entry.previewFrameURLs.isEmpty)
        let before = store.usage.bytes

        await store.ensurePreviewFrames(for: entry)
        let filled = try #require(store.videos.first)
        #expect(filled.previewFrameURLs.count == 12 && probe.calls.withLock { $0 } == 1)
        // counted: the usage grew by exactly the frames' size
        #expect(store.usage.bytes == before + filled.previewFrameURLs.reduce(0) { $0 + size($1) })

        await store.ensurePreviewFrames(for: filled)
        await store.ensurePreviewFrames(for: entry)               // even with the stale value
        await store.backfillPreviewFrames()
        #expect(probe.calls.withLock { $0 } == 1)
        #expect(store.videos.first?.previewFrameURLs == filled.previewFrameURLs)

        // a fresh process sees them in the index
        let reopened = OfflineStore(root: root, tools: CountingTools(probe: Probe()))
        #expect(reopened.videos.first?.previewFrameURLs == filled.previewFrameURLs)
        #expect(reopened.usage == store.usage)
    }

    @Test func backfillCoversAnimatedWebpsAndEveryEntryWithAFile() async throws {
        let root = try makeTempDirectory()
        let old = OfflineStore(root: root, tools: CountingTools(probe: Probe(), makesFrames: false))
        _ = try await addWebP(old)
        _ = try await addClip(old)

        let store = OfflineStore(root: root, tools: CountingTools(probe: Probe()))
        #expect(store.videos.allSatisfy { $0.previewFrameURLs.isEmpty })
        await store.backfillPreviewFrames()
        let counts = Dictionary(uniqueKeysWithValues: store.videos.map { ($0.kind, $0.previewFrameURLs.count) })
        #expect(counts[.webp] == 3 && counts[.original] == 12)
    }

    @Test func backfillSkipsAnEntryWhoseFileWasEvictedBeforeItHadFrames() async throws {
        let root = try makeTempDirectory()
        let old = OfflineStore(root: root, tools: CountingTools(probe: Probe(), makesFrames: false))
        _ = try await addClip(old)
        await old.dropFilesKeepingPosters()

        let probe = Probe()
        let store = OfflineStore(root: root, tools: CountingTools(probe: probe))
        await store.backfillPreviewFrames()
        let entry = try #require(store.videos.first)
        await store.ensurePreviewFrames(for: entry)
        #expect(entry.fileURL == nil && store.videos.first?.previewFrameURLs.isEmpty == true)
        #expect(probe.calls.withLock { $0 } == 0)
    }

    @Test func aFileThatCannotBeReadIsNotRetriedOnEveryAsk() async throws {
        let root = try makeTempDirectory()
        let probe = Probe()
        let store = OfflineStore(root: root, tools: CountingTools(probe: probe))
        // not a video: the add makes a posterless entry and no frames
        let junk = try makeTempFile("junk.mp4", bytes: 2_000)
        let stored = try await store.add(
            file: junk, kind: .original, media: clipMedia, sessionID: nil, link: nil, remoteURL: nil, move: true)
        #expect(stored.previewFrameURLs.isEmpty)
        let afterAdd = probe.calls.withLock { $0 }
        await store.ensurePreviewFrames(for: stored)             // one more try this session...
        await store.ensurePreviewFrames(for: stored)             // ...then it is left alone
        await store.ensurePreviewFrames(for: stored)
        #expect(probe.calls.withLock { $0 } == afterAdd + 1)
        #expect(previewFiles(in: root).isEmpty)
    }

    // MARK: concurrency

    @Test func concurrentCallsForOneEntryShareOneRun() async throws {
        let root = try makeTempDirectory()
        let old = OfflineStore(root: root, tools: CountingTools(probe: Probe(), makesFrames: false))
        _ = try await addClip(old)

        let probe = Probe()
        let store = OfflineStore(root: root, tools: CountingTools(probe: probe))
        let entry = try #require(store.videos.first)
        async let a: Void = store.ensurePreviewFrames(for: entry)
        async let b: Void = store.ensurePreviewFrames(for: entry)
        async let c: Void = store.ensurePreviewFrames(for: entry)
        async let d: Void = store.backfillPreviewFrames()
        _ = await (a, b, c, d)

        #expect(probe.calls.withLock { $0 } == 1)
        #expect(store.videos.first?.previewFrameURLs.count == 12)
        #expect(previewFiles(in: root).count == 12)              // no duplicates, nothing orphaned
    }

    @Test func differentEntriesRenderOneAtATime() async throws {
        let root = try makeTempDirectory()
        let old = OfflineStore(root: root, tools: CountingTools(probe: Probe(), makesFrames: false))
        for _ in 0..<3 { _ = try await addClip(old) }

        let probe = Probe()
        let store = OfflineStore(root: root, tools: CountingTools(probe: probe))
        let entries = store.videos
        async let a: Void = store.ensurePreviewFrames(for: entries[0])
        async let b: Void = store.ensurePreviewFrames(for: entries[1])
        async let c: Void = store.ensurePreviewFrames(for: entries[2])
        _ = await (a, b, c)
        #expect(probe.calls.withLock { $0 } == 3)
        #expect(probe.peak.withLock { $0 } == 1)
        #expect(store.videos.allSatisfy { $0.previewFrameURLs.count == 12 })
    }

    @Test func theStoreAnnouncesWhenFramesAppear() async throws {
        let root = try makeTempDirectory()
        let old = OfflineStore(root: root, tools: CountingTools(probe: Probe(), makesFrames: false))
        _ = try await addClip(old)
        let store = OfflineStore(root: root, tools: CountingTools(probe: Probe()))
        let entry = try #require(store.videos.first)

        let fired = Mutex(false)
        withObservationTracking { _ = store.videos } onChange: { fired.withLock { $0 = true } }
        #expect(fired.withLock { $0 } == false)
        await store.ensurePreviewFrames(for: entry)
        #expect(fired.withLock { $0 })
    }

    // MARK: eviction and deletion

    @Test func evictingTheFileKeepsPosterAndFrames() async throws {
        let root = try makeTempDirectory()
        let store = OfflineStore(root: root)
        let stored = try await addClip(store)
        let poster = try #require(stored.posterURL)
        await store.dropFilesKeepingPosters()

        let kept = try #require(store.videos.first)
        #expect(kept.fileURL == nil && kept.posterURL == poster)
        #expect(kept.previewFrameURLs == stored.previewFrameURLs)
        #expect(kept.previewFrameURLs.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })
        // still counted: poster + frames, no file
        let frames = kept.previewFrameURLs.reduce(0) { $0 + size($1) }
        #expect(store.usage == StorageUsage(count: 0, bytes: size(poster) + frames))
        // and after a restart
        let reopened = OfflineStore(root: root)
        #expect(reopened.videos.first?.previewFrameURLs == stored.previewFrameURLs)
    }

    @Test func theLimitEvictsFilesFirstAndFramesGoOnlyWithTheirRecord() async throws {
        let root = try makeTempDirectory()
        let suite = "cobalt.preview.test.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let tick = Mutex(1_800_000_000.0)
        let store = OfflineStore(
            root: root, tools: SyntheticTools(), defaults: defaults,
            now: { Date(timeIntervalSince1970: tick.withLock { $0 += 1; return $0 }) })
        var added: [StoredVideo] = []
        for _ in 0..<14 {
            added.append(try await store.add(
                file: try makeTempFile("f.mp4", bytes: 1_000), kind: .original, media: clipMedia,
                sessionID: nil, link: nil, remoteURL: nil, move: true))
        }
        let framesPer = added[0].previewFrameURLs.reduce(0) { $0 + size($1) }
        #expect(added.allSatisfy { $0.previewFrameURLs.count == 3 } && framesPer > 0)
        #expect(store.usage.bytes == 14 * (1_000 + framesPer))

        // room for 12 files and all 14 flipbooks: the two oldest files go, their frames stay
        await store.setLimit(12 * 1_000 + 14 * framesPer)
        let afterFiles = Dictionary(uniqueKeysWithValues: store.videos.map { ($0.id, $0) })
        #expect(afterFiles[added[0].id]?.fileURL == nil && afterFiles[added[1].id]?.fileURL == nil)
        #expect(afterFiles[added[2].id]?.fileURL != nil)
        for gone in added.prefix(2) {
            let v = try #require(afterFiles[gone.id])
            #expect(v.previewFrameURLs == gone.previewFrameURLs)
            #expect(v.previewFrameURLs.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })
        }
        #expect(previewFiles(in: root).count == 14 * 3)

        // a limit below even the protected newest twelve: the two file-less records are dropped
        // whole (poster-less here, so the frames are what they free), frames included
        await store.setLimit(12 * 1_000 + 12 * framesPer)
        #expect(Set(store.videos.map(\.id)) == Set(added.suffix(12).map(\.id)))
        #expect(previewFiles(in: root).count == 12 * 3)
        let leftover = Set(previewFiles(in: root))
        #expect(!added.prefix(2).flatMap(\.previewFrameURLs).contains { leftover.contains($0.lastPathComponent) })
        #expect(store.usage.bytes == 12 * (1_000 + framesPer))
    }

    @Test func removingAnEntryDeletesItsFrames() async throws {
        let root = try makeTempDirectory()
        let store = OfflineStore(root: root, tools: SyntheticTools())
        let a = try await store.add(file: try makeTempFile("a.mp4"), kind: .original, media: clipMedia, sessionID: nil, link: nil, remoteURL: nil, move: true)
        let b = try await store.add(file: try makeTempFile("b.mp4"), kind: .original, media: clipMedia, sessionID: nil, link: nil, remoteURL: nil, move: true)
        #expect(previewFiles(in: root).count == 6)

        await store.remove(a.id)
        #expect(a.previewFrameURLs.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) })
        #expect(b.previewFrameURLs.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })
        #expect(previewFiles(in: root).count == 3)

        await store.clearAll()
        #expect(previewFiles(in: root).isEmpty && store.videos.isEmpty && store.usage == StorageUsage(count: 0, bytes: 0))
    }

    @Test func removingAnEntryWhileItsFramesAreBeingMadeLeavesNothingBehind() async throws {
        let root = try makeTempDirectory()
        let old = OfflineStore(root: root, tools: CountingTools(probe: Probe(), makesFrames: false))
        let stored = try await addClip(old)

        let store = OfflineStore(root: root, tools: CountingTools(probe: Probe()))
        let entry = try #require(store.videos.first)
        async let making: Void = store.ensurePreviewFrames(for: entry)
        await Task.yield()
        await store.remove(stored.id)
        await making
        #expect(store.videos.isEmpty)
        #expect(previewFiles(in: root).isEmpty)
    }

    // MARK: on-disk robustness

    @Test func anIndexFromBeforeFlipbooksStillLoadsWithNoFrames() async throws {
        let root = try makeTempDirectory()
        let json = """
        [{"id":"a","kind":"original","fileName":null,"posterName":null,"name":"old","bytes":5,\
        "createdAt":767000000}]
        """
        try json.data(using: .utf8)!.write(to: root.appendingPathComponent("index.json"))
        let store = OfflineStore(root: root)
        #expect(store.videos.count == 1 && store.videos[0].previewFrameURLs.isEmpty)

        // and a StoredVideo value without the new key decodes
        let value = #"{"id":"a","kind":"original","name":"old","bytes":5,"createdAt":767000000}"#
        let decoded = try JSONDecoder().decode(StoredVideo.self, from: Data(value.utf8))
        #expect(decoded.id == "a" && decoded.previewFrameURLs.isEmpty)
    }

    @Test func aFlipbookWithAFrameMissingIsDroppedAndRemade() async throws {
        let root = try makeTempDirectory()
        let first = OfflineStore(root: root, tools: SyntheticTools())
        let stored = try await first.add(
            file: try makeTempFile("a.mp4"), kind: .original, media: clipMedia, sessionID: nil, link: nil, remoteURL: nil, move: true)
        try FileManager.default.removeItem(at: try #require(stored.previewFrameURLs.last))

        let reopened = OfflineStore(root: root, tools: SyntheticTools())
        #expect(reopened.videos.first?.previewFrameURLs.isEmpty == true)
        #expect(previewFiles(in: root).isEmpty)                  // the surviving frames went with the set
    }

    @Test func framesNobodyNamesAreSweptOnceTheyAreOldEnough() async throws {
        let root = try makeTempDirectory()
        let store = OfflineStore(root: root, tools: SyntheticTools())
        let stored = try await store.add(
            file: try makeTempFile("a.mp4"), kind: .original, media: clipMedia, sessionID: nil, link: nil, remoteURL: nil, move: true)
        let dir = root.appendingPathComponent("previews")
        let stray = dir.appendingPathComponent("stray-00.jpg")
        try Data(repeating: 1, count: 10).write(to: stray)

        await store.reload()                                      // fresh: could be another process mid-write
        #expect(FileManager.default.fileExists(atPath: stray.path))
        OfflineStore.purgeOrphanPreviews(
            root: root, referenced: Set(stored.previewFrameURLs.map(\.lastPathComponent)),
            olderThan: 60, now: Date().addingTimeInterval(3_600))
        #expect(!FileManager.default.fileExists(atPath: stray.path))
        #expect(stored.previewFrameURLs.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })
    }
}
