import Foundation
import Observation
import Synchronization
import Testing
@testable import CobaltKit

// 8.17: the offline index is read and written on `OfflineIndexEngine`, off the main thread, one job at a time; the main
// actor only adopts the snapshots, and only reassigns what it shows when they changed.

private let engineInfo = MediaInfo(name: "clip", duration: 6, width: 96, height: 160, bytes: nil, isImage: false)

/// Set by an observation's `onChange`, which may run on any thread.
private final class Fired: Sendable {
    let value = Mutex(false)
    var fired: Bool { value.withLock { $0 } }
}

private func freshEngineDefaults() -> UserDefaults {
    let suite = "cobalt.engine.test.\(UUID().uuidString)"
    let d = UserDefaults(suiteName: suite) ?? .standard
    d.removePersistentDomain(forName: suite)
    return d
}

@MainActor
struct OfflineStoreEngineTests {
    private func makeStore(limit: Int64? = nil) throws -> OfflineStore {
        let defaults = freshEngineDefaults()
        LimitDefaults.write(limit, to: defaults)
        return OfflineStore(root: try makeTempDirectory(), tools: MediaTestTools(), defaults: defaults)
    }

    @discardableResult
    private func add(_ store: OfflineStore, session: String, bytes: Int = 1_000) async throws -> StoredVideo {
        try await store.add(
            file: try makeTempFile("o.mp4", bytes: bytes), kind: .original, media: engineInfo, sessionID: session,
            link: nil, remoteURL: nil, move: true, keep: false)
    }

    /// Fires when `videos` or `media` is reassigned.
    private func watch(_ store: OfflineStore) -> Fired {
        let fired = Fired()
        withObservationTracking {
            _ = store.videos
            _ = store.media
        } onChange: {
            fired.value.withLock { $0 = true }
        }
        return fired
    }

    @Test func adoptingTheSameRecordsRepublishesNothing() async throws {
        let store = try makeStore()
        try await add(store, session: "S1")
        try await add(store, session: "S2")
        let before = store.adoptions
        let fired = watch(store)

        store.adopt(store.records)                                         // the same records, adopted directly
        await store.enforceLimit()                                         // no limit: the engine's read is the same index
        #expect(store.adoptions == before + 2, "every adopt is counted, the unchanged ones too")
        #expect(!fired.fired, "an unchanged index must not invalidate the library's observers")
        #expect(store.videos.count == 2)

        // the media lookups still answer after an unchanged adopt
        let first = try #require(store.media.first)
        #expect(store.media(id: first.id)?.id == first.id)

        await store.setTitle("capybara", media: first.id)                  // a real change does republish
        #expect(fired.fired)
        #expect(store.media(id: first.id)?.renditions.allSatisfy { $0.title == "capybara" } == true)
    }

    @Test func forcedAdoptRepublishesUnchangedRecords() async throws {
        let store = try makeStore()
        try await add(store, session: "S1")
        let fired = watch(store)
        store.adopt(store.records, force: true)                            // what `swapRoot` does when the root moves
        #expect(fired.fired)
    }

    @Test func writesInARowBothLandInOrder() async throws {
        let store = try makeStore()
        let video = try await add(store, session: "S1")
        let media = video.mediaID

        // queued back to back from the main actor without waiting in between: the engine runs them first in, first out
        let one = Task { await store.setTitle("one", media: media) }
        let two = Task { await store.setTitle("two", media: media) }
        await one.value
        await two.value
        #expect(store.media(id: media)?.renditions.first?.title == "two")
        #expect(OfflineStore.readRecords(root: store.root).first?.title == "two", "the last write is what is on disk")

        // many writes at once: every one lands (each re-reads the index the one before it wrote)
        var ids: [String] = []
        for i in 0..<8 { ids.append(try await add(store, session: "M\(i)").mediaID) }
        await withTaskGroup(of: Void.self) { group in
            for (i, id) in ids.enumerated() {
                group.addTask { @MainActor in await store.setTitle("t\(i)", media: id) }
            }
        }
        let onDisk = OfflineStore.readRecords(root: store.root)
        for (i, id) in ids.enumerated() {
            #expect(onDisk.first { $0.media == id }?.title == "t\(i)")
            #expect(store.media(id: id)?.renditions.first?.title == "t\(i)")
        }
    }

    @Test func anOlderSnapshotNeverReplacesANewerOne() async throws {
        let store = try makeStore()
        let video = try await add(store, session: "S1")
        let older = try await store.engine.write(limit: nil, enforce: false, pinned: [], protecting: { _ in [] }) { records in
            records[0].title = "older"
        }
        let newer = try await store.engine.write(limit: nil, enforce: false, pinned: [], protecting: { _ in [] }) { records in
            records[0].title = "newer"
        }
        #expect(newer.sequence > older.sequence)
        store.adopt(newer)
        store.adopt(older)                                                 // resumed late: dropped
        #expect(store.videos.first { $0.id == video.id }?.title == "newer")
    }

    @Test func enforceLimitPlansOffTheMainThread() async throws {
        let store = try makeStore()
        for i in 0..<14 { try await add(store, session: "L\(i)", bytes: 100) }
        let before = OfflineIndexEngine.planThreads.withLock { $0 }
        // 14 × (100 file + 50 poster) = 2 100; the two oldest files free 200, so 1 900 takes only those
        LimitDefaults.write(1_900, to: store.defaults)
        await store.enforceLimit()
        let after = OfflineIndexEngine.planThreads.withLock { $0 }
        #expect(after.offMain > before.offMain, "the plan ran")
        #expect(after.onMain == before.onMain, "and never on the main thread")
        // it still evicts: the two oldest files go, the newest twelve media are protected
        #expect(store.videos.filter { $0.fileURL == nil }.count == 2)
        #expect(OfflineStore.readRecords(root: store.root).filter { $0.fileName == nil }.count == 2)
    }

    @Test func planEvictionReadsOnceAndChangesNothingOnDisk() async throws {
        let store = try makeStore()
        for i in 0..<14 { try await add(store, session: "P\(i)", bytes: 100) }
        let root = store.root
        let planned = await Task.detached { OfflineStore.planEviction(root: root, limit: 1_900, protecting: []) }.value
        let result = try #require(planned)
        #expect(result.plan.files.count == 2)
        #expect(result.records == OfflineStore.readRecords(root: root), "the plan's records are the index as read")
        #expect(OfflineStore.readRecords(root: root).allSatisfy { $0.fileName != nil }, "planning writes nothing")
    }
}
