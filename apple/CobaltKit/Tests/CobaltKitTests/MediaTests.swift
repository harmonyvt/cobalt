import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import CobaltKit

/// AVFoundation and ImageIO for real, on files the tests generate (an `AVAssetWriter` clip, a PNG,
/// a 188-byte animated WebP) and on a loopback server that serves ranges like `/studio/<sid>/source`.
@Suite(.serialized)
struct MediaToolsTests {
    let tools = SystemMediaTools()

    private func collect(_ stream: AsyncThrowingStream<Frame, Error>) async throws -> [Frame] {
        var out: [Frame] = []
        for try await frame in stream { out.append(frame) }
        return out
    }

    private func expectFilmstrip(_ frames: [Frame]) {
        #expect(frames.map(\.index) == Array(0..<9))                                   // nine, in order
        #expect(frames.allSatisfy { max($0.image.width, $0.image.height) <= 360 })
        #expect(frames.allSatisfy { $0.image.height > $0.image.width })                 // 96×160 stays portrait
        let first = TestImages.meanColor(frames[0].image)
        let last = TestImages.meanColor(frames[8].image)
        #expect(first.b > first.r && last.r > last.b)                                   // blue → red over the clip
        #expect(last.r - first.r > 100)
        let reds = frames.map { TestImages.meanColor($0.image).r }
        #expect(zip(reds, reds.dropFirst()).allSatisfy { $0 <= $1 + 2 })                // time moves forward
    }

    @Test func probeReadsDurationAndSizeOfALocalVideo() async throws {
        let clip = try await TestVideo.clip()
        let info = try #require(await tools.probe(file: clip))
        #expect(abs((info.duration ?? 0) - 6) < 0.2)
        #expect(info.width == 96 && info.height == 160 && !info.isImage)
        #expect((info.bytes ?? 0) > 0)
        let notVideo = try makeTempFile("notes.txt")
        #expect(await tools.probe(file: notVideo) == nil)
    }

    @Test func filmstripFromALocalFile() async throws {
        let clip = try await TestVideo.clip()
        expectFilmstrip(try await collect(tools.frames(of: .local(clip), duration: nil, count: 9)))
        // a duration the caller already knows is used as is
        let known = try await collect(tools.frames(of: .local(clip), duration: 6, count: 9))
        #expect(known.count == 9)
    }

    @Test func filmstripFromAnExtensionLessRangeURL() async throws {
        let data = try Data(contentsOf: try await TestVideo.clip())
        let server = try await LoopbackServer.start { request in
            LoopbackServer.serve(data, contentType: "video/mp4", for: request)
        }
        defer { server.stop() }
        let url = server.base.appendingPathComponent("studio/AbCdEfGhIjKlMnOpQrStUv/source")
        #expect(url.pathExtension.isEmpty)
        expectFilmstrip(try await collect(tools.frames(of: .remote(url), duration: 6, count: 9)))

        // it read the file in ranges, never as one whole download
        let ranged = server.requests.filter { $0.headers["range"] != nil }
        #expect(!ranged.isEmpty)
        #expect(ranged.contains { $0.headers["range"] != "bytes=0-" } || ranged.count > 1)
    }

    @Test func aWrongContentTypeFallsBackToTheMimeOverride() async throws {
        let data = try Data(contentsOf: try await TestVideo.clip())
        let server = try await LoopbackServer.start { request in
            LoopbackServer.serve(data, contentType: "application/octet-stream", for: request)
        }
        defer { server.stop() }
        let url = server.base.appendingPathComponent("studio/AbCdEfGhIjKlMnOpQrStUv/source")
        expectFilmstrip(try await collect(tools.frames(of: .remote(url), duration: nil, count: 9)))
    }

