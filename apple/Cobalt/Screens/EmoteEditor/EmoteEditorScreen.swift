import CobaltKit
import SwiftUI

// THE EMOTE EDITOR (APP-API-CONTRACT 71, apple/CONTRACT.md "emote editor"; mockup scenes "emote …" of the Duo redesign).
//
//     EmoteEditorScreen(model:, target:, close:)
//
// One editor for a picture, a webp, a gif or a video of the library. Duo first: from `EmoteEditorScreen.splitWidth` (700 pt) of its own
// width it is two panes with the seam between (the result, its compare line, its 1x/2x/4x sizes and two chat lines on one;
// the tabs, their controls, the live ticks and the actions on the other); narrower, the preview stays on top and the tab bar
// with one tab's controls sits under it. The preview moves on the device at once (crop box, squash as a scale); every settled
// change calls `make` with `replace` and the seam glows while it runs. Actions: upload to 7tv (the draft goes as it is, 57.9),
// save to library, share the file. The made file is a draft on the server for 24 hours; closing the editor deletes it.

/// What the editor opens on: the library file as an `EmoteSource`, and the rendition that downloads or finds its bytes.
struct EmoteEditorTarget: Identifiable {
    let id = UUID()
    let source: EmoteSource
    let rendition: Rendition

    /// A target made of parts (previews).
    init(source: EmoteSource, rendition: Rendition) {
        self.source = source
        self.rendition = rendition
    }

    /// A library file with no rendition of its own (the 7tv upload page): one that downloads `file` when it is not here.
    init(file: LibraryFile, title: String?) {
        source = EmoteSource(file: file, title: title)
        rendition = Rendition(id: "f:\(file.id)", kind: .item(index: 0, type: .photo), file: file, createdAt: file.createdAt)
    }

    /// A rendition of a post (its page, its menu), when its file is one an emote can be made from.
    init?(rendition: Rendition, title: String?) {
        guard let file = rendition.file else { return nil }
        let source = EmoteSource(file: file, title: title)
        guard source.isSupported else { return nil }
        self.source = source
        self.rendition = rendition
    }
}

struct EmoteEditorScreen: View {
    /// The editor's own width (pt) from which it is two panes.
    static let splitWidth: CGFloat = 700

    let model: AppModel
    let target: EmoteEditorTarget
    let close: () -> Void
    /// A source picture that is already open (previews); the real one is read from the library file.
    var loader: EmoteSourceLoader?

    @State private var editor: EmoteEditorModel?

    init(
        model: AppModel, target: EmoteEditorTarget, loader: EmoteSourceLoader? = nil, initialTab: EmoteEditorModel.Tab? = nil,
        close: @escaping () -> Void
    ) {
        self.model = model
        self.target = target
        self.loader = loader
        self.close = close
        let made = model.emoteEditor(for: target.source)
        if let initialTab { made?.tab = initialTab }
        _editor = State(initialValue: made)
    }

