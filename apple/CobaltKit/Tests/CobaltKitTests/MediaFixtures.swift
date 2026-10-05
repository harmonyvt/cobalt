import AVFoundation
import CoreGraphics
import CoreVideo
import Foundation
import ImageIO
import UniformTypeIdentifiers

enum TestVideo {
    struct Failure: Error { var message: String }

    /// A real H.264 file written with `AVAssetWriter`: every frame is a flat colour that moves from
    /// red to blue over the clip, a key frame every second, so frames taken at different times can
    /// be told apart.
    /// `fragmented`: an empty `moov` and one `moof` per interval (what cobalt's ffmpeg remux writes, and
    /// what an X gif-converted mp4 looks like); `rotated`: a 90 degree `preferredTransform`.
    static func make(
        at url: URL, seconds: Double, width: Int = 96, height: Int = 160, fps: Int = 15,
        fragmented: Bool = false, rotated: Bool = false
    ) async throws {
        try? FileManager.default.removeItem(at: url)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [AVVideoMaxKeyFrameIntervalKey: fps],
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
        ])
        if rotated { input.transform = CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 0, ty: 0) }
        if fragmented { writer.movieFragmentInterval = CMTime(seconds: 0.5, preferredTimescale: 600) }
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? Failure(message: "startWriting") }
        writer.startSession(atSourceTime: .zero)

        let total = Int(seconds * Double(fps))
        for i in 0..<total {
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(2)) }
            var buffer: CVPixelBuffer?
            CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, nil, &buffer)
            guard let buffer else { throw Failure(message: "pixel buffer") }
            let p = Double(i) / Double(max(1, total - 1))
            CVPixelBufferLockBaseAddress(buffer, [])
            if let base = CVPixelBufferGetBaseAddress(buffer) {
                let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
                for y in 0..<height {
                    let row = base.advanced(by: y * rowBytes).assumingMemoryBound(to: UInt8.self)
                    for x in 0..<width {
                        row[x * 4 + 0] = UInt8(255 * (1 - p))   // B
                        row[x * 4 + 1] = 90                     // G
                        row[x * 4 + 2] = UInt8(255 * p)         // R
                        row[x * 4 + 3] = 255
                    }
                }
            }
            CVPixelBufferUnlockBaseAddress(buffer, [])
            guard adaptor.append(buffer, withPresentationTime: CMTime(value: Int64(i), timescale: Int32(fps))) else {
                throw writer.error ?? Failure(message: "append \(i)")
            }
        }
        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? Failure(message: "finish") }
    }

    /// Cached per run: writing a 6 s clip takes a moment, and every test only reads it.
    private static let shared = SharedVideo()
    static func clip(seconds: Double = 6) async throws -> URL { try await shared.url(seconds: seconds) }
}

private actor SharedVideo {
    private var urls: [Double: URL] = [:]

    func url(seconds: Double) async throws -> URL {
        if let u = urls[seconds], FileManager.default.fileExists(atPath: u.path) { return u }
        let dir = try makeTempDirectory()
        let u = dir.appendingPathComponent("clip-\(Int(seconds))s.mp4")
        try await TestVideo.make(at: u, seconds: seconds)
        urls[seconds] = u
        return u
    }
}

enum TestImages {
    /// A 24×16 animated WebP, three flat frames (red, green, blue) shown for 100, 200 and 300 ms
    /// (made with Pillow; 188 bytes).
    static let animatedWebP = Data(base64Encoded:
        "UklGRrQAAABXRUJQVlA4WAoAAAACAAAAFwAADwAAQU5JTQYAAAAAAAAAAABBTk1GKAAAAAAAAAAAABcAAA8AAGQAAAJWUDhMDwAAAC8XwAMABxD9j/4HIqL/AQBBTk1GKAAAAAAAAAAAABcAAA8AAMgAAABWUDhMDwAAAC8XwAMAB9D/iP4HIqL/AQBBTk1GKAAAAAAAAAAAABcAAA8AACwBAABWUDhMDwAAAC8XwAMABxDR//4HIqL/AQA=")!

    /// A PNG of the given size written with ImageIO.
    static func png(width: Int, height: Int) throws -> Data {
        let space = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { throw TestVideo.Failure(message: "context") }
        ctx.setFillColor(CGColor(red: 0.2, green: 0.6, blue: 0.9, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        guard let image = ctx.makeImage() else { throw TestVideo.Failure(message: "image") }
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
            throw TestVideo.Failure(message: "destination")
        }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { throw TestVideo.Failure(message: "finalize") }
        return data as Data
    }

    /// Mean (R, G, B) of an image, 0...255, for telling frames apart.
    static func meanColor(_ image: CGImage) -> (r: Double, g: Double, b: Double) {
        let w = 4, h = 4
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        pixels.withUnsafeMutableBytes { raw in
            guard let ctx = CGContext(
                data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return }
            ctx.interpolationQuality = .low
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        var r = 0.0, g = 0.0, b = 0.0
        for i in 0..<(w * h) {
            r += Double(pixels[i * 4]); g += Double(pixels[i * 4 + 1]); b += Double(pixels[i * 4 + 2])
        }
        let n = Double(w * h)
        return (r / n, g / n, b / n)
    }
}
