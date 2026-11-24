#if os(iOS)
import CobaltKit
import SwiftUI

/// The tools row "video edits": the editor's projects as a list, newest first, each opening the editor on it. The same projects
/// the library's edits shelf shows (`EditorStore`), with rename and delete in the row's menu.
struct ToolsEditsScreen: View {
    let model: AppModel

    @State private var renaming: EditProject?
    @State private var newName = ""
    @State private var deleting: EditProject?

    private var store: EditorStore { model.editor }

    var body: some View {
        Group {
            if store.projects.isEmpty {
                empty
            } else {
                List(store.projects) { project in
                    Button { open(project) } label: { EditRow(project: project, render: store.render(project.render?.id ?? "") ?? project.render) }
                        .buttonStyle(.plain)
                        .listRowBackground(CobaltColor.row)
                        .contextMenu { menu(project) }
                        .swipeActions(edge: .trailing) {
                            Button(Copy.Editor.delete, systemImage: Symbol.delete, role: .destructive) { deleting = project }
                        }
                }
                .scrollContentBackground(.hidden)
            }
        }
        .background(CobaltColor.bg)
        .navigationTitle(Copy.PhoneNav.toolsEditor)
        .navigationBarTitleDisplayMode(.inline)
        .task { await store.refresh() }
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
    }

    @ViewBuilder
    private var empty: some View {
        switch store.listState {
        case .failed:
            ContentUnavailableView {
                Label(Copy.PhoneNav.editsFailed, systemImage: Symbol.error).font(CobaltType.body)
            } actions: {
                Button(Copy.PhoneNav.editsRetry, systemImage: Symbol.retry) { Task { await store.refresh() } }
                    .buttonStyle(.cobaltSecondary(fullWidth: false))
            }
        case .idle, .loading:
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        case .loaded:
            ContentUnavailableView {
                Label(Copy.PhoneNav.editsEmpty, systemImage: Symbol.PhoneNav.editor).font(CobaltType.body)
            } description: {
                Text(Copy.PhoneNav.editsEmptyBody).font(CobaltType.caption)
            }
        }
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
        Task { try? await store.rename(project.id, to: name) }
    }

    private func commitDelete() {
        guard let project = deleting else { return }
        deleting = nil
        Task { try? await store.delete(project.id) }
    }
}

/// One project: its cover (masked for session replay by `EditorPoster`), title, length and clips, and when it was edited or how its
/// newest render went.
private struct EditRow: View {
    let project: EditProject
    let render: EditRender?

    private static let height: CGFloat = 48

    private var coverWidth: CGFloat {
        let aspect = CGFloat(project.canvas.w) / CGFloat(max(1, project.canvas.h))
        return min(86, max(34, (Self.height * aspect).rounded()))
    }

    var body: some View {
        HStack(spacing: 12) {
            EditorPoster(url: project.coverURL, fallback: CobaltColor.elevated, maxPixel: 200)
                .frame(width: coverWidth, height: Self.height)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(project.title.isEmpty ? Copy.Editor.untitled : project.title)
                    .font(CobaltType.bodyMedium)
                    .foregroundStyle(CobaltColor.text)
                    .lineLimit(1)
                Text(Copy.Editor.clipsLine(Copy.Editor.clock(project.duration), project.clipCount))
                    .font(CobaltType.caption)
                    .foregroundStyle(CobaltColor.caption)
                    .monospacedDigit()
                    .lineLimit(1)
                if let text = Copy.Editor.badge(render) {
                    Text(text)
                        .font(CobaltType.caption)
                        .foregroundStyle(render?.status == .error ? CobaltColor.errorText : CobaltColor.linkBlue)
                        .lineLimit(1)
                } else {
                    Text(Copy.Editor.editedAgo(Copy.Editor.ago(project.updatedAt, now: Date())))
                        .font(CobaltType.caption)
                        .foregroundStyle(CobaltColor.caption)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }
}
#endif
