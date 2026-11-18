import AVFoundation
import CoreImage
import CoreVideo
import Foundation
import Vision

// On-device cuts of an overlay video. Person uses Vision's person segmentation; subject uses the foreground instance
// mask (the same request a picture's cutout uses). Both write an alpha .mov (`video/quicktime`) the editor uploads as
// `role = alt` with `spec.kind` `person_cut` or `subject_cut`. Depth is the same upload with `depth_cut`, and it stays
// a stub until Depth Anything V2 small can be downloaded (see `EditDepthModel`).

public enum EditCutKind: String, Sendable, Equatable {
    case depthCut = "depth_cut"
    case personCut = "person_cut"
    case subjectCut = "subject_cut"

    public var effect: EditEffectKind {
        switch self {
        case .depthCut: return .depth
        case .personCut: return .person
        case .subjectCut: return .subject
        }
    }
}

public enum EditMaskError: Error, Equatable, Sendable {
    /// Depth Anything V2 small is not in this build.
    case depthUnavailable
    case noVideo
    /// Vision found nothing to keep.
    case empty
    /// Longer than `EditMaskExport.maxSeconds`. The device cut stops there; the server's remove-background limit is the same 60s.
    case tooLong
    case failed
}

public enum EditMaskExport {
    /// A device cut longer than this is refused, the same ceiling as Bria (section 67).
    public static let maxSeconds = 60.0

    /// An alpha `.mov` of `source` from `start` to `end` (source seconds). `soften` is 0...1 and blurs the mask edge.
    /// Throws `depthUnavailable` for a depth cut: the model is not bundled and there is no download URL in this build.
    public static func movie(source: URL, kind: EditCutKind, start: Double, end: Double, soften: Double) async throws -> URL {
        if kind == .depthCut { throw EditMaskError.depthUnavailable }
        let span = end - start
        guard span.isFinite, span > 0.05 else { throw EditMaskError.noVideo }
        if span > maxSeconds { throw EditMaskError.tooLong }

        let asset = AVURLAsset(url: source)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw EditMaskError.noVideo }
        let natural = try await track.load(.naturalSize)
        let transform = try await track.load(.preferredTransform)
        let duration = try await asset.load(.duration).seconds
        let oriented = CGRect(origin: .zero, size: natural).applying(transform).standardized
        var w = max(2, Int(abs(oriented.width).rounded()))
        var h = max(2, Int(abs(oriented.height).rounded()))
        // A long edge over 1280 is scaled down: the alternate is an overlay, and a 4K mask blows the writer up.
        let long = max(w, h)
        if long > 1280 {
            let s = 1280.0 / Double(long)
            w = max(2, Int((Double(w) * s).rounded()))
            h = max(2, Int((Double(h) * s).rounded()))
        }
        if w % 2 != 0 { w -= 1 }
        if h % 2 != 0 { h -= 1 }

        let out = FileManager.default.temporaryDirectory.appendingPathComponent("cut-\(UUID().uuidString).mov")
        if FileManager.default.fileExists(atPath: out.path) { try? FileManager.default.removeItem(at: out) }