    @Test func anUnreadableSourceEndsTheStreamWithAnError() async throws {
        let server = try await LoopbackServer.start { _ in .json(#"{"status":"error","error":{"code":"error.studio.expired"}}"#, status: 410) }
        defer { server.stop() }
        let url = server.base.appendingPathComponent("studio/AbCdEfGhIjKlMnOpQrStUv/source")
        await #expect(throws: (any Error).self) { _ = try await collect(tools.frames(of: .remote(url), duration: 6, count: 9)) }
        let junk = try makeTempFile("junk.mp4", bytes: 2_000)
        await #expect(throws: (any Error).self) { _ = try await collect(tools.frames(of: .local(junk), duration: nil, count: 9)) }
    }

    @Test func cancellingStopsTheFilmstrip() async throws {
        let clip = try await TestVideo.clip()
        let stream = tools.frames(of: .local(clip), duration: nil, count: 9)
        let task = Task { () -> Int in
            var n = 0
            for try await _ in stream { n += 1; if n == 2 { try await Task.sleep(for: .seconds(30)) } }
            return n
        }
        try await Task.sleep(for: .milliseconds(300))
        task.cancel()
        let result = await task.result
        #expect({ if case .failure = result { return true } else { return false } }())
    }

    // MARK: posters

    @Test func posterFromALocalVideoAndFromARangeURL() async throws {
        let clip = try await TestVideo.clip()
        let dir = try makeTempDirectory()

        let local = dir.appendingPathComponent("local.jpg")
        #expect(await tools.poster(for: clip, isImage: false, to: local))
        try expectJPEG(local, longEdge: 160)

        let data = try Data(contentsOf: clip)
        let server = try await LoopbackServer.start { LoopbackServer.serve(data, contentType: "video/mp4", for: $0) }
        defer { server.stop() }
        let remote = dir.appendingPathComponent("remote.jpg")
        #expect(await tools.poster(of: .remote(server.base.appendingPathComponent("studio/AbCdEfGhIjKlMnOpQrStUv/source")), to: remote))
        try expectJPEG(remote, longEdge: 160)

        #expect(await tools.poster(for: try makeTempFile("junk.mp4"), isImage: false, to: dir.appendingPathComponent("none.jpg")) == false)
    }

    @Test func posterFromAnAnimatedWebpIsItsFirstFrame() async throws {
        let dir = try makeTempDirectory()
        let webp = dir.appendingPathComponent("anim.webp")
        try TestImages.animatedWebP.write(to: webp)
        let poster = dir.appendingPathComponent("anim.jpg")
        #expect(await tools.poster(for: webp, isImage: true, to: poster))
        try expectJPEG(poster, longEdge: 24)
        let image = try #require(SystemMediaTools.thumbnail(of: webp))
        let c = TestImages.meanColor(image)
        #expect(c.r > 200 && c.g < 60 && c.b < 60)                      // frame 0 is red
    }

    private func expectJPEG(_ url: URL, longEdge: Int) throws {
        let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
        #expect(CGImageSourceGetType(source) as String? == "public.jpeg")
        let props = try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        let w = (props[kCGImagePropertyPixelWidth] as? Int) ?? 0
        let h = (props[kCGImagePropertyPixelHeight] as? Int) ?? 0
        #expect(max(w, h) == longEdge && max(w, h) <= 360)
    }

    // MARK: ImageIO

    @Test func animatedWebpDecodesWithItsFrameDelays() throws {
        let webp = try makeTempDirectory().appendingPathComponent("anim.webp")
        try TestImages.animatedWebP.write(to: webp)
        let info = try #require(tools.imageInfo(file: webp))
        #expect(info.width == 24 && info.height == 16 && info.isImage)
        #expect(abs((info.duration ?? 0) - 0.6) < 0.001)                // 100 + 200 + 300 ms
        #expect(info.bytes == Int64(TestImages.animatedWebP.count))

        let source = try #require(CGImageSourceCreateWithURL(webp as CFURL, nil))
        #expect(CGImageSourceGetCount(source) == 3)
        let colors = (0..<3).compactMap { CGImageSourceCreateImageAtIndex(source, $0, nil) }.map(TestImages.meanColor)
        #expect(colors.count == 3)
        #expect(colors[0].r > 200 && colors[1].g > 200 && colors[2].b > 200)
    }

    @Test func stillImagesReportSizeButNoDuration() throws {
        let png = try makeTempDirectory().appendingPathComponent("still.png")
        try TestImages.png(width: 40, height: 30).write(to: png)
        let info = try #require(tools.imageInfo(file: png))
        #expect(info.width == 40 && info.height == 30 && info.duration == nil && info.isImage)
        #expect(tools.imageInfo(file: try makeTempFile("notes.txt")) == nil)
    }

    // MARK: upload content types

    @Test func uploadContentTypesStayInsideWhatTheServerTakes() {
        #expect(MIME.type(forFileName: "IMG_0412.MOV") == "video/quicktime")
        #expect(MIME.type(forFileName: "clip.mp4") == "video/mp4")
        #expect(MIME.type(forFileName: "clip.m4v") == "video/mp4")              // not video/x-m4v
        #expect(MIME.type(forFileName: "photo.heic") == "image/heic")
        #expect(MIME.type(forFileName: "photo.heif") == "image/heic")
        #expect(MIME.type(forFileName: "a.gif") == "image/gif")
        #expect(MIME.type(forFileName: "a.png") == "image/png")
        #expect(MIME.type(forFileName: "a.jpg") == "image/jpeg")
        #expect(MIME.type(forFileName: "a.webp") == "image/webp")
        #expect(MIME.type(forFileName: "noextension") == "application/octet-stream")
        #expect(!MIME.uploadTypes.contains(MIME.type(forFileName: "notes.pdf")))   // the server will say 415
    }
}
