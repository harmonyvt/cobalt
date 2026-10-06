import CobaltKit
import SwiftUI

/// The gallery image's settings: the four layouts (picked each time, `3 across` first), a preview drawn to scale from
/// `GalleryGeometry` (the same function the server's helper runs, so what is drawn is what is made), and the notes the
/// layout earns: which photos it crops, which it draws larger than their own pixels, which videos it leaves out
/// (apple/CONTRACT-GALLERY.md 1.15, R3, R4; boards `Gallery-Combine` and `Gallery-Image`).
struct CombineImagePane: View {
    @Bindable var combine: CombineModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(Copy.Combine.layoutLabel)
                .font(CobaltType.captionSmall)
                .foregroundStyle(CobaltColor.caption)
            layouts
            if let canvas = combine.canvas {
                CombineImagePreview(combine: combine, canvas: canvas)
                Text(meta(canvas))
                    .font(CobaltType.captionSmall)
                    .monospacedDigit()
                    .foregroundStyle(CobaltColor.caption)
                    .accessibilityAddTraits(.updatesFrequently)
                notes(canvas)
            } else if let reason = combine.gate.reason {
                Text(reason)
                    .font(CobaltType.captionSmall)
                    .foregroundStyle(CobaltColor.errorText)
                    .accessibilityAddTraits(.updatesFrequently)
            }
            if combine.imagePhotos.skipped > 0 {
                Text(Copy.Gallery.videosSkipped(combine.imagePhotos.skipped))
                    .font(CobaltType.badge)
                    .foregroundStyle(CobaltColor.caption)
            }
        }
    }

    private func meta(_ canvas: GalleryCanvas) -> String {
        Copy.Gallery.imageMeta(canvas.width, canvas.height, Copy.Gallery.size(combine.estimatedBytes))
            + (canvas.scaledToCap ? Copy.Combine.scaledNote : "")
    }

    // MARK: the four layouts

    private var layouts: some View {
        HStack(spacing: 6) {
            ForEach(GalleryLayout.allCases, id: \.self) { layout in
                let on = combine.layout == layout
                Button { combine.layout = layout } label: {
                    VStack(spacing: 3) {
                        LayoutGlyph(layout: layout).frame(width: 28, height: 28)
                        Text(layout.label)
                            .font(.cobalt(10.5, on ? .semibold : .regular, relativeTo: .caption2))
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }
                    .foregroundStyle(on ? CobaltColor.onText : CobaltColor.text)
                    .frame(maxWidth: .infinity, minHeight: 58)
                    .background(on ? CobaltColor.text : CobaltColor.surface, in: .rect(cornerRadius: 12))
                    .contentShape(.rect(cornerRadius: 12))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Copy.Combine.layoutNameA11y(layout.label))
                .accessibilityAddTraits(on ? [.isButton, .isSelected] : .isButton)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Copy.Combine.layoutA11y)
    }

    // MARK: notes

    @ViewBuilder
    private func notes(_ canvas: GalleryCanvas) -> some View {
        let photos = combine.imagePhotos.photos
        let cropped = canvas.croppedIndices.compactMap { photos.indices.contains($0) ? photos[$0].id : nil }
        let lines = noteLines(canvas, photos: photos, cropped: cropped)
        ForEach(lines, id: \.self) { line in
            Text(line)
                .font(CobaltType.badge)
                .foregroundStyle(CobaltColor.caption)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func noteLines(_ canvas: GalleryCanvas, photos: [GalleryItem], cropped: [Int]) -> [String] {
        var lines: [String] = []
        if !cropped.isEmpty, let first = canvas.cells.first {
            lines.append(Copy.Gallery.cropped(Copy.Gallery.photoNames(cropped), cell: Copy.Gallery.shape(first.rect.size)))
        }
        for cell in canvas.cells {
            guard let up = cell.upscale, photos.indices.contains(cell.index) else { continue }
            let name = Copy.Gallery.itemLabel(.photo, index: photos[cell.index].id)
            let alone = canvas.cells.filter { $0.rect.minY == cell.rect.minY }.count == 1
            lines.append(alone ? Copy.Gallery.drawnLarger(name, Copy.Gallery.times(up)) : Copy.Combine.drawnLargerCropped(name, Copy.Gallery.times(up)))
        }
        return lines
    }
}

/// The preview: the canvas drawn to scale, every photo aspect-filled in its cell (so a cropped photo shows what the cell
/// keeps), no gaps and no borders. A tall strip scrolls inside its box.
struct CombineImagePreview: View {
    let combine: CombineModel
    let canvas: GalleryCanvas

    var body: some View {
        let photos = combine.imagePhotos.photos
        GeometryReader { proxy in
            let size = drawnSize(in: proxy.size.width)
            ScrollView([.horizontal, .vertical]) {
                ZStack(alignment: .topLeading) {
                    ForEach(canvas.cells, id: \.index) { cell in
                        if photos.indices.contains(cell.index) {
                            let photo = photos[cell.index]
                            let r = rect(of: cell, scale: size.scale)
                            CombinePicture(sources: combine.pictureSources(photo.id), maxPixel: 420, item: photo, number: photo.id)
                                .frame(width: r.width, height: r.height)
                                .clipped()
                                .offset(x: r.minX, y: r.minY)
                        }
                    }
                }
                .frame(width: size.width, height: size.height, alignment: .topLeading)
                .frame(minWidth: proxy.size.width - 8)
                .padding(4)
            }
        }
        .frame(height: combine.layout == .row ? 190 : 210)
        .background(CobaltColor.surface, in: .rect(cornerRadius: 10))
        .clipShape(.rect(cornerRadius: 10))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Copy.Combine.imagePreviewA11y)
    }

    /// The board's scales: a strip a little under half the box, a grid most of it, side by side 150 tall.
    private func drawnSize(in available: CGFloat) -> (width: CGFloat, height: CGFloat, scale: CGFloat) {
        let box = min(max(available - 8, 120), 460)
        let w = CGFloat(canvas.width), h = CGFloat(canvas.height)
        let scale: CGFloat
        switch combine.layout {
        case .strip: scale = (box * 0.4) / w
        case .grid2: scale = (box * 0.74) / w
        case .grid3: scale = (box * 0.8) / w
        case .row: scale = 150 / h
        }
        return ((w * scale).rounded(), (h * scale).rounded(), scale)
    }

    /// A cell's rectangle in points, rounded on both edges so neighbours meet exactly.
    private func rect(of cell: GalleryCanvas.Cell, scale: CGFloat) -> CGRect {
        let x0 = (cell.rect.minX * scale).rounded(), x1 = (cell.rect.maxX * scale).rounded()
        let y0 = (cell.rect.minY * scale).rounded(), y1 = (cell.rect.maxY * scale).rounded()
        return CGRect(x: x0, y: y0, width: max(1, x1 - x0), height: max(1, y1 - y0))
    }
}

/// A layout drawn as little cells (the board's `layCells`).
private struct LayoutGlyph: View {
    let layout: GalleryLayout

    private var cells: [CGRect] {
        func r(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGRect { CGRect(x: x, y: y, width: w, height: h) }
        switch layout {
        case .strip: return [r(9, 1, 10, 6), r(9, 8, 10, 6), r(9, 15, 10, 6), r(9, 22, 10, 5)]
        case .grid2: return [r(2, 2, 11, 11), r(15, 2, 11, 11), r(2, 15, 11, 11), r(15, 15, 11, 11)]
        case .grid3: return [r(1, 5, 8, 8), r(10, 5, 8, 8), r(19, 5, 8, 8), r(1, 15, 8, 8), r(10, 15, 8, 8), r(19, 15, 8, 8)]
        case .row: return [r(1, 8, 6, 12), r(8, 8, 6, 12), r(15, 8, 6, 12), r(22, 8, 5, 12)]
        }
    }

    var body: some View {
        Canvas { context, _ in
            for cell in cells {
                context.fill(Path(roundedRect: cell, cornerRadius: 1), with: .style(.foreground.opacity(0.6)))
            }
        }
        .accessibilityHidden(true)
    }
}
