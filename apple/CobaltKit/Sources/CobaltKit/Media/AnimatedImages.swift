import AVFoundation
import CoreGraphics
import CoreVideo
import Foundation
import ImageIO

// GIFs. AVFoundation cannot open one (no `isPlayable`, no video track), and a GIF reaches the app
// under any name: a gif an old server stored as `video/mp4`, an extension-less `/studio/<sid>/source`,
// an upload picked from Files. So a GIF is recognised by its first bytes, never by its name, and read
// with ImageIO (frames, delays) or turned into an mp4 of the same frames for the players.

/// What a file really is, from its first bytes.
enum MediaSniff {
    /// `GIF87a` / `GIF89a`.
    static func isGIF(_ head: Data) -> Bool {
        guard head.count >= 6 else { return false }
        let sig = head.prefix(6)
        return sig.elementsEqual(Array("GIF89a".utf8)) || sig.elementsEqual(Array("GIF87a".utf8))
    }

    static func isGIF(file: URL) -> Bool {
        guard file.isFileURL, let handle = try? FileHandle(forReadingFrom: file) else { return false }
        defer { try? handle.close() }
        return isGIF((try? handle.read(upToCount: 6)) ?? Data())
    }

    /// The first six bytes of a remote file, read through a streaming request that is cancelled as soon
    /// as they are in (a server that ignores `Range` must not make this a whole download).
    static func isGIF(remote url: URL) async -> Bool {
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.setValue("bytes=0-5", forHTTPHeaderField: "Range")
        guard let (bytes, response) = try? await URLSession.shared.bytes(for: request),
              let http = response as? HTTPURLResponse, http.statusCode == 200 || http.statusCode == 206
        else { return false }
        var head = Data()
        do {
            for try await byte in bytes {
                head.append(byte)
                if head.count >= 6 { break }
            }
        } catch { return false }
        return isGIF(head)
    }
}

/// A GIF's frames and the time each one is shown, read with ImageIO.
struct GIFTimeline {
    let source: CGImageSource
    /// Seconds each frame is shown (`frameDelay`), one per frame.
    let delays: [Double]
    let width: Int
    let height: Int

    var count: Int { delays.count }
    var duration: Double { delays.reduce(0, +) }

