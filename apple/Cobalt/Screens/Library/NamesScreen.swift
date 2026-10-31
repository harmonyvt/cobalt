import CobaltKit
import SwiftUI

// Library › names (APP-API-CONTRACT 48.6): the words the owner has taught search. Each name with a few of its example
// pictures, its meaning, how many posts carry it and a switch; swipe or right click to delete; a tap opens the name screen
// (`NameEditorScreen`), pushed over the list. Its own tab ("search names", under "more" on iPhone), and a sheet from
// `NamesPresenter` for a name in a post's detail or "this is… › new name…" in a post's menu.

struct NamesScreen: View {
    let model: AppModel

    private var names: SearchNamesModel { model.searchNames }

    var body: some View {
        Form {
            Section {
                Text(Copy.Names.hint)
                    .font(CobaltType.captionSmall)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            listSection
        }
        .formStyle(.grouped)
        .font(CobaltType.body)
        .navigationTitle(Copy.Names.title)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { names.startNew() } label: {
                    Label(Copy.Names.newName, systemImage: Symbol.Names.add).labelStyle(.iconOnly)
                }
                .help(Copy.Names.newName)
            }
        }
        .sheetCorner()
        .task { await names.load() }
        .motion(Motion.rows, value: names.names)
        .navigationDestination(isPresented: editorShown) {
            if let editor = names.editor {
                NameEditorScreen(model: model, editor: editor)
            }
        }
    }

    /// The pushed name screen follows the model's editor; going back closes it.
    private var editorShown: Binding<Bool> {
        Binding(get: { names.editor != nil }, set: { shown in if !shown { names.closeEditor() } })
    }

    private var listSection: some View {
        Section {
            if names.names.isEmpty {
                if names.isLoading || !names.hasLoaded && names.failure == nil {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(Copy.Names.loading).font(CobaltType.captionSmall).foregroundStyle(.secondary)
                    }
                } else if names.failure == nil {
                    Text(Copy.Names.empty).font(CobaltType.captionSmall).foregroundStyle(.secondary)
                }
            }
            ForEach(names.names) { name in
                NameRow(model: model, name: name)
            }
            if let failure = names.failure {
                HStack(spacing: 8) {
                    Text(Copy.failure(failure)).font(CobaltType.captionSmall).foregroundStyle(CobaltColor.errorText)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if names.names.isEmpty {
                        Button { Task { await names.load() } } label: {
                            Label(Copy.Names.retry, systemImage: Symbol.Names.retry)
                        }
                        .buttonStyle(.cobaltIcon(.small))
                    }
                }
            }
        } footer: {
            Text(Copy.Names.tip).font(CobaltType.captionSmall).lineSpacing(2)
        }
    }
}

/// One name: up to three example pictures, the name, its meaning, `14 posts · 2 other words`, a switch. A tap opens it.
private struct NameRow: View {
    let model: AppModel
    let name: TaughtName

    private var names: SearchNamesModel { model.searchNames }

