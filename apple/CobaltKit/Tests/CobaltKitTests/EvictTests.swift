import CoreGraphics
import Foundation
import Observation
import Synchronization
import Testing
@testable import CobaltKit

// `OfflineStore.evict(_:)`: "remove offline copy" in the media detail. One entry's video file goes;
// its record, poster and flipbook stay (what the storage limit does to the oldest entries).

/// A poster of 50 bytes and three synthetic flipbook frames, no decoding.
private struct EvictTools: MediaTools {
    func probe(file: URL) async -> MediaInfo? { nil }
    func frames(of input: FrameInput, duration: Double?, count: Int) -> AsyncThrowingStream<Frame, Error> {
        AsyncThrowingStream { $0.finish() }
    }
    func poster(for file: URL, isImage: Bool, to destination: URL) async -> Bool {
        try? FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        return (try? Data(repeating: 9, count: 50).write(to: destination)) != nil
    }
    func previewFrames(of file: URL, animatedImage: Bool, count: Int, maxEdge: CGFloat) async -> [CGImage] {
        (0..<3).compactMap { _ in PreviewMedia.gradient(width: 48, height: 32) }
    }
}

private let info = MediaInfo(name: "clip", duration: 6, width: 96, height: 160, bytes: nil, isImage: false)

@MainActor
private struct Rig {
    let root: URL
    let defaults: UserDefaults
    let store: OfflineStore

    init(root: URL? = nil) throws {
        let suite = "cobalt.evict.test.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite) ?? .standard
        defaults.removePersistentDomain(forName: suite)
        LimitDefaults.write(nil, to: defaults)                       // no limit: only evict() removes files here
        let root = try root ?? makeTempDirectory()
        self.root = root
        self.defaults = defaults
        self.store = OfflineStore(root: root, tools: EvictTools(), defaults: defaults)
    }

    @discardableResult
    func add(_ bytes: Int = 1_000, to other: OfflineStore? = nil) async throws -> StoredVideo {
        try await (other ?? store).add(
            file: try makeTempFile("clip.mp4", bytes: bytes), kind: .original, media: info, sessionID: nil, link: nil,
            remoteURL: nil, move: true)
    }

    func reopened() -> OfflineStore { OfflineStore(root: root, tools: EvictTools(), defaults: defaults) }

    func exists(_ url: URL?) -> Bool { url.map { FileManager.default.fileExists(atPath: $0.path) } ?? false }
}

@MainActor
struct EvictTests {
    @Test func evictingDropsTheFileAndKeepsRecordPosterAndFlipbook() async throws {
        let rig = try Rig()
        let stored = try await rig.add(1_000)
        let other = try await rig.add(400)
        let file = try #require(stored.fileURL)
        #expect(!stored.previewFrameURLs.isEmpty && stored.posterURL != nil)
        let before = rig.store.usage
        #expect(before.count == 2)

        let dropped = await rig.store.evict(stored.id)
        #expect(dropped)

        let after = try #require(rig.store.videos.first { $0.id == stored.id })
        #expect(after.fileURL == nil)
        #expect(!rig.exists(file))
        #expect(after.posterURL == stored.posterURL && rig.exists(after.posterURL))
        #expect(after.previewFrameURLs == stored.previewFrameURLs)
        #expect(after.previewFrameURLs.allSatisfy { rig.exists($0) })
        #expect(after.name == stored.name && after.bytes == stored.bytes && after.createdAt == stored.createdAt)
        // the entry still counts toward the library, its file no longer toward the usage
        #expect(rig.store.videos.count == 2)
        #expect(rig.store.usage.count == 1)
        #expect(rig.store.usage.bytes == before.bytes - 1_000)
        // the other entry is untouched
        let kept = try #require(rig.store.videos.first { $0.id == other.id })
        #expect(rig.exists(kept.fileURL))
    }

    @Test func theEvictionIsWrittenToTheIndex() async throws {
        let rig = try Rig()
        let stored = try await rig.add()
        await rig.store.evict(stored.id)
        let reopened = rig.reopened()
        let entry = try #require(reopened.videos.first { $0.id == stored.id })
        #expect(entry.fileURL == nil && entry.posterURL != nil && entry.previewFrameURLs.count == stored.previewFrameURLs.count)
        #expect(reopened.usage.count == 0)
    }

