import Foundation
import Testing
@testable import CobaltKit

// The editor's download folder (apple/CONTRACT-EDITOR.md 3.4): past 2 GB the oldest files go, except a file the open
// session has pinned and a registered local copy. Serving a decoded file again refreshes its last-used time.

@MainActor
struct EditSourceCacheTests {
    private func directory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("edit-source-cache-\(UUID().uuidString)", isDirectory: true)
    }

    private func cache(in dir: URL) -> EditSourceCache {
        EditSourceCache(directory: dir, client: { PreviewClient() }, provider: { _ in nil })
    }

    private func write(_ url: URL, bytes: Int, date: Date) throws {
        try Data(count: bytes).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
    }

    @Test func trimKeepsAPinnedFileAndDropsOlderUnpinnedOnes() async throws {
        let dir = directory()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let oldest = dir.appendingPathComponent("oldest.bin")
        let pinned = dir.appendingPathComponent("pinned.bin")
        let newest = dir.appendingPathComponent("newest.bin")
        try write(oldest, bytes: 400, date: Date(timeIntervalSince1970: 1_000))
        try write(pinned, bytes: 400, date: Date(timeIntervalSince1970: 2_000))
        try write(newest, bytes: 400, date: Date(timeIntervalSince1970: 3_000))

        let store = cache(in: dir)
        let owner = UUID()
        await store.pin(owner: owner, file: pinned)
        await store.trim(keeping: Set<URL>(), limit: 500)

        let fm = FileManager.default
        #expect(fm.fileExists(atPath: pinned.path))
        #expect(!fm.fileExists(atPath: oldest.path))
        #expect(!fm.fileExists(atPath: newest.path))

        await store.unpinOwner(owner)
        await store.trim(keeping: Set<URL>(), limit: 100)
        #expect(!fm.fileExists(atPath: pinned.path))
    }

    @Test func trimKeepsARegisteredLocalFile() async throws {
        let dir = directory()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let local = dir.appendingPathComponent("local.bin")
        let other = dir.appendingPathComponent("other.bin")
        try write(local, bytes: 400, date: Date(timeIntervalSince1970: 1_000))
        try write(other, bytes: 400, date: Date(timeIntervalSince1970: 3_000))
        let store = cache(in: dir)
        await store.register(local: local, for: "kept-locally")
        await store.trim(keeping: Set<URL>(), limit: 100)
        #expect(FileManager.default.fileExists(atPath: local.path))
        #expect(!FileManager.default.fileExists(atPath: other.path))
    }

    @Test func aFileServedFromMemoryHasItsLastUsedTimeRefreshedAndStaysPinned() async throws {
        let dir = directory()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==")!
        let id = "pic000000000001"
        let file = dir.appendingPathComponent("\(id).png")
        try png.write(to: file)
        let source = EditSource(id: id, name: "dot.png", kind: .photo, contentType: "image/png", width: 1, height: 1)
        let store = cache(in: dir)
        _ = try await store.asset(for: source)

        let stale = Date(timeIntervalSince1970: 1_000)
        try FileManager.default.setAttributes([.modificationDate: stale], ofItemAtPath: file.path)
        _ = try await store.asset(for: source)
        let refreshed = try file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        #expect((refreshed ?? .distantPast) > stale)

        let owner = UUID()
        await store.pin(owner: owner, id: id)
        let bulky = dir.appendingPathComponent("bulk.bin")
        try write(bulky, bytes: 2_000, date: Date(timeIntervalSince1970: 5_000))
        try FileManager.default.setAttributes([.modificationDate: stale], ofItemAtPath: file.path)
        await store.trim(keeping: Set<URL>(), limit: 500)
        #expect(FileManager.default.fileExists(atPath: file.path))
        #expect(!FileManager.default.fileExists(atPath: bulky.path))
    }
}
