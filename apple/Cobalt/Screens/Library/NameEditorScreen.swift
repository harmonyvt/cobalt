import CobaltKit
import SwiftUI

// The name page (APP-API-CONTRACT 48.6; mockup search-names/mockup.html), in the screen pane: the word and its "also called"
// chips, what it means, a "this is Lia" strip and a "not Lia" strip of pictures, "listen to: the words … the examples" (strength),
// "cut-off: more posts … stricter", and "who's in": the preview's posts with a dashed cut-off line between those that carry
// the name and those that don't; a tap cycles a post through example, not and no mark. Slider and mark changes re-run the
// preview after 300 ms (`SearchNameEditor`); save writes it. "try a search" runs a query with and without names.
//
// The editor is the model's (`SearchNamesModel.editor`), so the page can be rebuilt for another shape (beside the tab,
// spanned) without losing a draft. The names list opens a name with `NamePane.open`; the page reads the editor, and opens
// the name by id itself when it is not there (a restored pane, a link). A name not made yet is `NamePane.newID`.

/// How a name gets into the pane.
@MainActor
enum NamePane {
    /// The pane item for a name that has no id yet ("new name…").
    static let newID = "new"

    /// Opens a saved name from the list: the editor first (it is the model's), then the pane.
    static func open(_ name: TaughtName, model: AppModel, pane: Pane?) {
        let names = model.searchNames
        if names.editor?.saved?.id != name.id { names.open(name) }
        names.showingList = false
        pane?.open(.name(name.id))
    }

    /// A new name, with `example` as its first example when it comes from a post's menu.
    static func startNew(example: String? = nil, model: AppModel, pane: Pane?) {
        let names = model.searchNames
        names.startNew(example: example)
        names.showingList = false
        pane?.open(.name(newID))
    }
}

/// A saved or new name in the pane. The title is the word as it is typed; the one big button is save, the rest of the
/// editor is the body (a form drawn as cards, since a form would scroll inside the pane's own scrolling).
struct NamePage: View {
    let id: String
    let model: AppModel

    @Environment(Pane.self) private var pane
    @Environment(\.paneShape) private var shape
    @Environment(\.paneHeaderHeight) private var headerHeight
    @State private var failed = false
    @State private var confirmingDelete = false

    private var names: SearchNamesModel { model.searchNames }
    private var item: PaneItem { .name(id) }
    private var isNew: Bool { id == NamePane.newID }

    /// The editor for this page's name, once the model holds it.
    private var editor: SearchNameEditor? {
        guard let editor = names.editor else { return nil }
        if isNew { return editor.isNew ? editor : nil }
        return editor.saved?.id == id ? editor : nil
    }

    var body: some View {
        Group {
            if let editor {
                page(editor)
            } else if failed {
                PaneGonePage()
            } else {
                PaneLoadingPage()
            }
        }
        .task(id: id) { await open() }
        .paneKeeps(item) {
            if names.editor === editor { names.closeEditor() }
        }
    }

    /// Makes the model's editor this name's: a name opened from the list already is; a restored pane or a link opens it.
    private func open() async {
        failed = false
        if isNew {
            if names.editor?.isNew != true { names.startNew() }
        } else if names.editor?.saved?.id != id {
            if !(await names.open(id: id)) { failed = true }
        }
        names.showingList = false
    }

    private func page(_ editor: SearchNameEditor) -> some View {
        PanePage(
            title: editor.isNew ? Copy.Names.newTitle : Copy.Names.display(editor.draft.name),
            subtitle: editor.saved.map(Copy.Names.summary),
            more: editor.isNew ? [] : [
                PaneAction(Copy.Names.delete, systemImage: Symbol.Names.delete, role: .destructive, needsServer: true) {
                    confirmingDelete = true
                },
            ]
        ) {
            hero(editor)
        } controls: {
            saveControls(editor)
        } body: {
            NameEditorSections(model: model, editor: editor)
                .padding(.horizontal, 16)
        }
        .modifier(NameEditorEvents(editor: editor))
        .confirmationDialog(Copy.Names.delete, isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button(Copy.Names.delete, role: .destructive) {
                guard let saved = editor.saved else { return }
                Task {
                    await names.delete(saved)
                    pane.close()
                }
            }
        }
    }

    /// The name's example pictures, fanned, over a quiet field (nothing in a bar: a name is never running).
    private func hero(_ editor: SearchNameEditor) -> some View {
        let keys = Array(editor.posts(marked: .yes).prefix(6).map(\.key))
        return ZStack {
            CobaltColor.surface
            NameStack(model: model, keys: keys)
                .scaleEffect(1.5)
        }
        .frame(height: 120)
        .padding(.top, shape == .tall ? headerHeight : 0)
        .background(CobaltColor.surface)
    }

