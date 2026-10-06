import CobaltKit
import CoreGraphics
import Foundation
import UniformTypeIdentifiers

extension Rendition {
    /// The tab's word: `video`, `webp`, or `webp 2` when the media has several (CONTRACT-MEDIA 1.9).
    func tabName(of item: MediaItem) -> String {
        switch kind {
        case .video: return Copy.Media.video
        case .webp(let n): return item.webpCount > 1 ? Copy.Media.webpTab(n) : Copy.Media.webp
        case .item, .slideshow, .galleryImage, .crop: return self.tabName      // gallery tabs: lane A3 draws them (CONTRACT-GALLERY.A0-API.md)
        }
    }

    var tabSymbol: String { isWebp ? Symbol.Media.webp : Symbol.Media.video }

    /// The device holds the file (the index says so; the player and the share link check the disk).
    var hasFileHere: Bool { local?.fileURL != nil }

    /// The aspect of the picture: its own size, else 9:16.
    var aspect: CGFloat {
        if let w = width, let h = height, w > 0, h > 0 { return CGFloat(w) / CGFloat(h) }
        return 9.0 / 16.0
    }

    /// The lowercase file type for the corner capsule: from the stored file, then the public link, then
    /// what the rendition is.
    var typeLabel: String {
        let candidates: [URL?] = [local?.fileURL, publicURL, local?.remoteURL, file?.url]
        for url in candidates {
            guard var ext = url?.pathExtension.lowercased(), !ext.isEmpty, ext.count <= 5 else { continue }
            if ext == "jpeg" { ext = "jpg" }
            if ext == "qt" { ext = "mov" }
            if let type = UTType(filenameExtension: ext), type.conforms(to: .audiovisualContent) || type.conforms(to: .image) {
                return ext
            }
        }
        return isWebp ? "webp" : "mp4"
    }
}

/// The meta line and the rows of a rendition (CONTRACT-MEDIA 1.10 and 5).
enum DetailMeta {
    static func size(_ r: Rendition) -> String? {
        guard let w = r.width, let h = r.height else { return nil }
        return Format.size(w, h)
    }

    /// `00:02.0 → 00:12.0` when the trim is known, else the length (`10.1 s`).
    static func range(_ r: Rendition) -> String? {
        if let clip = r.clip { return Copy.timecodeRange(clip.range) }
        return r.duration.map { Format.seconds($0) }
    }

    /// `crop 1:1`, `crop` for a free shape; nil when the whole frame was kept or the crop is unknown.
    static func crop(_ r: Rendition, in item: MediaItem) -> String? {
        guard let rect = r.clip?.crop, !rect.isFull else { return nil }
        var source: CGSize?
        let video = item.video
        if let w = video?.width ?? item.post?.width, let h = video?.height ?? item.post?.height { source = CGSize(width: w, height: h) }
        if let source, let match = rect.matchedAspect(in: source), match.ratio != nil {
            return Copy.Media.cropBadge(match.label)
        }
        return Copy.Media.cropBadge("")
    }

    /// `14.8 s · 720×1280 · 4.3 MB · saved yesterday 13:59` / `00:02.0 → 00:12.0 · crop 1:1 · 480×480 · 2.4 MB · made today 20:52`.
    static func line(_ r: Rendition, in item: MediaItem, now: Date = Date()) -> String {
        let bytes = r.bytes.map { Format.bytes($0) }
        let when = Format.when(r.createdAt, now: now)
        switch r.kind {
        case .video, .item, .slideshow, .galleryImage, .crop:         // gallery files: lane A3 words their own meta lines
            return Copy.Media.videoMeta(seconds: r.duration.map { Format.seconds($0) }, size: size(r), bytes: bytes, when: when)
        case .webp:
            return Copy.Media.webpMeta(range: range(r), crop: crop(r, in: item), size: size(r), bytes: bytes, when: when)
        }
    }

    /// The wide layout's `LabeledContent` rows: length, trim, crop, size, bytes, made.
    static func rows(_ r: Rendition, in item: MediaItem, now: Date = Date()) -> [(label: String, value: String)] {
        var out: [(String, String)] = []
        if let d = r.duration { out.append((Copy.Media.length, Format.seconds(d))) }
        if r.isWebp, let clip = r.clip { out.append((Copy.Media.trim, Copy.timecodeRange(clip.range))) }
        if r.clip?.crop.map({ !$0.isFull }) ?? false, let crop = crop(r, in: item) {
            // the row's label says "crop": the value is just the shape (`1:1`, `free`)
            let shape = crop.hasPrefix("crop ") ? String(crop.dropFirst(5)) : CropRect.Aspect.free.label
            out.append((Copy.Media.crop, shape))
        }
        if let size = size(r) { out.append((Copy.Media.size, size)) }
        if let bytes = r.bytes { out.append((Copy.Media.fileSize, Format.bytes(bytes))) }
        out.append((r.isWebp ? Copy.Media.made : Copy.Media.saved, Format.when(r.createdAt, now: now)))
        return out
    }

    /// `media.capybaraharmony.com/PrEvIeW001.webp`.
    static func linkText(_ url: URL) -> String {
        let host = url.host(percentEncoded: false) ?? ""
        return host + url.path(percentEncoded: false)
    }
}
