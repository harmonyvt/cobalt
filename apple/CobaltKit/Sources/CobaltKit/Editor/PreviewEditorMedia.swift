import AVFoundation
import CoreGraphics
import CoreMedia
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

// The preview sources are real files (apple/CONTRACT-EDITOR.md 3.8): small H.264 clips written once per run with `AVAssetWriter`
// (a board colour, a moving bar, a frame counter, a 1 kHz AAC tone), a 12-frame GIF and a PNG, so the composition and the
// compositor run in previews and tests with no network. They are small on purpose; the server-side sizes the sources declare keep
// the board's aspect ratios.

/// One generated file.
struct PreviewEditorFile: Sendable {
    enum Content: Sendable { case video, gif, png }

    var fileID: String
    var name: String
    var content: Content
    var color: UInt32
    /// Encoded size, in pixels.
    var width: Int
    var height: Int
    var seconds: Double
    var audio: Bool
    /// A 90 degree rotation flag on the track: the display is the encoded size turned.
    var rotated: Bool
    var fileType: AVFileType

    var fileExtension: String {
        switch content {
        case .gif: return "gif"
        case .png: return "png"
        case .video: return fileType == .mov ? "mov" : "mp4"
        }
    }
}

actor PreviewEditorMedia {
    static let shared = PreviewEditorMedia()

    static let fps = 15
    static let sampleRate = 44_100

    /// The files the preview projects name, by library file id.
    static let files: [PreviewEditorFile] = [
        PreviewEditorFile(fileID: PreviewEditorIDs.pier, name: "pier.mp4", content: .video, color: 0x3b5b73, width: 320, height: 180,
                          seconds: 12, audio: true, rotated: false, fileType: .mp4),
        PreviewEditorFile(fileID: PreviewEditorIDs.surf, name: "surf.mp4", content: .video, color: 0x6d4f3a, width: 320, height: 180,
                          seconds: 10, audio: true, rotated: false, fileType: .mp4),
        PreviewEditorFile(fileID: PreviewEditorIDs.sunset, name: "sunset.mov", content: .video, color: 0x3f6b4f, width: 320, height: 180,
                          seconds: 5.5, audio: true, rotated: false, fileType: .mov),
        PreviewEditorFile(fileID: PreviewEditorIDs.friends, name: "friends.mp4", content: .video, color: 0x6b3f4a, width: 320, height: 180,
                          seconds: 4, audio: false, rotated: true, fileType: .mp4),
        PreviewEditorFile(fileID: PreviewEditorIDs.dance, name: "dance.gif", content: .gif, color: 0x8a5ca8, width: 120, height: 90,
                          seconds: 1.2, audio: false, rotated: false, fileType: .mp4),
        PreviewEditorFile(fileID: PreviewEditorIDs.photo, name: "harbour.png", content: .png, color: 0x5c7a8a, width: 160, height: 120,
                          seconds: 0, audio: false, rotated: false, fileType: .mp4),
    ]

    /// The file for a library file id; an id the preview does not know gets one of the four clips (stable per id).
    static func file(forID id: String) -> PreviewEditorFile {
        if let known = files.first(where: { $0.fileID == id }) { return known }
        let videos = files.filter { $0.content == .video }
        let sum = id.unicodeScalars.reduce(0) { ($0 &+ Int($1.value)) & 0xFFFF }
        return videos[sum % videos.count]
    }

    let directory: URL
    private var tasks: [String: Task<URL?, Never>] = [:]

    init(directory: URL = FileManager.default.temporaryDirectory.appendingPathComponent("capystore-editor-preview-media", isDirectory: true)) {
        self.directory = directory
    }

    /// The local file for a library file id, written on first use.
    func url(forFile id: String) async -> URL? {
        let spec = Self.file(forID: id)
        let key = spec.fileID
        if let running = tasks[key] { return await running.value }
        let dest = directory.appendingPathComponent("\(key).\(spec.fileExtension)")
        if let size = (try? FileManager.default.attributesOfItem(atPath: dest.path)[.size]) as? Int, size > 0 { return dest }
        let dir = directory
        let task = Task<URL?, Never> {
            do {
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                // a part file of its own: two instances on one directory (parallel tests) must not remove each other's
                let part = dir.appendingPathComponent("\(key).\(UUID().uuidString).part.\(spec.fileExtension)")
                defer { try? FileManager.default.removeItem(at: part) }
                try await Self.write(spec, to: part)
                do {
                    try FileManager.default.moveItem(at: part, to: dest)
                } catch where FileManager.default.fileExists(atPath: dest.path) {
                    // another writer finished first; its file is the same
                }
                return dest
            } catch {
                return nil
            }
        }
        tasks[key] = task
        let result = await task.value
        tasks[key] = nil
        return result
    }

    // MARK: writing

    enum WriteError: Error { case writer, buffer }

    static func write(_ spec: PreviewEditorFile, to url: URL) async throws {
        switch spec.content {
        case .video: try await writeVideo(spec, to: url)
        case .gif: try writeGIF(spec, to: url)
        case .png: try writePNG(spec, to: url)
        }
    }

    private static func rgb(_ hex: UInt32) -> (CGFloat, CGFloat, CGFloat) {
        (CGFloat((hex >> 16) & 0xFF) / 255, CGFloat((hex >> 8) & 0xFF) / 255, CGFloat(hex & 0xFF) / 255)
    }

    /// The picture of frame `index` of `total`: the board colour, a bar sliding across, the frame number.
    private static func draw(_ ctx: CGContext, width: Int, height: Int, color: UInt32, index: Int, total: Int, label: Bool) {
        let (r, g, b) = rgb(color)
        ctx.setFillColor(red: r, green: g, blue: b, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let progress = total > 1 ? CGFloat(index) / CGFloat(total - 1) : 0
        ctx.setFillColor(red: 1, green: 1, blue: 1, alpha: 0.35)
        let bar = CGFloat(width) * 0.12
        ctx.fill(CGRect(x: (CGFloat(width) - bar) * progress, y: 0, width: bar, height: CGFloat(height)))
        guard label else { return }
        let size = CGFloat(min(width, height)) * 0.28
        let font = CTFontCreateWithName("Menlo-Bold" as CFString, size, nil)
        let white = CGColor(gray: 1, alpha: 1)
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): white,
        ]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: String(index), attributes: attributes))
        ctx.textPosition = CGPoint(x: CGFloat(width) * 0.08, y: CGFloat(height) * 0.12)
        CTLineDraw(line, ctx)
    }

    private static func bitmap(width: Int, height: Int, data: UnsafeMutableRawPointer?, bytesPerRow: Int) -> CGContext? {
        CGContext(
            data: data, width: width, height: height, bitsPerComponent: 8, bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
    }

    private static func writeVideo(_ spec: PreviewEditorFile, to url: URL) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: spec.fileType)
        let video = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: spec.width, AVVideoHeightKey: spec.height,
        ])
        video.expectsMediaDataInRealTime = false
        if spec.rotated {
            // 90 degrees clockwise: the encoded 320 x 180 plays as 180 x 320
            video.transform = CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: CGFloat(spec.height), ty: 0)
        }
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: video, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA),
            kCVPixelBufferWidthKey as String: spec.width, kCVPixelBufferHeightKey as String: spec.height,
        ])
        guard writer.canAdd(video) else { throw WriteError.writer }
        writer.add(video)

        var audio: AVAssetWriterInput?
        if spec.audio {
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: sampleRate, AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 64_000,
            ])
            input.expectsMediaDataInRealTime = false
            guard writer.canAdd(input) else { throw WriteError.writer }
            writer.add(input)
            audio = input
        }
        guard writer.startWriting() else { throw writer.error ?? WriteError.writer }
        writer.startSession(atSourceTime: .zero)

        let frames = max(1, Int((spec.seconds * Double(fps)).rounded()))
        let perFrame = sampleRate / fps
        // Each input is fed whenever it is ready and finished as soon as its data runs out: the writer holds one input back until
        // the other catches up (interleaving), so waiting for both to be ready at once never ends.
        var videoFrame = 0, audioFrame = 0
        while videoFrame < frames || (audio != nil && audioFrame < frames) {
            var progressed = false
            if videoFrame < frames, video.isReadyForMoreMediaData {
                try appendVideo(videoFrame)
                videoFrame += 1
                if videoFrame == frames { video.markAsFinished() }
                progressed = true
            }
            if let audio, audioFrame < frames, audio.isReadyForMoreMediaData {
                try appendAudio(audio, audioFrame)
                audioFrame += 1
                if audioFrame == frames { audio.markAsFinished() }
                progressed = true
            }
            if !progressed {
                if writer.status == .failed { throw writer.error ?? WriteError.writer }
                try await Task.sleep(nanoseconds: 2_000_000)
            }
        }
        await writer.finishWriting()
        if writer.status != .completed { throw writer.error ?? WriteError.writer }

        func appendVideo(_ i: Int) throws {
            guard let pool = adaptor.pixelBufferPool else { throw WriteError.buffer }
            var buffer: CVPixelBuffer?
            guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer) == kCVReturnSuccess, let buffer else { throw WriteError.buffer }
            CVPixelBufferLockBaseAddress(buffer, [])
            if let ctx = bitmap(
                width: spec.width, height: spec.height, data: CVPixelBufferGetBaseAddress(buffer),
                bytesPerRow: CVPixelBufferGetBytesPerRow(buffer)) {
                draw(ctx, width: spec.width, height: spec.height, color: spec.color, index: i, total: frames, label: true)
            }
            CVPixelBufferUnlockBaseAddress(buffer, [])
            guard adaptor.append(buffer, withPresentationTime: CMTime(value: Int64(i), timescale: Int32(fps))) else {
                throw writer.error ?? WriteError.writer
            }
        }

        func appendAudio(_ audio: AVAssetWriterInput, _ i: Int) throws {
            var samples = [Int16](repeating: 0, count: perFrame)
            for s in 0..<perFrame {
                let n = Double(i * perFrame + s)
                samples[s] = Int16(sin(2 * .pi * 1_000 * n / Double(sampleRate)) * 8_000)
            }
            guard let sample = pcmBuffer(samples, start: Int64(i * perFrame)) else { throw WriteError.buffer }
            guard audio.append(sample) else { throw writer.error ?? WriteError.writer }
        }
    }

    /// Mono 16-bit PCM at 44.1 kHz as a sample buffer starting at `start` samples.
    private static func pcmBuffer(_ samples: [Int16], start: Int64) -> CMSampleBuffer? {
        var asbd = AudioStreamBasicDescription(
            mSampleRate: Float64(sampleRate), mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kLinearPCMFormatFlagIsSignedInteger | kLinearPCMFormatFlagIsPacked,
            mBytesPerPacket: 2, mFramesPerPacket: 1, mBytesPerFrame: 2, mChannelsPerFrame: 1, mBitsPerChannel: 16, mReserved: 0)
        var format: CMAudioFormatDescription?
        guard CMAudioFormatDescriptionCreate(
            allocator: nil, asbd: &asbd, layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil, extensions: nil,
            formatDescriptionOut: &format) == noErr, let format else { return nil }
        let bytes = samples.count * 2
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(
            allocator: nil, memoryBlock: nil, blockLength: bytes, blockAllocator: nil, customBlockSource: nil, offsetToData: 0,
            dataLength: bytes, flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block) == noErr, let block else { return nil }
        let copied = samples.withUnsafeBytes { raw -> OSStatus in
            guard let base = raw.baseAddress else { return -1 }
            return CMBlockBufferReplaceDataBytes(with: base, blockBuffer: block, offsetIntoDestination: 0, dataLength: bytes)
        }
        guard copied == noErr else { return nil }
        var sample: CMSampleBuffer?
        guard CMAudioSampleBufferCreateReadyWithPacketDescriptions(
            allocator: nil, dataBuffer: block, formatDescription: format, sampleCount: samples.count,
            presentationTimeStamp: CMTime(value: start, timescale: Int32(sampleRate)), packetDescriptions: nil,
            sampleBufferOut: &sample) == noErr else { return nil }
        return sample
    }

    private static func writeGIF(_ spec: PreviewEditorFile, to url: URL) throws {
        let count = 12
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.gif.identifier as CFString, count, nil) else {
            throw WriteError.writer
        }
        CGImageDestinationSetProperties(destination, [
            kCGImagePropertyGIFDictionary as String: [kCGImagePropertyGIFLoopCount as String: 0],
        ] as CFDictionary)
        for i in 0..<count {
            guard let ctx = bitmap(width: spec.width, height: spec.height, data: nil, bytesPerRow: 0) else { throw WriteError.buffer }
            draw(ctx, width: spec.width, height: spec.height, color: spec.color, index: i, total: count, label: true)
            guard let image = ctx.makeImage() else { throw WriteError.buffer }
            CGImageDestinationAddImage(destination, image, [
                kCGImagePropertyGIFDictionary as String: [kCGImagePropertyGIFDelayTime as String: 0.1],
            ] as CFDictionary)
        }
        guard CGImageDestinationFinalize(destination) else { throw WriteError.writer }
    }

    private static func writePNG(_ spec: PreviewEditorFile, to url: URL) throws {
        guard let ctx = bitmap(width: spec.width, height: spec.height, data: nil, bytesPerRow: 0) else { throw WriteError.buffer }
        draw(ctx, width: spec.width, height: spec.height, color: spec.color, index: 1, total: 2, label: false)
        guard let image = ctx.makeImage(),
              let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw WriteError.buffer
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw WriteError.writer }
    }
}