    /// Save, with the model's own problem line (what the old save bar said).
    private func saveControls(_ editor: SearchNameEditor) -> some View {
        VStack(spacing: 6) {
            if let problem = editor.saveProblem {
                Text(Copy.Names.problem(problem))
                    .font(CobaltType.captionSmall)
                    .foregroundStyle(CobaltColor.errorText)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .transition(.opacity)
            }
            Button {
                Task { await editor.save() }
            } label: {
                Text(saveLabel(editor))
            }
            .buttonStyle(.cobaltPrimary())
            .disabled(!editor.canSave)
        }
        .motion(Motion.rows, value: editor.saveProblem)
    }

    private func saveLabel(_ editor: SearchNameEditor) -> String {
        if editor.isSaving { return Copy.Names.saving }
        if !editor.isDirty { return Copy.Names.saved }
        return Copy.Names.save(editor.draft.trimmedName)
    }
}

/// The sections of the editor, one card each (what the name screen's form held).
private struct NameEditorSections: View {
    let model: AppModel
    @Bindable var editor: SearchNameEditor

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            NameWordsSection(editor: editor)
            NameMeaningSection(editor: editor)
            NameStripsSection(model: model, editor: editor)
            NameDialsSection(editor: editor)
            NameWhosInSection(model: model, editor: editor)
            NameTrySearchSection(model: model, editor: editor)
        }
        .font(CobaltType.body)
    }
}

/// A titled card: what a form's section was.
private struct NameBlock<Header: View, Content: View, Footer: View>: View {
    let header: Header
    let content: Content
    let footer: Footer

    init(@ViewBuilder header: () -> Header, @ViewBuilder content: () -> Content, @ViewBuilder footer: () -> Footer) {
        self.header = header()
        self.content = content()
        self.footer = footer()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            header.padding(.horizontal, 4)
            VStack(alignment: .leading, spacing: 12) { content }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
                .background(CobaltColor.surface, in: .rect(cornerRadius: 20))
            footer.padding(.horizontal, 4)
        }
    }
}

extension NameBlock where Header == EmptyView, Footer == EmptyView {
    init(@ViewBuilder content: () -> Content) {
        self.init(header: { EmptyView() }, content: content, footer: { EmptyView() })
    }
}

extension NameBlock where Header == Text, Footer == EmptyView {
    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.init(
            header: { Text(title).font(CobaltType.caption).foregroundStyle(CobaltColor.caption) },
            content: content, footer: { EmptyView() })
    }
}

/// The preview follows the draft; a save, a mark and a refusal are felt. (Its pending read stops when the pane lets the
/// editor go, not when a page is rebuilt for another shape.)
private struct NameEditorEvents: ViewModifier {
    let editor: SearchNameEditor

    func body(content: Content) -> some View {
        content
            .task { editor.start() }
            .onChange(of: editor.draft) { editor.draftChanged() }
            .haptic(.success, trigger: editor.savedTick)
            .haptic(.selection, trigger: editor.draft.yes.count + editor.draft.no.count * 1_000)
            .haptic(.error, trigger: editor.saveProblem) { $0 != nil }
    }
}

// MARK: - the word

private struct NameWordsSection: View {
    @Bindable var editor: SearchNameEditor
    @State private var aliasDraft = ""
    @State private var addingAlias = false
    @FocusState private var aliasFocused: Bool

    var body: some View {
        NameBlock(Copy.Names.alsoCalled) {
            TextField(Copy.Names.namePlaceholder, text: $editor.draft.name)
                .font(Font.cobalt(22, .semibold, relativeTo: .title2))
                .autocorrectionDisabled()
                .accessibilityLabel(Copy.Names.nameA11y)
                .onChange(of: editor.draft.name) { _, new in
                    if new.count > TaughtName.maxNameLength { editor.draft.name = String(new.prefix(TaughtName.maxNameLength)) }
                }
            AboutFlow(spacing: 6) {
                ForEach(editor.draft.aliases, id: \.self) { word in
                    AboutTagChip(tag: word, tone: .owner) { editor.draft.removeAlias(word) }
                }
                if editor.draft.aliases.count < TaughtName.maxAliases { aliasControl }
            }
            .padding(.vertical, 2)
        }
    }

