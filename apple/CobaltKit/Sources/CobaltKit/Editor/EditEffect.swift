import CoreGraphics
import CoreImage
import Foundation

// Effects on an overlay video (APP-API-CONTRACT 66 and 67, plus on-device cuts).
//
// The wire stays what the server stores today: optional `key` and `background` on each overlay, optional `output` on the
// timeline. The app's menu is a list of effects; only greenscreen becomes a `key`. Person, subject and depth replace the
// overlay's file with an uploaded alternate (`role = alt`). Remove background is the server's Bria job (section 67), which
// comes back as a ProRes alternate. Nothing here is chosen for the owner: the menu starts with no method.

/// One method in the effects menu. The owner picks it. Nothing is chosen automatically.
public enum EditEffectKind: String, Sendable, Equatable, CaseIterable {
    case greenscreen
    case depth
    case person
    case subject
    case removeBackground
}

/// A greenscreen `key` (section 66): `{ color, similarity, blend, spill }`.
/// `similarity` is 0.01...0.6, `blend` (edge softness, "feather") is 0...0.5, `spill` is 0...1.
/// Green `#00B140` and blue `#0047BB` are the presets the server also despills.
public struct EditChromaKey: Sendable, Equatable, Hashable, Codable {
    public var color: String
    public var similarity: Double
    public var blend: Double
    public var spill: Double

    public static let green = "#00B140"
    public static let blue = "#0047BB"

    public init(color: String = green, similarity: Double = 0.2, blend: Double = 0.05, spill: Double = 0.4) {
        self.color = color
        self.similarity = similarity
        self.blend = blend
        self.spill = spill
    }

    /// The numbers the server accepts, or nil when the colour is not `#RRGGBB`.
    public func normalized() -> EditChromaKey? {
        guard let color = Self.hex(color) else { return nil }
        return EditChromaKey(
            color: color,
            similarity: min(0.6, max(0.01, similarity)),
            blend: min(0.5, max(0, blend)),
            spill: min(1, max(0, spill)))
    }

    /// `#RRGGBB` uppercase, or nil.
    public static func hex(_ raw: String) -> String? {
        let s = raw.trimmingCharacters(in: .whitespaces)
        guard s.count == 7, s.hasPrefix("#"), s.dropFirst().allSatisfy({ $0.isHexDigit }) else { return nil }
        return "#" + s.dropFirst().uppercased()
    }

    /// 0...1 components of `color`, or nil.
    public var rgb: (r: Double, g: Double, b: Double)? {
        guard let color = Self.hex(color) else { return nil }
        let digits = color.dropFirst()
        func channel(_ pair: Substring) -> Double? {
            guard let n = Int(pair, radix: 16) else { return nil }
            return Double(n) / 255
        }
        let chars = Array(digits)
        guard chars.count == 6,
              let r = channel(Substring(chars[0...1])),
              let g = channel(Substring(chars[2...3])),
              let b = channel(Substring(chars[4...5])) else { return nil }
        return (r, g, b)
    }

    /// Green and blue presets, which the server despills. Any other colour is an eyedropper sample.
    public var despill: EditChromaSpill? {
        switch Self.hex(color) {
        case Self.green: return .green
        case Self.blue: return .blue
        default: return nil
        }
    }
}

public enum EditChromaSpill: String, Sendable { case green, blue }

/// What sits behind a keyed subject. Transparent is the default and is left out of the JSON.
/// `blur` is a preview on the device: the server's `background` is only `color` or `clip` (section 66), so blur is not sent.
public enum EditOverlayBackground: Sendable, Equatable {
    case color(String)
    case clip
    case blur

    /// The object the server stores, or nil for transparent and for blur (blur is not on the wire).
    public var wire: EditBackgroundWire? {
        switch self {
        case .color(let raw):
            guard let color = EditChromaKey.hex(raw) else { return nil }
            return EditBackgroundWire(type: "color", color: color)
        case .clip: return EditBackgroundWire(type: "clip", color: nil)
        case .blur: return nil
        }
    }

    public init?(wire: EditBackgroundWire) {
        switch wire.type {
        case "color":
            guard let color = wire.color, EditChromaKey.hex(color) != nil else { return nil }
            self = .color(EditChromaKey.hex(color)!)
        case "clip": self = .clip
        default: return nil
        }
    }
}

