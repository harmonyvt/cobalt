import CobaltKit
import SwiftUI

#if canImport(AppKit)
import AppKit
#endif

/// The open editor: picks the layout, owns the toast, the unsaved-changes alert and the render outcomes (apple/CONTRACT-EDITOR.md
/// 4.2, 4.6). Every layout below it reads the same `EditorHost` from the environment.
///
/// Layout: `EditorScreen` (Mac A) on the Mac, and on iPad when the width is 900 pt or more with a regular size class;
/// `EditorPhoneScreen` (lane 6) otherwise. Resizing across 900 pt switches layouts and keeps the session.
struct EditorRoot: View {
    let model: AppModel
    let session: EditSession

    @State private var host = EditorHost()
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    #else
    @Environment(\.openWindow) private var openWindow
    #endif

    /// The width at which iPad gets the Mac layout.
    static let deskWidth: CGFloat = 900

    var body: some View {
        GeometryReader { geo in
            layout(width: geo.size.width)
        }
        .environment(host)
        .overlay(alignment: .bottom) {
            if let toast = host.toast {
                EditorToastView(toast: toast) { host.dismissToast() }
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
        .motion(Motion.card, value: host.toast?.id)
        .alert(Copy.Editor.closeUnsavedTitle, isPresented: $host.confirmingClose) {
            Button(Copy.Editor.keepEditing, role: .cancel) {}
            Button(Copy.Editor.closeAnyway, role: .destructive) { host.closeAnyway(model) }
        } message: {
            Text(Copy.Editor.closeUnsavedBody)
        }
        .onChange(of: session.activeRender?.status) { old, new in renderChanged(from: old, to: new) }
        .onAppear {
            if let line = EditorLauncher.shared.firstToast {
                EditorLauncher.shared.firstToast = nil
                host.show(line)
            }
        }
        .haptic(.success, trigger: host.doneTick)
        #if os(macOS)
        .background(EditorWindowGuard(
            onCloseButton: { host.requestClose(model) },
            onClosed: {
                // the window went some way other than the red button (Window > Close, quit): flush and close the session;
                // if that cannot be done (unsaved or conflicted edits) keep it and bring the window back
                guard model.editor.session != nil else { return }
                Task {
                    if await model.editor.close() { return }
                    EditorLauncher.shared.firstToast = Copy.Editor.closeUnsavedTitle
                    openWindow(id: EditorWindowID.editor)
                }
            }))
        .navigationTitle(session.project.title)
        #endif
    }

    @ViewBuilder
    private func layout(width: CGFloat) -> some View {
        #if os(macOS)
        EditorScreen(model: model, session: session)
        #else
        if sizeClass == .regular && width >= Self.deskWidth {
            EditorScreen(model: model, session: session)
        } else {
            EditorPhoneScreen(model: model, session: session)
        }
        #endif
    }

    // MARK: render outcomes

    private func renderChanged(from old: EditRender.Status?, to new: EditRender.Status?) {
        guard let old, let new, let render = session.activeRender, Self.isRunning(old) else { return }
        switch new {
        case .done:
            host.noteRenderDone()
            host.show(Copy.Editor.rendered, actionTitle: Copy.Editor.openVideo, seconds: 10) { openRendered(render) }
        case .error:
            host.show(
                Copy.Editor.renderFailed(Copy.Editor.renderReason(render.error)), actionTitle: Copy.Editor.tryAgain, seconds: 10
            ) { session.renderConfirmRequested = true }
        case .queued, .preparing, .rendering, .finishing, .cancelled:
            break
        }
    }

    private static func isRunning(_ status: EditRender.Status) -> Bool {
        switch status {
        case .queued, .preparing, .rendering, .finishing: return true
        case .done, .error, .cancelled: return false
        }
    }

    /// `open` on the `rendered` toast: the video's detail in the library (the queue's own destination). The iPhone and iPad
    /// close the editor first; on the Mac the main window comes forward.
    private func openRendered(_ render: EditRender) {
        guard let item = render.itemID else { return }
        let show = {
            model.selectedTab = .save
            model.requestedMediaID = "post:\(item)"
        }
        #if os(iOS)
        Task {
            if await model.editor.close() { show() } else { host.confirmingClose = true }
        }
        #else
        show()
        openWindow(id: "main")
        #endif
    }
}

// MARK: - the opening screen

/// Before the session exists: a skeleton of the editor while `GET /edits/<id>` answers, and the failure with `try again` and
/// `close` (apple/CONTRACT-EDITOR.md 4.7).
struct EditorOpeningView: View {
    let model: AppModel

    private var launcher: EditorLauncher { .shared }

    var body: some View {
        VStack(spacing: 0) {
            skeletonBar
            Spacer(minLength: 0)
            content
            Spacer(minLength: 0)
            skeletonTimeline
        }
        .background(EditorColor.panel)
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private var content: some View {
        switch launcher.state {
        case .failed(_, let error):
            VStack(spacing: 14) {
                Image(systemName: Symbol.Editor.missing)
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(CobaltColor.caption)
                Text(Copy.Editor.couldntOpen)
                    .font(CobaltType.bodyMedium)
                    .foregroundStyle(CobaltColor.text)
                Text(Copy.Editor.errorLine(error))
                    .font(CobaltType.caption)
                    .foregroundStyle(CobaltColor.caption)
                    .multilineTextAlignment(.center)
                ButtonRow {
                    Button(Copy.Editor.tryAgain, systemImage: Symbol.Editor.retry) { Task { await launcher.retry(model: model) } }
                        .buttonStyle(.cobaltPrimary(fullWidth: false, compact: true))
                    Button(Copy.Editor.close, systemImage: Symbol.Editor.close) { launcher.dismiss() }
                        .buttonStyle(.cobaltSecondary(fullWidth: false, compact: true))
                }
                .frame(maxWidth: 360)
            }
            .padding(24)
        default:
            VStack(spacing: 12) {
                ProgressView()
                Text(Copy.Editor.openingProject)
                    .font(CobaltType.caption)
                    .foregroundStyle(CobaltColor.caption)
            }
            .accessibilityElement(children: .combine)
        }
    }

    private var skeletonBar: some View {
        HStack {
            RoundedRectangle(cornerRadius: 5).fill(EditorColor.field).frame(width: 140, height: 14)
            Spacer()
            #if os(iOS)
            if case .opening = launcher.state {
                Button(Copy.Editor.close, systemImage: Symbol.Editor.close) { launcher.dismiss() }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.cobaltSecondary(fullWidth: false, compact: true))
            }
            #endif
        }
        .padding(.horizontal, 14)
        .frame(height: 48)
        .background(EditorColor.bar)
    }

    private var skeletonTimeline: some View {
        VStack(spacing: 8) {
            ForEach(0..<3, id: \.self) { _ in
                RoundedRectangle(cornerRadius: 6).fill(EditorColor.field).frame(height: 36)
            }
        }
        .padding(14)
        .frame(height: 160)
        .background(EditorColor.lane)
        .opacity(0.8)
        .accessibilityHidden(true)
    }
}

#if os(macOS)
// MARK: - the window's close

/// The editor window's red button must ask first (`editor.close()` flushes the autosave and may refuse): this puts its action
/// in our hands. ⌘W is a shortcut on the editor itself. If the window goes some other way, `onClosed` makes sure no session is
/// left behind.
private struct EditorWindowGuard: NSViewRepresentable {
    let onCloseButton: @MainActor () -> Void
    let onClosed: @MainActor () -> Void

    func makeNSView(context: Context) -> Probe {
        let view = Probe()
        view.onCloseButton = onCloseButton
        view.onClosed = onClosed
        return view
    }

    func updateNSView(_ view: Probe, context: Context) {
        view.onCloseButton = onCloseButton
        view.onClosed = onClosed
    }

    final class Probe: NSView {
        var onCloseButton: (@MainActor () -> Void)?
        var onClosed: (@MainActor () -> Void)?
        private var observer: (any NSObjectProtocol)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            if let button = window.standardWindowButton(.closeButton) {
                button.target = self
                button.action = #selector(closeClicked)
            }
            if let observer { NotificationCenter.default.removeObserver(observer) }
            observer = NotificationCenter.default.addObserver(
                forName: NSWindow.willCloseNotification, object: window, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.windowClosed() }
            }
        }

        private func windowClosed() {
            if let observer { NotificationCenter.default.removeObserver(observer) }
            observer = nil
            onClosed?()
        }

        @objc private func closeClicked() {
            MainActor.assumeIsolated { onCloseButton?() }
        }
    }
}
#endif
