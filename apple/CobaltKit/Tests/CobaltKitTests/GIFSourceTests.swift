import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import CobaltKit

/// An animated GIF as the app meets it: cobalt turns an X "gif" into a real .gif by default, and a
/// server that did not know labelled it `video/mp4`, so the file is a GIF under an .mp4 name, or under
/// no name at all. AVFoundation cannot open one; every reader must work from the bytes.
enum TestGIF {
    /// `colors` frames of flat red/green/blue/... each shown `delays[i]` seconds (a delay of 0.01 is what an
    /// encoder writes for "as fast as possible").
    static func make(at url: URL, size: Int = 64, colors: [(UInt8, UInt8, UInt8)], delays: [Double]) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.gif.identifier as CFString, colors.count, nil) else {
            throw TestVideo.Failure(message: "gif destination")
        }
        CGImageDestinationSetProperties(dest, [
            kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0],
        ] as CFDictionary)
        for (i, c) in colors.enumerated() {
            let ctx = CGContext(
                data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            ctx.setFillColor(red: CGFloat(c.0) / 255, green: CGFloat(c.1) / 255, blue: CGFloat(c.2) / 255, alpha: 1)
            ctx.fill(CGRect(x: 0, y: 0, width: size, height: size))
            CGImageDestinationAddImage(dest, ctx.makeImage()!, [
                kCGImagePropertyGIFDictionary: [
                    kCGImagePropertyGIFDelayTime: delays[i], kCGImagePropertyGIFUnclampedDelayTime: delays[i],
                ],
            ] as CFDictionary)
        }
        guard CGImageDestinationFinalize(dest) else { throw TestVideo.Failure(message: "gif finalize") }
    }

    static let rgb: [(UInt8, UInt8, UInt8)] = [(255, 0, 0), (0, 255, 0), (0, 0, 255), (255, 255, 0)]

    /// 4 frames, 1 s each: red, green, blue, yellow; saved as `name`.
    static func clip(named name: String = "twitter_1.mp4") throws -> URL {
        let url = try makeTempDirectory().appendingPathComponent(name)
        try make(at: url, colors: rgb, delays: [1, 1, 1, 1])
        return url
    }
}

@Suite(.serialized)
struct GIFSourceTests {
    let tools = SystemMediaTools()

    // MARK: what AVFoundation does with it (the reported failure)

    @Test func avFoundationCannotOpenAGIFStoredAsAnMP4() async throws {
        let gif = try TestGIF.clip(named: "twitter_1897839691212202479.mp4")
        // the reported failure: the video readers find nothing in it ...
        await #expect(throws: (any Error).self) { _ = try await SystemMediaTools.openAsset(gif) }
        // ... so a video-only probe has no length, size or poster to give
        let asset = AVURLAsset(url: gif)
        #expect((try? await asset.load(.isPlayable)) != true)
    }

    // MARK: sniffing

    @Test func aGIFIsRecognisedByItsBytesNotItsName() throws {
        #expect(MediaSniff.isGIF(file: try TestGIF.clip(named: "clip.mp4")))
        #expect(MediaSniff.isGIF(file: try TestGIF.clip(named: "no-extension")))
        #expect(MediaSniff.isGIF(Data("GIF87a....".utf8)))
        #expect(!MediaSniff.isGIF(Data("GIF8".utf8)))
        let video = try makeTempFile("clip.gif", bytes: 500)                  // a .gif name with other bytes
        #expect(!MediaSniff.isGIF(file: video))
        #expect(!MediaSniff.isGIF(file: URL(string: "https://example.com/x.gif")!))
    }

