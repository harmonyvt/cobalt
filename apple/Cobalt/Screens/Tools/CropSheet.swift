import CobaltKit
import SwiftUI

// THE CROP SHEET (lane A7 · TOOLS, apple/CONTRACT-GALLERY.md 1.20 and 1.23; board `Photo-Detail`)
//
//     CropSheet(model: AppModel, item: MediaItem, rendition: Rendition, initial: FrameSpec? = nil, done: (String?) -> Void)
//
// Opened by the detail's `more › crop…` on a photo (a single photo, or one photo of a gallery). Frame chips (`1:1 4:5 9:16 3:4
// free`), the fill (`cut to fit` with the rectangle you move and pinch, or `blurred bars`: the whole photo on a blurred copy of
// itself), the size it will be, and `save crop`. The picture is drawn on this device (`FrameRenderer`), uploaded as a made file
// of the photo (`PUT /library/items/<id>/made`) and kept here with the media: it comes back as a `crop 9:16` tab, public or
// private with the media's switch, and the photo is never changed. When the upload fails the sheet stays in crop mode and
// says so; `save crop` tries again. A server that does not keep crops (plain cobalt, no `features.gallery`) turns the button
// into the Photos (or, on the Mac, file) save: nothing is stored server-side.

struct CropSheet: View {
    let model: AppModel
    let item: MediaItem
    let rendition: Rendition
    /// Closes the sheet's work: nil when the crop became a tab (the detail selects it), a line when it went to Photos.
    var done: (String?) -> Void = { _ in }

