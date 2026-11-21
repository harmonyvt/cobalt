import CoreGraphics
import Foundation
import ImageIO
import Synchronization
import UniformTypeIdentifiers

// The emote editor on `PreviewClient` (APP-API-CONTRACT 71): `POST /7tv/emotes/make` answers a plausible draft after a short
// delay (a still gradient picture of the stretched crop's shape, whatever the format), so previews and UI tests run offline.
// The numbers follow the request: a file id naming a video makes a clip of `end - start` seconds at `fps`; a fixed quality
// that would pass 7 MiB answers `over_cap`. A shape outside 1:32..3:1 is `error.seventv.too_large`, as the real route says.

/// The drafts the preview "server" holds, by id.
final class PreviewEmoteDrafts: Sendable {
    static let shared = PreviewEmoteDrafts()

    struct Entry: Sendable {
        var draft: EmoteDraft
        var data: Data
    }

    private let state = Mutex<[String: Entry]>([:])
    private let counter = Mutex(0)

    /// How many drafts were made (tests count remakes with it).
    var issued: Int { counter.withLock { $0 } }

    func nextID() -> String {
        let n = counter.withLock { value -> Int in
            value += 1
            return value
        }
        return "PrevDraft" + String(format: "%013d", n)
    }

    func put(_ entry: Entry, replacing id: String?) {
        state.withLock { all in
            if let id { all[id] = nil }
            all[entry.draft.draftID] = entry
        }
    }

    func entry(_ id: String) -> Entry? { state.withLock { $0[id] } }

    @discardableResult
    func remove(_ id: String) -> Bool { state.withLock { $0.removeValue(forKey: id) != nil } }

    /// A made file for `request`, as the server would answer it (the picture is a flat gradient).
    static func make(_ request: EmoteMakeRequest, id: String, now: Date) throws -> Entry {
        let lower = request.fileID.lowercased()
        if lower.contains("missing") { throw SevenTvError.fileNotFound }
        if lower.contains("busy") { throw SevenTvError.busy }
        if lower.contains("broken") { throw SevenTvError.fitFailed("could not decode the picture") }
        let isVideo = lower.contains("video") || lower.contains("mp4")
        let sourceW = 720.0, sourceH = isVideo ? 720.0 : 540.0
        let box = request.crop?.clamped ?? .whole
        let s = (request.stretch ?? .identity).clamped
        let stretched = (width: sourceW * box.w * s.w, height: sourceH * box.h * s.h)
        guard EmoteLimits.shapeFits(width: stretched.width, height: stretched.height) else { throw SevenTvError.tooLarge }
        let out = EmoteLimits.outputPixels(stretched: stretched, size: request.size)
        let fps = Double(request.fps ?? EmoteLimits.defaultFps)
        var frames = 1
        var seconds = 0.0
        if request.format != .png {
            if isVideo {
                let from = request.start ?? 0
                let to = request.end ?? (from + EmoteLimits.defaultMoment)
                seconds = max(EmoteLimits.momentRange.lowerBound, min(EmoteLimits.momentRange.upperBound, to - from))
                frames = EmoteLimits.estimatedFrames(seconds: seconds, fps: Int(fps), bounce: request.bounce)
            } else {
                seconds = 2.4
                frames = Int((seconds * min(fps, 20)).rounded())
                if request.bounce { frames = frames * 2 - 2 }
            }
        }
        // a rough weight: pixels x frames, lighter at a lower quality; a gif is heavier than a webp
        let quality = request.quality ?? 70
        let perPixel = (request.format == .gif ? 0.9 : 0.35) * (0.4 + Double(quality) / 100)
        let bytes = Int64(max(2_000, Double(out.width * out.height * frames) * perPixel / 8))
        let over = request.quality != nil && bytes > EmoteLimits.capBytes
        let draft = EmoteDraft(
            draftID: id, format: request.format, width: out.width, height: out.height, frames: frames,
            durationMs: Int(seconds * 1000), bytes: bytes, quality: request.format == .png ? nil : quality, overCap: over,
            expiresAt: now.addingTimeInterval(24 * 3600))
        return Entry(draft: draft, data: PreviewEmoteArt.png(width: out.width, height: out.height))
    }
}

/// A small gradient with a round face, as PNG bytes: what a preview draft "is".
enum PreviewEmoteArt {
    static func png(width: Int, height: Int) -> Data {
        let w = max(1, min(width, 512)), h = max(1, min(height, 512))
        let space = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return Data() }
        let colors = [CGColor(red: 0.95, green: 0.42, blue: 0.75, alpha: 1), CGColor(red: 0.45, green: 0.3, blue: 0.9, alpha: 1)]
        if let gradient = CGGradient(colorsSpace: space, colors: colors as CFArray, locations: [0, 1]) {
            ctx.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: w, y: h), options: [])
        }
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.85))
        let d = CGFloat(min(w, h)) * 0.5
        ctx.fillEllipse(in: CGRect(x: (CGFloat(w) - d) / 2, y: (CGFloat(h) - d) / 2, width: d, height: d))
        guard let image = ctx.makeImage() else { return Data() }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil) else { return Data() }
        CGImageDestinationAddImage(dest, image, nil)
        CGImageDestinationFinalize(dest)
        return out as Data
    }
}

extension PreviewClient {
    private func emoteReady(_ call: String, delay: Double) async throws {
        sevenTvState.record(call)
        try await clock.sleep(seconds: delay * timeScale)
        guard scenario.hasStage else { throw PipelineFailure.unsupported }
    }

    public func makeEmoteDraft(_ request: EmoteMakeRequest) async throws -> EmoteDraft {
        try await emoteReady("POST make \(request.fileID)", delay: 0.6)
        let entry = try PreviewEmoteDrafts.make(request, id: PreviewEmoteDrafts.shared.nextID(), now: clock.now())
        PreviewEmoteDrafts.shared.put(entry, replacing: request.replace)
        return entry.draft
    }

    public func emoteDraftData(id: String) async throws -> Data {
        try await emoteReady("GET draft \(id)", delay: 0.1)
        guard let entry = PreviewEmoteDrafts.shared.entry(id) else { throw SevenTvError.draftNotFound }
        return entry.data
    }

    public func deleteEmoteDraft(id: String) async throws {
        try await emoteReady("DELETE draft \(id)", delay: 0.05)
        guard PreviewEmoteDrafts.shared.remove(id) else { throw SevenTvError.draftNotFound }
    }

    public func saveEmoteDraft(id: String, title: String?) async throws -> EmoteDraftSaved {
        try await emoteReady("POST draft save \(id)", delay: 0.4)
        guard PreviewEmoteDrafts.shared.entry(id) != nil else { throw SevenTvError.draftNotFound }
        return EmoteDraftSaved(itemID: "preview-emote-item-\(id)", fileID: "preview-emote-file-\(id)")
    }
}