/// `{ type, color? }` as section 66 stores a background. Transparent is absent, not this value.
public struct EditBackgroundWire: Sendable, Equatable, Codable {
    public var type: String
    public var color: String?

    public init(type: String, color: String?) {
        self.type = type
        self.color = color
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(type, forKey: .type)
        if let color { try c.encode(color, forKey: .color) }
    }
}

/// The timeline's `output` (section 66). mp4 is the default and is left out, so an edit that does not name one keeps its bytes.
public enum EditKeyedOutput: String, Sendable, Equatable, Codable, CaseIterable {
    case mp4, webm, prores, webp

    /// Nil for mp4: the key is omitted.
    public var stored: EditKeyedOutput? { self == .mp4 ? nil : self }
}

/// One effect in the in-app list. Greenscreen carries the `key` it maps to. The other kinds do not: they replace the file.
public struct EditEffect: Sendable, Equatable {
    public var kind: EditEffectKind
    public var key: EditChromaKey?

    public init(kind: EditEffectKind, key: EditChromaKey? = nil) {
        self.kind = kind
        self.key = key
    }

    public static func greenscreen(_ key: EditChromaKey) -> EditEffect {
        EditEffect(kind: .greenscreen, key: key)
    }
}

/// The draft the canvas previews before Apply. It is not saved.
public struct EditEffectDraft: Sendable, Equatable {
    public var overlayID: String
    public var kind: EditEffectKind
    public var key: EditChromaKey
    public var background: EditOverlayBackground?
    public var showMask: Bool
    public var split: Bool

    public init(
        overlayID: String, kind: EditEffectKind, key: EditChromaKey, background: EditOverlayBackground? = nil,
        showMask: Bool = false, split: Bool = false
    ) {
        self.overlayID = overlayID
        self.kind = kind
        self.key = key
        self.background = background
        self.showMask = showMask
        self.split = split
    }
}

/// How the in-app list becomes the fields the server already stores.
public enum EditEffects {
    /// The `key` a list writes. Only a greenscreen effect has one; every other kind leaves `key` unset.
    /// The last greenscreen wins when a list somehow holds two.
    public static func chromaKey(in effects: [EditEffect]) -> EditChromaKey? {
        effects.last { $0.kind == .greenscreen }?.key?.normalized()
    }

    /// The list an overlay is already showing: one greenscreen when `key` is set, otherwise nothing.
    /// A cut that replaced the file is a new item, not a second field.
    public static func list(key: EditChromaKey?) -> [EditEffect] {
        guard let key = key?.normalized() else { return [] }
        return [.greenscreen(key)]
    }
}

/// How many videos sit on top of each other at one moment. Past 8 the preview drops to a smaller picture and says so.
public enum EditOverlap {
    public static let comfortableVideos = 8

    /// The most overlays whose `video` test is true that share one output frame.
    public static func peak(in t: EditTimeline, timing: EditTiming, video: (EditOverlay) -> Bool) -> Int {
        guard !t.overlay.isEmpty, timing.frames > 0 else { return 0 }
        var best = 0
        var i = 0
        while i < t.overlay.count {
            let start = timing.overlay.indices.contains(i) ? timing.overlay[i].start : 0
            var n = 0
            for (j, o) in t.overlay.enumerated() where video(o) && timing.overlay.indices.contains(j) {
                let slot = timing.overlay[j]
                if start >= slot.start, start < slot.start + slot.frames { n += 1 }
            }
            if n > best { best = n }
            i += 1
        }
        return best
    }
}

/// Depth Anything V2 small. Not in this build: there is no model to bundle or to download from a URL we ship.
/// A later build can fetch it once into Application Support/`cacheFolderName` (about `approximateMegabytes` MB, float16)
/// and cache it. Person and subject do not need it.
public enum EditDepthModel {
    public static let isBundled = false
    public static let approximateMegabytes = 95
    public static let cacheFolderName = "coreml-depth-anything-v2-small"
}

// MARK: - live chroma (Core Image)