    @ViewBuilder
    private var aliasControl: some View {
        if addingAlias {
            TextField(Copy.Names.aliasPlaceholder, text: $aliasDraft)
                .font(CobaltType.captionSmall)
                .focused($aliasFocused)
                .autocorrectionDisabled()
                #if os(iOS)
                .textInputAutocapitalization(.never)
                #endif
                .submitLabel(.done)
                .onSubmit { addAlias() }
                .frame(minWidth: 110)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(CobaltColor.elevated.opacity(0.6), in: Capsule())
                .onAppear { aliasFocused = true }
        } else {
            Button { addingAlias = true } label: {
                Text(Copy.Names.addAlias)
                    .font(CobaltType.captionSmall)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .overlay(Capsule().strokeBorder(CobaltColor.border, style: StrokeStyle(lineWidth: 1.2, dash: [4, 3])))
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
        }
    }

    private func addAlias() {
        editor.draft.addAlias(aliasDraft)
        aliasDraft = ""
        addingAlias = false
    }
}

// MARK: - the meaning

private struct NameMeaningSection: View {
    @Bindable var editor: SearchNameEditor

    var body: some View {
        NameBlock(Copy.Names.means) {
            TextField(Copy.Names.meaningPlaceholder, text: $editor.draft.meaning, axis: .vertical)
                .lineLimit(2...6)
                .accessibilityLabel(Copy.Names.meaningA11y)
                .onChange(of: editor.draft.meaning) { _, new in
                    if new.count > TaughtName.maxMeaningLength {
                        editor.draft.meaning = String(new.prefix(TaughtName.maxMeaningLength))
                    }
                }
            if let preview = editor.preview, !preview.embedded {
                Label(Copy.Names.notEmbedded, systemImage: Symbol.Names.notEmbedded)
                    .font(CobaltType.captionSmall)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

// MARK: - this is / not

private struct NameStripsSection: View {
    let model: AppModel
    let editor: SearchNameEditor

    var body: some View {
        NameBlock {
            strip(.yes)
            strip(.no)
        }
    }

    private func strip(_ mark: NameMark) -> some View {
        let posts = editor.posts(marked: mark)
        let name = editor.draft.name
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text(mark == .yes ? Copy.Names.thisIs(name) : Copy.Names.notName(name))
                    .font(CobaltType.captionSmall)
                    .foregroundStyle(.secondary)
                Text("\(posts.count)")
                    .font(CobaltType.captionSmall.weight(.semibold))
                    .monospacedDigit()
            }
            if posts.isEmpty {
                Text(mark == .yes ? Copy.Names.noExamples : Copy.Names.noNots)
                    .font(CobaltType.captionSmall)
                    .foregroundStyle(.tertiary)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(Array(posts.enumerated()), id: \.offset) { index, entry in
                            NameStripThumb(model: model, post: entry.post, index: index, mark: mark) {
                                editor.draft.set(nil, for: entry.key)
                            }
                        }
                    }
                }
            }
        }
        .padding(.vertical, 2)
    }
}

/// A marked post in a strip: its picture with the mark's ring; its menu takes the mark off.
private struct NameStripThumb: View {
    let model: AppModel
    let post: LibraryPost?
    let index: Int
    let mark: NameMark
    let unmark: () -> Void

    var body: some View {
        Group {
            if let post {
                NameThumb(model: model, post: post, size: 52, index: index)
            } else {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(CobaltColor.elevated)
                    .frame(width: 52, height: 52)
            }
        }
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(mark == .yes ? CobaltColor.text : CobaltColor.errorText, lineWidth: 2)
        }
        .contextMenu {
            Button(Copy.Names.unmark, systemImage: Symbol.Names.unmark, action: unmark)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(post.map { model.mediaItem(for: $0).titleText } ?? "")
        .accessibilityAction(named: Text(Copy.Names.unmark), unmark)
    }
}

// MARK: - the two dials

private struct NameDialsSection: View {
    @Bindable var editor: SearchNameEditor

    var body: some View {
        NameBlock {
            NameDial(
                title: Copy.Names.listenTo(editor.draft.strength), value: $editor.draft.strength, range: 0...1,
                low: Copy.Names.theWords, high: Copy.Names.theExamples, a11y: Copy.Names.strengthA11y,
                a11yValue: Copy.Names.percent(editor.draft.strength))
            NameDial(
                title: Copy.Names.cutoff(editor.draft.cutoff), value: $editor.draft.cutoff, range: cutoffRange,
                low: Copy.Names.morePosts, high: Copy.Names.stricter, a11y: Copy.Names.cutoffA11y,
                a11yValue: Copy.Names.score(editor.draft.cutoff))
        }
    }

