import CobaltKit
import SwiftUI

/// Remove background (apple/CONTRACT-EDITOR.md 12, APP-API-CONTRACT 39.3): the picture on a checkerboard with the cutout as it
/// will be (hold it to see the original), the mode (`auto` / `white` / `colour`), and for white and colour the tolerance,
/// "only from the edges" (keeps white eyes), soften and trim. In colour mode a tap on the picture picks the colour; it starts as
/// the commonest colour along the edge. `cut out and place` makes the new PNG in the library and puts it over the video at the
/// playhead on the lowest free layer.
///
/// The live preview runs on a 640 px copy on the device. When the picture cannot be read here (not downloaded, the preview
/// server), there is no live preview and the server makes the cutout (`features.cutout_auto`).
struct EditorCutoutSheet: View {
    let session: EditSession
    let source: EditSource
    /// An overlay showing `source` that should show the cutout instead; nil puts the cutout on at the playhead.
    var replacing: String?
    /// After the cutout was made and placed (then `close`).
    var made: () -> Void = {}
    let close: () -> Void

    @State private var original: CGImage?
    @State private var small: CGImage?
    @State private var result: CGImage?
    @State private var loadFailed = false
    @State private var mode: CutoutMode = .auto
    @State private var key: Color = .white
    @State private var tolerance: Double = 20
    @State private var edgesOnly = true
    @State private var soften = true
    @State private var trim = true
    @State private var showBefore = false
    @State private var working = false
    @State private var previewError: CutoutError?
    @State private var error: CutoutError?

    private var options: CutoutMaker.Options {
        CutoutMaker.Options(
            mode: mode, key: rgb(key), tolerance: tolerance, edgesOnly: edgesOnly, soften: soften ? 1 : 0, trim: trim)
    }

