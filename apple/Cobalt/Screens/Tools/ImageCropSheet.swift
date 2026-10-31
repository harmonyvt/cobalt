import CobaltKit
import SwiftUI

// THE PICTURE CROP SHEET (apple/CONTRACT-EDITOR.md 13, APP-API-CONTRACT 44; mockup https://claude.ai/artifact/TpWXqfmaoEuFLBsGA5Fua9)
//
//     ImageCropSheet(name:, load:, serverCan:, note:, primary:, secondary:, close:)
//
// One sheet for iPhone, iPad and Mac: the picture with a crop box (`ImageCropStage`), the aspect chips `free · original · 1:1 ·
// 4:5 · 9:16 · 16:9`, rotate left, flip, `remove background`, and its buttons: `save a copy` (the library), `save a copy` and
// `crop and place` (the editor's bin and add sheet), `crop` (an image overlay: the crop takes the overlay's picture). The crop
// is made on the device at full resolution and uploaded as a PNG; when the picture cannot be opened here and the server can make
// it (`serverCan`), the server crops the whole picture (turn, flip, background) instead. The Mac lays it out as a panel: the
// picture on the left, the controls in a sidebar; ↩ runs the primary button, esc cancels, the arrow keys nudge the box.
//
// The entry points build it with `ImageCropSheet.library(...)` (Library/LibraryImageCropHook.swift) and `.editor(...)` (below).

/// One of the sheet's buttons: its words, its symbol, and what it does with the crop (`picture` is the stored picture at full
/// size, nil when it could not be opened here). It throws `ImageCropError` to keep the sheet open and say why.
struct ImageCropAction {
    let title: String
    let symbol: String
    let run: @MainActor (ImageCropSpec, CGImage?) async throws -> Void
}

struct ImageCropSheet: View {
    /// The picture's name, under the title.
    let name: String
    /// The stored picture at full size.
    let load: @MainActor () async throws -> CGImage
    /// The server can make this crop itself (the argument: `remove background` is on).
    let serverCan: @MainActor (Bool) -> Bool
    var note: String = Copy.Editor.cropNote
    let primary: ImageCropAction
    var secondary: ImageCropAction?
    let close: () -> Void

    @State private var original: ImageCropPicture?
    @State private var small: ImageCropPicture?
    @State private var shown: ImageCropPicture?
    @State private var model: ImageCropModel?
    @State private var loadFailed = false
    @State private var working: String?
    @State private var error: ImageCropError?
    @State private var made = 0
    @State private var failed = 0

    var body: some View {
        content
            .modifier(ImageCropSheetFrame(busy: working != nil))
            .modifier(ImageCropSheetHaptics(snaps: model?.snaps ?? 0, made: made, failed: failed))
            .task { await loadPicture() }
            .task(id: turnKey) { await refreshShown() }
    }

    @ViewBuilder
    private var content: some View {
        if Platform.isMac {
            VStack(alignment: .leading, spacing: 14) {
                header
                HStack(alignment: .top, spacing: 18) {
                    stage.frame(maxWidth: .infinity, maxHeight: .infinity)
                    sidebar.frame(width: 248)
                }
            }
        } else {
            VStack(alignment: .leading, spacing: 12) {
                header
                stage.frame(maxWidth: .infinity, minHeight: 240, maxHeight: .infinity)
                if let model { phoneControls(model) }
                messages
                buttons(stacked: false)
                noteLine
            }
        }
    }

    // MARK: header

