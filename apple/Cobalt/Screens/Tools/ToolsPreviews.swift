#if DEBUG
import CobaltKit
import CoreGraphics
import SwiftUI

// `#Preview`s of the repost tools over a drawn photo (a sunset with words, 1080×1350, like an Instagram carousel photo): the
// crop in each shape and fill, saving, the stay-in-crop-mode failure, and the repost frame. The sheets run over the gallery
// preview scenarios; the real flow (a crop that becomes a tab, a frame in Photos) is `-previewTool` (see `ToolsDebug`).

private enum SamplePhoto {
    @MainActor static let image: CGImage = {
        let w = 1080, h = 1350
        let context = CGContext(
            data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        let colors = [CGColor(srgbRed: 0.35, green: 0.2, blue: 0.5, alpha: 1), CGColor(srgbRed: 0.98, green: 0.62, blue: 0.45, alpha: 1)] as CFArray
        let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors, locations: [0, 1])!
        context.drawLinearGradient(gradient, start: CGPoint(x: 0, y: 0), end: CGPoint(x: 0, y: h), options: [])
        context.setFillColor(CGColor(srgbRed: 1, green: 0.93, blue: 0.67, alpha: 1))
        context.fillEllipse(in: CGRect(x: 650, y: 820, width: 300, height: 300))
        context.setFillColor(CGColor(srgbRed: 0.1, green: 0.08, blue: 0.18, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: w, height: 330))
        return context.makeImage()!
    }()
}

@MainActor
private func sheet(
    _ scenario: PreviewScenario, link: String = "https://www.instagram.com/p/Ddy0-gpGg5U/",
    _ make: @escaping @MainActor (AppModel, MediaItem, ToolPhoto) -> AnyView
) -> some View {
    PreviewHost(scenario) { model in ToolsPreviewScene(model: model, link: link, make: make) }
}

/// Pastes the gallery, waits for the save, then shows the sheet over the media's first photo.
@MainActor
private struct ToolsPreviewScene: View {
    let model: AppModel
    let link: String
    let make: @MainActor (AppModel, MediaItem, ToolPhoto) -> AnyView
    @State private var shown: AnyView?

    var body: some View {
        Group {
            if let shown { shown } else { ProgressView().controlSize(.large) }
        }
        .task {
            model.pipeline.start(pastedText: link)
            for _ in 0..<300 {
                try? await Task.sleep(for: .milliseconds(100))
                if model.pipeline.galleryRun?.phase == .saved { break }
            }
            await model.library.refresh()
            guard let item = model.store.media.first.map({ model.mediaItem(for: $0) }), let first = ToolPhotos.photos(of: item).first else { return }
            let photo = ToolPhoto(first, image: SamplePhoto.image, pixels: CGSize(width: 1080, height: 1350))
            shown = make(model, item, photo)
        }
    }
}

#Preview("crop · 9:16, blurred bars") {
    sheet(.galleryInstagram) { model, item, photo in
        AnyView(CropSheet(model: model, item: item, photo: photo, crop: FrameCropModel(source: photo.pixels)))
    }
}
#Preview("crop · 4:5, cut to fit") {
    sheet(.galleryInstagram) { model, item, photo in
        AnyView(CropSheet(model: model, item: item, photo: photo, crop: FrameCropModel(source: photo.pixels, spec: FrameSpec(aspect: .classic, fill: .cut))))
    }
}
#Preview("crop · free") {
    sheet(.galleryInstagram) { model, item, photo in
        AnyView(CropSheet(model: model, item: item, photo: photo, crop: FrameCropModel(source: photo.pixels, spec: FrameSpec(aspect: .free))))
    }
}
#Preview("crop · saving") {
    sheet(.galleryInstagram) { model, item, photo in
        let crop = FrameCropModel(source: photo.pixels)
        crop.phase = .saving(fraction: 0.4, bytes: 412_000)
        return AnyView(CropSheet(model: model, item: item, photo: photo, crop: crop))
    }
}
#Preview("crop · upload failed, still in crop mode") {
    sheet(.galleryInstagram) { model, item, photo in
        let crop = FrameCropModel(source: photo.pixels)
        crop.phase = .failed(words: Copy.Gallery.cropFailed)
        return AnyView(CropSheet(model: model, item: item, photo: photo, crop: crop))
    }
}
#Preview("crop · a server that keeps none") {
    sheet(.plainCobalt) { model, item, photo in
        AnyView(CropSheet(model: model, item: item, photo: photo, crop: FrameCropModel(source: photo.pixels)))
    }
}
#Preview("repost frame · mixed post") {
    sheet(.galleryMixed, link: "https://www.instagram.com/p/DdMix1xedPo/") { model, item, photo in
        AnyView(RepostSheet(model: model, item: item, start: photo.rendition))
    }
}
#Preview("repost frame · dark, wide", traits: .fixedLayout(width: 700, height: 900)) {
    sheet(.galleryInstagram) { model, item, photo in
        AnyView(RepostSheet(model: model, item: item, start: photo.rendition, initial: FrameSpec(aspect: .square, fill: .cut)))
    }
    .preferredColorScheme(.dark)
}
#endif
