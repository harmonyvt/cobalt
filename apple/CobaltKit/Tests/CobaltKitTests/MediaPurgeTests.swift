import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import Synchronization
import Testing
@testable import CobaltKit

// Lane D of the lifecycle fix (the audit: "nothing frees caches on a memory warning; heavy players have no shared pause/cap
// rule"): the in-memory picture caches empty on a purge and keep what is on disk, an animation stops when its owner is
// freed, and the player pool's cap and its pause and resume around the app leaving the screen.

private final class FetchCount: Sendable {
    private let calls = Mutex(0)
    var value: Int { calls.withLock { $0 } }
    func add() { calls.withLock { $0 += 1 } }
}

private func tempDir() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("media-purge-\(UUID().uuidString)", isDirectory: true)
}

private func box(width: Int = 8, height: Int = 8) throws -> ImageBox {
    let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
    let ctx = try #require(CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    ctx.setFillColor(CGColor(red: 0.9, green: 0.3, blue: 0.1, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
    return ImageBox(try #require(ctx.makeImage()))
}

/// A two-frame animated GIF, so ImageIO has something to animate.
private func gif() throws -> Data {
    let out = NSMutableData()
    let dest = try #require(CGImageDestinationCreateWithData(out, "com.compuserve.gif" as CFString, 2, nil))
    let frame: [CFString: Any] = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 0.1]]
    CGImageDestinationSetProperties(dest, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
    CGImageDestinationAddImage(dest, try box().image, frame as CFDictionary)
    CGImageDestinationAddImage(dest, try box(width: 8, height: 8).image, frame as CFDictionary)
    #expect(CGImageDestinationFinalize(dest))
    return out as Data
}

@MainActor
@Suite struct MediaPurgeTests {
    // MARK: caches

    @Test func aMemoryWarningEmptiesAPictureCache() throws {
        let lifecycle = AppLifecycle()
        let cache = MediaMemoryCache(costLimit: 1024 * 1024, countLimit: 10)
        PurgeHook.register(with: lifecycle) { [weak cache] _ in cache?.removeAll() }
        cache.store(try box(), forKey: "a")
        #expect(cache.image(forKey: "a") != nil)
        lifecycle.feed(.memoryWarning)
        #expect(cache.image(forKey: "a") == nil)
    }

    @Test func leavingTheScreenEmptiesItToo() throws {
        let lifecycle = AppLifecycle()
        let cache = MediaMemoryCache(costLimit: 1024 * 1024, countLimit: 10)
        PurgeHook.register(with: lifecycle) { [weak cache] _ in cache?.removeAll() }
        lifecycle.feed(.becameActive)
        cache.store(try box(), forKey: "b")
        lifecycle.feed(.willResignActive)
        #expect(cache.image(forKey: "b") != nil)    // still on screen: kept
        lifecycle.feed(.didEnterBackground)
        #expect(cache.image(forKey: "b") == nil)
    }

    @Test func theSharedPictureCacheEmpties() throws {
        let key = "test|purge|\(UUID().uuidString)"
        MediaPipeline.memory.store(try box(), forKey: key)
        #expect(MediaPipeline.memory.image(forKey: key) != nil)
        MediaPipeline.memory.removeAll()
        #expect(MediaPipeline.memory.image(forKey: key) == nil)
    }

    @Test func anEmotePurgeKeepsTheDisk() async throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let count = FetchCount()
        let url = URL(string: "https://cdn.7tv.app/emote/purge/2x.webp")!
        let bytes = Data([1, 2, 3, 4])
        let cache = EmoteCache(directory: dir, fetch: { _ in count.add(); return bytes })
        #expect(await cache.data(for: url) == bytes)
        #expect(cache.memoryData(for: url) == bytes)

        let lifecycle = AppLifecycle()
        PurgeHook.register(with: lifecycle) { [weak cache] _ in cache?.purgeMemory() }
        lifecycle.feed(.memoryWarning)