    private var header: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(Copy.Editor.pictureCrop)
                    .font(CobaltType.sheetTitle)
                    .foregroundStyle(CobaltColor.text)
                    .accessibilityAddTraits(.isHeader)
                Text(subtitle)
                    .font(CobaltType.captionSmall)
                    .foregroundStyle(CobaltColor.caption)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 8)
            Button { model?.reset() } label: { Label(Copy.Editor.cropReset, systemImage: Symbol.Editor.cropReset) }
                .buttonStyle(.cobaltIcon(.small))
                .disabled(model == nil || working != nil)
            CloseButton(cancels: true, action: close)
                .disabled(working != nil)
        }
    }

    private var subtitle: String {
        guard let original else { return name }
        return "\(name) · \(Copy.Editor.cropSize(original.image.width, original.image.height))"
    }

    // MARK: the picture

    @ViewBuilder
    private var stage: some View {
        ZStack {
            if let model, let shown {
                ImageCropStage(model: model, image: shown.image)
                    .disabled(working != nil)
            } else if loadFailed {
                VStack(spacing: 10) {
                    Image(systemName: Symbol.Gallery.missing)
                        .font(.system(size: 24))
                        .foregroundStyle(CobaltColor.caption)
                    Text(serverCan(model?.cutout ?? false) ? Copy.Editor.cropNoPreview : ToolsCopy.cantOpen)
                        .font(CobaltType.captionSmall)
                        .foregroundStyle(CobaltColor.caption)
                        .multilineTextAlignment(.center)
                    Button(ToolsCopy.retry, systemImage: Symbol.retry) { Task { await loadPicture() } }
                        .buttonStyle(.cobaltSecondary(fullWidth: false, compact: true))
                }
                .padding(16)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ProgressView(Copy.Editor.cropLoading)
                    .font(CobaltType.captionSmall)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(CobaltColor.elevated.opacity(0.4), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    // MARK: controls

    private func phoneControls(_ model: ImageCropModel) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if shown != nil {
                ScrollView(.horizontal, showsIndicators: false) { aspectChips(model) }
                    .scrollBounceBehavior(.basedOnSize)
            }
            HStack(spacing: 10) {
                turnButtons(model)
                Spacer(minLength: 8)
                backgroundToggle(model)
            }
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let model {
                if shown != nil {
                    sideLabel(Copy.Editor.cropAspect)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 66), spacing: 6)], alignment: .leading, spacing: 6) {
                        chips(model)
                    }
                }
                sideLabel(Copy.Editor.cropTurn)
                turnButtons(model)
                backgroundToggle(model)
                if shown != nil, let out = model.output {
                    Text(Copy.Editor.cropReadout(x: model.shownBox.x, y: model.shownBox.y, w: out.width, h: out.height))
                        .font(Font.cobalt(11, .regular, relativeTo: .caption2).monospacedDigit())
                        .foregroundStyle(CobaltColor.caption)
                }
            }
            messages
            Spacer(minLength: 0)
            buttons(stacked: true)
            noteLine
        }
    }

    private func sideLabel(_ text: String) -> some View {
        Text(text)
            .font(Font.cobalt(11, .semibold, relativeTo: .caption2))
            .foregroundStyle(CobaltColor.caption)
            .accessibilityAddTraits(.isHeader)
    }

    private func aspectChips(_ model: ImageCropModel) -> some View {
        HStack(spacing: 6) { chips(model) }
    }

    @ViewBuilder
    private func chips(_ model: ImageCropModel) -> some View {
        ForEach(ImageCropModel.Aspect.allCases) { aspect in
            ImageCropChip(title: aspect.label, selected: model.aspect == aspect) { model.choose(aspect) }
                .disabled(working != nil)
        }
    }

    private func turnButtons(_ model: ImageCropModel) -> some View {
        IconRow(spacing: 8, alignment: .leading) {
            Button { model.rotateLeft() } label: { Label(Copy.Editor.cropRotateLeft, systemImage: Symbol.Editor.cropRotateLeft) }
                .buttonStyle(.cobaltIcon(.small))
            Button { model.toggleFlip() } label: { Label(Copy.Editor.cropFlip, systemImage: Symbol.Editor.cropFlip) }
                .buttonStyle(.cobaltIcon(.small, prominent: model.flip != .none))
        }
        .disabled(working != nil)
        .fixedSize()
    }

    private func backgroundToggle(_ model: ImageCropModel) -> some View {
        Toggle(Copy.Editor.cropRemoveBackground, isOn: Binding(get: { model.cutout }, set: { model.cutout = $0 }))
            .font(Font.cobalt(12.5, .regular, relativeTo: .callout))
            .foregroundStyle(CobaltColor.text)
            .tint(CobaltColor.linkBlue)
            .fixedSize()
            .disabled(working != nil)
    }

    @ViewBuilder
    private var messages: some View {
        if let error {
            Text(Copy.Editor.cropError(error))
                .font(CobaltType.captionSmall)
                .foregroundStyle(CobaltColor.errorText)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.updatesFrequently)
        } else if let working {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("\(working) · \(Copy.Editor.cropping)")
                    .font(CobaltType.captionSmall)
                    .foregroundStyle(CobaltColor.caption)
            }
            .accessibilityElement(children: .combine)
        }
    }

    // MARK: buttons

    private var canRun: Bool {
        guard working == nil, let model, model.canMake else { return false }
        return original != nil || serverCan(model.cutout)
    }

    @ViewBuilder
    private func buttons(stacked: Bool) -> some View {
        let layout = stacked ? AnyLayout(VStackLayout(spacing: 8)) : AnyLayout(HStackLayout(spacing: 10))
        layout {
            if let secondary {
                Button(secondary.title, systemImage: secondary.symbol) { Task { await run(secondary) } }
                    .buttonStyle(.cobaltSecondary())
                    .disabled(!canRun)
            }
            Button(primary.title, systemImage: primary.symbol) { Task { await run(primary) } }
                .buttonStyle(.cobaltPrimary())
                .keyboardShortcut(.defaultAction)
                .disabled(!canRun)
        }
    }

    private var noteLine: some View {
        Text(note)
            .font(CobaltType.captionSmall)
            .foregroundStyle(CobaltColor.caption)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: work

    /// What the shown picture depends on.
    private var turnKey: String { "\(model?.rotate ?? 0) \(model?.flip.rawValue ?? "none") \(small != nil)" }

    private func loadPicture() async {
        guard original == nil else { return }
        loadFailed = false
        do {
            let picture = try await load()
            let preview = CutoutMaker.previewSized(picture, maxSide: 1_400) ?? picture
            original = ImageCropPicture(picture)
            small = ImageCropPicture(preview)
            shown = small
            model = ImageCropModel(source: CGSize(width: picture.width, height: picture.height))
            loadFailed = false
        } catch {
            loadFailed = true
            // the server can still turn, flip and cut out the whole picture
            if model == nil { model = ImageCropModel(source: CGSize(width: 1_000, height: 1_000)) }
        }
    }

    /// The picture turned and flipped as the model says, off the main thread.
    private func refreshShown() async {
        guard let small, let model else { return }
        let rotate = model.rotate, flip = model.flip
        let turned: ImageCropPicture? = await Task.detached(priority: .userInitiated) {
            ImageCropper.turned(small.image, rotate: rotate, flip: flip).map(ImageCropPicture.init)
        }.value
        guard !Task.isCancelled, let turned else { return }
        shown = turned
    }

    private func run(_ action: ImageCropAction) async {
        guard canRun, let model else { return }
        let spec = model.spec
        working = action.title
        error = nil
        defer { working = nil }
        do {
            try await action.run(spec, original?.image)
            made += 1
            close()
        } catch let e as ImageCropError {
            error = e
            failed += 1
        } catch {
            self.error = .failed
            failed += 1
        }
    }
}

