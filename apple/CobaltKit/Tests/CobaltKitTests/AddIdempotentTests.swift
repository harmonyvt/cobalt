import CoreGraphics
import Foundation
import Testing
@testable import CobaltKit

// OfflineStore.add is idempotent inside its coordinated index write: the same webp (same
// remoteURL) or the same session's original (same sessionID) is one entry, however many adds race.

/// Writes a real poster file and three flipbook frames, so a discarded duplicate has files to leave
/// behind (the preview tools make none).
private struct FileMakingTools: MediaTools {
    func probe(file: URL) async -> MediaInfo? { nil }
    func frames(of input: FrameInput, duration: Double?, count: Int) -> AsyncThrowingStream<Frame, Error> {
        AsyncThrowingStream { $0.finish() }
    }
    func poster(for file: URL, isImage: Bool, to destination: URL) async -> Bool {
        try? FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        return (try? Data(repeating: 1, count: 40).write(to: destination)) != nil
    }
    func previewFrames(of file: URL, animatedImage: Bool, count: Int, maxEdge: CGFloat) async -> [CGImage] {
        (0..<3).compactMap { _ in PreviewMedia.gradient(width: 16, height: 16) }
    }
}

private let hostedWebp = URL(string: "https://media.capybaraharmony.com/IdEmPoTeNt1.webp")!
private let otherWebp = URL(string: "https://media.capybaraharmony.com/IdEmPoTeNt2.webp")!
private let webpInfo = MediaInfo(name: "made.webp", duration: 1, width: 24, height: 16, bytes: 64, isImage: false)
private let clipInfo = MediaInfo(name: "o", duration: 1, width: 1, height: 1, bytes: 50, isImage: false)

@MainActor
private func makeStore(_ root: URL) -> OfflineStore {
    OfflineStore(root: root, tools: FileMakingTools())
}

/// Every file under files/, posters/ and previews/ that the index does not name.
@MainActor
private func orphans(_ store: OfflineStore, root: URL) -> [String] {
    let fm = FileManager.default
    var named = Set<String>()
    for v in store.videos {
        if let f = v.fileURL { named.insert("files/" + f.lastPathComponent) }
        if let p = v.posterURL { named.insert("posters/" + p.lastPathComponent) }
        for u in v.previewFrameURLs { named.insert("previews/" + u.lastPathComponent) }
    }
    var out: [String] = []
    for sub in ["files", "posters", "previews"] {
        let names = (try? fm.contentsOfDirectory(atPath: root.appendingPathComponent(sub).path)) ?? []
        for name in names where !named.contains("\(sub)/\(name)") { out.append("\(sub)/\(name)") }
    }
    return out
}

@MainActor
private func addWebp(
    _ store: OfflineStore, remote: URL? = hostedWebp, sid: String? = "sid", link: URL? = nil, publicURL: URL? = nil
) async throws -> StoredVideo {
    try await store.add(
        file: try makeTempFile("made.webp", bytes: 64), kind: .webp, media: webpInfo, sessionID: sid,
        link: link, remoteURL: remote, move: true, publicURL: publicURL)
}

@MainActor
private func addOriginal(_ store: OfflineStore, sid: String?) async throws -> StoredVideo {
    try await store.add(
        file: try makeTempFile("o.mp4", bytes: 50), kind: .original, media: clipInfo,
        sessionID: sid, link: nil, remoteURL: nil, move: true)
}

@MainActor
@Suite(.serialized)
struct AddIdempotentTests {
    @Test func manyConcurrentAddsOfOneWebpYieldOneEntryAndNoOrphanFile() async throws {
        let root = try makeTempDirectory()
        let store = makeStore(root)
        let tasks = (0..<12).map { _ in Task { try await addWebp(store).id } }
        var ids: [String] = []
        for task in tasks { ids.append(try await task.value) }
        #expect(Set(ids).count == 1, "every caller got the one surviving entry")
        #expect(store.videos.count == 1)
        #expect(orphans(store, root: root).isEmpty, "\(orphans(store, root: root))")
        let fresh = makeStore(root)
        #expect(fresh.videos.map(\.id) == Array(ids.prefix(1)), "the index on disk holds the same single entry")
        let kept = try #require(store.videos.first)
        #expect(FileManager.default.fileExists(atPath: try #require(kept.fileURL).path))
        #expect(kept.posterURL.map { FileManager.default.fileExists(atPath: $0.path) } == true)
        #expect(kept.previewFrameURLs.count == 3)
    }

