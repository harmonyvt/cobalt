import CobaltKit
import SwiftUI

// THE REPOST FRAME SHEET (lane A7 · TOOLS, apple/CONTRACT-GALLERY.md 1.24)
//
//     RepostSheet(model: AppModel, item: MediaItem, start: Rendition?, initial: FrameSpec? = nil, done: (String?) -> Void)
//
// Opened by the detail's `more › repost frame…`. Pick `9:16`, `1:1` or `4:5`, and how the photo meets the frame: `blurred bars`
// (the whole photo on a blurred copy of itself, the default) or `cut to fit` (from the middle). The sheet shows the frame it
// will make for the photo you are on (step through the others with the arrows); `save this one` puts it in Photos (on the Mac:
// a file you choose), `all 10` puts every photo's frame there (a folder on the Mac), `share` opens the share sheet with it.
// The frames are made on this device when you ask: nothing is uploaded, no tab is made, the media is unchanged. A video or gif
// in the post is skipped and counted. `keep in cobalt` makes the frame into a crop of that photo (a tab), the same call as
// `crop`.

struct RepostSheet: View {
    @MainActor @Observable
    final class Draft {
        enum Phase: Equatable {
            case idle
            case working(String)
            case done(String)
            case failed(String)
        }

        var aspect: FrameSpec.Aspect
        var fill: FrameSpec.Fill
        var index: Int
        var phase: Phase = .idle

        init(spec: FrameSpec?, index: Int) {
            let spec = spec ?? FrameSpec(aspect: .story, fill: .blur)
            // a repost frame has no free shape: an unknown one starts as 9:16
            aspect = FrameSpec.Aspect.repost.contains(spec.aspect) ? spec.aspect : .story
            fill = spec.effectiveFill
            self.index = index
        }

        var spec: FrameSpec { FrameSpec(aspect: aspect, fill: fill) }
        var isWorking: Bool { if case .working = phase { return true } else { return false } }
    }

    let model: AppModel
    let item: MediaItem
    var done: (String?) -> Void = { _ in }