    /// The mockup's 0.2 to 0.9 (where cosines live), wider when a saved name sits outside it.
    private var cutoffRange: ClosedRange<Double> {
        min(0.2, editor.draft.cutoff)...max(0.9, editor.draft.cutoff)
    }
}

/// A labelled slider with a word at each end.
private struct NameDial: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let low: String
    let high: String
    let a11y: String
    let a11yValue: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(CobaltType.captionSmall)
                .foregroundStyle(.secondary)
                .monospacedDigit()
            Slider(value: $value, in: range, step: 0.01)
                .accessibilityLabel(a11y)
                .accessibilityValue(a11yValue)
            HStack {
                Text(low)
                Spacer(minLength: 8)
                Text(high)
            }
            .font(CobaltType.badge)
            .foregroundStyle(.secondary)
            .accessibilityHidden(true)
        }
        .padding(.vertical, 2)
    }
}

// MARK: - who's in

private struct NameWhosInSection: View {
    let model: AppModel
    let editor: SearchNameEditor

    var body: some View {
        NameBlock(header: { header }) {
            if let preview = editor.preview {
                ForEach(editor.carrying) { entry in row(entry) }
                if !editor.carrying.isEmpty, !editor.notCarrying.isEmpty { NameCutLine() }
                ForEach(editor.notCarrying) { entry in row(entry) }
                if preview.posts.isEmpty {
                    Text(Copy.Names.noPreview).font(CobaltType.captionSmall).foregroundStyle(.secondary)
                }
            } else if editor.isPreviewing {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(Copy.Names.previewing).font(CobaltType.captionSmall).foregroundStyle(.secondary)
                }
            } else {
                Text(Copy.Names.noPreview).font(CobaltType.captionSmall).foregroundStyle(.secondary)
            }
            if editor.previewFailed {
                HStack(spacing: 8) {
                    Text(Copy.Names.previewFailed).font(CobaltType.captionSmall).foregroundStyle(CobaltColor.errorText)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button { editor.refreshPreview() } label: {
                        Label(Copy.Names.retry, systemImage: Symbol.Names.retry)
                    }
                    .buttonStyle(.cobaltIcon(.small))
                }
            }
        } footer: {
            EmptyView()
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(Copy.Names.whosIn(editor.preview?.carries ?? editor.carrying.count))
                    .font(CobaltType.caption).foregroundStyle(CobaltColor.caption).monospacedDigit()
                if editor.isPreviewing, editor.preview != nil { ProgressView().controlSize(.mini) }
            }
            Text(Copy.Names.whosInHint).font(CobaltType.captionSmall).foregroundStyle(.secondary)
        }
    }

    private func row(_ entry: SearchNamePreview.Entry) -> some View {
        NameWhosInRow(model: model, entry: entry, mark: editor.draft.mark(of: entry.postKey)) {
            editor.cycle(entry.postKey)
        }
    }
}

/// The dashed line between the posts that carry the name and those that don't.
private struct NameCutLine: View {
    var body: some View {
        HStack(spacing: 8) {
            dash
            Text(Copy.Names.cutLine).font(CobaltType.badge).foregroundStyle(.secondary)
            dash
        }
        .accessibilityElement(children: .combine)
    }

    private var dash: some View {
        Line()
            .stroke(CobaltColor.border, style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
            .frame(height: 1)
    }

    private struct Line: Shape {
        func path(in rect: CGRect) -> Path {
            var p = Path()
            p.move(to: CGPoint(x: rect.minX, y: rect.midY))
            p.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
            return p
        }
    }
}

/// One post of "who's in": its picture, its title, the mark (the draft's, which may be ahead of the preview) or its score.
/// Out posts are dimmed. A tap cycles the mark.
private struct NameWhosInRow: View {
    let model: AppModel
    let entry: SearchNamePreview.Entry
    let mark: NameMark?
    let cycle: () -> Void

    var body: some View {
        let title = entry.post.map { model.mediaItem(for: $0).titleText } ?? entry.postKey
        let isIn = mark == .yes || (mark == nil && entry.carries)
        Button(action: cycle) {
            HStack(spacing: 10) {
                if let post = entry.post {
                    NameThumb(model: model, post: post, size: 40)
                } else {
                    RoundedRectangle(cornerRadius: 8, style: .continuous).fill(CobaltColor.elevated).frame(width: 40, height: 40)
                }
                Text(title)
                    .font(CobaltType.captionSmall)
                    .foregroundStyle(CobaltColor.text)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                trailing
            }
            .opacity(isIn ? 1 : 0.55)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Copy.Names.rowA11y(title, mark: mark, carries: entry.carries, score: entry.score))
        .accessibilityHint(Copy.Names.rowA11yHint)
    }