    @Test func twoStoresOnOneDirectoryAddingTheSameWebpYieldOneEntry() async throws {
        let root = try makeTempDirectory()
        let app = makeStore(root)
        let shareExtension = makeStore(root)
        async let a = addWebp(app)
        async let b = addWebp(shareExtension)
        async let c = addWebp(app)
        async let d = addWebp(shareExtension)
        let ids = try await Set([a.id, b.id, c.id, d.id])
        #expect(ids.count == 1)
        await app.reload()
        await shareExtension.reload()
        #expect(app.videos.count == 1 && shareExtension.videos.count == 1)
        #expect(app.videos.first?.id == shareExtension.videos.first?.id)
        #expect(orphans(app, root: root).isEmpty, "\(orphans(app, root: root))")
    }

    @Test func differentRemoteURLsStillAddTwo() async throws {
        let root = try makeTempDirectory()
        let store = makeStore(root)
        async let a = addWebp(store, remote: hostedWebp)
        async let b = addWebp(store, remote: otherWebp)
        let (x, y) = try await (a, b)
        #expect(x.id != y.id && store.videos.count == 2)
        #expect(orphans(store, root: root).isEmpty)
    }

    @Test func webpsWithoutARemoteURLAreNeverMerged() async throws {
        let store = makeStore(try makeTempDirectory())
        _ = try await addWebp(store, remote: nil)
        _ = try await addWebp(store, remote: nil)
        #expect(store.videos.count == 2)
    }

    @Test func aSecondAddReturnsTheExistingEntryAndFillsItsGaps() async throws {
        let root = try makeTempDirectory()
        let store = makeStore(root)
        let first = try await addWebp(store, sid: "sid")
        let link = URL(string: "https://x.com/i/status/9")!
        let shared = URL(string: "https://media.capybaraharmony.com/Pub.mp4")!
        let second = try await addWebp(store, sid: "sid", link: link, publicURL: shared)
        #expect(second.id == first.id && second.fileURL == first.fileURL)
        #expect(second.link == link && second.publicURL == shared, "newly known fields are merged")
        #expect(store.videos.count == 1)
        #expect(store.videos.first?.link == link)
        #expect(orphans(store, root: root).isEmpty)
        // what is already known is not overwritten
        let third = try await addWebp(store, sid: "other", link: URL(string: "https://x.com/other")!)
        #expect(third.id == first.id && third.sessionID == "sid" && third.link == link)
    }

    @Test func aSessionsOriginalIsOneEntryButOtherSessionsAndSessionlessSavesAreNot() async throws {
        let root = try makeTempDirectory()
        let store = makeStore(root)
        let a = try await addOriginal(store, sid: "s1")
        let b = try await addOriginal(store, sid: "s1")
        #expect(a.id == b.id && store.videos.count == 1)
        let c = try await addOriginal(store, sid: "s2")
        #expect(c.id != a.id)
        _ = try await addOriginal(store, sid: nil)
        _ = try await addOriginal(store, sid: nil)
        #expect(store.videos.count == 4, "two plain saves of one link are two copies the owner asked for")
        // a webp of the same session is another kind: its own entry
        _ = try await addWebp(store, sid: "s1")
        #expect(store.videos.count == 5)
        #expect(orphans(store, root: root).isEmpty)
    }

    @Test func anOriginalWhoseFileWasEvictedIsRefilledByTheNextAdd() async throws {
        let root = try makeTempDirectory()
        let store = makeStore(root)
        let first = try await addOriginal(store, sid: "s1")
        #expect(await store.evict(first.id))
        #expect(store.videos.first?.fileURL == nil)
        let again = try await addOriginal(store, sid: "s1")
        #expect(again.id == first.id && store.videos.count == 1)
        let file = try #require(again.fileURL)
        #expect(FileManager.default.fileExists(atPath: file.path), "the entry has its file back")
        #expect(orphans(store, root: root).isEmpty, "\(orphans(store, root: root))")
    }

    @Test func detachDuringTheWebpDownloadStoresExactlyOneWebp() async throws {
        let r = DetachRig()
        let p = r.pipeline
        await r.toReady()
        let gate = Gate()
        let base = r.ctx.client
        var stub = ScriptedClient(base: base)
        stub.downloadHook = { file, dest in
            if case .open(let url) = file, url.pathExtension == "webp" { await gate.wait() }
            return try await base.download(file, to: dest, progress: { _ in })
        }
        r.ctx.client = stub
        p.makeWebp()
        await r.park(gate)
        #expect(r.webps.isEmpty)

        p.detach()
        #expect(r.ctx.background.count == 1)
        // the other path stores the same webp while the first download is still on the wire
        let rival = try await r.store.add(
            file: try makeTempFile("rival.webp", bytes: 64), kind: .webp, media: webpInfo,
            sessionID: nil, link: nil, remoteURL: PreviewData.short.webpURL, move: true)
        await gate.open()
        await r.drive { r.ctx.background.isEmpty }
        #expect(r.webps.count == 1, "\(r.webps.count) webps")
        #expect(r.webps.first?.id == rival.id)
        #expect(r.webps.first?.sessionID != nil, "the pipeline's add merged its session into the entry")
    }
}