/// A live greenscreen on one frame. It follows section 66's numbers closely enough to aim the sliders: distance from the
/// key colour, a soft edge of `blend`, and a despill on the green and blue presets. The render on the server is ffmpeg's
/// `chromakey` and is the one that is saved.
public enum EditChroma {
    private static let lock = NSLock()
    // Only touched with `lock` held.
    nonisolated(unsafe) private static var cubes: [EditChromaKey: Data] = [:]

    /// `image` with the key colour taken out. `mask` paints what remains white (the result / mask toggle).
    public static func apply(_ image: CIImage, key: EditChromaKey, mask: Bool) -> CIImage {
        guard let key = key.normalized(), let data = cubeData(for: key),
              let cube = CIFilter(name: "CIColorCube") else { return image }
        cube.setValue(16, forKey: "inputCubeDimension")
        cube.setValue(data, forKey: "inputCubeData")
        cube.setValue(image, forKey: kCIInputImageKey)
        guard var out = cube.outputImage?.cropped(to: image.extent) else { return image }
        if mask {
            let white = CIImage(color: CIColor(red: 1, green: 1, blue: 1)).cropped(to: image.extent)
            out = white.applyingFilter("CIBlendWithMask", parameters: [
                kCIInputBackgroundImageKey: CIImage(color: .clear).cropped(to: image.extent),
                kCIInputMaskImageKey: out,
            ])
        }
        return out
    }

    /// Left half of `keyed` over the right? The before/after split: the original on the left of `extent`, the keyed picture
    /// on the right.
    public static func split(original: CIImage, keyed: CIImage) -> CIImage {
        let extent = original.extent
        let mid = extent.minX + extent.width / 2
        let left = original.cropped(to: CGRect(x: extent.minX, y: extent.minY, width: mid - extent.minX, height: extent.height))
        let right = keyed.cropped(to: CGRect(x: mid, y: extent.minY, width: extent.maxX - mid, height: extent.height))
        return right.composited(over: left)
    }

    private static func cubeData(for key: EditChromaKey) -> Data? {
        lock.lock()
        defer { lock.unlock() }
        if let cached = cubes[key] { return cached }
        guard let data = cubeData(key) else { return nil }
        cubes[key] = data
        if cubes.count > 8 { cubes.removeAll(); cubes[key] = data }
        return data
    }

    /// 16³ RGBA floats. A sample closer than `similarity` (treated as a 0...1 distance) goes clear; `blend` feathers it.
    private static func cubeData(_ key: EditChromaKey) -> Data? {
        guard let rgb = key.rgb else { return nil }
        let n = 16
        var bytes = [Float](repeating: 0, count: n * n * n * 4)
        let edge0 = Float(key.similarity)
        let edge1 = edge0 + Float(max(0.001, key.blend))
        let kr = Float(rgb.r), kg = Float(rgb.g), kb = Float(rgb.b)
        var i = 0
        for b in 0..<n {
            for g in 0..<n {
                for r in 0..<n {
                    let rf = Float(r) / Float(n - 1)
                    let gf = Float(g) / Float(n - 1)
                    let bf = Float(b) / Float(n - 1)
                    let dist = sqrt((rf - kr) * (rf - kr) + (gf - kg) * (gf - kg) + (bf - kb) * (bf - kb)) / sqrt(3)
                    let alpha = smooth(dist, edge0, edge1)
                    var rr = rf, gg = gf, bb = bf
                    if let spill = key.despill, alpha > 0.02 {
                        let mix = Float(key.spill)
                        switch spill {
                        case .green:
                            let floor = max(rf, bf)
                            gg = gf + (floor - gf) * mix * (1 - alpha)
                        case .blue:
                            let floor = max(rf, gf)
                            bb = bf + (floor - bf) * mix * (1 - alpha)
                        }
                    }
                    bytes[i] = rr; bytes[i + 1] = gg; bytes[i + 2] = bb; bytes[i + 3] = alpha
                    i += 4
                }
            }
        }
        return bytes.withUnsafeBytes { Data($0) }
    }

    private static func smooth(_ x: Float, _ e0: Float, _ e1: Float) -> Float {
        if x <= e0 { return 0 }
        if x >= e1 { return 1 }
        let t = (x - e0) / (e1 - e0)
        return t * t * (3 - 2 * t)
    }
}
