import CobaltKit
import SwiftUI

/// The `render` button of the top bar. At rest it says `render`; while a render of this project runs it carries the progress
/// (`waiting · 1 ahead`, `preparing`, `rendering 40%`, `finishing`) and opens the same popover.
struct RenderButton: View {
    let model: AppModel
    let session: EditSession
    @Binding var shown: Bool

    private var running: EditRender? {
        guard let r = session.activeRender, r.isActive else { return nil }
        return r
    }

    var body: some View {
        Button { shown = true } label: {
            HStack(spacing: 6) {
                if let running {
                    ProgressView(value: running.progress.map { min(1, max(0, $0)) })
                        .progressViewStyle(.circular)
                        .controlSize(.small)
                    Text(Copy.Editor.renderLine(running))
                        .monospacedDigit()
                } else {
                    Text(Copy.Editor.render)
                }
            }
            .lineLimit(1)
            .fixedSize()
        }
        .buttonStyle(.cobaltPrimary(fullWidth: false, compact: true))
        .help("\(Copy.Editor.render) · ⌘↩")
        .accessibilityLabel(running.map { "\(Copy.Editor.render), \(Copy.Editor.renderLine($0))" } ?? Copy.Editor.render)
        .popover(isPresented: $shown, arrowEdge: .bottom) {
            EditorRenderCard(model: model, session: session, close: { shown = false })
                #if os(iOS)
                .presentationCompactAdaptation(.popover)
                #endif
        }
    }
}

/// The popover (Mac, iPad) and the iPhone's sheet content: before a render, the confirm card (`renderTitle`, the summary,
/// `renderNote`, `render` / `cancel`, disabled with the first problem's words or `renderOffline`); once one runs, its progress
/// and `cancel render`; if the edit changed since it started, `renderingOlder`.
struct EditorRenderCard: View {
    let model: AppModel
    let session: EditSession
    let close: () -> Void

    @Environment(EditorHost.self) private var host
    @State private var starting = false
    @State private var confirmingCancel = false
    @State private var failure: String?

    private var running: EditRender? {
        guard let r = session.activeRender, r.isActive else { return nil }
        return r
    }

    /// Why `render` is off right now, in words.
    private var blocker: String? {
        if session.hasMissingSources { return Copy.Editor.removeMissing }
        if let line = session.problemLine { return line }
        if case .failed(let error) = session.saveState, error == .offline { return Copy.Editor.renderOffline }
        if case .conflict = session.saveState { return Copy.Editor.conflictTitle }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let running { progress(running) } else { confirm }
        }
        .padding(16)
        .frame(width: 300, alignment: .leading)
    }

    // MARK: before a render

    @ViewBuilder
    private var confirm: some View {
        Text(Copy.Editor.renderTitle)
            .font(CobaltType.bodySemibold)
            .foregroundStyle(CobaltColor.text)
        let canvas = session.timeline.canvas
        Text(Copy.Editor.renderSummary(w: canvas.w, h: canvas.h, fps: canvas.fps, duration: Copy.Editor.clock(session.timing.seconds)))
            .font(CobaltType.caption)
            .foregroundStyle(CobaltColor.text)
            .monospacedDigit()
        Text(Copy.Editor.renderNote)
            .font(CobaltType.captionSmall)
            .foregroundStyle(CobaltColor.caption)
            .fixedSize(horizontal: false, vertical: true)
        if let line = failure ?? blocker {
            Text(line)
                .font(CobaltType.captionSmall)
                .foregroundStyle(CobaltColor.errorText)
                .fixedSize(horizontal: false, vertical: true)
        }
        ButtonRow {
            Button(Copy.Editor.render, systemImage: Symbol.Editor.render) { start() }
                .buttonStyle(.cobaltPrimary(compact: true))
                .disabled(blocker != nil || starting)
                .keyboardShortcut(.defaultAction)
            Button(Copy.Editor.cancel) { close() }
                .buttonStyle(.cobaltSecondary(compact: true))
                .keyboardShortcut(.cancelAction)
        }
    }

    private func start() {
        failure = nil
        starting = true
        Task {
            defer { starting = false }
            do {
                _ = try await session.render()
                close()
            } catch {
                failure = Copy.Editor.errorLine(EditError.from(error))
            }
        }
    }

    // MARK: while it runs

    @ViewBuilder
    private func progress(_ render: EditRender) -> some View {
        Text(Copy.Editor.renderTitle)
            .font(CobaltType.bodySemibold)
            .foregroundStyle(CobaltColor.text)
        Text(Copy.Editor.renderLine(render))
            .font(CobaltType.caption)
            .foregroundStyle(CobaltColor.text)
            .monospacedDigit()
            .contentTransition(.opacity)
        StoryBar(fraction: render.status == .rendering ? render.progress : nil, height: 4)
        if render.revision < session.project.revision {
            Text(Copy.Editor.renderingOlder)
                .font(CobaltType.captionSmall)
                .foregroundStyle(CobaltColor.caption)
        }
        Text(Copy.Editor.renderNote)
            .font(CobaltType.captionSmall)
            .foregroundStyle(CobaltColor.caption)
            .fixedSize(horizontal: false, vertical: true)
        if confirmingCancel {
            Text(Copy.Editor.cancelRenderTitle)
                .font(CobaltType.bodyMedium)
                .foregroundStyle(CobaltColor.text)
            ButtonRow {
                Button(Copy.Editor.cancelRender, role: .destructive) {
                    confirmingCancel = false
                    cancelRender()
                }
                .buttonStyle(.cobaltSecondary(compact: true))
                Button(Copy.Editor.keepRendering) { confirmingCancel = false }
                    .buttonStyle(.cobaltPrimary(compact: true))
            }
        } else {
            ButtonRow {
                Button(Copy.Editor.cancelRender, role: .destructive) { confirmingCancel = true }
                    .buttonStyle(.cobaltSecondary(compact: true))
                Button(Copy.Editor.done) { close() }
                    .buttonStyle(.cobaltPrimary(compact: true))
            }
        }
    }

    private func cancelRender() {
        guard let id = running?.id else { return }
        Task {
            do {
                try await model.editor.cancel(render: id)
            } catch {
                host.show(Copy.Editor.errorLine(EditError.from(error)))
            }
        }
    }
}