        #expect(cache.memoryData(for: url) == nil)
        #expect(await cache.has(url))                 // the file is still there
        #expect(await cache.data(for: url) == bytes)   // read back from disk
        #expect(count.value == 1)                      // never fetched again
    }

    // MARK: animations

    @Test func anAnimationStopsWhenItsSlotIsFreed() throws {
        let data = try gif()
        let animation = try #require(MediaAnimation.play(data: data, maxPixel: 8) { _ in })
        var slot: MediaAnimationSlot? = MediaAnimationSlot()
        slot?.set(animation)
        #expect(!animation.isStopped)
        slot = nil
        #expect(animation.isStopped)
    }

    @Test func replacingOrClearingASlotStopsTheOldAnimation() throws {
        let data = try gif()
        let first = try #require(MediaAnimation.play(data: data, maxPixel: 8) { _ in })
        let second = try #require(MediaAnimation.play(data: data, maxPixel: 8) { _ in })
        let slot = MediaAnimationSlot()
        slot.set(first)
        slot.set(second)
        #expect(first.isStopped && !second.isStopped)
        slot.stop()
        #expect(second.isStopped && slot.animation == nil)
    }

    // MARK: the player cap

    @Test func underTheCapNothingPauses() {
        let slots = (1...3).map { PlayerCap.Slot(id: $0, started: $0, protected: false) }
        #expect(PlayerCap.toPause(slots, cap: 4, keep: 3).isEmpty)
        #expect(PlayerCap.toPause(slots, cap: 3, keep: 3).isEmpty)
    }

    @Test func overTheCapTheOldestUnprotectedPause() {
        let slots = [
            PlayerCap.Slot(id: 1, started: 5, protected: false),
            PlayerCap.Slot(id: 2, started: 1, protected: true),     // the hero: oldest, never chosen
            PlayerCap.Slot(id: 3, started: 2, protected: false),
            PlayerCap.Slot(id: 4, started: 3, protected: false),
            PlayerCap.Slot(id: 5, started: 9, protected: false),    // just asked to play
            PlayerCap.Slot(id: 6, started: 4, protected: false),
        ]
        #expect(PlayerCap.toPause(slots, cap: 4, keep: 5) == [3, 4])
        #expect(PlayerCap.toPause(slots, cap: 1, keep: 5) == [3, 4, 6, 1])
    }

    @Test func protectedPlayersAreNeverPausedEvenOverTheCap() {
        let slots = (1...5).map { PlayerCap.Slot(id: $0, started: $0, protected: true) }
        #expect(PlayerCap.toPause(slots, cap: 2).isEmpty)
        #expect(PlayerCap.toPause([], cap: 0).isEmpty)
    }

    // MARK: the pool

    /// iOS pauses on "resign active", the Mac on "hidden" (another app in front is still on screen there).
    private var leave: LifecycleEvent {
        #if os(macOS)
        return .hidden
        #else
        return .willResignActive
        #endif
    }

    private func isPlaying(_ player: AVPlayer) -> Bool { player.rate != 0 }

    @Test func thePoolPausesTheOldestPastItsCap() {
        let pool = PlayerPool(lifecycle: AppLifecycle(), cap: 2)
        let players = (0..<3).map { _ in AVPlayer() }
        for player in players { pool.play(player, as: .orbit) }
        #expect(!isPlaying(players[0]))
        #expect(isPlaying(players[1]) && isPlaying(players[2]))
        for player in players { player.pause() }
    }

    @Test func thePoolPausesOnLeavingAndResumesWhatTheOwnerStillWants() {
        let lifecycle = AppLifecycle()
        let pool = PlayerPool(lifecycle: lifecycle, cap: 4)
        lifecycle.feed(.becameActive)
        let kept = AVPlayer(), pausedByOwner = AVPlayer(), dropped = AVPlayer()
        pool.play(kept, as: .hero)
        pool.play(pausedByOwner, as: .loop)
        pool.play(dropped, as: .orbit)
        pool.pause(pausedByOwner)

        lifecycle.feed(leave)
        #expect(!isPlaying(kept) && !isPlaying(dropped))
        // a player started while the app is away waits for it to come back
        let late = AVPlayer()
        pool.play(late, as: .focus)
        #expect(!isPlaying(late))
        pool.forget(dropped)

        lifecycle.feed(.becameActive)
        #expect(isPlaying(kept) && isPlaying(late))
        #expect(!isPlaying(pausedByOwner) && !isPlaying(dropped))
        for player in [kept, pausedByOwner, dropped, late] { player.pause() }
    }

    @Test func aMemoryWarningReleasesOnlyIdlePlayersThatOfferedTo() {
        let lifecycle = AppLifecycle()
        let pool = PlayerPool(lifecycle: lifecycle, cap: 4)
        let idle = AVPlayer(), busy = AVPlayer(), mine = AVPlayer()
        var released: [String] = []
        pool.play(idle, as: .loop, release: { released.append("idle") })
        pool.play(busy, as: .loop, release: { released.append("busy") })
        pool.play(mine, as: .hero)
        pool.pause(idle)
        pool.pause(mine)
        lifecycle.feed(.memoryWarning)
        #expect(released == ["idle"])
        #expect(pool.counts.known == 2)
        busy.pause()
    }
}