    /// What the live preview depends on (`Options` holds a tuple, so it is keyed by text).
    private var previewKey: String {
        "\(mode.rawValue) \(CutoutMaker.hex(rgb(key))) \(tolerance) \(edgesOnly) \(soften) \(trim) \(small != nil)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            stage
            controls
            if let error {
                Text(Copy.Editor.cutoutError(error))
                    .font(CobaltType.captionSmall)
                    .foregroundStyle(CobaltColor.errorText)
            }
            Button {
                Task { await cutOut() }
            } label: {
                Text(working ? Copy.Editor.cutoutMaking : (replacing == nil ? Copy.Editor.cutOutAndPlace : Copy.Editor.cutOut))
            }
            .buttonStyle(.cobaltPrimary())
            .disabled(working || (loadFailed && !session.canServerCutout(mode: mode)))
        }
        .padding(20)
        .frame(minWidth: Platform.isMac ? 420 : nil, maxWidth: 560)
        .background(CobaltColor.surface.ignoresSafeArea())
        .task { await load() }
        .task(id: previewKey) { await refreshPreview() }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text(Copy.Editor.removeBackground)
                .font(CobaltType.sheetTitle)
                .foregroundStyle(CobaltColor.text)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 8)
            CloseButton(cancels: true, action: close)
        }
    }

    // MARK: the picture

    private var stage: some View {
        ZStack {
            Checkerboard()
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            if let shown = showBefore ? small ?? original : result ?? small ?? original {
                GeometryReader { geo in
                    let fit = fitted(CGSize(width: shown.width, height: shown.height), in: geo.size)
                    Image(decorative: shown, scale: 1)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: fit.width, height: fit.height)
                        .position(x: geo.size.width / 2, y: geo.size.height / 2)
                        .contentShape(Rectangle())
                        .gesture(pickColour(in: geo.size, fit: fit, from: shown))
                }
                .padding(12)
            } else if loadFailed {
                VStack(spacing: 8) {
                    EditorPoster(url: source.posterURL, fallback: EditorColor.clip(for: source.id), maxPixel: 320)
                        .frame(maxWidth: 160, maxHeight: 160)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    Text(Copy.Editor.cutoutNoPreview)
                        .font(CobaltType.captionSmall)
                        .foregroundStyle(CobaltColor.caption)
                }
                .padding(12)
            } else {
                ProgressView(Copy.Editor.cutoutLoading)
                    .font(CobaltType.captionSmall)
            }
        }
        .frame(height: Platform.isMac ? 300 : 260)
        .overlay(alignment: .bottomLeading) {
            if small != nil {
                Text(showBefore ? Copy.Editor.cutoutBefore : (mode == .color ? Copy.Editor.cutoutPickColour : Copy.Editor.cutoutHoldBefore))
                    .font(Font.cobalt(10, .regular, relativeTo: .caption2))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                    .padding(8)
            }
        }
        .onLongPressGesture(minimumDuration: 0.2, maximumDistance: 30) {
        } onPressingChanged: { pressing in
            showBefore = pressing
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Copy.Editor.removeBackground)
        .accessibilityAddTraits(.isImage)
    }

    /// In colour mode a tap picks the colour under the finger from the picture on screen (a cleared spot picks nothing).
    private func pickColour(in size: CGSize, fit: CGSize, from picture: CGImage) -> some Gesture {
        SpatialTapGesture().onEnded { tap in
            guard mode == .color else { return }
            let left = (size.width - fit.width) / 2, top = (size.height - fit.height) / 2
            let point = CGPoint(x: (tap.location.x - left) / max(1, fit.width), y: (tap.location.y - top) / max(1, fit.height))
            if let c = CutoutMaker.colour(at: point, in: picture) {
                key = Color(red: Double(c.r) / 255, green: Double(c.g) / 255, blue: Double(c.b) / 255)
            }
        }
    }

    private func fitted(_ image: CGSize, in box: CGSize) -> CGSize {
        guard image.width > 0, image.height > 0, box.width > 0, box.height > 0 else { return .zero }
        let s = min(box.width / image.width, box.height / image.height)
        return CGSize(width: image.width * s, height: image.height * s)
    }

    // MARK: controls

    private var controls: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker(Copy.Editor.removeBackground, selection: $mode) {
                Text(Copy.Editor.cutoutAuto).tag(CutoutMode.auto)
                Text(Copy.Editor.cutoutWhite).tag(CutoutMode.white)
                Text(Copy.Editor.cutoutColour).tag(CutoutMode.color)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            if mode == .color {
                ColorPicker(Copy.Editor.cutoutColour, selection: $key, supportsOpacity: false)
                    .font(Font.cobalt(12, .regular, relativeTo: .caption))
            }
            if mode != .auto {
                HStack(spacing: 10) {
                    Text(Copy.Editor.cutoutTolerance)
                        .font(Font.cobalt(12, .regular, relativeTo: .caption))
                        .frame(width: 80, alignment: .leading)
                    Slider(value: $tolerance, in: 0...100, step: 1)
                        .accessibilityLabel(Copy.Editor.cutoutTolerance)
                    Text("\(Int(tolerance))")
                        .font(Font.cobalt(12, .regular, relativeTo: .caption).monospacedDigit())
                        .frame(width: 30, alignment: .trailing)
                }
                Toggle(isOn: $edgesOnly) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(Copy.Editor.cutoutEdgesOnly)
                        Text(Copy.Editor.cutoutEdgesHint)
                            .font(CobaltType.captionSmall)
                            .foregroundStyle(CobaltColor.caption)
                    }
                }
                Toggle(Copy.Editor.cutoutSoften, isOn: $soften)
            }
            Toggle(Copy.Editor.cutoutTrim, isOn: $trim)
        }
        .font(Font.cobalt(12.5, .regular, relativeTo: .callout))
        .foregroundStyle(CobaltColor.text)
        .tint(CobaltColor.linkBlue)
    }

    // MARK: work

    private func load() async {
        do {
            let picture = try await session.picture(for: source)
            original = picture
            small = CutoutMaker.previewSized(picture) ?? picture
            if let edge = CutoutMaker.edgeColour(small ?? picture) {
                key = Color(red: Double(edge.r) / 255, green: Double(edge.g) / 255, blue: Double(edge.b) / 255)
            }
        } catch {
            loadFailed = true
        }
    }

    /// The cutout of the small copy, a moment after the last change.
    private func refreshPreview() async {
        guard let small else { return }
        try? await Task.sleep(for: .milliseconds(120))
        guard !Task.isCancelled else { return }
        let box = ImageBox(small)
        let opts = options
        let made: Result<ImageBox, CutoutError> = await Task.detached(priority: .userInitiated) {
            do { return .success(ImageBox(try CutoutMaker.make(box.image, opts))) } catch let e as CutoutError {
                return .failure(e)
            } catch {
                return .failure(.failed)
            }
        }.value
        guard !Task.isCancelled else { return }
        switch made {
        case .success(let image):
            result = image.image
            previewError = nil
        case .failure(let e):
            result = nil
            previewError = e
        }
        if error == .empty { error = nil }
    }

    private func cutOut() async {
        working = true
        error = nil
        defer { working = false }
        do {
            try await session.makeCutout(of: source, options: options, place: true, replacing: replacing)
            made()
            close()
        } catch let e as CutoutError {
            error = e
        } catch {
            self.error = .failed
        }
    }

    private func rgb(_ color: Color) -> (r: UInt8, g: UInt8, b: UInt8) {
        let resolved = color.resolve(in: EnvironmentValues())
        let srgb = CGColorSpace(name: CGColorSpace.sRGB)
        let cg = srgb.flatMap { resolved.cgColor.converted(to: $0, intent: .defaultIntent, options: nil) } ?? resolved.cgColor
        let c = cg.components ?? [1, 1, 1]
        func byte(_ i: Int) -> UInt8 {
            let v = c.count >= 3 ? c[i] : c[0]
            return UInt8(max(0, min(255, (v * 255).rounded())))
        }
        return (byte(0), byte(1), byte(2))
    }
}

