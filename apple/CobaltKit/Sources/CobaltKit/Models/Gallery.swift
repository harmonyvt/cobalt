import CoreGraphics
import Foundation

// Photos and galleries (apple/CONTRACT-GALLERY.md section 4, wire: APP-API-CONTRACT 18.2 and 18.9-18.13).
// Pure values: what a post's items are, what the owner may ask to make from them, and the rules that say whether
// the server will take the ask (caps, the 0.5 s step, the fit). No network, no disk, no clock.

// MARK: - Which items to save

/// `items` on `POST /studio` (18.2): `"all"` | `[0, 3]` | `"first-video"`.
public enum GalleryChoice: Sendable, Equatable, Codable {
    case all
    case some([Int])
    case firstVideo

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let word = try? c.decode(String.self) {
            switch word {
            case "all": self = .all
            case "first-video": self = .firstVideo
            default: throw DecodingError.dataCorruptedError(in: c, debugDescription: "unknown items choice \(word)")
            }
            return
        }
        self = .some(try c.decode([Int].self))
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .all: try c.encode("all")
        case .firstVideo: try c.encode("first-video")
        case .some(let indices): try c.encode(indices)
        }
    }

    /// The JSON value the wire takes (`"all"`, `"first-video"`, or an array of picker indices).
    var wireValue: Any {
        switch self {
        case .all: return "all"
        case .firstVideo: return "first-video"
        case .some(let indices): return indices
        }
    }
}

// MARK: - Items

/// One item of a post (a photo, a video or a gif), as the app knows it so far: the picker answer gives the type
/// and a thumb; the session and the library fill in the size and the length.
public struct GalleryItem: Sendable, Equatable, Identifiable {
    /// The item's index in the post (cobalt's picker index; `item_index` on the server).
    public var id: Int
    public var type: MediaType
    public var width: Int?
    public var height: Int?
    /// Seconds; nil for a photo, and for a video or gif whose length is not known yet.
    public var duration: Double?
    public var thumb: URL?

    public init(id: Int, type: MediaType, width: Int? = nil, height: Int? = nil, duration: Double? = nil, thumb: URL? = nil) {
        self.id = id
        self.type = type
        self.width = width
        self.height = height
        self.duration = duration
        self.thumb = thumb
    }

    public init(_ picker: PickerItem) {
        self.init(id: picker.id, type: picker.type, thumb: picker.thumb)
    }

    public var isPhoto: Bool { type == .photo }
    /// A video or a gif: it plays its own length in a slideshow.
    public var isMotion: Bool { type != .photo }

    /// The pixel size when both sides are known.
    public var size: CGSize? {
        guard let width, let height, width > 0, height > 0 else { return nil }
        return CGSize(width: width, height: height)
    }
}

extension MediaType {
    /// The type a content type names; nil for an unknown one. `image/gif` is a gif (it plays), any other image a photo.
    public init?(contentType: String?) {
        guard let type = contentType?.lowercased() else { return nil }
        if type == "image/gif" { self = .gif }
        else if type.hasPrefix("image/") { self = .photo }
        else if type.hasPrefix("video/") { self = .video }
        else { return nil }
    }
}

// MARK: - Slideshow

/// What a slideshow is made from and how (`POST /studio/<sid>/slideshow`, 18.5 and 18.10).
public struct SlideshowPlan: Sendable, Equatable, Codable {
    public enum Format: String, Sendable, Codable { case webp, mp4 }
    public enum Frame: String, Sendable, Codable { case asPosted = "keep", story = "9:16", square = "1:1" }
    public enum Sound: String, Sendable, Codable { case none, own }

    public var format: Format
    /// Play order, 2-20, unique: `item_index` values.
    public var items: [Int]
    /// One value for every photo: 0.5...10 in steps of 0.5 (default 2.0).
    public var photoSeconds: Double
    /// Crossfade of 0.3 s (default true).
    public var fade: Bool
    public var frame: Frame
    /// mp4 only; always `.none` for a webp.
    public var sound: Sound
    /// webp only (`Settings.webpQuality`).
    public var quality: WebpQuality?
    /// webp only (`Settings.webpWidth`: 320 or 480).
    public var width: Int?

    public static let webpMaxSeconds = 60.0
    public static let mp4MaxSeconds = 180.0
    /// Videos and gifs together, in either format.
    public static let motionMaxSeconds = 60.0
    /// The slider: 0.5 to 10 s in 0.5 s steps (the server takes 0.5 to 15, one decimal).
    public static let secondsRange: ClosedRange<Double> = 0.5...10
    public static let secondsStep = 0.5
    public static let defaultPhotoSeconds = 2.0
    /// The slack the caps have (a webp of 60.4 s is still 60 s).
    static let capSlack = 0.5
    public static let crossfadeSeconds = 0.3

