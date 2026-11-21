@preconcurrency import AVFoundation
import CoreImage
import CoreMedia
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Writes the two files of a Live Photo: a HEIC still and a QuickTime movie, tied together by one content identifier
/// (the still's Apple maker note 17 and the movie's `com.apple.quicktime.content.identifier`). The movie also carries a
/// `still-image-time` sample at the moment the still was taken, which is where the Lock Screen stops.
enum LivePhotoWriter {
    /// The still: a HEIC with the identifier in its maker note (or none, for a plain still).
    static func writeStill(_ image: CGImage, identifier: String?, to url: URL) throws {
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.heic.identifier as CFString, 1, nil) else {
            throw WallpaperError.writeFailed
        }
        var props: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: 0.92]
        if let identifier {
            props[kCGImagePropertyMakerAppleDictionary] = ["17": identifier]
        }
        CGImageDestinationAddImage(dest, image, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw WallpaperError.writeFailed }
    }
}

/// The movie half of a Live Photo, written one frame at a time (so a 3 s clip never holds all its frames in memory).
final class LivePhotoMovie {
    private let writer: AVAssetWriter
    private let video: AVAssetWriterInput
    private let adaptor: AVAssetWriterInputPixelBufferAdaptor
    private let timescale: CMTimeScale
    private var next = 0
    let size: CGSize

    /// Opens the movie at `url` and writes its metadata: the content identifier, and the `still-image-time` sample at
    /// frame `stillIndex`.
    init(url: URL, size: CGSize, fps: Double, stillIndex: Int, identifier: String) async throws {
        try? FileManager.default.removeItem(at: url)
        self.size = size
        timescale = CMTimeScale(fps.rounded())
        writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let content = AVMutableMetadataItem()
        content.keySpace = .quickTimeMetadata
        content.key = "com.apple.quicktime.content.identifier" as NSString
        content.value = identifier as NSString
        content.dataType = "com.apple.metadata.datatype.UTF-8"
        writer.metadata = [content]

        let w = Int(size.width), h = Int(size.height)
        video = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: w,
            AVVideoHeightKey: h,
        ])
        video.expectsMediaDataInRealTime = false
        adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: video, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: w,
            kCVPixelBufferHeightKey as String: h,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
        ])
        guard writer.canAdd(video) else { throw WallpaperError.writeFailed }
        writer.add(video)

        let spec: [String: Any] = [
            kCMMetadataFormatDescriptionMetadataSpecificationKey_Identifier as String:
                "mdta/com.apple.quicktime.still-image-time",
            kCMMetadataFormatDescriptionMetadataSpecificationKey_DataType as String:
                "com.apple.metadata.datatype.int8",
        ]
        var description: CMFormatDescription?
        CMMetadataFormatDescriptionCreateWithMetadataSpecifications(
            allocator: kCFAllocatorDefault, metadataType: kCMMetadataFormatType_Boxed,
            metadataSpecifications: [spec] as CFArray, formatDescriptionOut: &description)
        let meta = AVAssetWriterInput(mediaType: .metadata, outputSettings: nil, sourceFormatHint: description)
        meta.expectsMediaDataInRealTime = false
        let metaAdaptor = AVAssetWriterInputMetadataAdaptor(assetWriterInput: meta)
        guard writer.canAdd(meta) else { throw WallpaperError.writeFailed }
        writer.add(meta)

        guard writer.startWriting() else { throw writer.error ?? WallpaperError.writeFailed }
        writer.startSession(atSourceTime: .zero)

        let stillItem = AVMutableMetadataItem()
        stillItem.keySpace = .quickTimeMetadata
        stillItem.key = "com.apple.quicktime.still-image-time" as NSString
        stillItem.value = 0 as NSNumber
        stillItem.dataType = "com.apple.metadata.datatype.int8"
        let stillTime = CMTime(value: CMTimeValue(stillIndex), timescale: timescale)
        let group = AVTimedMetadataGroup(
            items: [stillItem], timeRange: CMTimeRange(start: stillTime, duration: CMTime(value: 1, timescale: 100)))
        while !meta.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 2_000_000) }
        guard metaAdaptor.append(group) else { throw writer.error ?? WallpaperError.writeFailed }
        meta.markAsFinished()
    }

    /// Appends the next frame: `draw` fills the pixel buffer it is handed.
    func append(_ draw: (CVPixelBuffer) -> Void) async throws {
        while !video.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 2_000_000) }
        guard let pool = adaptor.pixelBufferPool else { throw writer.error ?? WallpaperError.writeFailed }
        var buffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
        guard let buffer else { throw WallpaperError.writeFailed }
        draw(buffer)
        guard adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(next), timescale: timescale)) else {
            throw writer.error ?? WallpaperError.writeFailed
        }
        next += 1
    }

    func finish() async throws {
        video.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? WallpaperError.writeFailed }
    }

    /// Stops writing and leaves no file behind.
    func cancel() {
        writer.cancelWriting()
        try? FileManager.default.removeItem(at: writer.outputURL)
    }
}
