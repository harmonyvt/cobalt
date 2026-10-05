import CoreGraphics
import Foundation

enum PreviewMedia {
    /// A valid 1×1 grey PNG: what preview downloads write to disk.
    static let placeholderBytes = Data(base64Encoded:
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==")!

    /// The boards' frame placeholder: a grey gradient (`#4a4a4f → #232326`), tilted like 170deg.
    static func gradient(width: Int, height: Int) -> CGImage? {
        let space = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        let colors = [
            CGColor(red: 0x4a / 255, green: 0x4a / 255, blue: 0x4f / 255, alpha: 1),
            CGColor(red: 0x23 / 255, green: 0x23 / 255, blue: 0x26 / 255, alpha: 1),
        ] as CFArray
        guard let g = CGGradient(colorsSpace: space, colors: colors, locations: [0, 1]) else { return nil }
        ctx.drawLinearGradient(
            g, start: CGPoint(x: Double(width) * 0.1, y: Double(height)),
            end: CGPoint(x: Double(width) * 0.9, y: 0), options: [])
        return ctx.makeImage()
    }
}

/// Frames in previews and tests are grey gradients that develop one per 150 ms (the boards'
/// read step), then nothing to decode.
struct PreviewMediaTools: MediaTools {
    let clock: any PipelineClock
    let clip: PreviewData.Clip

    func probe(file: URL) async -> MediaInfo? {
        MediaInfo(
            name: clip.title, duration: clip.duration, width: clip.width, height: clip.height,
            bytes: clip.bytes, isImage: false)
    }

    func frames(of input: FrameInput, duration: Double?, count: Int) -> AsyncThrowingStream<Frame, Error> {
        let clock = clock
        let aspect = Double(clip.width) / Double(max(1, clip.height))
        let h = 96
        let w = max(24, Int((Double(h) * aspect).rounded()))
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for i in 0..<count {
                        try await clock.sleep(seconds: PreviewData.frameSeconds)
                        if let image = PreviewMedia.gradient(width: w, height: h) {
                            continuation.yield(Frame(index: i, image: image))
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func poster(for file: URL, isImage: Bool, to destination: URL) async -> Bool { false }
}

/// Lets a preview pretend a file of any size was picked (the `.tooBig` scenario, a file that does
/// not exist), and copies it only when it does.
struct PreviewIntake: FileIntake {
    let scenario: PreviewScenario

    func inspect(_ url: URL) throws -> IntakeFile {
        let onDisk = ((try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? NSNumber)?.int64Value
        let name = url.lastPathComponent.isEmpty ? "clip.mov" : url.lastPathComponent
        var type = MIME.type(forFileName: name)
        if scenario == .image && !type.hasPrefix("image/") { type = "image/png" }
        return IntakeFile(
            url: url, name: name, bytes: PreviewData.uploadBytes(forFileSize: onDisk, scenario: scenario),
            contentType: type)
    }

    func copyIn(_ file: IntakeFile, to destination: URL) async throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
        if fm.fileExists(atPath: file.url.path) {
            try fm.copyItem(at: file.url, to: destination)
        } else {
            try PreviewMedia.placeholderBytes.write(to: destination)
        }
        return destination
    }
}

struct PreviewPhotos: PhotosSaver {
    let clock: any PipelineClock
    func save(fileURL: URL, isImage: Bool) async throws -> String? {
        try await clock.sleep(seconds: 0.3)
        return "PREVIEW-ASSET/L0/001"
    }
}
