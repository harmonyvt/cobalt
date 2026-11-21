#if DEBUG
import CobaltKit
import CoreGraphics
import SwiftUI

// `#Preview`s of the emote editor on the preview server (`PreviewEmoteEditor.swift`: `make` answers a plausible draft after a
// short delay, offline): one screen wide (the preview on top, one tab's controls under it), a spread (the result on one side,
// the tabs on the other), a video with the frames tab, and a source whose shape the server would refuse.

private enum EmotePreviewArt {
    /// A pink cat-ish blob on a purple gradient, 720 x 540 (a flat drawing; the real editor draws the library's picture).
    @MainActor static let image: CGImage = {
        let w = 720, h = 540
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let context = CGContext(
            data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let colors = [CGColor(srgbRed: 0.45, green: 0.25, blue: 0.5, alpha: 1), CGColor(srgbRed: 0.5, green: 0.35, blue: 0.95, alpha: 1)] as CFArray
        let gradient = CGGradient(colorsSpace: space, colors: colors, locations: [0, 1])!
        context.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: 0, y: h), options: [])
        context.setFillColor(CGColor(srgbRed: 1, green: 0.45, blue: 0.8, alpha: 1))
        context.fillEllipse(in: CGRect(x: 160, y: 80, width: 400, height: 300))
        context.fill(CGRect(x: 190, y: 330, width: 60, height: 100))
        context.fill(CGRect(x: 470, y: 330, width: 60, height: 100))
        context.setFillColor(CGColor(srgbRed: 0.3, green: 0.05, blue: 0.3, alpha: 1))
        context.fill(CGRect(x: 250, y: 200, width: 220, height: 24))
        return context.makeImage()!
    }()

    @MainActor static var strip: [CGImage] { Array(repeating: image, count: 12) }
}

@MainActor
private func editor(
    _ model: AppModel, file: String = "preview-pic", type: String = "image/webp", duration: Double? = nil,
    tab: EmoteEditorModel.Tab? = nil
) -> some View {
    let source = EmoteSource(
        fileID: file, title: "lia squish", contentType: type, width: 720, height: 540, duration: duration, bytes: 1_400_000)
    let rendition = Rendition(id: "f:\(file)", kind: .item(index: 0, type: .photo), createdAt: Date())
    let target = EmoteEditorTarget(source: source, rendition: rendition)
    let loader = EmoteSourceLoader(preview: EmotePreviewArt.image, duration: duration, strip: duration == nil ? [] : EmotePreviewArt.strip)
    return EmoteEditorPreviewHost(model: model, target: target, loader: loader, tab: tab)
}

/// Opens the editor on a tab (the tab lives on the editor's model, which the screen makes).
private struct EmoteEditorPreviewHost: View {
    let model: AppModel
    let target: EmoteEditorTarget
    let loader: EmoteSourceLoader
    let tab: EmoteEditorModel.Tab?

    var body: some View {
        EmoteEditorScreen(model: model, target: target, loader: loader, initialTab: tab) {}
    }
}

#Preview("emote editor · iphone", traits: .fixedLayout(width: 390, height: 844)) {
    PreviewHost(.happy) { model in editor(model, tab: .squash) }
}
#Preview("emote editor · iphone dark", traits: .fixedLayout(width: 390, height: 844)) {
    PreviewHost(.happy) { model in editor(model, tab: .compress) }
        .preferredColorScheme(.dark)
}
#Preview("emote editor · spread", traits: .fixedLayout(width: 1_100, height: 760)) {
    PreviewHost(.happy) { model in editor(model, tab: .compress) }
}
#Preview("emote editor · crop", traits: .fixedLayout(width: 1_100, height: 760)) {
    PreviewHost(.happy) { model in editor(model, tab: .crop) }
        .preferredColorScheme(.dark)
}
#Preview("emote editor · video", traits: .fixedLayout(width: 1_100, height: 760)) {
    PreviewHost(.happy) { model in editor(model, file: "preview-video-mp4", type: "video/mp4", duration: 42, tab: .frames) }
        .preferredColorScheme(.dark)
}
#Preview("emote editor · not linked", traits: .fixedLayout(width: 390, height: 844)) {
    PreviewHost(.stageNotConnected) { model in editor(model, tab: .format) }
}
#endif
