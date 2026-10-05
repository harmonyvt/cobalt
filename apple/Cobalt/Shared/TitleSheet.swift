import CobaltKit
import SwiftUI

// Naming an upload (CONTRACT-LIBRARY2 decision 3). The upload starts the instant a file is picked; this is the
// small sheet that rises over the save tab while it runs (`name it`), and the one inline row the share
// sheet's progress card gains for a file. Neither ever blocks the run: `done` and `skip` only decide what the
// pipeline is told (`Pipeline.setTitle`), an unchanged default is the same as skip, and the run goes on
// whatever the sheet does.
//
// Compiled into the share extension too: nothing here may name an app-only type (`AppModel`, `shell`...).
// The app presents `TitleSheet` from `AppShell`; `ShareRootView` draws `TitleRow`.

/// One file intake that wants a title: the default the field starts with (the file's name without its media
/// extension; for a Photos pick that is `from photos · 4 oct`). A new request is a new sheet.
struct TitleRequest: Identifiable, Equatable {
    let id = UUID()
    let defaultTitle: String
}

enum TitleText {
    /// At most `MediaTitle.maxLength` Unicode code points, cut on a `Character` boundary (never inside a
    /// grapheme), without trimming: the field is still being typed in.
    static func capped(_ text: String, limit: Int = MediaTitle.maxLength) -> String {
        guard text.unicodeScalars.count > limit else { return text }
        var out = ""
        var count = 0
        for character in text {
            let n = character.unicodeScalars.count
            if count + n > limit { break }
            out.append(character)
            count += n
        }
        return out
    }

    /// What to tell the pipeline for what was typed: the cleaned text, or nil (the default) when the field is
    /// empty or still says what it started with.
    static func custom(_ draft: String, default fallback: String) -> String? {
        guard let typed = MediaTitle.clean(draft) else { return nil }
        return typed == MediaTitle.clean(fallback) ? nil : typed
    }

    /// The line under the field: the run's own words (`uploading your file · 1.2 of 18.2 MB`, then `reading the
    /// video`), or why it stopped while the title is kept. Empty once there is nothing left to say.
    static func liveLine(story: ProgressStory?, failed: Bool) -> String {
        if failed { return Copy.Media.titleKept }
        guard let story else { return "" }
        if case .text(let detail)? = story.detail { return "\(story.headline) · \(detail)" }
        return story.headline
    }

    static func showsCount(_ text: String) -> Bool { text.unicodeScalars.count >= 60 }
}

// MARK: - the field

/// One line of text, filled with the default and selected the first time it takes focus (typing replaces it),
/// capped at 80 code points, with a clear button. Return runs `onSubmit`; losing focus runs `onEnd`.
struct TitleField: View {
    @Binding var text: String
    /// The sheet takes focus (and the keyboard) as it rises; the share row waits for a tap.
    var autofocus = false
    var onSubmit: () -> Void = {}
    var onEnd: () -> Void = {}

    @State private var selection: TextSelection?
    @State private var selectedOnce = false
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 6) {
            TextField(Copy.Library2.titleField, text: $text, selection: $selection)
                .focused($focused)
                .submitLabel(.done)
                .onSubmit(onSubmit)
                .font(CobaltType.body)
                .foregroundStyle(CobaltColor.text)
                .accessibilityLabel(Copy.Library2.titleField)
            if !text.isEmpty {
                Button {
                    text = ""
                    focused = true
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 17))
                        .foregroundStyle(CobaltColor.caption)
                        .frame(width: Metrics.hit, height: Metrics.hit)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Copy.Media.clearTitle)
            }
        }
        .padding(.leading, 12)
        .padding(.trailing, text.isEmpty ? 12 : 0)
        .frame(minHeight: Metrics.hit)
        .background(CobaltColor.elevated, in: RoundedRectangle(cornerRadius: Metrics.radius, style: .continuous))
        .onChange(of: text) { _, now in
            let cut = TitleText.capped(now)
            if cut != now { text = cut }
        }
        .onChange(of: focused) { _, now in
            if now {
                selectAllOnce()
            } else {
                onEnd()
            }
        }
        .task {
            guard autofocus else { return }
            // after the sheet's rise has settled: focus asked for sooner is dropped
            try? await Task.sleep(for: .milliseconds(500))
            focused = true
        }
    }

    /// The whole default is selected the first time the field is entered; later taps place the cursor.
    private func selectAllOnce() {
        guard !selectedOnce, !text.isEmpty else { return }
        selectedOnce = true
        Task { @MainActor in
            // the field has to be first responder before it takes a selection
            try? await Task.sleep(for: .milliseconds(60))
            selection = TextSelection(range: text.startIndex..<text.endIndex)
        }
    }
}