// MARK: - parts

/// An aspect chip: its words on a capsule, filled when it is the one chosen.
private struct ImageCropChip: View {
    let title: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(Font.cobalt(12, .medium, relativeTo: .caption))
                .foregroundStyle(selected ? CobaltColor.onText : CobaltColor.text)
                .lineLimit(1)
                .padding(.horizontal, 12)
                .frame(minHeight: 30)
                .background(selected ? CobaltColor.text : CobaltColor.elevated, in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// The sheet's padding, background and size (a panel of its own size on the Mac, the large detent on a phone).
private struct ImageCropSheetFrame: ViewModifier {
    let busy: Bool

    func body(content: Content) -> some View {
        content
            .padding(20)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(CobaltColor.surface.ignoresSafeArea())
            #if os(iOS)
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
            #else
            .frame(minWidth: 760, idealWidth: 880, maxWidth: 1_200, minHeight: 500, idealHeight: 600, maxHeight: 900)
            #endif
            .interactiveDismissDisabled(busy)
    }
}

private struct ImageCropSheetHaptics: ViewModifier {
    let snaps: Int
    let made: Int
    let failed: Int

    func body(content: Content) -> some View {
        content
            .haptic(.selection, rising: snaps)
            .haptic(.success, rising: made)
            .haptic(.error, rising: failed)
    }
}

// MARK: - the editor's entry points

extension ImageCropSheet {
    /// From the editor: a picture of the bin or the add sheet (`save a copy` and `crop and place`: the crop goes over the video
    /// at the playhead on the lowest free layer), or an image overlay (`replacing`: one `crop` button, the crop takes the
    /// overlay's picture with the same place, width, time and layer). `saved` runs after a copy was made (the library
    /// refreshes so the bin lists it); `placed` after the crop went on the video.
    static func editor(
        session: EditSession, source: EditSource, replacing overlayID: String? = nil, saved: @escaping @MainActor () -> Void = {},
        placed: @escaping @MainActor () -> Void = {}, close: @escaping () -> Void
    ) -> ImageCropSheet {
        let load: @MainActor () async throws -> CGImage = { try await session.picture(for: source) }
        let serverCan: @MainActor (Bool) -> Bool = { session.canServerCrop(source, cutout: $0) }
        if let overlayID {
            let replace = ImageCropAction(title: Copy.Editor.pictureCrop, symbol: Symbol.Editor.imageCrop) { spec, picture in
                try await session.makeImageCrop(of: source, picture: picture, spec: spec, place: false, replacing: overlayID)
                saved()
                placed()
            }
            return ImageCropSheet(
                name: source.shortName, load: load, serverCan: serverCan, note: Copy.Editor.cropReplaceNote, primary: replace,
                secondary: nil, close: close)
        }
        let place = ImageCropAction(title: Copy.Editor.cropAndPlace, symbol: Symbol.Editor.cropPlace) { spec, picture in
            try await session.makeImageCrop(of: source, picture: picture, spec: spec, place: true)
            saved()
            placed()
        }
        let copy = ImageCropAction(title: Copy.Editor.cropSaveCopy, symbol: Symbol.Editor.cropSaveCopy) { spec, picture in
            try await session.makeImageCrop(of: source, picture: picture, spec: spec, place: false)
            saved()
        }
        return ImageCropSheet(
            name: source.shortName, load: load, serverCan: serverCan, primary: place, secondary: copy, close: close)
    }
}

/// Presents the crop sheet for the editor picture `source` names (the bin, the add sheet, an overlay's sheet or inspector).
struct EditorImageCropPresenter: ViewModifier {
    let session: EditSession
    @Binding var source: EditSource?
    /// The overlay whose picture the crop takes; nil offers `save a copy` and `crop and place`.
    var replacing: String?
    var saved: @MainActor () -> Void = {}
    var placed: @MainActor () -> Void = {}

    func body(content: Content) -> some View {
        content.sheet(item: $source) { picture in
            ImageCropSheet.editor(session: session, source: picture, replacing: replacing, saved: saved, placed: placed) {
                source = nil
            }
        }
    }
}
