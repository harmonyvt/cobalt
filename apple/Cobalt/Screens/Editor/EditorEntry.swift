import CobaltKit
import SwiftUI

// The editor's two ways in from the library (apple/CONTRACT-EDITOR.md 4.1): `edit` in the select pill's action row, and the
// `edits` shelf above the share links.

/// `edit` in `LibrarySelectPill`'s action row, after `make link` / `collection` and before `share`. Enabled when at least one
/// pick has a video on the server. Tapped, it makes the project and opens the editor on it (`creating` while it works);
/// a failure is `couldntCreate` (or the more exact refusal) in the pill's line. Icon-only, like the rest of the row.
struct EditPicksButton: View {
    let model: AppModel
    /// The ticked posts, in the order they were ticked.
    let picks: [LibraryRow]
    /// The pill's line for the editor: `couldntCreate`, `editNoVideo` or `editLine`; nil says nothing.
    @Binding var note: String?

    @State private var creating = false

    /// A pick the editor can use: a video with a server copy, or a gallery with one.
    static func canEdit(_ row: LibraryRow) -> Bool {
        let item = row.item
        if item.kind == .gallery {
            return item.items.contains { $0.itemType == .video && $0.file != nil }
        }
        guard item.kind == .video || item.kind == .webp else { return false }
        return item.video?.file != nil
    }

    private var enabled: Bool { picks.contains(where: Self.canEdit) && !creating }

    var body: some View {
        Button(action: create) {
            Label(Copy.Editor.edit, systemImage: Symbol.Editor.edit)
        }
        .buttonStyle(.cobaltIcon(tint: CobaltColor.collectionSet, state: creating ? .working : .idle))
        .disabled(!enabled)
        .accessibilityLabel(creating ? Copy.Editor.creating : Copy.Editor.edit)
        .accessibilityHint(enabled ? Copy.Editor.editLine : Copy.Editor.editNoVideo)
        .onChange(of: picks.map(\.id)) { _, _ in note = nil }
    }

    private func create() {
        note = nil
        creating = true
        Task {
            defer { creating = false }
            let items = picks.filter(Self.canEdit).map(\.item)
            do {
                let left = try await model.editor.create(from: items)
                EditorLauncher.shared.firstToast = Self.firstToast(left)
            } catch {
                switch EditError.from(error) {
                case .invalid(.empty): note = Copy.Editor.editNoVideo
                case .tooMany: note = Copy.Editor.tooManyProjects
                case .invalid(let problem): note = Copy.Editor.problem(problem)
                default: note = Copy.Editor.couldntCreate
                }
            }
        }
    }

    /// What the editor's first toast says about the picks it left out.
    static func firstToast(_ left: EditLeftOut) -> String? {
        var lines: [String] = []
        if left.photosAndGifs > 0 { lines.append(Copy.Editor.leftOut(left.photosAndGifs)) }
        if left.notOnServer > 0 { lines.append(Copy.Editor.notOnServer(left.notOnServer)) }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }
}

// MARK: - the shelf

/// The saved projects newest first as cards (the library shelf's `edits` tab): the cover (canvas-shaped, 56 pt tall), the
/// title, `0:26 · 17 clips · 3 d ago`, `open`, and a badge for the newest render. A tap opens; the context menu has `open`,
/// `rename…` and `delete…`. Shown while the editor is available and there is a project; the library puts it above the links.
struct LibraryEditsShelf: View {
    let model: AppModel

    @State private var renaming: EditProject?
    @State private var newName = ""
    @State private var deleting: EditProject?

    private var store: EditorStore { model.editor }

    /// Whether the shelf has anything to show (also `LibraryShelves.hasContent`'s test).
    static func shows(_ model: AppModel) -> Bool {
        model.editor.isAvailable && !model.editor.projects.isEmpty
    }

