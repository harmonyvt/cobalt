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
                if on {
                    openWindow(id: EditorWindowID.editor)
                } else {
                    // After this update, so a close and a new open in the same turn cannot be closed by the old one.
                    // `dismissWindow` alone calls `performClose`, which clicks the traffic-light button. That button's
                    // action is the unsaved-changes check and does not close the window, so the scene stays on the
                    // opening skeleton. `NSWindow.close()` is the one that actually takes it down.
                    Task { @MainActor in
                        guard !showing else { return }
                        EditorWindowCloser.closeWindow()
                        dismissWindow(id: EditorWindowID.editor)
                    }
                }
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
        content.fullScreenCover(isPresented: Binding(
            get: { showing },
            set: { presented in
                // The cover is not a swipe-away sheet. If it does dismiss while nothing is open, drop the load too:
                // leaving `.opening` set would make `showing` true and bring the skeleton back.
                if !presented, model.editor.session == nil { EditorLauncher.shared.dismiss() }
            }
        )) {
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

    @Environment(\.dismiss) private var dismiss

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
        .syncGlow(model.library.syncStatus)
        .modifier(EditorLoadWatch(model: model, dismiss: dismiss))
        #if os(macOS)
        .background {
            EditorWindowAnchor {
                // The red button (or Window > Close) while the skeleton is up: there is no session yet, so the guard
                // in `EditorRoot` is not installed. Forget the load or the window comes back to the spinner.
                guard model.editor.session == nil else { return }
                EditorLauncher.shared.dismiss()
            }
        }
        #endif
    }
}

/// The opening clock, and the close when the edit is gone. A session that is on screen is left alone (a finished open
/// is `.idle` too). Both platforms: a load that never answers becomes the failure card. Mac: `NSWindow.close()`.
/// iPhone and iPad: `dismiss()` of the cover, in case the binding did not take it down.
private struct EditorLoadWatch: ViewModifier {
    let model: AppModel
    let dismiss: DismissAction

    private var launcher: EditorLauncher { .shared }

    /// Nothing is open and nothing is loading. The window or cover should go.
    private var shouldClose: Bool {
        guard model.editor.session == nil else { return false }
        if case .dismiss = EditorWindowLoad.presentation(hasSession: false, phase: launcher.state, now: Date()) {
            return true
        }
        return false
    }

    func body(content: Content) -> some View {
        content
            .task(id: launcher.timeoutKey) { await launcher.waitForTimeout() }
            .task(id: shouldClose) {
                guard shouldClose else { return }
                // One turn later, so a session published in this update is visible and we do not close over it.
                await Task.yield()
                guard model.editor.session == nil else { return }
                guard case .idle = launcher.state else { return }
                #if os(macOS)
                EditorWindowCloser.closeWindow()
                #endif
                dismiss()
            }
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
        // A window that was open at quit would otherwise come back with no session and sit on the opening skeleton.
        .restorationBehavior(.disabled)
    }
}
#endif