        let reader = try AVAssetReader(asset: asset)
        let begin = max(0, start)
        let finish = min(end, duration.isFinite ? duration : end)
        reader.timeRange = CMTimeRange(
            start: CMTime(seconds: begin, preferredTimescale: 600),
            end: CMTime(seconds: max(begin + 0.05, finish), preferredTimescale: 600))
        let samples = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        ])
        samples.alwaysCopiesSampleData = false
        guard reader.canAdd(samples) else { throw EditMaskError.failed }
        reader.add(samples)

        let writer = try AVAssetWriter(outputURL: out, fileType: .mov)
        let codec = codec(writer: writer, width: w, height: h)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: codec,
            AVVideoWidthKey: w,
            AVVideoHeightKey: h,
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: w,
            kCVPixelBufferHeightKey as String: h,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
        ])
        guard writer.canAdd(input) else { throw EditMaskError.failed }
        writer.add(input)
        guard reader.startReading(), writer.startWriting() else { throw EditMaskError.failed }
        writer.startSession(atSourceTime: .zero)

        let context = CIContext(options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull()])
        let orientation = EditRenderPlan.orientation(of: transform)
        let size = CGSize(width: w, height: h)
        var frames = 0
        var kept = false
        var origin: CMTime?
        while let sample = samples.copyNextSampleBuffer() {
            guard let buffer = CMSampleBufferGetImageBuffer(sample) else { continue }
            let pts = CMSampleBufferGetPresentationTimeStamp(sample)
            if origin == nil { origin = pts }
            let when = CMTimeSubtract(pts, origin ?? .zero)
            let upright = EditFrameComposer.orient(CIImage(cvPixelBuffer: buffer), orientation)
            guard let frame = render(upright, to: size, context: context) else { continue }
            let masked = try maskedFrame(frame, kind: kind, soften: soften, context: context, size: size)
            if masked.opaque { kept = true }
            while !input.isReadyForMoreMediaData {
                try await Task.sleep(for: .milliseconds(4))
            }
            if !adaptor.append(masked.buffer, withPresentationTime: when) { throw EditMaskError.failed }
            frames += 1
        }
        input.markAsFinished()
        await writer.finishWriting()
        guard frames > 0, writer.status == .completed else {
            try? FileManager.default.removeItem(at: out)
            throw EditMaskError.failed
        }
        guard kept else {
            try? FileManager.default.removeItem(at: out)
            throw EditMaskError.empty
        }
        return out
    }

    private static func codec(writer: AVAssetWriter, width: Int, height: Int) -> AVVideoCodecType {
        let hevc = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.hevcWithAlpha, AVVideoWidthKey: width, AVVideoHeightKey: height,
        ])
        if writer.canAdd(hevc) { return .hevcWithAlpha }
        return .proRes4444
    }

    private static func render(_ image: CIImage, to size: CGSize, context: CIContext) -> CVPixelBuffer? {
        var buffer: CVPixelBuffer?
        let attrs: [String: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
            kCVPixelBufferCGImageCompatibilityKey as String: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
        ]
        guard CVPixelBufferCreate(kCFAllocatorDefault, Int(size.width), Int(size.height), kCVPixelFormatType_32BGRA, attrs as CFDictionary, &buffer) == kCVReturnSuccess,
              let buffer else { return nil }
        let scaled = EditFrameComposer.scale(image, to: PixelSize(w: Int(size.width), h: Int(size.height)))
        context.render(scaled, to: buffer, bounds: CGRect(origin: .zero, size: size), colorSpace: nil)
        return buffer
    }

    /// The frame with the mask as its alpha, and whether any pixel was kept.
    private static func maskedFrame(
        _ buffer: CVPixelBuffer, kind: EditCutKind, soften: Double, context: CIContext, size: CGSize
    ) throws -> (buffer: CVPixelBuffer, opaque: Bool) {
        let request: VNImageBasedRequest
        switch kind {
        case .personCut:
            let person = VNGeneratePersonSegmentationRequest()
            person.qualityLevel = .balanced
            person.outputPixelFormat = kCVPixelFormatType_OneComponent8
            request = person
        case .subjectCut:
            request = VNGenerateForegroundInstanceMaskRequest()
        case .depthCut:
            throw EditMaskError.depthUnavailable
        }
        let handler = VNImageRequestHandler(cvPixelBuffer: buffer, orientation: .up, options: [:])
        try handler.perform([request])
        guard let maskBuffer = try optionalMask(from: request, handler: handler) else {
            let clear = CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: 0)).cropped(to: CGRect(origin: .zero, size: size))
            guard let out = render(clear, to: size, context: context) else { throw EditMaskError.failed }
            return (out, false)
        }
        let image = CIImage(cvPixelBuffer: buffer)
        var mask = CIImage(cvPixelBuffer: maskBuffer)
        mask = EditFrameComposer.scale(mask, to: PixelSize(w: Int(size.width), h: Int(size.height)))
        let radius = max(0, min(1, soften)) * 12
        if radius > 0.4 {
            mask = mask.applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: radius]).cropped(to: image.extent)
        }
        let clear = CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: 0)).cropped(to: image.extent)
        let keyed = image.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: clear,
            kCIInputMaskImageKey: mask,
        ])
        guard let out = render(keyed, to: size, context: context) else { throw EditMaskError.failed }
        return (out, maskHasInk(maskBuffer))
    }

    private static func optionalMask(from request: VNImageBasedRequest, handler: VNImageRequestHandler) throws -> CVPixelBuffer? {
        if let person = request as? VNGeneratePersonSegmentationRequest {
            return person.results?.first?.pixelBuffer
        }
        if let subject = request as? VNGenerateForegroundInstanceMaskRequest, let observation = subject.results?.first {
            return try observation.generateScaledMaskForImage(forInstances: observation.allInstances, from: handler)
        }
        return nil
    }

    private static func maskHasInk(_ buffer: CVPixelBuffer) -> Bool {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return false }
        let w = CVPixelBufferGetWidth(buffer)
        let h = CVPixelBufferGetHeight(buffer)
        let row = CVPixelBufferGetBytesPerRow(buffer)
        let bytes = base.assumingMemoryBound(to: UInt8.self)
        let stepX = max(1, w / 24)
        let stepY = max(1, h / 24)
        for y in stride(from: 0, to: h, by: stepY) {
            for x in stride(from: 0, to: w, by: stepX) where bytes[y * row + x] > 24 { return true }
        }
        return false
    }
}