    private let photos: [Rendition]
    private let skipped: Int
    @State private var draft: Draft
    @State private var current: ToolPhoto?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.hapticsEnabled) private var haptics
    @Environment(\.dynamicTypeSize) private var typeSize

    init(model: AppModel, item: MediaItem, start: Rendition?, initial: FrameSpec? = nil, done: @escaping (String?) -> Void = { _ in }) {
        self.model = model
        self.item = item
        self.done = done
        let photos = ToolPhotos.photos(of: item)
        self.photos = photos
        self.skipped = ToolPhotos.skipped(in: item)
        let index = start.flatMap { s in photos.firstIndex { $0.id == s.id } } ?? 0
        _draft = State(initialValue: Draft(spec: initial, index: index))
    }

    private var shown: Rendition? { photos.indices.contains(draft.index) ? photos[draft.index] : nil }

    /// The place the photo has in the post (`photo 3 of 10`), or its place among the photos of a single one.
    private var place: String {
        guard let shown else { return "" }
        let n = max(photos.count, item.galleryTotal)
        return ToolsCopy.photoOf((shown.itemIndex ?? 0) + 1, n)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            stage
            controls
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
        .task(id: shown?.id) { await open() }
        .interactiveDismissDisabled(draft.isWorking)
        #if DEBUG
        .task { await ToolsDebug.apply(to: draft, save: { saveOne() }) }
        #endif
    }

    private func open() async {
        guard let shown else { return }
        let photo = ToolPhoto(shown)
        current = photo
        await photo.load(model: model)
    }

    // MARK: header

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(ToolsCopy.repostTitle).font(CobaltType.sheetTitle)
                Text(ToolsCopy.repostNote)
                    .font(CobaltType.captionSmall)
                    .foregroundStyle(CobaltColor.caption)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            CloseButton(cancels: true) { dismiss() }
                .disabled(draft.isWorking)
        }
    }

    // MARK: the frame

    private var stage: some View {
        VStack(spacing: 8) {
            ZStack {
                if let current, let image = current.image {
                    FramePreview(image: image, aspect: draft.aspect, fill: draft.fill)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .transition(.opacity)
                } else if current?.state == .failed {
                    VStack(spacing: 8) {
                        Image(systemName: Symbol.Gallery.missing).font(.system(size: 24)).foregroundStyle(CobaltColor.errorText)
                        Text(ToolsCopy.cantOpen)
                            .font(CobaltType.caption)
                            .foregroundStyle(CobaltColor.errorText)
                            .multilineTextAlignment(.center)
                    }
                } else {
                    ProgressView().controlSize(.large)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 220, maxHeight: .infinity)
            .animation(reduceMotion ? nil : Motion.rows, value: draft.aspect)
            .animation(reduceMotion ? nil : Motion.rows, value: draft.fill)
            pager
        }
    }

    /// `‹  photo 3 of 10  ›` when there is more than one photo.
    @ViewBuilder
    private var pager: some View {
        HStack(spacing: 12) {
            if photos.count > 1 {
                Button { step(-1) } label: { Image(systemName: "chevron.left") }
                    .buttonStyle(.cobaltSecondary(fullWidth: false, compact: true))
                    .disabled(draft.index == 0 || draft.isWorking)
                    .accessibilityLabel(ToolsCopy.previous)
            }
            Text(place)
                .font(CobaltType.captionSmall)
                .foregroundStyle(CobaltColor.caption)
                .monospacedDigit()
                .frame(maxWidth: .infinity)
            if photos.count > 1 {
                Button { step(1) } label: { Image(systemName: "chevron.right") }
                    .buttonStyle(.cobaltSecondary(fullWidth: false, compact: true))
                    .disabled(draft.index >= photos.count - 1 || draft.isWorking)
                    .accessibilityLabel(ToolsCopy.next)
            }
        }
    }

    private func step(_ delta: Int) {
        let to = draft.index + delta
        guard photos.indices.contains(to) else { return }
        draft.phase = .idle
        draft.index = to
    }

    // MARK: the choices and the buttons

    private var controls: some View {
        VStack(alignment: .leading, spacing: 10) {
            shapes.disabled(draft.isWorking)
            fills.disabled(draft.isWorking)
            HStack(alignment: .firstTextBaseline) {
                Text(ToolsCopy.readoutTitle).font(CobaltType.captionSmall).foregroundStyle(CobaltColor.caption)
                Spacer(minLength: 8)
                if let current, current.state == .ready {
                    let size = FrameRenderer.outputSize(source: current.pixels, spec: draft.spec)
                    Text(ToolsCopy.readout(size))
                        .font(Font.cobalt(14, .medium, relativeTo: .callout).monospacedDigit())
                        .contentTransition(.numericText())
                        .accessibilityLabel(ToolsCopy.sizeA11y(size))
                }
            }
            .accessibilityElement(children: .combine)
            statusLine
            actions
            if skipped > 0 {
                Text(Copy.Gallery.videosSkippedFrames(skipped))
                    .font(CobaltType.badge)
                    .foregroundStyle(CobaltColor.caption)
            }
        }
        .haptic(.success, trigger: draft.phase, enabled: haptics) { if case .done = $0 { return true } else { return false } }
        .haptic(.error, trigger: draft.phase, enabled: haptics) { if case .failed = $0 { return true } else { return false } }
        .haptic(.selection, trigger: draft.aspect, enabled: haptics)
    }

    @ViewBuilder
    private var shapes: some View {
        let binding = Binding(get: { draft.aspect }, set: { new in withAnimation(reduceMotion ? nil : Motion.rows) { draft.aspect = new; draft.phase = .idle } })
        let picker = Picker(ToolsCopy.shape, selection: binding) {
            ForEach(FrameSpec.Aspect.repost, id: \.self) { Text($0.label).tag($0) }
        }
        if typeSize.isAccessibilitySize {
            picker.pickerStyle(.menu).labelsHidden().frame(maxWidth: .infinity, alignment: .leading)
        } else {
            picker.pickerStyle(.segmented).labelsHidden()
        }
    }

    @ViewBuilder
    private var fills: some View {
        let binding = Binding(get: { draft.fill }, set: { new in withAnimation(reduceMotion ? nil : Motion.rows) { draft.fill = new; draft.phase = .idle } })
        Picker(ToolsCopy.fill, selection: binding) {
            ForEach([FrameSpec.Fill.blur, .cut], id: \.self) {
                Text(ToolsCopy.fillShort($0)).tag($0).accessibilityLabel(ToolsCopy.fillLong($0))
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
    }

    @ViewBuilder
    private var statusLine: some View {
        switch draft.phase {
        case .idle:
            EmptyView()
        case .working(let words):
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(words).font(CobaltType.captionSmall).foregroundStyle(CobaltColor.caption).monospacedDigit()
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.updatesFrequently)
        case .done(let words):
            Label(words, systemImage: Symbol.checkmark)
                .font(CobaltType.captionSmall)
                .foregroundStyle(CobaltColor.text)
                .accessibilityAddTraits(.updatesFrequently)
        case .failed(let words):
            Text(words)
                .font(CobaltType.captionSmall)
                .foregroundStyle(CobaltColor.errorText)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.updatesFrequently)
        }
    }

    private var actions: some View {
        let busy = draft.isWorking || shown == nil || current?.state != .ready
        return VStack(spacing: 8) {
            Button(Copy.Gallery.saveThisOne, systemImage: GalleryActions.saveSymbol) { saveOne() }
                .buttonStyle(.cobaltPrimary())
                .keyboardShortcut(.defaultAction)
                .disabled(busy)
            ButtonRow {
                if photos.count > 1 {
                    Button(Copy.Gallery.saveAllFrames(photos.count), systemImage: Symbol.Gallery.saveToPhotos) { saveAll() }
                        .buttonStyle(.cobaltSecondary())
                        .disabled(busy)
                }
                if let shown {
                    ShareLink(
                        item: SharedFrame(model: model, rendition: shown, spec: draft.spec),
                        preview: SharePreview(AppModel.frameName(of: shown, spec: draft.spec))
                    ) {
                        Label(Copy.Media.share, systemImage: Symbol.Media.share)
                    }
                    .buttonStyle(.cobaltSecondary())
                    .disabled(busy)
                }
                if let shown, model.canStoreCrop(of: shown) {
                    Button(Copy.Gallery.keepInCobalt, systemImage: Symbol.Gallery.crop) { keep(shown) }
                        .buttonStyle(.cobaltSecondary())
                        .disabled(busy)
                }
            }
        }
    }

    // MARK: making

    /// `save this one`: this photo's frame to Photos; on the Mac to a file the owner names.
    private func saveOne() {
        guard let shown, !draft.isWorking else { return }
        let spec = draft.spec
        draft.phase = .working(ToolsCopy.making)
        Task {
            do {
                #if os(macOS)
                let made = try await model.repostFrames([shown], spec: spec, to: .files)
                defer { ToolsExport.discard(made.files) }
                guard let file = made.files.first, try ToolsExport.save(file) else { draft.phase = .idle; return }
                draft.phase = .done(ToolsCopy.saved(1, skipped: 0))
                #else
                _ = try await model.repostFrames([shown], spec: spec, to: .photos)
                draft.phase = .done(ToolsCopy.saved(1, skipped: 0))
                #endif
            } catch {
                draft.phase = .failed(DetailController.words(error))
            }
        }
    }

    /// `all 10`: every photo's frame to Photos in one go; on the Mac to a folder the owner picks.
    private func saveAll() {
        guard !draft.isWorking else { return }
        let spec = draft.spec
        let all = photos
        #if os(macOS)
        guard let folder = ToolsExport.chooseFolder() else { return }
        let target = RepostTarget.folder(folder)
        #else
        let target = RepostTarget.photos
        #endif
        draft.phase = .working(ToolsCopy.makingN(0, of: all.count))
        Task {
            do {
                var made = 0
                // one photo at a time so the line can say how far it is; each frame is sent as soon as it is drawn
                for photo in all {
                    draft.phase = .working(ToolsCopy.makingN(made + 1, of: all.count))
                    _ = try await model.repostFrames([photo], spec: spec, to: target)
                    made += 1
                }
                draft.phase = .done(ToolsCopy.saved(made, skipped: skipped))
            } catch {
                draft.phase = .failed(DetailController.words(error))
            }
        }
    }

    /// `keep in cobalt`: this frame as a crop of the photo (a tab), the same call as `crop`.
    private func keep(_ photo: Rendition) {
        guard !draft.isWorking else { return }
        let spec = draft.spec
        draft.phase = .working(Copy.Gallery.saveCrop)
        Task {
            do {
                try await model.saveCrop(of: photo, in: item, spec: spec)
                done(nil)
                dismiss()
            } catch {
                draft.phase = .failed(Copy.Gallery.cropFailed)
            }
        }
    }
}
