import CoreGraphics
import Foundation
import Synchronization
import Testing
@testable import CobaltKit

// StoredVideo.publicURL (persisted, optional in old indexes) and the bounded, cancellable backfill.

/// Frames on demand: instant and synthetic, optionally off (an index written before flipbooks),
/// counted, and optionally parking the first call until a gate opens.
private final class FrameLog: Sendable {
    let makes = Mutex(true)
    let calls = Mutex(0)
    let parkFirst = Mutex<Gate?>(nil)
}

private struct LoggedTools: MediaTools {
    let log: FrameLog
    func probe(file: URL) async -> MediaInfo? { nil }
    func frames(of input: FrameInput, duration: Double?, count: Int) -> AsyncThrowingStream<Frame, Error> {
        AsyncThrowingStream { $0.finish() }
    }
    func poster(for file: URL, isImage: Bool, to destination: URL) async -> Bool { false }
    func previewFrames(of file: URL, animatedImage: Bool, count: Int, maxEdge: CGFloat) async -> [CGImage] {
        guard log.makes.withLock({ $0 }) else { return [] }
        let n = log.calls.withLock { v -> Int in v += 1; return v }
        if n == 1, let gate = log.parkFirst.withLock({ $0 }) { await gate.wait() }
        return (0..<3).compactMap { _ in PreviewMedia.gradient(width: 48, height: 32) }
    }
}

private let clipMedia = MediaInfo(name: "clip", duration: 6, width: 96, height: 160, bytes: nil, isImage: false)

@MainActor
@Suite(.serialized)
struct PublicURLTests {
    private func addOriginal(_ store: OfflineStore, session: String?, name: String = "clip") async throws -> StoredVideo {
        try await store.add(
            file: try makeTempFile("\(name).mp4", bytes: 2_000), kind: .original, media: clipMedia, sessionID: session,
            link: nil, remoteURL: nil, move: true)
    }

    @Test func publicURLIsPersistedAndSurvivesAReopen() async throws {
        let root = try makeTempDirectory()
        let log = FrameLog()
        let store = OfflineStore(root: root, tools: LoggedTools(log: log))
        let a = try await addOriginal(store, session: "S1")
        let b = try await addOriginal(store, session: "S2")
        #expect(a.publicURL == nil)

        let url = URL(string: "https://media.capybaraharmony.com/AbCdEf.mp4")!
        #expect(store.setPublicURL(url, forSession: "S1") == 1)
        #expect(store.videos.first { $0.id == a.id }?.publicURL == url)
        #expect(store.videos.first { $0.id == b.id }?.publicURL == nil)

        let reopened = OfflineStore(root: root, tools: LoggedTools(log: log))
        #expect(reopened.videos.first { $0.id == a.id }?.publicURL == url)
        #expect(reopened.videos.first { $0.id == b.id }?.publicURL == nil)
    }

    @Test func aWebpOfTheSameSessionIsNotBadged() async throws {
        let store = OfflineStore(root: try makeTempDirectory(), tools: LoggedTools(log: FrameLog()))
        _ = try await addOriginal(store, session: "S1")
        _ = try await store.add(
            file: try makeTempFile("w.webp", bytes: 500), kind: .webp, media: clipMedia, sessionID: "S1", link: nil,
            remoteURL: URL(string: "https://media.capybaraharmony.com/x.webp"), move: true)
        store.setPublicURL(URL(string: "https://media.capybaraharmony.com/y.mp4")!, forSession: "S1")
        #expect(store.videos.first { $0.kind == .webp }?.publicURL == nil)
        #expect(store.videos.first { $0.kind == .original }?.publicURL != nil)
    }

    @Test func addCanCarryTheLinkAndAnUnknownSessionTouchesNothing() async throws {
        let store = OfflineStore(root: try makeTempDirectory(), tools: LoggedTools(log: FrameLog()))
        let url = URL(string: "https://media.capybaraharmony.com/z.mp4")!
        let v = try await store.add(
            file: try makeTempFile("c.mp4", bytes: 800), kind: .original, media: clipMedia, sessionID: "S9", link: nil,
            remoteURL: nil, move: true, publicURL: url)
        #expect(v.publicURL == url)
        #expect(store.setPublicURL(url, forSession: "nope") == 0)
    }