// MARK: - the sheet (the app)

/// `name it`: the heading, the field with the default selected, the upload's own progress line, `skip` and
/// `done`. iPhone and iPad: a short sheet with the keyboard up and the card behind it still alive; Mac: the same
/// view, 420 pt wide. Return is done, swipe down (or escape) is skip. If the run is reset behind it, it closes.
struct TitleSheet: View {
    let pipeline: Pipeline
    let defaultTitle: String
    /// Closes the sheet (the shell clears its request).
    let dismiss: () -> Void

    @State private var draft: String
    @Environment(\.dynamicTypeSize) private var typeSize

    init(pipeline: Pipeline, defaultTitle: String, dismiss: @escaping () -> Void) {
        self.pipeline = pipeline
        self.defaultTitle = defaultTitle
        self.dismiss = dismiss
        _draft = State(initialValue: TitleText.capped(defaultTitle))
    }

    private var failed: Bool {
        if case .failed = pipeline.state { return true }
        return false
    }

    var body: some View {
        let line = TitleText.liveLine(story: pipeline.progressStory, failed: failed)
        VStack(alignment: .leading, spacing: 12) {
            Text(Copy.Library2.nameIt)
                .font(Font.cobalt(16, .semibold, relativeTo: .headline))
                .foregroundStyle(CobaltColor.text)
                .accessibilityAddTraits(.isHeader)
            TitleField(text: $draft, autofocus: true, onSubmit: done)
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(line)
                    .font(CobaltType.caption)
                    .foregroundStyle(failed ? CobaltColor.errorText : CobaltColor.caption)
                    .lineLimit(2)
                    .contentTransition(.numericText())
                    .accessibilityAddTraits(.updatesFrequently)
                Spacer(minLength: 0)
                if TitleText.showsCount(draft) {
                    Text(Copy.Library2.titleCount(draft.unicodeScalars.count))
                        .font(CobaltType.caption)
                        .foregroundStyle(CobaltColor.caption)
                        .monospacedDigit()
                }
            }
            .frame(minHeight: 16, alignment: .top)
            ProportionalPair {
                Button(Copy.Library2.skip) { dismiss() }
                    .buttonStyle(.cobaltSecondary())
                    .keyboardShortcut(.cancelAction)
                Button(Copy.Library2.done) { done() }
                    .buttonStyle(.cobaltPrimary())
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 20)
        .padding(.bottom, 12)
        #if os(macOS)
        .frame(width: 420)
        #else
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .presentationDetents(typeSize.isAccessibilitySize ? [.height(248), .large] : [.height(248)])
        .presentationBackgroundInteraction(.enabled)
        .presentationDragIndicator(.visible)
        #endif
        .onChange(of: pipeline.state == .idle) { _, idle in
            if idle { dismiss() }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Copy.Library2.nameIt)
    }

    /// An unchanged default (or an empty field) tells the pipeline nothing.
    private func done() {
        pipeline.setTitle(TitleText.custom(draft, default: defaultTitle))
        dismiss()
    }
}

/// Two children side by side, a third and two thirds of the width: `skip` stays small, `done` leads.
private struct ProportionalPair: Layout {
    var spacing: CGFloat = 8

