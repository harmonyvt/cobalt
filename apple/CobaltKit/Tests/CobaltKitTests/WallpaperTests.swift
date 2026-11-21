import AVFoundation
import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import CobaltKit

// The wallpaper maker (apple/CONTRACT-WALLPAPER.md): the range rules, the Duo cut, and a real Live Photo written from an
// animated gif, with the identifier in both files and the still-image-time sample in the movie.

struct WallpaperTests {
    /// A 2 s gif (20 frames, 0.1 s each) of a square moving across a gradient, `width` × `height`.
    static func gif(width: Int = 360, height: Int = 640, frames: Int = 20) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("wallpaper-test-\(UUID().uuidString).gif")
        let dest = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.gif.identifier as CFString, frames, nil))
        for i in 0..<frames {
            let ctx = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpaceCreateDeviceRGB(),
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            ctx.setFillColor(red: 0.3, green: 0.2, blue: 0.5, alpha: 1)
            ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
            ctx.setFillColor(red: 1, green: 0.6, blue: 0.8, alpha: 1)
            ctx.fillEllipse(in: CGRect(x: 40 + i * 6, y: 160, width: 200, height: 200))
            let image = try #require(ctx.makeImage())
            let props = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 0.1]] as CFDictionary
            CGImageDestinationAddImage(dest, image, props)
        }
        #expect(CGImageDestinationFinalize(dest))
        return url
    }

    @Test func timesEndOnTheLastFrame() {
        let times = WallpaperMaker.times(start: 1, length: 3)
        #expect(times.count == 90)
        #expect(times.first == 1)
        #expect(abs((times.last ?? 0) - 4) < 0.0001)
    }

    @Test func evenSides() {
        #expect(WallpaperMaker.even(CGSize(width: 361, height: 641)) == CGSize(width: 360, height: 640))
    }

    @Test func duoHalvesLeaveTheHingeOut() {
        let image = CIImage(color: .red).cropped(to: CGRect(x: 0, y: 0, width: 762, height: 800))
        let left = WallpaperMaker.Half.left.crop(image).extent
        let right = WallpaperMaker.Half.right.crop(image).extent
        #expect(left.minX == 0 && left.width == 372)
        #expect(right.maxX == 762 && right.width == 372)
        #expect(right.minX - left.maxX == 18)
    }

    @Test func gifOpensAsAnimated() async throws {
        let url = try Self.gif()
        defer { try? FileManager.default.removeItem(at: url) }
        let source = try await WallpaperSource.open(url)
        #expect(source.kind == .animated)
        #expect(abs(source.duration - 2) < 0.01)
        #expect(source.size == CGSize(width: 360, height: 640))
        let maker = WallpaperMaker(source: source)
        let r = maker.range(start: 5, length: 3)
        #expect(r.start == 0 && abs(r.length - 2) < 0.01)
    }

    @Test func notAPictureIsUnreadable() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("wallpaper-junk-\(UUID().uuidString).bin")
        try Data("not a picture".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        await #expect(throws: (any Error).self) { _ = try await WallpaperSource.open(url) }
    }

    @Test(arguments: [WallpaperLook(), WallpaperLook(blur: 0.6, parallax: 0.8)])
    func writesALivePhoto(look: WallpaperLook) async throws {
        let url = try Self.gif()
        defer { try? FileManager.default.removeItem(at: url) }
        let maker = WallpaperMaker(source: try await WallpaperSource.open(url))
        let files = try await maker.make(start: 0, length: 3, look: look, target: .lockScreen)
        defer { files.forEach { $0.remove() } }
        let file = try #require(files.first)
        #expect(files.count == 1)

        // the still: a HEIC whose maker note 17 is the identifier
        let still = try #require(CGImageSourceCreateWithURL(file.still as CFURL, nil))
        let props = try #require(CGImageSourceCopyPropertiesAtIndex(still, 0, nil) as? [CFString: Any])
        let apple = try #require(props[kCGImagePropertyMakerAppleDictionary] as? [String: Any])
        let identifier = try #require(apple["17"] as? String)

        // the movie: the same identifier, a video track, and a metadata track
        let movie = AVURLAsset(url: try #require(file.video))
        let items = try await movie.load(.metadata)
        let ids = try await items.asyncCompactMap { item -> String? in
            guard (item.key as? String) == "com.apple.quicktime.content.identifier" else { return nil }
            return try await item.load(.stringValue)
        }
        #expect(ids == [identifier])
        #expect(try await movie.loadTracks(withMediaType: .video).count == 1)
        #expect(try await movie.loadTracks(withMediaType: .metadata).count == 1)
        let seconds = try await movie.load(.duration).seconds
        #expect(seconds > 1.8 && seconds < 2.2)
    }

    @Test func duoPairWritesTwo() async throws {
        let url = try Self.gif(width: 762, height: 800, frames: 12)
        defer { try? FileManager.default.removeItem(at: url) }
        let maker = WallpaperMaker(source: try await WallpaperSource.open(url))
        let files = try await maker.make(start: 0, length: 3, look: WallpaperLook(), target: .duoPair)
        defer { files.forEach { $0.remove() } }
        #expect(files.count == 2)
        for file in files {
            let still = try #require(CGImageSourceCreateWithURL(file.still as CFURL, nil))
            let props = try #require(CGImageSourceCopyPropertiesAtIndex(still, 0, nil) as? [CFString: Any])
            #expect((props[kCGImagePropertyPixelWidth] as? Int) == 372)
        }
    }

    @Test func strokesPaintTheMask() throws {
        let renderer = WallpaperRenderer()
        let extent = CGRect(x: 0, y: 0, width: 100, height: 100)
        let look = WallpaperLook(softness: 0, findsSubject: false, strokes: [
            WallpaperStroke(points: [CGPoint(x: 0.25, y: 0.25)], radius: 0.1, adds: true),
        ])
        let mask = renderer.finalMask(found: nil, look: look, extent: extent)
        let image = try #require(renderer.cgImage(mask))
        let data = try #require(image.dataProvider?.data as Data?)
        let row = image.bytesPerRow
        // top left quarter (the stroke) is white, bottom right is black; CGImage rows run top to bottom
        #expect(data[25 * row + 25 * 4] > 200)
        #expect(data[75 * row + 75 * 4] < 50)
    }
}

private extension Array {
    func asyncCompactMap<T>(_ transform: (Element) async throws -> T?) async rethrows -> [T] {
        var out: [T] = []
        for element in self { if let value = try await transform(element) { out.append(value) } }
        return out
    }
}
