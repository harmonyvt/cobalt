import CobaltKit
import SwiftUI

/// AppShell's one modifier for the editor (apple/CONTRACT-EDITOR.md 4.2). While a project is open (or opening):
/// iOS and iPadOS show `EditorWindowContent` in a full-screen cover, the Mac opens the `editor` window. It also keeps the
/// library's edits shelf fresh (refresh at launch, when the library tab comes up, when the editor closes), puts the lines
/// other parts of the editor leave for the shell on the screen (`closeRendering`, `editorOff`, `projectGone`), and, in debug
/// builds, takes `-previewEditor beach|cats|<project id>` (pair it with `-previewScenario happy` or an `editor*` scenario).
struct EditorPresenter: ViewModifier {
    let model: AppModel

    @Environment(\.shell) private var shell
    #if os(macOS)
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow
    #endif

    private var launcher: EditorLauncher { .shared }
    private var hasSession: Bool { model.editor.session != nil }
    private var showing: Bool { hasSession || launcher.isBusy }

    func body(content: Content) -> some View {
        content
            .modifier(EditorCover(model: model, showing: showing))
            #if os(macOS)
            .onChange(of: showing, initial: true) { _, on in
                if on { openWindow(id: EditorWindowID.editor) } else { dismissWindow(id: EditorWindowID.editor) }
            }
            #endif
            .onChange(of: hasSession) { _, isOpen in
                guard !isOpen else { return }
                if !model.editor.isAvailable {
                    shell.showStatus(Copy.Editor.editorOff)
                    launcher.afterClose = nil
                } else if let line = launcher.afterClose {
                    shell.showStatus(line)
                    launcher.afterClose = nil
                }
                Task { await model.editor.refresh() }
            }
            .onChange(of: launcher.afterClose) { _, line in
                guard let line, !showing else { return }
                shell.showStatus(line)
                launcher.afterClose = nil
            }
            .task(id: model.editor.isAvailable) {
                if model.editor.isAvailable { await model.editor.refresh() }
            }
            .onChange(of: model.selectedTab) { _, tab in
                if tab == .library, model.editor.isAvailable { Task { await model.editor.refresh() } }
            }
            #if DEBUG
            .task { await openPreviewProject() }
            #endif
    }

    #if DEBUG
    /// `-previewEditor beach|cats|<project id>`: opens that project once the list is in.
    private func openPreviewProject() async {
        guard let raw = UserDefaults.standard.string(forKey: "previewEditor"), !raw.isEmpty else { return }
        for _ in 0..<120 where !model.editor.isAvailable { try? await Task.sleep(for: .milliseconds(500)) }
        guard model.editor.isAvailable else { return }
        for _ in 0..<20 {
            await model.editor.refresh()
            if !model.editor.projects.isEmpty { break }
            try? await Task.sleep(for: .milliseconds(500))
        }
        let word = raw == "cats" ? "cat" : (raw == "beach" ? "beach" : "")
        let project = model.editor.projects.first { $0.id == raw }
            ?? model.editor.projects.first { !word.isEmpty && $0.title.contains(word) }
            ?? model.editor.projects.first
        guard let project else { return }
        await launcher.open(project.id, model: model)
    }
    #endif
}

enum EditorWindowID {
    static let editor = "editor"
}

/// iOS: the full-screen cover. The Mac has no cover: its window comes from the `EditorWindow` scene.
private struct EditorCover: ViewModifier {
    let model: AppModel
    let showing: Bool

    func body(content: Content) -> some View {
        #if os(iOS)
        content.fullScreenCover(isPresented: Binding(get: { showing }, set: { _ in })) {
            EditorWindowContent(model: model)
                .cobaltRoot(model: model)
        }
        #else
        content
        #endif
    }
}

/// What the editor window (Mac) or cover (iPhone, iPad) holds: the editor once the session exists, before that the opening
/// screen with its failure.
struct EditorWindowContent: View {
    let model: AppModel

    var body: some View {
        Group {
            if let session = model.editor.session {
                EditorRoot(model: model, session: session)
                    .id(session.project.id)
            } else {
                EditorOpeningView(model: model)
            }
        }
        .background(CobaltColor.bg.ignoresSafeArea())
    }
}

#if os(macOS)
/// The Mac editor: its own window, one at a time (apple/CONTRACT-EDITOR.md decision 6). Not opened at launch; the presenter
/// opens it when a project opens.
struct EditorWindow: Scene {
    let model: AppModel

    var body: some Scene {
        Window(Copy.Editor.title, id: EditorWindowID.editor) {
            EditorWindowContent(model: model)
                .cobaltRoot(model: model)
                .frame(minWidth: 960, minHeight: 640)
        }
        .defaultSize(width: 1280, height: 800)
        .windowResizability(.contentMinSize)
        .defaultLaunchBehavior(.suppressed)
    }
}
#endif