/// The grey and white squares behind a transparent picture.
struct Checkerboard: View {
    var size: CGFloat = 10

    var body: some View {
        Canvas { context, canvas in
            context.fill(Path(CGRect(origin: .zero, size: canvas)), with: .color(Color(white: 0.92)))
            let cols = Int(canvas.width / size) + 1, rows = Int(canvas.height / size) + 1
            var dark = Path()
            for row in 0..<rows {
                for col in 0..<cols where (row + col).isMultiple(of: 2) {
                    dark.addRect(CGRect(x: CGFloat(col) * size, y: CGFloat(row) * size, width: size, height: size))
                }
            }
            context.fill(dark, with: .color(Color(white: 0.8)))
        }
        .accessibilityHidden(true)
    }
}

/// The overlay's layer (`layer 2` with down and up) and, for a picture, `remove background`: shared by the inspector (Mac,
/// iPad) and the overlay sheet (iPhone).
struct EditorOverlayLayerRows: View {
    let session: EditSession
    let overlay: EditOverlay
    let removeBackground: () -> Void

    @State private var refused = 0

    private var source: EditSource? { session.source(for: overlay.item) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if session.overlayTrackLimit > 1 {
                EditorSection(Copy.Editor.layer, trailing: Copy.Editor.layerName(overlay.track)) {
                    IconRow(spacing: 8, alignment: .leading) {
                        layerButton(Symbol.Editor.layerDown, Copy.Editor.layerDown, enabled: overlay.track > 0) {
                            session.setOverlayTrack(id: overlay.id, overlay.track - 1)
                        }
                        layerButton(Symbol.Editor.layerUp, Copy.Editor.layerUp, enabled: overlay.track + 1 < session.overlayTrackLimit) {
                            session.setOverlayTrack(id: overlay.id, overlay.track + 1)
                        }
                    }
                }
            }
            if session.canCutout, let kind = source?.kind, kind == .photo || kind == .gif {
                IconRow(alignment: .leading) {
                    EditorInspectorButton(title: Copy.Editor.removeBackground, symbol: Symbol.Editor.cutout, action: removeBackground)
                }
            }
        }
        .haptic(.error, trigger: refused)
    }

    private func layerButton(_ symbol: String, _ label: String, enabled: Bool, move: @escaping () -> Bool) -> some View {
        Button {
            if !move() { refused += 1 }
        } label: {
            Label(label, systemImage: symbol)
        }
        .buttonStyle(.cobaltIcon(.small))
        .disabled(!enabled)
    }
}