    public init(
        format: Format, items: [Int], photoSeconds: Double = SlideshowPlan.defaultPhotoSeconds, fade: Bool = true,
        frame: Frame = .asPosted, sound: Sound = .none, quality: WebpQuality? = nil, width: Int? = nil
    ) {
        self.format = format
        self.items = items
        self.photoSeconds = photoSeconds
        self.fade = fade
        self.frame = frame
        self.sound = format == .webp ? .none : sound
        self.quality = format == .webp ? quality : nil
        self.width = format == .webp ? width : nil
    }

    /// The plan the sheet opens with: 2 s a photo, crossfade on, as posted, no sound; a webp takes the app's own
    /// quality and width settings.
    @MainActor
    public static func standard(_ format: Format, items: [Int], settings: Settings?) -> SlideshowPlan {
        SlideshowPlan(
            format: format, items: items,
            quality: format == .webp ? (settings?.webpQuality ?? .med) : nil,
            width: format == .webp ? (settings?.webpWidth ?? 480) : nil)
    }

    /// The wire's `seconds`: `photoSeconds` for a photo, nil (JSON `null`) for a video or gif (its own length), in
    /// play order. An index the post does not have counts as a photo. Every request that carries a plan (the
    /// combine sheet, the share sheet, Shortcuts) uses this.
    public func seconds(for items: [GalleryItem]) -> [Double?] {
        let byID = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return self.items.map { byID[$0]?.isMotion == true ? nil : photoSeconds }
    }

    /// The items of the post this plan plays, in play order (an index the post lacks is left out).
    public func chosen(from items: [GalleryItem]) -> [GalleryItem] {
        let byID = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return self.items.compactMap { byID[$0] }
    }

    /// Photos × `photoSeconds` + the videos' and gifs' lengths, rounded to 0.1 s.
    public func length(of items: [GalleryItem]) -> Double {
        let chosen = chosen(from: items)
        var total = 0.0
        for item in chosen { total += item.isMotion ? (item.duration ?? 0) : photoSeconds }
        return (total * 10).rounded() / 10
    }

    /// What the videos and gifs add up to.
    public func motionLength(of items: [GalleryItem]) -> Double {
        let sum = chosen(from: items).reduce(0.0) { $0 + ($1.isMotion ? ($1.duration ?? 0) : 0) }
        return (sum * 10).rounded() / 10
    }

    /// Whether the server will take this plan, and if not why (section 1.15's caps and their ways out).
    public func check(_ items: [GalleryItem]) -> SlideshowCheck {
        let chosen = chosen(from: items)
        guard chosen.count >= 2, Set(self.items).count == self.items.count else { return .tooFew }
        let total = length(of: items)
        let motion = motionLength(of: items)
        let photos = chosen.filter(\.isPhoto).count
        if motion > Self.motionMaxSeconds + Self.capSlack { return .tooMuchVideo(motion) }
        let cap = format == .webp ? Self.webpMaxSeconds : Self.mp4MaxSeconds
        if total > cap + Self.capSlack {
            // the longest 0.5 s step that fits: the videos keep their length, only the photos shrink
            let fit = photos > 0 ? (((cap - motion) / Double(photos)) * 2).rounded(.down) / 2 : 0
            return .tooLong(length: total, cap: cap, fitSeconds: fit >= Self.secondsStep ? fit : nil)
        }
        return .ok
    }

    /// `photoSeconds` snapped to the slider: inside 0.5...10, on a 0.5 step.
    public static func snapped(_ seconds: Double) -> Double {
        let stepped = (seconds / secondsStep).rounded() * secondsStep
        return min(secondsRange.upperBound, max(secondsRange.lowerBound, stepped))
    }
}

/// `SlideshowPlan.check`'s answer.
public enum SlideshowCheck: Sendable, Equatable {
    case ok
    /// Fewer than 2 items are ticked (or one is listed twice).
    case tooFew
    /// Over the format's cap. `fitSeconds`: the longest 0.5 s step a photo could have and still fit, when one does.
    case tooLong(length: Double, cap: Double, fitSeconds: Double?)
    /// The videos and gifs alone add up to more than a slideshow can hold (60 s).
    case tooMuchVideo(Double)

    public var isOK: Bool { self == .ok }
}

// MARK: - Gallery image

public enum GalleryLayout: String, Sendable, Codable, CaseIterable {
    case strip, grid2, grid3, row
}

/// What a gallery image is made from (`POST /studio/<sid>/gallery-image`, 18.11).
public struct GalleryImagePlan: Sendable, Equatable, Codable {
    public var items: [Int]
    public var layout: GalleryLayout

    public init(items: [Int], layout: GalleryLayout = .grid3) {
        self.items = items
        self.layout = layout
    }