    @State private var photo: ToolPhoto
    @State private var crop: FrameCropModel?
    private let initial: FrameSpec?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.hapticsEnabled) private var haptics
    @Environment(\.dynamicTypeSize) private var typeSize

    init(model: AppModel, item: MediaItem, rendition: Rendition, initial: FrameSpec? = nil, done: @escaping (String?) -> Void = { _ in }) {
        self.model = model
        self.item = item
        self.rendition = rendition
        self.initial = initial
        self.done = done
        _photo = State(initialValue: ToolPhoto(rendition))
    }

    #if DEBUG
    /// Previews: a photo that is already decoded, and the model in a state (`saving`, `failed`).
    init(model: AppModel, item: MediaItem, photo: ToolPhoto, crop: FrameCropModel) {
        self.model = model
        self.item = item
        self.rendition = photo.rendition
        self.initial = nil
        _photo = State(initialValue: photo)
        _crop = State(initialValue: crop)
    }
    #endif

    private var stores: Bool { model.canStoreCrop(of: rendition) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if let crop {
                editor(crop)
            } else {
                loading
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, Platform.isMac ? 20 : 24)
        .padding(.bottom, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        #if os(iOS)
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        #else
        .frame(minWidth: 460, idealWidth: 520, maxWidth: 680, minHeight: 640, idealHeight: 760, maxHeight: 900)
        #endif
        .task {
            await photo.load(model: model)
            if crop == nil, photo.state == .ready { crop = FrameCropModel(source: photo.pixels, spec: initial) }
            #if DEBUG
            if let crop { await ToolsDebug.apply(to: crop, save: save) }
            #endif
        }
        .interactiveDismissDisabled(crop?.phase.isSaving ?? false)
    }

    // MARK: header

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(ToolsCopy.cropTitle).font(CobaltType.sheetTitle)
                Text(subtitle)
                    .font(CobaltType.captionSmall)
                    .foregroundStyle(CobaltColor.caption)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 0)
            CloseButton(cancels: true) { dismiss() }
                .disabled(crop?.phase.isSaving ?? false)
        }
    }

    private var subtitle: String {
        let name = rendition.itemIndex.map { Copy.Gallery.itemLabel(.photo, index: $0) } ?? DetailWords.photo
        guard photo.pixels.width > 0 else { return name }
        return "\(name) · \(Int(photo.pixels.width))×\(Int(photo.pixels.height))"
    }

    // MARK: while the photo opens

    @ViewBuilder
    private var loading: some View {
        VStack(spacing: 12) {
            Spacer(minLength: 0)
            if photo.state == .failed {
                Image(systemName: Symbol.Gallery.missing).font(.system(size: 26)).foregroundStyle(CobaltColor.errorText)
                Text(ToolsCopy.cantOpen)
                    .font(CobaltType.caption)
                    .foregroundStyle(CobaltColor.errorText)
                    .multilineTextAlignment(.center)
                Button(ToolsCopy.retry, systemImage: Symbol.retry) {
                    Task {
                        await photo.load(model: model)
                        if photo.state == .ready { crop = FrameCropModel(source: photo.pixels, spec: initial) }
                    }
                }
                .buttonStyle(.cobaltSecondary(fullWidth: false))
            } else {
                ProgressView().controlSize(.large)
                Text(ToolsCopy.loading).font(CobaltType.caption).foregroundStyle(CobaltColor.caption)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
    }

    // MARK: editing

    @ViewBuilder
    private func editor(_ crop: FrameCropModel) -> some View {
        let busy = crop.phase.isSaving
        if let image = photo.image {
            FrameCropStage(model: crop, image: image)
                .frame(maxWidth: .infinity, minHeight: 220, maxHeight: .infinity)
                .padding(.vertical, 2)
                .animation(reduceMotion ? nil : Motion.rows, value: crop.aspect)
                .animation(reduceMotion ? nil : Motion.rows, value: crop.fill)
                .disabled(busy)
        }
        VStack(alignment: .leading, spacing: 10) {
            shapes(crop).disabled(busy)
            if crop.aspect != .free {
                fills(crop).disabled(busy)
            } else {
                Text(ToolsCopy.fillNote(aspect: .free, fill: .cut, alreadyThatShape: false))
                    .font(CobaltType.captionSmall)
                    .foregroundStyle(CobaltColor.caption)
                    .fixedSize(horizontal: false, vertical: true)
            }
            readout(crop)
            status(crop)
            ButtonRow {
                Button(ToolsCopy.cancel) { dismiss() }
                    .buttonStyle(.cobaltSecondary())
                    .disabled(busy)
                Button(ToolsCopy.cropPrimary(stores: stores), systemImage: stores ? Symbol.Gallery.crop : GalleryActions.saveSymbol) { save(crop) }
                    .buttonStyle(.cobaltPrimary())
                    .keyboardShortcut(.defaultAction)
                    .disabled(busy || !crop.isValid)
            }
            Text(stores ? ToolsCopy.cropIsNew : (Platform.isMac ? ToolsCopy.cropNotKeptMac : ToolsCopy.cropNotKept))
                .font(CobaltType.captionSmall)
                .foregroundStyle(CobaltColor.caption)
                .fixedSize(horizontal: false, vertical: true)
        }
        .haptic(.selection, trigger: crop.snaps, enabled: haptics) { $0 > 0 }
        .haptic(.error, trigger: crop.phase.failure, enabled: haptics) { $0 != nil }
    }

    /// Segmented on a phone; a menu where the five labels cannot sit side by side (the largest text sizes).
    @ViewBuilder
    private func shapes(_ crop: FrameCropModel) -> some View {
        let binding = Binding(get: { crop.aspect }, set: { new in withAnimation(reduceMotion ? nil : Motion.rows) { crop.choose(new) } })
        let picker = Picker(ToolsCopy.shape, selection: binding) {
            ForEach(FrameSpec.Aspect.allCases, id: \.self) { Text($0.label).tag($0) }
        }
        if typeSize.isAccessibilitySize {
            picker.pickerStyle(.menu).labelsHidden().frame(maxWidth: .infinity, alignment: .leading)
        } else {
            picker.pickerStyle(.segmented).labelsHidden()
        }
    }

    @ViewBuilder
    private func fills(_ crop: FrameCropModel) -> some View {
        let binding = Binding(get: { crop.fill }, set: { new in withAnimation(reduceMotion ? nil : Motion.rows) { crop.choose(fill: new) } })
        Picker(ToolsCopy.fill, selection: binding) {
            ForEach([FrameSpec.Fill.blur, .cut], id: \.self) {
                Text(ToolsCopy.fillShort($0)).tag($0).accessibilityLabel(ToolsCopy.fillLong($0))
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        Text(ToolsCopy.fillNote(aspect: crop.aspect, fill: crop.fill, alreadyThatShape: crop.alreadyThatShape))
            .font(CobaltType.captionSmall)
            .foregroundStyle(CobaltColor.caption)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func readout(_ crop: FrameCropModel) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(ToolsCopy.readoutTitle).font(CobaltType.captionSmall).foregroundStyle(CobaltColor.caption)
            Spacer(minLength: 8)
            Text(ToolsCopy.readout(crop.output))
                .font(Font.cobalt(14, .medium, relativeTo: .callout).monospacedDigit())
                .foregroundStyle(crop.isValid ? CobaltColor.text : CobaltColor.errorText)
                .contentTransition(.numericText())
                .accessibilityLabel(ToolsCopy.sizeA11y(crop.output))
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func status(_ crop: FrameCropModel) -> some View {
        switch crop.phase {
        case .editing:
            if !crop.isValid {
                Label(CropCopy.tooSmall, systemImage: Symbol.Gallery.missing)
                    .font(CobaltType.captionSmall)
                    .foregroundStyle(CobaltColor.errorText)
                    .accessibilityLabel(CropCopy.tooSmallA11y)
            }
        case .saving(let fraction, let bytes):
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(ToolsCopy.saving(bytes.map(ToolsCopy.uploading)))
                        .font(CobaltType.captionSmall)
                        .foregroundStyle(CobaltColor.caption)
                        .monospacedDigit()
                }
                if let fraction { ProgressView(value: fraction).progressViewStyle(.linear) }
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.updatesFrequently)
        case .failed(let words):
            Text(words)
                .font(CobaltType.captionSmall)
                .foregroundStyle(CobaltColor.errorText)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.updatesFrequently)
        }
    }

    // MARK: save

    private func save(_ crop: FrameCropModel) {
        guard !crop.phase.isSaving, crop.isValid else { return }
        let spec = crop.spec
        crop.phase = .saving(fraction: nil, bytes: nil)
        Task {
            do {
                if stores {
                    try await model.saveCrop(of: rendition, in: item, spec: spec) { progress in
                        Task { @MainActor in
                            guard crop.phase.isSaving else { return }
                            crop.phase = .saving(fraction: progress.total.map { Double(progress.bytes) / Double(max(1, $0)) }, bytes: progress.total)
                        }
                    }
                    done(nil)
                    dismiss()
                } else {
                    let line = try await saveElsewhere(spec)
                    if let line { done(line); dismiss() } else { crop.phase = .editing }
                }
            } catch {
                // the upload failed: stay in crop mode, nothing changed, `save crop` again
                crop.phase = .failed(words: stores ? Copy.Gallery.cropFailed : DetailController.words(error))
            }
        }
    }

    /// No server copy: the picture goes to Photos (iPhone, iPad) or to a file the owner picks (Mac). The line to say after,
    /// or nil when the owner cancelled the panel.
    private func saveElsewhere(_ spec: FrameSpec) async throws -> String? {
        #if os(macOS)
        let made = try await model.repostFrames([rendition], spec: spec, to: .files)
        defer { ToolsExport.discard(made.files) }
        guard let file = made.files.first, try ToolsExport.save(file) else { return nil }
        return DetailWords.savedToFolder(1)
        #else
        _ = try await model.repostFrames([rendition], spec: spec, to: .photos)
        return DetailWords.savedToPhotos(1)
        #endif
    }
}