    @Test func anEntryInUseIsNeverEvictedUntilItIsReleased() async throws {
        let rig = try Rig()
        let stored = try await rig.add()
        let file = try #require(stored.fileURL)
        rig.store.pin(stored.id)
        rig.store.pin(stored.id)                                       // two runs read it
        #expect(rig.store.isInUse(stored.id))

        #expect(await rig.store.evict(stored.id) == false)
        #expect(rig.exists(file) && rig.store.videos.first?.fileURL == file)

        rig.store.unpin(stored.id)
        #expect(await rig.store.evict(stored.id) == false)             // one run still has it
        rig.store.unpin(stored.id)
        #expect(!rig.store.isInUse(stored.id))
        #expect(await rig.store.evict(stored.id))
        #expect(!rig.exists(file) && rig.store.videos.first?.fileURL == nil)
    }

    @Test func unknownAndAlreadyEvictedEntriesChangeNothing() async throws {
        let rig = try Rig()
        let stored = try await rig.add()
        let other = try await rig.add()

        #expect(await rig.store.evict("no-such-entry") == false)
        #expect(rig.store.usage.count == 2)

        #expect(await rig.store.evict(stored.id))
        let usage = rig.store.usage
        #expect(await rig.store.evict(stored.id) == false)             // a second time: nothing left to free
        #expect(rig.store.usage == usage)
        #expect(rig.exists(rig.store.videos.first { $0.id == other.id }?.fileURL))
    }

    @Test func theOwnersChoiceReachesTheNewestEntriesTheLimitProtects() async throws {
        let rig = try Rig()
        let stored = try await rig.add()                               // the newest of one: the limit would never touch it
        #expect(OfflineStore.protectedNewest > 1)
        #expect(await rig.store.evict(stored.id))
        #expect(rig.store.videos.first?.fileURL == nil)
    }

    @Test func theStoreAnnouncesTheEviction() async throws {
        let rig = try Rig()
        let stored = try await rig.add()

        let videosChanged = Mutex(false)
        withObservationTracking { _ = rig.store.videos } onChange: { videosChanged.withLock { $0 = true } }
        let usageChanged = Mutex(false)
        withObservationTracking { _ = rig.store.usage } onChange: { usageChanged.withLock { $0 = true } }
        #expect(!videosChanged.withLock { $0 } && !usageChanged.withLock { $0 })

        await rig.store.evict(stored.id)
        #expect(videosChanged.withLock { $0 })
        #expect(usageChanged.withLock { $0 })
    }

    @Test func downloadingAgainRefillsTheEvictedEntry() async throws {
        let rig = try Rig()
        let stored = try await rig.add(1_000)
        await rig.store.evict(stored.id)

        let fresh = try makeTempFile("again.mp4", bytes: 1_000)
        let refilled = try await rig.store.attach(file: fresh, to: stored.id, move: true)
        #expect(refilled.id == stored.id && rig.exists(refilled.fileURL))
        #expect(refilled.posterURL == stored.posterURL)
        #expect(rig.store.videos.count == 1 && rig.store.usage.count == 1)
    }

    @Test func evictingAKeptEntryDropsItsFileToo() async throws {
        // decision 10: "remove offline copy" is the owner's own choice, kept or cached
        let rig = try Rig()
        let kept = try await rig.store.add(
            file: try makeTempFile("clip.mp4", bytes: 800), kind: .original, media: info, sessionID: nil, link: nil,
            remoteURL: nil, move: true, keep: true)
        #expect(kept.keep && kept.isOffline && kept.place == .cache, "no visible root here: kept and waiting in files/")
        let file = try #require(kept.fileURL)
        #expect(await rig.store.evict(kept.id))
        let after = try #require(rig.store.videos.first { $0.id == kept.id })
        #expect(!rig.exists(file) && after.fileURL == nil && !after.keep && !after.isOffline && after.posterURL != nil)
        #expect(rig.store.offlineUsage.offline.count == 0)
    }
}