    /// The photos of the plan in drawing order, and how many videos and gifs it leaves out (R4).
    public func photos(in items: [GalleryItem]) -> (photos: [GalleryItem], skipped: Int) {
        let byID = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var photos: [GalleryItem] = []
        var skipped = 0
        for index in self.items {
            guard let item = byID[index] else { continue }
            if item.isPhoto { photos.append(item) } else { skipped += 1 }
        }
        return (photos, skipped)
    }

    /// A gallery image needs 2 photos (R4); the server refuses a video or a gif in `items`, so a caller sends
    /// `photoIndices(in:)`.
    public func isPossible(in items: [GalleryItem]) -> Bool { photos(in: items).photos.count >= 2 }

    /// The plan with only its photos: what goes on the wire.
    public func photoOnly(in items: [GalleryItem]) -> GalleryImagePlan {
        GalleryImagePlan(items: photos(in: items).photos.map(\.id), layout: layout)
    }
}

/// What the owner asks to make from a post.
public enum GalleryMake: Sendable, Equatable {
    case slideshow(SlideshowPlan)
    case image(GalleryImagePlan)

    /// "slideshow webp", "slideshow mp4", "gallery image" (`Copy.Gallery`'s words).
    public var what: String {
        switch self {
        case .slideshow(let plan): return plan.format == .webp ? "slideshow webp" : "slideshow mp4"
        case .image: return "gallery image"
        }
    }

    /// The item indices, in play or drawing order.
    public var items: [Int] {
        switch self {
        case .slideshow(let plan): return plan.items
        case .image(let plan): return plan.items
        }
    }
}

// MARK: - Roles, kinds, specs

/// What a library row or a store record is within a post (`role` on `GET /library?v=3`).
public enum GalleryRole: String, Sendable, Codable { case item, slideshow, crop, export }

/// A post's kind (`kind` on `GET /library?v=3`; `StoredMedia.kind` on the device).
public enum MediaKind: String, Sendable, Codable { case video, photo, gallery, webp }

/// The spec a made file carries (`made_spec`, at most 512 bytes): read leniently, an unknown field is ignored.
public struct MadeSpec: Sendable, Equatable {
    /// `"gallery"` for a gallery image; absent on a slideshow.
    public var kind: String?
    public var layout: GalleryLayout?
    public var format: SlideshowPlan.Format?
    public var items: [Int]
    /// The JSON as the server sent it (what a store record keeps).
    public var data: Data

    public init(kind: String? = nil, layout: GalleryLayout? = nil, format: SlideshowPlan.Format? = nil, items: [Int] = [], data: Data = Data()) {
        self.kind = kind
        self.layout = layout
        self.format = format
        self.items = items
        self.data = data
    }

    /// Nil when `data` is not a JSON object.
    public init?(data: Data) {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        self.init(
            kind: object["kind"] as? String,
            layout: (object["layout"] as? String).flatMap(GalleryLayout.init(rawValue:)),
            format: (object["format"] as? String).flatMap(SlideshowPlan.Format.init(rawValue:)),
            items: (object["items"] as? [Any])?.compactMap { ($0 as? NSNumber)?.intValue } ?? [],
            data: data)
    }

    init?(object: [String: Any]) {
        guard JSONSerialization.isValidJSONObject(object), let data = try? JSONSerialization.data(withJSONObject: object) else { return nil }
        self.init(data: data)
    }
}

/// What a made file is, within its post: the key a remake replaces (R8: one `slideshow webp`, one `slideshow` mp4,
/// one `gallery image` per layout). A crop is never replaced.
public enum MadeKind: Sendable, Equatable, Hashable {
    case slideshow(SlideshowPlan.Format)
    case galleryImage(GalleryLayout)
    case crop

    /// From a row's role and spec. A slideshow row made before 18.10 has no format and counts as mp4; an export that
    /// is not a gallery image (a long image or a PDF made by an older build) has no kind here.
    public init?(role: GalleryRole?, spec: MadeSpec?) {
        switch role {
        case .slideshow?: self = .slideshow(spec?.format ?? .mp4)
        case .export?:
            guard spec?.kind == "gallery", let layout = spec?.layout else { return nil }
            self = .galleryImage(layout)
        case .crop?: self = .crop
        default: return nil
        }
    }

    /// The tab's name (`Copy.Gallery`): `slideshow webp`, `slideshow`, `gallery image · 3 across`.
    public var tabName: String {
        switch self {
        case .slideshow(.webp): return "slideshow webp"
        case .slideshow(.mp4): return "slideshow"
        case .galleryImage(let layout): return "gallery image · \(layout.label)"
        case .crop: return "crop"
        }
    }
}

extension GalleryLayout {
    /// The layout's name as the sheet and the file names say it.
    public var label: String {
        switch self {
        case .strip: return "strip"
        case .grid2: return "2 across"
        case .grid3: return "3 across"
        case .row: return "side by side"
        }
    }
}