    var body: some View {
        // the shelf's `edits` tab supplies the header (`LibraryShelves`); this is the row of cards
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(spacing: 10) {
                ForEach(store.projects) { project in
                    Button { open(project) } label: {
                        EditCard(project: project, render: store.render(project.render?.id ?? "") ?? project.render)
                    }
                    .buttonStyle(.plain)
                    .contextMenu { menu(project) }
                }
            }
            .padding(.horizontal, 12)
        }
        .scrollClipDisabled()
        .alert(Copy.Editor.renameTitle, isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField(Copy.Editor.renamePlaceholder, text: $newName)
            Button(Copy.Editor.rename.replacingOccurrences(of: "…", with: "")) { commitRename() }
            Button(Copy.Editor.cancel, role: .cancel) {}
        }
        .confirmationDialog(
            Copy.Editor.deleteTitle, isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
            titleVisibility: .visible
        ) {
            Button(Copy.Editor.deleteConfirm, role: .destructive) { commitDelete() }
            Button(Copy.Editor.cancel, role: .cancel) {}
        } message: {
            Text(Copy.Editor.deleteBody)
        }
        .task { await model.editor.refresh() }
    }

    @ViewBuilder
    private func menu(_ project: EditProject) -> some View {
        Button(Copy.Editor.open, systemImage: Symbol.openApp) { open(project) }
        Button(Copy.Editor.rename, systemImage: "pencil") {
            newName = project.title
            renaming = project
        }
        Button(Copy.Editor.delete, systemImage: Symbol.delete, role: .destructive) { deleting = project }
    }

    private func open(_ project: EditProject) {
        Task { await EditorLauncher.shared.open(project.id, model: model) }
    }

    private func commitRename() {
        guard let project = renaming else { return }
        renaming = nil
        let name = newName
        Task { try? await model.editor.rename(project.id, to: name) }
    }

    private func commitDelete() {
        guard let project = deleting else { return }
        deleting = nil
        Task { try? await model.editor.delete(project.id) }
    }
}

/// One project on the shelf.
private struct EditCard: View {
    let project: EditProject
    let render: EditRender?

    /// The cover's height: the shelf's one card size (`ShelfCard`).
    private static let height: CGFloat = 56

    private var coverWidth: CGFloat {
        let aspect = CGFloat(project.canvas.w) / CGFloat(max(1, project.canvas.h))
        return min(100, max(40, (Self.height * aspect).rounded()))
    }

    var body: some View {
        ShelfCard {
            EditorPoster(url: project.coverURL, fallback: CobaltColor.elevated, maxPixel: 200)
                .frame(width: coverWidth, height: Self.height)
        } lines: {
            Text(project.title.isEmpty ? Copy.Editor.untitled : project.title)
                .font(CobaltType.bodyMedium)
                .foregroundStyle(CobaltColor.text)
                .lineLimit(1)
            Text(Copy.Editor.clipsLine(Copy.Editor.clock(project.duration), project.clipCount))
                .font(CobaltType.badge)
                .foregroundStyle(CobaltColor.caption)
                .monospacedDigit()
                .lineLimit(1)
            // the newest render's word (`rendered`, `rendering 40%`) in place of when, so it never wraps on the cover
            if let text = Copy.Editor.badge(render) {
                Text(text)
                    .font(CobaltType.badge)
                    .foregroundStyle(render?.status == .error ? CobaltColor.errorText : CobaltColor.linkBlue)
                    .lineLimit(1)
            } else {
                Text(Copy.Editor.editedAgo(Copy.Editor.ago(project.updatedAt, now: Date())))
                    .font(CobaltType.badge)
                    .foregroundStyle(CobaltColor.caption)
                    .lineLimit(1)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(a11y)
        .accessibilityAddTraits(.isButton)
    }

    private var a11y: String {
        var parts = [
            project.title, Copy.Editor.clipsLine(Copy.Editor.clock(project.duration), project.clipCount),
            Copy.Editor.editedAgo(Copy.Editor.ago(project.updatedAt, now: Date())),
        ]
        if let text = Copy.Editor.badge(render) { parts.append(text) }
        return parts.joined(separator: ", ")
    }
}
