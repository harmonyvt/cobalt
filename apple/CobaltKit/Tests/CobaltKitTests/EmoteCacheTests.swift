import Foundation
import Synchronization
import Testing
@testable import CobaltKit

// The device's 7TV emote cache (APP-API-CONTRACT 57.13): one fetch per URL, kept on disk across instances, the least
// recently used trimmed past the cap, prefetch skipping what is there, and the kept 7TV answers.

private final class FetchCount: Sendable {
    private let calls = Mutex<[URL]>([])
    var all: [URL] { calls.withLock { $0 } }
    func add(_ url: URL) { calls.withLock { $0.append(url) } }
}

private func tempDir() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("emote-cache-\(UUID().uuidString)", isDirectory: true)
}

private func emote(_ n: Int) -> URL { URL(string: "https://cdn.7tv.app/emote/\(n)/2x.webp")! }

@Suite struct EmoteCacheTests {
    @Test func fetchesOnceAndKeepsOnDisk() async throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let count = FetchCount()
        let fetch: EmoteCache.Fetch = { url in
            count.add(url)
            try await Task.sleep(for: .milliseconds(30))
            return Data(url.absoluteString.utf8)
        }
        let cache = EmoteCache(directory: dir, fetch: fetch)
        async let a = cache.data(for: emote(1))
        async let b = cache.data(for: emote(1))
        let (first, second) = await (a, b)
        #expect(first == Data(emote(1).absoluteString.utf8))
        #expect(second == first)
        #expect(count.all == [emote(1)])
        #expect(cache.memoryData(for: emote(1)) == first)

        // a new launch: read from disk, no fetch
        let offline = EmoteCache(directory: dir, fetch: { _ in throw URLError(.notConnectedToInternet) })
        #expect(await offline.data(for: emote(1)) == first)
        #expect(await offline.has(emote(1)))
        #expect(await offline.data(for: emote(2)) == nil)
    }

    @Test func trimsTheLeastRecentlyUsed() async throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let cache = EmoteCache(directory: dir, limit: 1000, fetch: { _ in Data(repeating: 7, count: 300) })
        for n in 1...3 {
            _ = await cache.data(for: emote(n))
            try await Task.sleep(for: .milliseconds(20))
        }
        // over 1000 bytes with the fourth: trimmed to 800 or less, the oldest first
        _ = await cache.data(for: emote(4))
        #expect(await cache.diskBytes() <= 800)
        let fresh = EmoteCache(directory: dir, limit: 1000, fetch: { _ in throw URLError(.notConnectedToInternet) })
        #expect(await fresh.has(emote(4)))
        #expect(await !fresh.has(emote(1)))
    }

    @Test func prefetchSkipsWhatIsThere() async throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let count = FetchCount()
        let cache = EmoteCache(directory: dir, fetch: { url in count.add(url); return Data([1, 2, 3]) })
        _ = await cache.data(for: emote(1))
        await cache.prefetch([emote(1), emote(2), emote(3), emote(2)])
        for _ in 0..<200 where await !cache.isIdle { try await Task.sleep(for: .milliseconds(10)) }
        #expect(await cache.isIdle)
        #expect(Set(count.all) == [emote(1), emote(2), emote(3)])
        #expect(count.all.count == 3)
        #expect(await cache.has(emote(3)))
    }

    @Test func answersAreKeptByURL() {
        let url = URL(string: "https://api.example.com/7tv/sets/01H?page=1")!
        SevenTvAnswerCache.save(Data("{\"a\":1}".utf8), for: url)
        #expect(SevenTvAnswerCache.load(for: url) == Data("{\"a\":1}".utf8))
        #expect(SevenTvAnswerCache.load(for: URL(string: "https://other.example.com/7tv/sets/01H?page=1")!) == nil)
        SevenTvAnswerCache.clear()
        #expect(SevenTvAnswerCache.load(for: url) == nil)
    }
}
