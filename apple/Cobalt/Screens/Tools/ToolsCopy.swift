import CobaltKit
import CoreGraphics
import Foundation

/// The words of the repost tools (`crop` and `repost frame`, apple/CONTRACT-GALLERY.md 1.22-1.24) that `Copy.Gallery` does not
/// carry. Contract strings (`crop`, `save crop`, `keep in cobalt`, `cut to fit`, `whole photo, blurred bars`, the failure line,
/// `repost frame`, `save this one`) stay in `Copy.Gallery`; this file adds only the lines around them. Lowercase like every
/// control, in the file beside the screens that draw them.
enum ToolsCopy {
    // MARK: the menu

    static let cropMenu = "crop…"
    static let repostMenu = "repost frame…"

    // MARK: shared

    static let shape = "frame shape"
    static let fill = "outside the frame"
    static let readoutTitle = "picture"
    static let cancel = Copy.cancel
    static let loading = "opening the photo…"
    static let cantOpen = "can't open this photo. it is not on this \(Copy.device) and the server did not send it."
    static let retry = "try again"

    /// "1080×1920 · jpeg".
    static func readout(_ size: CGSize) -> String {
        "\(Int(size.width.rounded()))×\(Int(size.height.rounded())) · jpeg"
    }

    static func sizeA11y(_ size: CGSize) -> String {
        "picture \(Int(size.width.rounded())) by \(Int(size.height.rounded())) pixels"
    }

    /// The segmented control's short word for each fill; the long one (`Copy.Gallery.fillBlur`) is its VoiceOver label.
    static func fillShort(_ fill: FrameSpec.Fill) -> String { fill == .cut ? Copy.Gallery.fillCut : Copy.Gallery.fillBlurShort }
    static func fillLong(_ fill: FrameSpec.Fill) -> String { fill == .cut ? Copy.Gallery.fillCut : Copy.Gallery.fillBlur }

    /// The line under the fill control.
    static func fillNote(aspect: FrameSpec.Aspect, fill: FrameSpec.Fill, alreadyThatShape: Bool) -> String {
        if aspect == .free { return "drag the corners to cut any shape. nothing is added around it." }
        if alreadyThatShape { return "the photo already is \(aspect.label)." }
        switch fill {
        case .blur: return "nothing is cut: the photo sits on a blurred copy of itself (the slideshow's fill)."
        case .cut: return "the edges outside the frame are cut. drag the frame to move it, pinch to resize."
        }
    }

    // MARK: crop

    static let cropTitle = Copy.Gallery.crop
    static let cropIsNew = "a crop is a new file in this media (a tab); the photo stays as it was."
    static let cropNotKept = "this server doesn't keep crops. the picture goes to your photos."
    static let cropNotKeptMac = "this server doesn't keep crops. the picture is saved where you choose."
    static func saving(_ detail: String?) -> String { detail.map { "saving the crop · \($0)" } ?? "saving the crop" }
    static func uploading(_ bytes: Int64) -> String { "uploading \(Copy.Gallery.size(bytes))" }

    /// The sheet's one prominent button: `save crop` when the server keeps it, else the Photos (iPhone, iPad) or file (Mac) save.
    static func cropPrimary(stores: Bool) -> String {
        if stores { return Copy.Gallery.saveCrop }
        #if os(macOS)
        return Copy.saveAs
        #else
        return Copy.Media.savePhotos
        #endif
    }

    // MARK: repost frame

    static let repostTitle = Copy.Gallery.repostFrame
    static let repostNote = "made here, when you save or share. nothing is uploaded and nothing is added to this media."
    static func photoOf(_ i: Int, _ n: Int) -> String { Copy.Gallery.itemName("photo", i, of: n) }
    static let previous = "previous photo"
    static let next = "next photo"
    static let making = "making the frame…"
    static func makingN(_ done: Int, of n: Int) -> String { "making \(done) of \(n)…" }
    static let kept = "kept in cobalt: it is a tab of this media."
    /// What the repost sheet says after a save: iPhone and iPad put frames in Photos, the Mac in a folder or file.
    static func saved(_ n: Int, skipped: Int) -> String {
        #if os(macOS)
        let line = DetailWords.savedToFolder(n)
        #else
        let line = DetailWords.savedToPhotos(n)
        #endif
        return skipped > 0 ? "\(line) \(Copy.Gallery.videosSkippedFrames(skipped))." : line
    }
}