    init?(file: URL) {
        guard MediaSniff.isGIF(file: file), let source = CGImageSourceCreateWithURL(file as CFURL, nil) else { return nil }
        let n = CGImageSourceGetCount(source)
        guard n > 0, let first = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let w = (first[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let h = (first[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue, w > 0, h > 0
        else { return nil }
        self.source = source
        self.width = w
        self.height = h
        self.delays = (0..<n).map { i in
            Self.frameDelay((CGImageSourceCopyPropertiesAtIndex(source, i, nil) as? [CFString: Any]) ?? [:])
        }
    }

    /// How long a GIF frame is shown, the way ffmpeg (the server's clock, which the trim's seconds are
    /// measured on) and browsers do: a delay under 2 centiseconds (0 and 1 are what encoders write for
    /// "as fast as you can") is 10 centiseconds. ImageIO's own "clamped" value is not relied on.
    static func frameDelay(_ props: [CFString: Any]) -> Double {
        let dict = props[kCGImagePropertyGIFDictionary] as? [CFString: Any]
        let raw = (dict?[kCGImagePropertyGIFUnclampedDelayTime] as? NSNumber)?.doubleValue
            ?? (dict?[kCGImagePropertyGIFDelayTime] as? NSNumber)?.doubleValue ?? 0
        return raw < 0.02 ? 0.1 : raw
    }

    /// The index of the frame on screen at `seconds` (the last frame past the end).
    func index(at seconds: Double) -> Int {
        var t = 0.0
        for (i, d) in delays.enumerated() {
            t += d
            if seconds < t { return i }
        }
        return max(0, count - 1)
    }

    /// `count` frames at the middle of each of `count` equal slices of the clip, in order, long edge
    /// capped at `maxEdge`.
    func filmstrip(count: Int, maxEdge: CGFloat) -> [Frame] {
        guard count > 0, duration > 0 else { return [] }
        let slice = duration / Double(count)
        var out: [Frame] = []
        for i in 0..<count {
            if let image = thumbnail(at: index(at: (Double(i) + 0.5) * slice), maxEdge: maxEdge) {
                out.append(Frame(index: i, image: image))
            }
        }
        return out
    }

    func thumbnail(at index: Int, maxEdge: CGFloat) -> CGImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxEdge,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, min(max(0, index), count - 1), options as CFDictionary)
    }
}

enum GIFTranscodeError: Error { case notAGIF, writer(String) }

/// An mp4 of a GIF's frames, so the players (the planet, the trim's preview, full screen) and the
/// frame readers, which are all AVFoundation, can use it. Timing follows `GIFTimeline.frameDelay`.
enum GIFTranscoder {
    /// The longest edge of the mp4 (a GIF is rarely bigger; H.264 would take 4K but the memory is not worth it).
    static let maxEdge = 1280

    @concurrent
    static func writeMP4(from file: URL, to destination: URL) async throws {
        guard let timeline = GIFTimeline(file: file) else { throw GIFTranscodeError.notAGIF }
        let scale = min(1.0, Double(maxEdge) / Double(max(timeline.width, timeline.height)))
        let outW = max(2, Int((Double(timeline.width) * scale).rounded()) & ~1)       // H.264 wants even sides
        let outH = max(2, Int((Double(timeline.height) * scale).rounded()) & ~1)

        let fm = FileManager.default
        try? fm.removeItem(at: destination)
        try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let writer = try AVAssetWriter(outputURL: destination, fileType: .mp4)
        let bitrate = min(8_000_000, max(600_000, outW * outH * 4))
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: outW, AVVideoHeightKey: outH,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: bitrate,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
            ],
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: outW, kCVPixelBufferHeightKey as String: outH,
        ])
        guard writer.canAdd(input) else { throw GIFTranscodeError.writer("cannot add input") }
        writer.add(input)
        guard writer.startWriting() else { throw GIFTranscodeError.writer(writer.error?.localizedDescription ?? "start") }
        writer.startSession(atSourceTime: .zero)

        func fail(_ error: Error) -> Error {
            writer.cancelWriting()
            try? fm.removeItem(at: destination)
            return error
        }

        let timescale: CMTimeScale = 1000
        var elapsed = 0.0
        for i in 0..<timeline.count {
            if Task.isCancelled { throw fail(CancellationError()) }
            while !input.isReadyForMoreMediaData {
                if writer.status == .failed { throw fail(GIFTranscodeError.writer(writer.error?.localizedDescription ?? "failed")) }
                try await Task.sleep(for: .milliseconds(4))
            }
            guard let pool = adaptor.pixelBufferPool else { throw fail(GIFTranscodeError.writer("no pixel buffer pool")) }
            var buffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
            guard let buffer else { throw fail(GIFTranscodeError.writer("no pixel buffer")) }
            // a frame ImageIO cannot decode repeats the picture before it (the timeline stays whole)
            if let image = CGImageSourceCreateImageAtIndex(timeline.source, i, nil) {
                Self.draw(image, into: buffer, width: outW, height: outH)
            } else if i == 0 {
                throw fail(GIFTranscodeError.writer("first frame unreadable"))
            }
            let time = CMTime(value: CMTimeValue((elapsed * Double(timescale)).rounded()), timescale: timescale)
            if !adaptor.append(buffer, withPresentationTime: time) {
                throw fail(GIFTranscodeError.writer(writer.error?.localizedDescription ?? "append"))
            }
            elapsed += timeline.delays[i]
        }
        input.markAsFinished()
        writer.endSession(atSourceTime: CMTime(value: CMTimeValue((elapsed * Double(timescale)).rounded()), timescale: timescale))
        await writer.finishWriting()
        guard writer.status == .completed else {
            throw fail(GIFTranscodeError.writer(writer.error?.localizedDescription ?? "finish"))
        }
    }

    private static func draw(_ image: CGImage, into buffer: CVPixelBuffer, width: Int, height: Int) {
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(buffer),
              let ctx = CGContext(
                data: base, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: CGColorSpace(name: CGColorSpace.sRGB)
                    ?? CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return }
        ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))     // a transparent gif plays over black
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    }
}
