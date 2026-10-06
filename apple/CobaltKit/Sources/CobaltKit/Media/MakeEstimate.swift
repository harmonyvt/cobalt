import CoreGraphics
import Foundation

// What making a slideshow or a gallery image costs, every figure an "about" (apple/CONTRACT-GALLERY.md 6.5). Measured on
// synthetic stills (0.3); the container's speed and the quality factors are assumptions. The same arithmetic as the
// boards' `GM.webpKB`, `GM.mp4MB`, `GM.jpegMB` and `GM.frame`, so a sheet and a board agree.
public enum MakeEstimate {
    /// 31 KB a photo and 161 KB a crossfade at 480x600 q75 (measured), 132 KB a second of video at 480x560.
    static let webpPhotoKB = 31.0, webpFadeKB = 161.0, webpVideoKBPerSecond = 132.0
    static let webpPhotoPixels = 480.0 * 600.0, webpVideoPixels = 480.0 * 560.0
    /// Assumed, not measured.
    static func qualityFactor(_ quality: WebpQuality?) -> Double {
        switch quality ?? .med {
        case .low: return 0.7
        case .med: return 1
        case .high: return 1.5
        }
    }
    /// 0.025 MB a second of stills and 0.25 MB a second of video at 1080x1350.
    static let mp4StillMBPerSecond = 0.025, mp4VideoMBPerSecond = 0.25, mp4ReferencePixels = 1080.0 * 1350.0
    static let jpegMBPerMegapixel = 0.3

    /// The frame a slideshow is drawn in: the webp's width (320 or 480, 480 by default) across at the chosen aspect;
    /// the mp4 1080 on the short side (1920 on the long side at most), or 9:16 / 1:1 at 1080. `items` are the post's
    /// items in play order; an item with no size counts as 4:5.
    public static func frame(for plan: SlideshowPlan, items: [GalleryItem]) -> CGSize {
        let chosen = plan.chosen(from: items)
        let dims = chosen.map { (w: $0.width ?? 1080, h: $0.height ?? 1350) }
        switch plan.format {
        case .webp:
            let width = plan.width ?? 480
            let aspect: Double
            switch plan.frame {
            case .story: aspect = 9.0 / 16.0
            case .square: aspect = 1
            case .asPosted: aspect = commonAspect(dims)
            }
            return CGSize(width: width, height: GalleryGeometry.even(Double(width) / aspect))
        case .mp4:
            switch plan.frame {
            case .story: return CGSize(width: 1080, height: 1920)
            case .square: return CGSize(width: 1080, height: 1080)
            case .asPosted:
                let best = mostCommon(dims)
                let scale = min(1080.0 / Double(min(best.w, best.h)), 1920.0 / Double(max(best.w, best.h)))
                return CGSize(
                    width: GalleryGeometry.even(Double(best.w) * scale), height: GalleryGeometry.even(Double(best.h) * scale))
            }
        }
    }

    static func mostCommon(_ dims: [(w: Int, h: Int)]) -> (w: Int, h: Int) {
        var seen: [String: Int] = [:]
        var best: (key: String, w: Int, h: Int)?
        for d in dims {
            let key = "\(d.w)x\(d.h)"
            seen[key, default: 0] += 1
            if best == nil || seen[key]! > seen[best!.key]! { best = (key, d.w, d.h) }
        }
        return (best?.w ?? 1080, best?.h ?? 1350)
    }

    static func commonAspect(_ dims: [(w: Int, h: Int)]) -> Double {
        let best = mostCommon(dims)
        return Double(best.w) / Double(best.h)
    }

    /// Bytes of the slideshow webp: stills, crossfades and video seconds, scaled by the frame's pixels and the quality.
    public static func webpBytes(_ items: [GalleryItem], plan: SlideshowPlan, frame: CGSize) -> Int64 {
        let chosen = plan.chosen(from: items)
        let pixels = Double(frame.width) * Double(frame.height)
        let still = pixels / webpPhotoPixels, motion = pixels / webpVideoPixels
        var kb = 0.0
        for item in chosen {
            kb += item.isPhoto ? webpPhotoKB * still : webpVideoKBPerSecond * motion * (item.duration ?? 0)
        }
        if plan.fade { kb += webpFadeKB * still * Double(max(0, chosen.count - 1)) }
        return Int64((kb * qualityFactor(plan.quality)).rounded()) * 1_000
    }

    /// Bytes of the slideshow mp4.
    public static func mp4Bytes(_ items: [GalleryItem], plan: SlideshowPlan, frame: CGSize) -> Int64 {
        let scale = Double(frame.width) * Double(frame.height) / mp4ReferencePixels
        var mb = 0.0
        for item in plan.chosen(from: items) {
            mb += item.isPhoto ? mp4StillMBPerSecond * plan.photoSeconds * scale : mp4VideoMBPerSecond * (item.duration ?? 0) * scale
        }
        return Int64(((mb * 10).rounded() / 10 * 1_000_000).rounded())
    }

    /// Bytes of the gallery image's JPEG: 0.3 MB a megapixel.
    public static func jpegBytes(_ canvas: GalleryCanvas) -> Int64 {
        let mb = (Double(canvas.width) * Double(canvas.height) / 1_000_000 * jpegMBPerMegapixel * 10).rounded() / 10
        return Int64((mb * 1_000_000).rounded())
    }

    /// Seconds the server's helper is assumed to take (the container is taken as 8x the local run): a webp 5 s + 0.6 s
    /// a photo + 0.6 s a crossfade + 2.5 s a second of video; an mp4 5 s + 0.45 s a second of stills + 2.5 s a second of
    /// video; a gallery image 3 s + 0.3 s a photo.
    public static func serverSeconds(_ what: GalleryMake, items: [GalleryItem]) -> Double {
        switch what {
        case .slideshow(let plan):
            let chosen = plan.chosen(from: items)
            let photos = Double(chosen.filter(\.isPhoto).count)
            let video = chosen.reduce(0.0) { $0 + ($1.isMotion ? ($1.duration ?? 0) : 0) }
            switch plan.format {
            case .webp:
                let fades = plan.fade ? Double(max(0, chosen.count - 1)) : 0
                return 5 + 0.6 * photos + 0.6 * fades + 2.5 * video
            case .mp4:
                return 5 + 0.45 * photos * plan.photoSeconds + 2.5 * video
            }
        case .image(let plan):
            return 3 + 0.3 * Double(plan.photos(in: items).photos.count)
        }
    }

    /// The canvas of a gallery image for `items` (the photos of the plan, with the sizes known; a photo of unknown
    /// size counts as 4:5), or nil with fewer than 2 photos.
    public static func canvas(for plan: GalleryImagePlan, items: [GalleryItem]) -> GalleryCanvas? {
        let sizes = plan.photos(in: items).photos.map { $0.size ?? CGSize(width: 1080, height: 1350) }
        return try? GalleryGeometry.layout(sizes, plan.layout)
    }
}