    var body: some View {
        Group {
            if let editor {
                EmoteEditorContent(model: model, editor: editor, target: target, loader: loader, close: close)
            } else {
                VStack(spacing: 12) {
                    Text(Copy.EmoteEditor.unavailable).font(CobaltType.body).foregroundStyle(CobaltColor.caption)
                    Button(Copy.EmoteEditor.close, action: close).buttonStyle(.cobaltSecondary(fullWidth: false))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(CobaltColor.bg.ignoresSafeArea())
        #if os(macOS)
        .frame(minWidth: 820, idealWidth: 1_040, maxWidth: 1_400, minHeight: 560, idealHeight: 700, maxHeight: 1_000)
        #endif
    }
}

// MARK: - the content

private struct EmoteEditorContent: View {
    let model: AppModel
    let editor: EmoteEditorModel
    let target: EmoteEditorTarget
    let close: () -> Void

    @State private var loader: EmoteSourceLoader
    @State private var playback = EmotePlayback()
    @State private var crop: ImageCropModel?
    @State private var upload: SevenTvUploadModel?
    @State private var saving = false
    @State private var actionError: String?
    @Environment(\.shell) private var shell

    init(model: AppModel, editor: EmoteEditorModel, target: EmoteEditorTarget, loader: EmoteSourceLoader?, close: @escaping () -> Void) {
        self.model = model
        self.editor = editor
        self.target = target
        self.close = close
        _loader = State(initialValue: loader ?? EmoteSourceLoader())
    }

    private var face: EmoteFaceSource { EmoteFaceSource(editor: editor, loader: loader, playback: playback) }

    var body: some View {
        GeometryReader { geo in
            Group {
                if geo.size.width >= EmoteEditorScreen.splitWidth { spread } else { stacked }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .modifier(EmoteEditorLifecycle(
            model: model, editor: editor, target: target, loader: loader, playback: playback, crop: $crop))
        .modifier(EmoteEditorHaptics(landed: editor.landed, failed: editor.failed))
        .sheet(item: $upload) { SevenTvUploadSheet(upload: $0) }
    }

    // MARK: layouts

    /// From 700 pt: the result on one side, the tabs on the other, the seam between.
    private var spread: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                header
                EmoteEditorStage(editor: editor, loader: loader, playback: playback, crop: crop)
                    .frame(minHeight: 240)
                Text(Copy.EmoteEditor.compareHint).font(CobaltType.captionSmall).foregroundStyle(CobaltColor.caption)
                EmoteSizes(face: face)
                EmoteChatLine(face: face, light: false)
                EmoteChatLine(face: face, light: true)
                EmoteMeter(editor: editor)
            }
            .padding(16)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            EmoteSeam(active: editor.remaking)
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    EmoteTabBar(editor: editor)
                    EmoteTabControls(editor: editor, crop: crop, loader: loader)
                    notes
                    EmoteChecks(editor: editor)
                    actions
                }
                .padding(16)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// Under 700 pt: the preview on top, one tab's controls under it (the "closed" scene).
    private var stacked: some View {
        VStack(spacing: 10) {
            header
            EmoteEditorStage(editor: editor, loader: loader, playback: playback, crop: crop)
                .frame(minHeight: 200)
            HStack(alignment: .bottom) {
                EmoteSizes(face: face, scales: [1, 2])
                Text(editor.draft.map { EmoteEditorModel.megabytes($0.bytes) } ?? "")
                    .font(CobaltType.captionSmall.monospacedDigit())
                    .foregroundStyle(CobaltColor.caption)
            }
            EmoteTabBar(editor: editor)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    EmoteTabControls(editor: editor, crop: crop, loader: loader)
                    notes
                    EmoteChecks(editor: editor)
                }
            }
            .frame(minHeight: 110, maxHeight: 280)
            actions
        }
        .padding(.horizontal, Metrics.gutter)
        .padding(.vertical, 8)
    }

    // MARK: pieces

    private var header: some View {
        HStack(spacing: 10) {
            CloseButton(cancels: true, action: close)
            VStack(alignment: .leading, spacing: 1) {
                Text(Copy.EmoteEditor.title).font(CobaltType.sheetTitle).foregroundStyle(CobaltColor.text)
                if !target.source.title.isEmpty {
                    Text(target.source.title)
                        .font(CobaltType.captionSmall)
                        .foregroundStyle(CobaltColor.caption)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer(minLength: 6)
            Button { editor.undo() } label: { Label(Copy.EmoteEditor.undo, systemImage: Symbol.EmoteEditor.undo) }
                .buttonStyle(.cobaltIcon(.small))
                .disabled(!editor.canUndo)
            Button { editor.redo() } label: { Label(Copy.EmoteEditor.redo, systemImage: Symbol.EmoteEditor.redo) }
                .buttonStyle(.cobaltIcon(.small))
                .disabled(!editor.canRedo)
        }
    }

    @ViewBuilder
    private var notes: some View {
        if let blocker = editor.blocker {
            EmoteNote(text: blocker == .shape ? Copy.EmoteEditor.shapeBlocked : Copy.EmoteEditor.momentBlocked, tint: CobaltColor.errorText)
        } else if let error = editor.error {
            EmoteNote(text: Copy.EmoteEditor.message(for: error), tint: CobaltColor.errorText)
        }
        if let actionError {
            EmoteNote(text: actionError, tint: CobaltColor.errorText)
        }
    }

    private var canUpload: Bool { editor.canUseDraft && model.sevenTv.canUpload }

    private var actions: some View {
        VStack(spacing: 8) {
            if !model.sevenTv.canUpload {
                EmoteNote(text: Copy.EmoteEditor.uploadNeedsLink, tint: CobaltColor.caption)
            }
            Button(Copy.EmoteEditor.upload, systemImage: Symbol.EmoteEditor.upload, action: startUpload)
                .buttonStyle(.cobaltPrimary())
                .disabled(!canUpload)
            HStack(spacing: 8) {
                Button(saving ? Copy.EmoteEditor.saving : Copy.EmoteEditor.saveToLibrary, systemImage: Symbol.EmoteEditor.library, action: save)
                    .buttonStyle(.cobaltSecondary())
                    .disabled(!editor.canUseDraft || saving)
                if let url = editor.shareURL, editor.canUseDraft {
                    ShareLink(item: url) { Label(Copy.EmoteEditor.share, systemImage: Symbol.EmoteEditor.share) }
                        .buttonStyle(.cobaltIcon())
                }
            }
        }
    }

    // MARK: doing

    private func startUpload() {
        guard let draft = editor.draft, editor.canUseDraft else { return }
        actionError = nil
        upload = model.sevenTv.uploader(draft: draft, source: target.source)
    }

    private func save() {
        saving = true
        actionError = nil
        Task {
            do {
                try await editor.saveToLibrary()
                shell.showStatus(Copy.EmoteEditor.saved)
                await model.library.refresh()
            } catch {
                actionError = Copy.EmoteEditor.message(for: SevenTvError.from(error))
            }
            saving = false
        }
    }
}

private struct EmoteNote: View {
    let text: String
    let tint: Color

    var body: some View {
        Text(text).font(CobaltType.caption).foregroundStyle(tint).fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - lifecycle

/// Starts the first draft and the source picture, keeps the crop box and the editor's crop in step, plays each new draft, and
/// cleans up when the editor goes.
private struct EmoteEditorLifecycle: ViewModifier {
    let model: AppModel
    let editor: EmoteEditorModel
    let target: EmoteEditorTarget
    let loader: EmoteSourceLoader
    let playback: EmotePlayback
    @Binding var crop: ImageCropModel?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .task { await start() }
            .task { if model.sevenTv.state == .idle { await model.sevenTv.load() } }
            .onChange(of: loader.state) { _, state in if state == .ready { makeCropModel() } }
            .onChange(of: crop?.rect) { _, _ in if let crop { editor.setCrop(crop.shownBox) } }
            .onChange(of: editor.settings.crop) { _, new in follow(new) }
            .onChange(of: editor.draftRevision) { _, revision in play(revision) }
            .onDisappear {
                editor.close()
                loader.discard()
                playback.stop()
            }
    }

    private func start() async {
        editor.start()
        await loader.load(model: model, rendition: target.rendition, source: target.source, at: editor.settings.start)
        if let size = loader.pixels {
            editor.useSourceSize(width: Int(size.width), height: Int(size.height), duration: loader.duration)
        }
        if crop == nil, loader.state == .ready { makeCropModel() }
    }

    private func makeCropModel() {
        guard crop == nil, let size = loader.pixels else { return }
        let made = ImageCropModel(source: size)
        if let box = editor.settings.crop { made.begin(ImageCropStart(aspect: .free, box: box)) }
        crop = made
    }

    /// Undo and redo change the crop under the box: the box follows (a drag already agrees, so it is left alone).
    private func follow(_ box: ImageCropRect?) {
        guard let crop else { return }
        let want = box ?? .whole
        let have = crop.shownBox
        let same = abs(want.x - have.x) < 1e-4 && abs(want.y - have.y) < 1e-4 && abs(want.w - have.w) < 1e-4 && abs(want.h - have.h) < 1e-4
        if !same { crop.begin(ImageCropStart(aspect: crop.aspect, box: want)) }
    }

    private func play(_ revision: Int) {
        guard let data = editor.draftData else { return }
        playback.play(
            data: data, animated: editor.draft?.isAnimated ?? false, revision: revision, reduceMotion: reduceMotion)
    }
}

private struct EmoteEditorHaptics: ViewModifier {
    let landed: Int
    let failed: Int

    func body(content: Content) -> some View {
        content
            .haptic(.selection, rising: landed)
            .haptic(.error, rising: failed)
    }
}