    private func widths(_ total: CGFloat) -> (CGFloat, CGFloat) {
        let usable = max(0, total - spacing)
        let first = usable / 3
        return (first, usable - first)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard subviews.count == 2 else { return .zero }
        let total = proposal.width ?? 320
        let (a, b) = widths(total)
        let height = max(
            subviews[0].sizeThatFits(ProposedViewSize(width: a, height: nil)).height,
            subviews[1].sizeThatFits(ProposedViewSize(width: b, height: nil)).height)
        return CGSize(width: total, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard subviews.count == 2 else { return }
        let (a, b) = widths(bounds.width)
        subviews[0].place(at: bounds.origin, anchor: .topLeading, proposal: ProposedViewSize(width: a, height: bounds.height))
        subviews[1].place(
            at: CGPoint(x: bounds.minX + a + spacing, y: bounds.minY), anchor: .topLeading,
            proposal: ProposedViewSize(width: b, height: bounds.height))
    }
}

// MARK: - the inline row (the share sheet)

/// The share sheet's one inline row for a file: `title`, prefilled, selected on the first tap, `done` on the
/// keyboard. No nested sheet in an extension. What is typed reaches the pipeline on return, when the field
/// loses focus, shortly after typing stops, and when the row goes away; the sheet that owns the draft also
/// sends it (`TitleText.custom`) before it closes, hands off or continues in the background, so leaving
/// straight after typing never loses it.
struct TitleRow: View {
    let pipeline: Pipeline
    let defaultTitle: String
    @Binding var draft: String

    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            TitleField(text: $draft, onSubmit: commit, onEnd: commit)
            if TitleText.showsCount(draft) {
                Text(Copy.Library2.titleCount(draft.unicodeScalars.count))
                    .font(CobaltType.caption)
                    .foregroundStyle(CobaltColor.caption)
                    .monospacedDigit()
            }
        }
        .task(id: draft) {
            try? await Task.sleep(for: .milliseconds(600))
            if !Task.isCancelled { commit() }
        }
        .onDisappear { commit() }
    }

    private func commit() {
        pipeline.setTitle(TitleText.custom(draft, default: defaultTitle))
    }
}

#if DEBUG
/// A preview over a model that has just been handed a file: the upload runs (the preview server's real timings)
/// while the title UI is on screen.
private struct TitleHost<Content: View>: View {
    @State private var model: AppModel
    private let scenario: PreviewScenario
    private let content: (Pipeline) -> Content

    init(_ scenario: PreviewScenario = .happy, @ViewBuilder content: @escaping (Pipeline) -> Content) {
        _model = State(initialValue: AppModel.preview(scenario))
        self.scenario = scenario
        self.content = content
    }

    var body: some View {
        content(model.pipeline)
            .task {
                guard model.pipeline.state == .idle else { return }
                model.pipeline.start(file: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("IMG_0412.mov"))
            }
    }
}

#Preview("title sheet · files default") {
    TitleHost { pipeline in
        Color(CobaltColor.bg)
            .sheet(isPresented: .constant(true)) { TitleSheet(pipeline: pipeline, defaultTitle: "IMG_0412") {} }
    }
}

#Preview("title sheet · photos default") {
    TitleHost { pipeline in
        Color(CobaltColor.bg)
            .sheet(isPresented: .constant(true)) { TitleSheet(pipeline: pipeline, defaultTitle: "from photos · 4 oct") {} }
    }
}

#Preview("title sheet · long title, 72 of 80") {
    TitleHost { pipeline in
        Color(CobaltColor.bg)
            .sheet(isPresented: .constant(true)) {
                TitleSheet(
                    pipeline: pipeline,
                    defaultTitle: "the whole afternoon at the harbour, before the wind came up and everyone left") {}
            }
    }
}

#Preview("title sheet · run failed behind it") {
    TitleHost(.tooBig) { pipeline in
        Color(CobaltColor.bg)
            .sheet(isPresented: .constant(true)) { TitleSheet(pipeline: pipeline, defaultTitle: "IMG_0412") {} }
    }
}

#Preview("title field · plain", traits: .sizeThatFitsLayout) {
    @Previewable @State var text = "IMG_0412"
    TitleField(text: $text)
        .padding(16)
        .background(CobaltColor.surface)
}
#endif
