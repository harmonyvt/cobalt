import CobaltKit
import SwiftUI
import UniformTypeIdentifiers

// The file-type badge on every planet (CONTRACT-ORBIT section 1): a small capsule in the planet's
// top-right corner with the lowercase type of the STORED FILE (mp4, mov, webp, gif, png, jpg...), read
// from its extension and UTType, never guessed from the post. One planet is one media (CONTRACT-MEDIA
// 1.7): the badge reads the FACE's file (the newest webp, else the video), and says `webp ×3` when the
// media has two or more webps. On planets whose short side is under ~40 pt it collapses to a tiny dot
// with a symbol (film for video, sparkles for webp, photo for an image) so it never covers the frame. It
// stays upright, rides with the planet, and stays legible over bright frames: a dark glass tint (65 %
// black, the app's badge back) behind the app's badge ink gives 5.3:1 over a pure white frame (the worst
// case; computed in the lane report).

/// What kind of file a planet's stored media is.
struct PlanetType: Equatable {
    /// "mp4", "webp", "mov", "gif", "png", "jpg"...
    let label: String
    /// `film`, `sparkles` or `photo`.
    let symbol: String

    init(label: String) {
        self.label = label
        self.symbol = Self.symbol(for: label)
    }

    /// From the stored file's extension; when the file was evicted, from the remote URL, then the
    /// name; and only when none of them has a real type, from what the entry is (an original video is
    /// an mp4 the server saved, a webp is a webp).
    init(_ video: StoredVideo) {
        let candidates: [URL?] = [video.fileURL, video.remoteURL, URL(fileURLWithPath: video.name)]
        for url in candidates {
            if let ext = Self.knownExtension(of: url) {
                self.init(label: ext)
                return
            }
        }
        self.init(label: video.kind == .webp ? "webp" : "mp4")
    }

    init(fileURL: URL?, fallback: String) {
        self.init(label: Self.knownExtension(of: fileURL) ?? fallback)
    }

    /// The lowercase extension when it names a real media type.
    static func knownExtension(of url: URL?) -> String? {
        guard var ext = url?.pathExtension.lowercased(), !ext.isEmpty, ext.count <= 5 else { return nil }
        if ext == "jpeg" { ext = "jpg" }
        if ext == "qt" { ext = "mov" }
        guard let type = UTType(filenameExtension: ext), type.conforms(to: .audiovisualContent) || type.conforms(to: .image) else { return nil }
        return ext
    }

    static func symbol(for ext: String) -> String {
        if ext == "webp" { return "sparkles" }
        if let type = UTType(filenameExtension: ext), type.conforms(to: .movie) { return "film" }
        return "photo"
    }
}

enum PlanetBadge {
    /// Inset from the planet's corner.
    static let inset: CGFloat = 4
    /// Under this on-screen short side the capsule collapses to a dot. The capsule is 11 pt type (a
    /// 3-letter type is about 34 pt wide, `webp ×3` about 52), so it needs a planet clearly wider than itself.
    static let compactBelow: CGFloat = 48
    /// The same for a capsule that carries a count (`webp ×3` is about 58 pt wide: it must not hang over its planet).
    static let compactBelowWithCount: CGFloat = 68
}

/// The corner of a planet in the orbit: the type capsule (11 pt type) of the face's file and, under it,
/// the link badge when the video was hosted (the old "has a webp" dot is gone: the face says it).
/// Light on purpose (no live glass: the orbit shows up to 35 of them while it turns). Below
/// `compactBelow` the capsule becomes one symbol dot (`sparkles` for a webp face, `film` for a video) in
/// one row with the link dot; no count.
struct PlanetBadges: View {
    let type: PlanetType
    var linked = false
    /// How many webps the media has: 2 or more reads `webp ×N` on a webp face.
    var webpCount = 0
    /// A gallery: the stack-and-count badge takes the place of the type (CONTRACT-GALLERY 1.22).
    var stack: Int?
    let compact: Bool

    private var label: String {
        if let stack { return "\(stack)" }
        return type.label == "webp" && webpCount > 1 ? Copy.Media.webpCount(webpCount) : type.label
    }

    private var symbol: String { stack == nil ? type.symbol : Symbol.Gallery.gallery }

    var body: some View {
        Group {
            if compact {
                HStack(spacing: 2) {
                    if linked { dot(Symbol.linkBadge, size: 14, glyph: 8) }
                    dot(symbol, size: 14, glyph: 8)
                }
            } else {
                VStack(alignment: .trailing, spacing: 3) {
                    capsule
                    if linked { dot(Symbol.linkBadge, size: 18, glyph: 10) }
                }
            }
        }
        .accessibilityHidden(true)
    }

    private var capsule: some View {
        HStack(spacing: 3) {
            if stack != nil { Image(systemName: Symbol.Gallery.gallery).font(.system(size: 9, weight: .semibold)) }
            Text(label)
        }
            .font(Font.cobalt(11, .medium, relativeTo: .caption))
            .dynamicTypeSize(...DynamicTypeSize.large)
            .lineLimit(1)
            .fixedSize()
            .foregroundStyle(CobaltColor.badgeInk)
            .padding(.horizontal, 6.5)
            .padding(.vertical, 3)
            .background(CobaltColor.badgeBack, in: Capsule())
            .overlay(Capsule().strokeBorder(rim, lineWidth: 0.75))
    }

    private func dot(_ symbol: String, size: CGFloat, glyph: CGFloat) -> some View {
        Image(systemName: symbol)
            .font(.system(size: glyph, weight: .semibold))
            .foregroundStyle(CobaltColor.badgeInk)
            .frame(width: size, height: size)
            .background(CobaltColor.badgeBack, in: Circle())
            .overlay(Circle().strokeBorder(rim, lineWidth: 0.75))
    }

    private var rim: LinearGradient {
        LinearGradient(colors: [.white.opacity(0.5), .white.opacity(0.1)], startPoint: .top, endPoint: .bottom)
    }
}