    var body: some View {
        HStack(spacing: 12) {
            Button { names.open(name) } label: {
                HStack(spacing: 12) {
                    NameStack(model: model, keys: Array(name.yes.prefix(3)))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(name.name).font(CobaltType.bodySemibold).foregroundStyle(CobaltColor.text)
                        Text(Copy.Names.meaningLine(name))
                            .font(CobaltType.captionSmall).foregroundStyle(.secondary).lineLimit(2)
                        Text(Copy.Names.summary(name))
                            .font(CobaltType.badge).foregroundStyle(.secondary).monospacedDigit()
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint(Copy.Names.openName(name.name))
            Toggle(Copy.Names.on(name.name), isOn: Binding(
                get: { name.enabled },
                set: { on in Task { await names.setEnabled(name, on) } }))
                .labelsHidden()
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button(role: .destructive) {
                Task { await names.delete(name) }
            } label: {
                Label(Copy.Names.delete, systemImage: Symbol.Names.delete)
            }
        }
        // the Mac has no swipe
        .contextMenu {
            Button(role: .destructive) {
                Task { await names.delete(name) }
            } label: {
                Label(Copy.Names.delete, systemImage: Symbol.Names.delete)
            }
        }
    }
}

/// Up to three example pictures, fanned; the names glyph when the name has none.
private struct NameStack: View {
    let model: AppModel
    let keys: [String]

    var body: some View {
        let posts = keys.compactMap { model.library.post(id: $0) }
        ZStack(alignment: .leading) {
            if posts.isEmpty {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(CobaltColor.elevated)
                    .frame(width: 40, height: 40)
                    .overlay {
                        Image(systemName: Symbol.Names.menu).font(.system(size: 15)).foregroundStyle(.secondary)
                    }
            } else {
                ForEach(Array(posts.enumerated()), id: \.element.id) { index, post in
                    NameThumb(model: model, post: post, size: 40, index: index)
                        .offset(x: CGFloat(index) * 10)
                        .zIndex(Double(posts.count - index))
                }
            }
        }
        .frame(width: 40 + CGFloat(max(0, posts.count - 1)) * 10, alignment: .leading)
        .accessibilityHidden(true)
    }
}

/// A post's picture as a small rounded square (the name screen's strips and rows, the list's stacks).
struct NameThumb: View {
    let model: AppModel
    let post: LibraryPost
    var size: CGFloat = 44
    var index: Int = 0

    var body: some View {
        FacePicture(item: model.mediaItem(for: post), maxPixel: 160, glyphSize: 14, gradient: FrameGradient.variant(forIndex: index))
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(CobaltColor.hairline)
            }
    }
}

/// Presents library › names as a sheet while `SearchNamesModel.showingList` is set, and reads the names once the library
/// is open on a server that has them (so a post's "this is…" lists them).
struct NamesPresenter: ViewModifier {
    let model: AppModel

    private var names: SearchNamesModel { model.searchNames }

    private var shown: Binding<Bool> {
        let model = self.model.searchNames
        return Binding(get: { model.showingList }, set: { model.showingList = $0 })
    }

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: shown, onDismiss: { names.closeEditor() }) {
                NavigationStack {
                    NamesScreen(model: model)
                }
                .sheetClose { names.closeAll() }
                #if os(macOS)
                .frame(minWidth: 520, idealWidth: 600, minHeight: 560, idealHeight: 760)
                #endif
            }
            .task(id: model.capabilities.names) {
                if model.capabilities.names, !names.hasLoaded { await names.load() }
            }
    }
}

/// "this is…" in a post's menu (48.6): the names (an example of one is ticked; picking it again takes the mark off), then
/// "new name…", which opens a new name with the post as its first example.
struct NamesPostMenu: View {
    let model: AppModel
    let postKey: String
    /// The shell's status line ("an example of Lia now").
    var showStatus: @MainActor (String) -> Void = { _ in }

    var body: some View {
        let names = model.searchNames
        Menu {
            ForEach(names.names.filter(\.enabled)) { name in
                let isExample = name.mark(of: postKey) == .yes
                Button {
                    mark(name, isExample ? nil : .yes)
                } label: {
                    if isExample {
                        Label(name.name, systemImage: "checkmark")
                    } else {
                        Text(name.name)
                    }
                }
            }
            if names.names.contains(where: \.enabled) { Divider() }
            Button(Copy.Names.newNameFromPost, systemImage: Symbol.Names.newName) {
                names.startNew(example: postKey)
            }
        } label: {
            Label(Copy.Names.thisIsMenu, systemImage: Symbol.Names.thisIs)
        }
    }

    private func mark(_ name: TaughtName, _ kind: NameMark?) {
        let names = model.searchNames
        let key = postKey
        let status = showStatus
        Task {
            if await names.mark(key, kind, on: name.id) != nil {
                status(kind == .yes ? Copy.Names.markedYes(name.name) : Copy.Names.unmarked(name.name))
            } else {
                status(Copy.Names.markFailed)
            }
        }
    }
}

#if DEBUG
@MainActor
private struct NamesScreenPreview: View {
    @State private var model = AppModel.previewNames()

    var body: some View {
        NavigationStack { NamesScreen(model: model) }
    }
}

#Preview("names · list") {
    NamesScreenPreview()
}
#endif