    @ViewBuilder
    private var trailing: some View {
        switch mark {
        case .yes?:
            NameMarkTag(text: Copy.Names.example, ink: CobaltColor.text)
        case .no?:
            NameMarkTag(text: Copy.Names.notIt, ink: CobaltColor.errorText)
        case nil:
            Text(Copy.Names.score(entry.score))
                .font(CobaltType.captionSmall)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
    }
}

private struct NameMarkTag: View {
    let text: String
    let ink: Color

    var body: some View {
        Text(text)
            .font(CobaltType.badge)
            .foregroundStyle(ink)
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .overlay(Capsule().strokeBorder(ink.opacity(0.6), lineWidth: 1))
    }
}

// MARK: - try a search

private struct NameTrySearchSection: View {
    let model: AppModel
    let editor: SearchNameEditor
    @State private var query = ""

    var body: some View {
        NameBlock(header: {
            Text(Copy.Names.trySearch).font(CobaltType.caption).foregroundStyle(CobaltColor.caption)
        }) {
            HStack(spacing: 8) {
                TextField(Copy.Names.tryPlaceholder, text: $query)
                    .autocorrectionDisabled()
                    .submitLabel(.search)
                    .onSubmit { editor.compare(query) }
                Button { editor.compare(query) } label: {
                    Label(Copy.Names.tryRun, systemImage: Symbol.Names.search)
                }
                .buttonStyle(.cobaltIcon(.small, state: editor.isComparing ? .working : .idle))
                .disabled(query.trimmingCharacters(in: .whitespaces).count < 2)
            }
            if let comparison = editor.comparison {
                HStack(alignment: .top, spacing: 12) {
                    NameTryColumn(model: model, title: Copy.Names.without, posts: comparison.without)
                    NameTryColumn(model: model, title: Copy.Names.with, posts: comparison.with)
                }
                Text(Copy.Names.used(comparison.used))
                    .font(CobaltType.badge)
                    .foregroundStyle(.secondary)
            }
            if editor.compareFailed {
                Text(Copy.Names.tryFailed).font(CobaltType.captionSmall).foregroundStyle(CobaltColor.errorText)
            }
        } footer: {
            Text(Copy.Names.tryHint).font(CobaltType.captionSmall).foregroundStyle(.secondary)
        }
        .onAppear { if query.isEmpty { query = suggested } }
    }

    /// The name and a word, like the mockup's "Lia dancing"; empty for a name with no word yet.
    private var suggested: String {
        let name = editor.draft.trimmedName
        return name.isEmpty ? "" : name
    }
}

/// One side of the comparison: the first posts, best first.
private struct NameTryColumn: View {
    let model: AppModel
    let title: String
    let posts: [LibraryPost]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(CobaltType.badge).foregroundStyle(.secondary)
            if posts.isEmpty {
                Text(Copy.Names.nothingFound).font(CobaltType.captionSmall).foregroundStyle(.tertiary)
            }
            ForEach(Array(posts.prefix(6).enumerated()), id: \.element.id) { index, post in
                HStack(spacing: 6) {
                    NameThumb(model: model, post: post, size: 28, index: index)
                    Text(model.mediaItem(for: post).titleText)
                        .font(CobaltType.badge)
                        .lineLimit(1)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

#if DEBUG
@MainActor
private struct NamePageHost: View {
    let shape: PaneShape
    var hinge: PaneHinge?
    @State private var model = AppModel.previewNames()

    var body: some View {
        AreaPageHost(item: .name("PrEvIeWname00001"), shape: shape, hinge: hinge) {
            NamePage(id: "PrEvIeWname00001", model: model)
        }
        .cobaltRoot(model: model)
    }
}

#Preview("names · Lia", traits: .fixedLayout(width: 440, height: 900)) {
    NamePageHost(shape: .tall)
}
#Preview("names · Lia, AX3", traits: .fixedLayout(width: 440, height: 1100)) {
    NamePageHost(shape: .tall).dynamicTypeSize(.accessibility3)
}
#Preview("names · Lia, wide", traits: .fixedLayout(width: 1000, height: 600)) {
    NamePageHost(shape: .wide)
}
#Preview("names · Lia, spanned", traits: .fixedLayout(width: 1080, height: 800)) {
    NamePageHost(shape: .split(.media), hinge: PaneHinge(axis: .vertical, position: 540))
}
#endif
