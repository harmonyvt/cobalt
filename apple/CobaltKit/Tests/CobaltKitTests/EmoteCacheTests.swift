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

private final class Network: Sendable {
    private let up = Mutex(true)
    var isUp: Bool { up.withLock { $0 } }
    func set(_ value: Bool) { up.withLock { $0 = value } }
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

    @Test func prefetchGivesUpWhenNothingAnswers() async throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let count = FetchCount()
        let cache = EmoteCache(directory: dir, fetch: { url in count.add(url); throw URLError(.notConnectedToInternet) })
        await cache.prefetch((1...200).map(emote))
        for _ in 0..<200 where await !cache.isIdle { try await Task.sleep(for: .milliseconds(10)) }
        // four workers, eight failures in a row: far fewer than 200 are tried
        #expect(count.all.count < 40)
    }

    @Test func answersAreKeptByURLAndKey() {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let answers = SevenTvAnswerCache(directory: dir)
        let url = URL(string: "https://api.example.com/7tv/sets/01H?page=1")!
        answers.save(Data("{\"a\":1}".utf8), for: url, scope: "key-a")
        #expect(answers.load(for: url, scope: "key-a") == Data("{\"a\":1}".utf8))
        // another server, another page, another key: nothing
        #expect(answers.load(for: URL(string: "https://other.example.com/7tv/sets/01H?page=1")!, scope: "key-a") == nil)
        #expect(answers.load(for: URL(string: "https://api.example.com/7tv/sets/01H?page=2")!, scope: "key-a") == nil)
        #expect(answers.load(for: url, scope: "key-b") == nil)
        answers.clear()
        #expect(answers.load(for: url, scope: "key-a") == nil)
    }

    @Test func answersAreTrimmedByCount() async throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let answers = SevenTvAnswerCache(directory: dir)
        let over = SevenTvAnswerCache.maxFiles + 5
        for n in 0..<over {
            answers.save(Data("{}".utf8), for: URL(string: "https://api.example.com/7tv/sets/\(n)")!, scope: "k")
        }
        let left = try FileManager.default.contentsOfDirectory(atPath: dir.path).count
        #expect(left <= SevenTvAnswerCache.maxFiles)
        #expect(left >= SevenTvAnswerCache.maxFiles * 4 / 5)
        // the newest stays
        #expect(answers.load(for: URL(string: "https://api.example.com/7tv/sets/\(over - 1)")!, scope: "k") != nil)
    }

    @Test func nothingIsKeptWithoutAFolder() {
        let none = SevenTvAnswerCache(directory: nil)
        let url = URL(string: "https://api.example.com/7tv")!
        none.save(Data("{}".utf8), for: url, scope: "")
        #expect(none.load(for: url, scope: "") == nil)
        none.clear()
    }
}

// MARK: - the live client's offline answers

@Suite(.serialized)
struct SevenTvOfflineTests {
    private static let linked = #"{"status":"success","linked":true,"channels":[]}"#
    private static let key = "2d6b9e10-5c3a-4f7e-8a21-9b0c4d7e1f35"

    private func setup(key: String? = key) -> (HTTPCobaltClient, online: Network, dir: URL, host: String) {
        let host = "t\(UUID().uuidString.prefix(8).lowercased()).test"
        let dir = tempDir()
        let online = Network()
        StubProtocol.install(host: host) { req in
            guard online.isUp else { throw URLError(.notConnectedToInternet) }
            switch (req.httpMethod ?? "GET", req.url?.path ?? "") {
            case ("GET", "/7tv"): return (200, [:], Data(Self.linked.utf8))
            case ("DELETE", "/7tv"): return (200, [:], Data(#"{"status":"success","linked":false}"#.utf8))
            default: return (404, [:], Data())
            }
        }
        var client = HTTPCobaltClient(
            baseURL: URL(string: "https://\(host)")!, apiKey: { key }, session: StubProtocol.session())
        client.answers = SevenTvAnswerCache(directory: dir)
        return (client, online, dir, host)
    }

    @Test func theLastAnswerStandsInWhenTheNetworkIsGone() async throws {
        let (client, online, dir, _) = setup()
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(try await client.sevenTvStatus().linked)
        online.set(false)
        #expect(try await client.sevenTvStatus().linked)
    }

    @Test func noKeptAnswerStillFails() async throws {
        let (client, online, dir, _) = setup()
        defer { try? FileManager.default.removeItem(at: dir) }
        online.set(false)
        await #expect(throws: CobaltError.self) { try await client.sevenTvStatus() }
    }

    @Test func anotherKeyDoesNotReadTheAnswer() async throws {
        let (client, online, dir, host) = setup()
        defer { try? FileManager.default.removeItem(at: dir) }
        _ = try await client.sevenTvStatus()
        online.set(false)
        var other = HTTPCobaltClient(
            baseURL: URL(string: "https://\(host)")!, apiKey: { "another-key" }, session: StubProtocol.session())
        other.answers = SevenTvAnswerCache(directory: dir)
        await #expect(throws: CobaltError.self) { try await other.sevenTvStatus() }
    }

    @Test func unlinkForgetsTheKeptAnswers() async throws {
        let (client, online, dir, _) = setup()
        defer { try? FileManager.default.removeItem(at: dir) }
        _ = try await client.sevenTvStatus()
        _ = try await client.unlinkSevenTv(logout: false)
        online.set(false)
        await #expect(throws: CobaltError.self) { try await client.sevenTvStatus() }
    }
}
