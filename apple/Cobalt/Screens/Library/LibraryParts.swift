import CobaltKit
import SwiftUI

/// Words that only the library card says (CONTRACT-MEDIA 1.13). Kept here so the screen never edits the shared
/// `Copy+Media.swift`; lowercase, like everything else.
enum LibraryCardCopy {
    /// "instagram Dd7P496wolG": the card's name for VoiceOver (the title without its separator dot).
    static func spokenTitle(service: String, ref: String?) -> String {
        ref.map { "\(service) \($0)" } ?? service
    }

    /// What the `video` chip says to VoiceOver.
    static func videoChipA11y(hosted: Bool, privateCopy: Bool) -> String {
        if hosted { return "\(Copy.Media.video), public link" }
        if privateCopy { return "\(Copy.Media.video), private copy" }
        return Copy.Media.video
    }

    /// What the `webp` chip says to VoiceOver: "3 webps, open the newest".
    static func webpChipA11y(_ n: Int) -> String {
        n > 1 ? "\(n) webps, open the newest" : "1 webp"
    }

    /// "14.8 s · 720×1280 · today 21:04": the video's length and size, then the media's latest activity.
    static func meta(_ item: MediaItem, now: Date) -> String {
        let source = item.video ?? item.face
        var parts: [String] = []
        if let d = source.duration ?? item.post?.duration { parts.append(Format.seconds(d)) }
        if let w = source.width ?? item.post?.width, let h = source.height ?? item.post?.height { parts.append(Format.size(w, h)) }
        parts.append(Format.when(item.latestAt, now: now))
        return parts.joined(separator: " · ")
    }
}

/// A rendition chip (CONTRACT-MEDIA 1.13): `video` (outline; a `link` glyph when hosted, a `lock` when only a
/// private copy exists) and `webp` / `webp ×3` (filled). A button: it opens the detail on that tab.
struct RenditionChip: View {
    enum Style { case video(hosted: Bool, privateCopy: Bool), webp(count: Int) }

    let style: Style
    let action: () -> Void

    private var label: String {
        switch style {
        case .video: return Copy.Media.video
        case .webp(let n): return Copy.Media.webpCount(n)
        }
    }

    private var leading: String {
        switch style {
        case .video: return Symbol.Media.video
        case .webp: return Symbol.Media.webp
        }
    }

    private var trailing: String? {
        guard case .video(let hosted, let privateCopy) = style else { return nil }
        if hosted { return Symbol.Media.hosted }
        return privateCopy ? Symbol.Media.privateCopy : nil
    }

    private var filled: Bool {
        if case .webp = style { return true }
        return false
    }

    /// Hosted video: the full ink; a private copy: the grey one; a webp: the inverse on its filled capsule.
    private var ink: Color {
        switch style {
        case .webp: return CobaltColor.onText
        case .video(let hosted, _): return hosted ? CobaltColor.text : CobaltColor.disabledInk
        }
    }

    private var a11y: String {
        switch style {
        case .video(let hosted, let privateCopy): return LibraryCardCopy.videoChipA11y(hosted: hosted, privateCopy: privateCopy)
        case .webp(let n): return LibraryCardCopy.webpChipA11y(n)
        }
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: leading).font(.system(size: 9.5, weight: .semibold)).accessibilityHidden(true)
                Text(label).lineLimit(1).fixedSize()
                if let trailing {
                    Image(systemName: trailing).font(.system(size: 9, weight: .semibold)).accessibilityHidden(true)
                }
            }
            .font(CobaltType.pill)
            .foregroundStyle(ink)
            .padding(.horizontal, 10)
            .frame(minHeight: 26)
            .background { if filled { Capsule().fill(CobaltColor.text) } }
            .overlay { if !filled { Capsule().strokeBorder(ink, lineWidth: 1) } }
            // the visible capsule is 26 pt; the touch target around it is taller
            .padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(CardPress())
        .accessibilityLabel(a11y)
    }
}

/// A press only dims; the card sits in a list row, so nothing may scale or move.
struct CardPress: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.opacity(configuration.isPressed ? 0.55 : 1)
    }
}

/// The media's picture: an aspect-correct box inside a square, at the face's own aspect (the newest webp, else
/// the video: a cropped webp is square or 4:5). The device's own poster of the face when it has one, else the first frame
/// of the face's public file, else any poster the device has for the media; a private-only media has neither and keeps the placeholder. Never plays: a list
/// of moving cards would be noise, and the detail is one tap away.
struct MediaPreview: View {
    let item: MediaItem
    var size: CGFloat = 64

    private var face: Rendition { item.face }
    private var fit: CGFloat { size - 8 }

    private var box: CGSize {
        let w = CGFloat(face.width ?? item.post?.width ?? 720), h = CGFloat(face.height ?? item.post?.height ?? 1280)
        let k = min(fit / max(w, 1), fit / max(h, 1))
        return CGSize(width: (w * k).rounded(), height: (h * k).rounded())
    }

    /// This device's poster of the face itself.
    private var facePoster: URL? { face.local?.posterURL }

    /// Last resort: any other record's poster (the original's frame stands in for a webp that has neither
    /// a stored poster nor a public file to borrow one from).
    private var otherPoster: URL? { item.local?.renditions.compactMap(\.posterURL).first }

    /// The public file's first frame: a webp's image, or a hosted video's frame.
    private var remote: RemotePoster? {
        if face.isWebp, let url = face.publicURL { return RemotePoster(url: url, isVideo: false) }
        if let hosted = item.video?.hosted, let url = hosted.url {
            return RemotePoster(url: url, isVideo: hosted.contentType?.lowercased().hasPrefix("image/") != true)
        }
        // a webp face with no public link of its own (not expected): the media's newest public webp
        if let url = item.webps.last(where: { $0.publicURL != nil })?.publicURL { return RemotePoster(url: url, isVideo: false) }
        return nil
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10, style: .continuous).fill(CobaltColor.elevated)
            ZStack {
                RoundedRectangle(cornerRadius: 6, style: .continuous).fill(FrameGradient.fill(1))
                if let facePoster {
                    StillImage(url: facePoster)
                } else if let remote {
                    RemoteStill(poster: remote)
                } else if let otherPoster {
                    StillImage(url: otherPoster)
                }
            }
            .frame(width: box.width, height: box.height)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}
