import CobaltKit
import SwiftUI

// THE ENTRY (lane A2 · COMBINE, apple/CONTRACT-GALLERY.md 1.15 and 5; boards `Gallery-Combine` and `Gallery-Image`)
//
//     CombineSheet(model: AppModel, media: MediaItem, output: CombineOutput = .slideshowWebp)
//     CombineSheet(model: AppModel, pipeline: Pipeline, output: CombineOutput = .slideshowWebp)
//
//     enum CombineOutput { case slideshowWebp, slideshowMp4, galleryImage }
//
// Present either as the content of a `.sheet`; the sheet picks its own detents (iPhone: large) and has its own close
// button, so the presenter adds nothing. The first form is for a media that is in the library or on this device (the
// detail's `more › make from this post…`, the library, the empty state of a missing tab): its items come from the media's
// `items` renditions and the make goes through `AppModel.make(_:from:)`. The second is for the gallery on the focus while
// it saves (the paste hero's `make from it` row: `slideshow webp` / `slideshow mp4` / `gallery image` pass the matching
// `output`): its items follow `pipeline.galleryItems`, a make chosen before the save ends waits for it (R7) through
// `Pipeline.make(_:)`, and the sheet says `after the save · 6 of 10`. `output` is the segment that opens selected.
//
// The sheet never owns a make: it is a job of the queue (focused, in the server's line), so closing the sheet at any
// moment never stops it; opening it again while one runs shows that make's progress.

/// The combine sheet: make a slideshow webp, a slideshow mp4 or a borderless gallery image from a gallery's items.
struct CombineSheet: View {
    @State private var combine: CombineModel
    @Environment(\.dismiss) private var dismiss
    #if DEBUG
    private var configure: (@MainActor (CombineModel) -> Void)?
    #endif

    init(model: AppModel, media: MediaItem, output: CombineOutput = .slideshowWebp) {
        _combine = State(initialValue: CombineModel(app: model, source: .media(media), output: output))
    }

    init(model: AppModel, pipeline: Pipeline, output: CombineOutput = .slideshowWebp) {
        _combine = State(initialValue: CombineModel(app: model, source: .run(pipeline), output: output))
    }

    #if DEBUG
    /// The preview scene's: the same sheet, with the model set up (a launch argument's state) before it shows.
    init(model: AppModel, media: MediaItem, output: CombineOutput, configure: @escaping @MainActor (CombineModel) -> Void) {
        self.init(model: model, media: media, output: output)
        self.configure = configure
    }

    init(model: AppModel, pipeline: Pipeline, output: CombineOutput, configure: @escaping @MainActor (CombineModel) -> Void) {
        self.init(model: model, pipeline: pipeline, output: output)
        self.configure = configure
    }
    #endif

    #if os(macOS)
    /// 740 pt; `-combineTall 1` (debug) lets the sheet grow to show everything at once for evidence.
    private static var idealHeight: CGFloat {
        #if DEBUG
        if UserDefaults.standard.bool(forKey: "combineTall") { return 1280 }
        #endif
        return 740
    }
    private static var maxHeight: CGFloat {
        #if DEBUG
        if UserDefaults.standard.bool(forKey: "combineTall") { return 1300 }
        #endif
        return 900
    }
    #endif

    var body: some View {
        let phase = combine.phase
        VStack(alignment: .leading, spacing: 12) {
            header
            outputs(editing: phase.isEdit)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if phase.isEdit { editor } else { CombineProgress(combine: combine, phase: phase) }
                }
                .padding(.horizontal, 1)
                .padding(.bottom, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollBounceBehavior(.basedOnSize)
            #if DEBUG
            .defaultScrollAnchor(UserDefaults.standard.bool(forKey: "combineScrollEnd") ? .bottom : .top)
            #endif
            if phase.isEdit { footer }
        }
        .padding(.horizontal, 20)
        .padding(.top, Platform.isMac ? 20 : 24)
        .padding(.bottom, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .motion(Motion.card, value: phase.isEdit)
        #if DEBUG
        .task { CombineSnapshot.say("sheet appeared"); configure?(combine) }
        #endif
        #if os(iOS)
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        #else
        .frame(minWidth: 480, idealWidth: 540, maxWidth: 680, minHeight: 600, idealHeight: Self.idealHeight, maxHeight: Self.maxHeight)
        #endif
    }

    // MARK: header and the three outputs

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(Copy.Combine.title).font(CobaltType.sheetTitle)
                Text("\(combine.title) · \(combine.countText)")
                    .font(CobaltType.captionSmall)
                    .foregroundStyle(CobaltColor.caption)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 0)
            CloseButton(cancels: true) { dismiss() }
        }
    }

    private func outputs(editing: Bool) -> some View {
        Picker(Copy.Combine.outputsA11y, selection: Binding(get: { combine.output }, set: { combine.output = $0 })) {
            ForEach(CombineOutput.allCases) { output in
                Text(output.label).tag(output)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        #if os(iOS)
        .controlSize(.large)
        #endif
        .disabled(!editing)
        .accessibilityLabel(Copy.Combine.outputsA11y)
    }

    // MARK: editing

    private var editor: some View {
        VStack(alignment: .leading, spacing: 14) {
            CombineStrip(combine: combine)
            if combine.output.isSlideshow {
                CombineSlideshowPane(combine: combine)
            } else {
                CombineImagePane(combine: combine)
            }
        }
    }

    /// The numbers, the reason a cap refuses (with its ways out), the replace note, and the one button.
    private var footer: some View {
        let gate = combine.gate
        return VStack(alignment: .leading, spacing: 6) {
            Divider()
            Text(combine.summary)
                .font(CobaltType.captionSmall)
                .monospacedDigit()
                .foregroundStyle(CobaltColor.caption)
                .accessibilityAddTraits(.updatesFrequently)
            if let reason = gate.reason, combine.output.isSlideshow {
                Text(reason)
                    .font(CobaltType.captionSmall)
                    .foregroundStyle(CobaltColor.errorText)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.updatesFrequently)
            }
            if !gate.ways.isEmpty {
                ButtonRow {
                    ForEach(gate.ways) { way in
                        Button(way.label) { combine.take(way) }
                            .buttonStyle(.cobaltSecondary(compact: true))
                    }
                }
            }
            if let note = combine.replacesNote, gate.allowed {
                Text(note)
                    .font(CobaltType.captionSmall)
                    .foregroundStyle(CobaltColor.caption)
            }
            Button(combine.output.makeLabel) { combine.make() }
                .buttonStyle(.cobaltPrimary())
                .disabled(!combine.canMake)
        }
    }
}