    @Test func anIndexWrittenBeforePublicURLExistedStillDecodes() async throws {
        let root = try makeTempDirectory()
        let store = OfflineStore(root: root, tools: LoggedTools(log: FrameLog()))
        let v = try await addOriginal(store, session: "S1")
        store.setPublicURL(URL(string: "https://media.capybaraharmony.com/q.mp4")!, forSession: "S1")

        // strip the key from the index on disk: what an older build wrote
        let indexURL = root.appendingPathComponent("index.json")
        var rows = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: indexURL)) as? [[String: Any]])
        #expect(rows[0]["publicURL"] != nil)
        for i in rows.indices { rows[i].removeValue(forKey: "publicURL") }
        try JSONSerialization.data(withJSONObject: rows).write(to: indexURL)

        let reopened = OfflineStore(root: root, tools: LoggedTools(log: FrameLog()))
        let old = try #require(reopened.videos.first { $0.id == v.id })
        #expect(old.publicURL == nil && old.fileURL != nil)
    }

    @Test func aStoredVideoJSONWithoutThePublicURLKeyDecodes() throws {
        let json = """
        {"id":"a","kind":"original","name":"n","bytes":5,"createdAt":0}
        """
        let v = try JSONDecoder().decode(StoredVideo.self, from: Data(json.utf8))
        #expect(v.publicURL == nil && v.previewFrameURLs.isEmpty)
        var withLink = v
        withLink.publicURL = URL(string: "https://media.capybaraharmony.com/r.mp4")
        let back = try JSONDecoder().decode(StoredVideo.self, from: JSONEncoder().encode(withLink))
        #expect(back == withLink)
    }
}

@MainActor
@Suite(.serialized)
struct BackfillBoundsTests {
    /// `count` kept videos with no flipbook (an index from before they existed), newest first.
    private func oldIndex(_ count: Int, root: URL) async throws {
        let log = FrameLog()
        log.makes.withLock { $0 = false }
        let store = OfflineStore(root: root, tools: LoggedTools(log: log))
        for i in 0..<count {
            _ = try await store.add(
                file: try makeTempFile("c\(i).mp4", bytes: 600 + i), kind: .original,
                media: MediaInfo(name: "c\(i)", duration: 6, width: 96, height: 160, bytes: nil, isImage: false),
                sessionID: nil, link: nil, remoteURL: nil, move: true)
        }
    }

    @Test func backfillCoversOnlyTheNewestThirtyFive() async throws {
        let root = try makeTempDirectory()
        try await oldIndex(40, root: root)
        let log = FrameLog()
        let store = OfflineStore(root: root, tools: LoggedTools(log: log))
        #expect(store.videos.count == 40 && store.videos.allSatisfy { $0.previewFrameURLs.isEmpty })

        await store.backfillPreviewFrames()
        #expect(log.calls.withLock { $0 } == 35)
        let withFrames = store.videos.enumerated().filter { !$0.element.previewFrameURLs.isEmpty }.map(\.offset)
        #expect(withFrames == Array(0..<35), "the newest 35 (index 0 is newest), no others")
        #expect(OfflineStore.backfillLimit == 35)

        // the older ones are still made on demand
        let old = try #require(store.videos.last)
        await store.ensurePreviewFrames(for: old)
        #expect(store.videos.last?.previewFrameURLs.isEmpty == false)
    }

    @Test func backfillStopsBetweenEntriesWhenItsTaskIsCancelled() async throws {
        let root = try makeTempDirectory()
        try await oldIndex(6, root: root)
        let log = FrameLog()
        let gate = Gate()
        log.parkFirst.withLock { $0 = gate }
        let store = OfflineStore(root: root, tools: LoggedTools(log: log))

        let task = Task { await store.backfillPreviewFrames() }
        var spins = 0
        while await gate.waiting == 0, spins < 500 {
            try? await Task.sleep(for: .milliseconds(2))
            spins += 1
        }
        #expect(await gate.waiting == 1, "the first entry's frames are in progress")
        task.cancel()
        await gate.open()
        await task.value

        #expect(log.calls.withLock { $0 } == 1, "no entry after the cancel was started")
        #expect(store.videos.filter { !$0.previewFrameURLs.isEmpty }.count == 1)
    }

    @Test func aTaskCancelledBeforeItStartsDoesNoWork() async throws {
        let root = try makeTempDirectory()
        try await oldIndex(3, root: root)
        let log = FrameLog()
        let store = OfflineStore(root: root, tools: LoggedTools(log: log))
        let task = Task { () async -> Void in
            while !Task.isCancelled { try? await Task.sleep(for: .milliseconds(1)) }
            await store.backfillPreviewFrames()
        }
        task.cancel()
        await task.value
        #expect(log.calls.withLock { $0 } == 0)
    }
}