    @Test func frameDelaysFollowFfmpegNotImageIOsClamp() {
        func props(_ d: Double) -> [CFString: Any] { [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFUnclampedDelayTime: d]] }
        #expect(GIFTimeline.frameDelay(props(0)) == 0.1)
        #expect(GIFTimeline.frameDelay(props(0.01)) == 0.1)
        #expect(GIFTimeline.frameDelay(props(0.02)) == 0.02)
        #expect(GIFTimeline.frameDelay(props(0.5)) == 0.5)
        #expect(GIFTimeline.frameDelay([:]) == 0.1)
    }

    // MARK: probing, frames, poster, flipbook (all through ImageIO)

    @Test func probeGivesALengthAndSizeNotNil() async throws {
        let gif = try TestGIF.clip()
        let info = try #require(await tools.probe(file: gif))
        #expect(abs((info.duration ?? 0) - 4) < 0.01)
        #expect(info.width == 64 && info.height == 64 && !info.isImage)
        #expect((info.bytes ?? 0) > 0)
    }

    @Test func filmstripOfALocalGIFComesFromItsFramesInOrder() async throws {
        let gif = try TestGIF.clip()
        var frames: [Frame] = []
        for try await f in tools.frames(of: .local(gif), duration: nil, count: 4) { frames.append(f) }
        #expect(frames.map(\.index) == [0, 1, 2, 3])
        let colors = frames.map { TestImages.meanColor($0.image) }
        #expect(colors[0].r > 200 && colors[0].g < 60)                        // red
        #expect(colors[1].g > 200 && colors[1].r < 60)                        // green
        #expect(colors[2].b > 200 && colors[2].r < 60)                        // blue
        #expect(colors[3].r > 200 && colors[3].g > 200 && colors[3].b < 60)   // yellow
        #expect(frames.allSatisfy { max($0.image.width, $0.image.height) <= 360 })
    }

    @Test func filmstripIsSpacedByTimeNotByFrameIndex() async throws {
        // red for 3 s, then green for 1 s: nine slices of 4/9 s have their middles at 0.22 ... 3.78 s, so seven
        // land on red and two on green (spaced by frame index it would be five and four)
        let url = try makeTempDirectory().appendingPathComponent("uneven")
        try TestGIF.make(at: url, colors: [(255, 0, 0), (0, 255, 0)], delays: [3, 1])
        var frames: [Frame] = []
        for try await f in tools.frames(of: .local(url), duration: nil, count: 9) { frames.append(f) }
        let greens = frames.filter { TestImages.meanColor($0.image).g > 200 }.count
        #expect(frames.count == 9 && greens == 2)
    }

    @Test func filmstripOfARemoteExtensionLessGIFLabelledVideoMp4() async throws {
        let data = try Data(contentsOf: try TestGIF.clip())
        let server = try await LoopbackServer.start { request in
            LoopbackServer.serve(data, contentType: "video/mp4", for: request)      // what the old server said
        }
        defer { server.stop() }
        let url = server.base.appendingPathComponent("studio/AbCdEfGhIjKlMnOpQrStUv/source")
        var frames: [Frame] = []
        let started = Date()
        for try await f in tools.frames(of: .remote(url), duration: 4, count: 4) { frames.append(f) }
        #expect(frames.map(\.index) == [0, 1, 2, 3])
        #expect(TestImages.meanColor(frames[2].image).b > 200)
        // it did not sit through AVFoundation's retry rounds (0.6 s + 1.8 s) first
        #expect(Date().timeIntervalSince(started) < 2.0)
    }

    @Test func posterAndFlipbookOfAGIFUnderAnMP4Name() async throws {
        let gif = try TestGIF.clip(named: "twitter_1.mp4")
        let dir = try makeTempDirectory()
        let poster = dir.appendingPathComponent("p.jpg")
        #expect(await tools.poster(for: gif, isImage: false, to: poster))
        let c = TestImages.meanColor(try #require(SystemMediaTools.thumbnail(of: gif)))
        #expect(c.r > 200 && c.g < 60)                                          // first frame
        let flip = await tools.previewFrames(of: gif, animatedImage: false, count: 12, maxEdge: 160)
        #expect(flip.count == 4)                                                // one per frame, in order
    }

    // MARK: the mp4 the players use

    @Test func playableCopyIsARealVideoOfTheSameLengthAndPicture() async throws {
        let gif = try TestGIF.clip()
        let out = try makeTempDirectory().appendingPathComponent("copy.mp4")
        #expect(await tools.playableCopy(of: gif, to: out))
        let probed = try #require(await tools.probe(file: out))
        #expect(abs((probed.duration ?? 0) - 4) < 0.2)
        #expect(probed.width == 64 && probed.height == 64)
        // AVFoundation opens it, and frames from it read red, green, blue, yellow
        var frames: [Frame] = []
        for try await f in tools.frames(of: .local(out), duration: nil, count: 4) { frames.append(f) }
        #expect(frames.count == 4)
        let colors = frames.map { TestImages.meanColor($0.image) }
        #expect(colors[0].r > colors[0].b + 100)
        #expect(colors[1].g > colors[1].r + 80 || colors[1].g > 150)
        #expect(colors[2].b > colors[2].r + 100)
    }

    @Test func playableCopyRefusesAnythingThatIsNotAGIF() async throws {
        let junk = try makeTempFile("clip.mp4")
        let out = try makeTempDirectory().appendingPathComponent("copy.mp4")
        #expect(await tools.playableCopy(of: junk, to: out) == false)
        #expect(!FileManager.default.fileExists(atPath: out.path))
        let video = try await TestVideo.clip()
        #expect(await tools.playableCopy(of: video, to: out) == false)
    }

    @Test func oddSizedGIFsAreWrittenWithEvenSides() async throws {
        let url = try makeTempDirectory().appendingPathComponent("odd.gif")
        try TestGIF.make(at: url, size: 51, colors: [(255, 0, 0), (0, 0, 255)], delays: [0.5, 0.5])
        let out = url.deletingLastPathComponent().appendingPathComponent("odd.mp4")
        #expect(await tools.playableCopy(of: url, to: out))
        let probed = try #require(await tools.probe(file: out))
        #expect(probed.width == 50 && probed.height == 50)
    }

    // MARK: the store keeps a playable original

    @MainActor @Test func theStoreKeepsAGIFOriginalAsAnMP4WithAPosterAndFlipbook() async throws {
        let root = try makeTempDirectory()
        let store = OfflineStore(root: root, tools: SystemMediaTools())
        let gif = try TestGIF.clip(named: "twitter_1.mp4")
        let stored = try await store.add(
            file: gif, kind: .original,
            media: MediaInfo(name: "twitter_1", duration: 4, width: 64, height: 64, bytes: nil, isImage: false),
            sessionID: "s1", link: nil, remoteURL: nil, move: true)
        let file = try #require(stored.fileURL)
        #expect(file.pathExtension == "mp4" && !MediaSniff.isGIF(file: file))
        // the planet's, the trim preview's and full screen's player can open it
        #expect(try await AVURLAsset(url: file).load(.isPlayable))
        #expect(stored.posterURL != nil)
        await store.ensurePreviewFrames(for: stored)
        #expect(store.videos.first { $0.id == stored.id }?.previewFrameURLs.count ?? 0 >= 2)
        // a second look at the same session is the same entry
        #expect(store.videos.filter { $0.sessionID == "s1" }.count == 1)
    }

    @MainActor @Test func aRealVideoOriginalIsStoredUntouched() async throws {
        let store = OfflineStore(root: try makeTempDirectory(), tools: SystemMediaTools())
        let clip = try await TestVideo.clip(seconds: 2)
        let copy = try makeTempDirectory().appendingPathComponent("v.mp4")
        try FileManager.default.copyItem(at: clip, to: copy)
        let before = try Data(contentsOf: copy)
        let stored = try await store.add(
            file: copy, kind: .original,
            media: MediaInfo(name: "v", duration: 2, width: 96, height: 160, bytes: nil, isImage: false),
            sessionID: "s2", link: nil, remoteURL: nil, move: true)
        #expect(try Data(contentsOf: try #require(stored.fileURL)) == before)
    }
}
