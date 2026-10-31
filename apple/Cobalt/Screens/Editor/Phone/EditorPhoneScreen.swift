#if os(iOS)
import CobaltKit
import SwiftUI

/// Which sheet the iPhone editor has up (apple/CONTRACT-EDITOR.md 4.4 to 4.6).
enum EditorPhoneSheet: Identifiable, Equatable {
    case clip(EditorPhoneClipSection)
    case overlay
    case volume
    case add(EditorPhoneAddMode)
    case render

    var id: String {
        switch self {
        case .clip(let section): return "clip-\(section.rawValue)"
        case .overlay: return "overlay"
        case .volume: return "volume"
        case .add(let mode): return "add-\(mode.rawValue)"
        case .render: return "render"
        }
    }
}

/// Where the clip sheet scrolls to when it opens.
enum EditorPhoneClipSection: String, Equatable {
    case trim, crop, speed
}

/// What the add sheet puts the picked file on.
enum EditorPhoneAddMode: String, Equatable {
    case main, overlay
}

/// The iPhone (and narrow iPad) editor, the approved board "iPhone A" (apple/CONTRACT-EDITOR.md 4.4): close, undo, redo, the
/// title and `render` on top; the canvas with the transport under it; a 150 pt timeline whose playhead is fixed at the centre
/// while the clips scroll under it; and a tray of six tools. The tools open sheets (4.5) and the render card (4.6).
///
/// `EditorRoot` provides the `EditorHost` (toast, close, unsaved alert) and the opening and failed screens.
struct EditorPhoneScreen: View {
    let model: AppModel
    let session: EditSession

    @Environment(EditorHost.self) private var host
    @State private var sheet: EditorPhoneSheet?
    @State private var scale = TimelineScale.standard

    var body: some View {
        VStack(spacing: 0) {
            EditorPhoneHeader(model: model, session: session, openRender: { sheet = .render })
            conflictBanner
            EditorPhonePreview(session: session)
            EditorPhoneProblemStrip(session: session)
            EditorPhoneTransport(session: session)
            EditorPhoneTimeline(session: session, scale: $scale, openAdd: { sheet = .add(.main) })
            EditorPhoneToolTray(session: session, open: { sheet = $0 })
        }
        .background(CobaltColor.bg.ignoresSafeArea())
        .sheet(item: $sheet) { current in
            EditorPhoneSheetContent(model: model, session: session, sheet: current, close: { sheet = nil })
                .environment(host)
                .cobaltRoot(model: model)
        }
        .onChange(of: session.renderConfirmRequested, initial: true) { _, requested in
            guard requested else { return }
            session.renderConfirmRequested = false
            sheet = .render
        }
        .modifier(EditorPhoneHaptics(session: session))
        .motion(Motion.card, value: session.saveState == .saved)
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private var conflictBanner: some View {
        if case .conflict = session.saveState {
            EditorPhoneConflictBanner(session: session)
                .transition(.opacity)
        }
    }
}

/// The selection tick (Settings › haptics), kept in its own modifier so the screen's body stays easy to type-check.
private struct EditorPhoneHaptics: ViewModifier {
    let session: EditSession

    func body(content: Content) -> some View {
        content.haptic(.selection, trigger: session.selection)
    }
}

/// The sheets, one view so the screen's body has a single closure to build.
private struct EditorPhoneSheetContent: View {
    let model: AppModel
    let session: EditSession
    let sheet: EditorPhoneSheet
    let close: () -> Void

    var body: some View {
        switch sheet {
        case .clip(let section):
            EditorPhoneClipSheet(session: session, section: section, pitchEnabled: model.capabilities.limits.editPitch)
                .presentationDetents([.large])
                .presentationDragIndicator(.hidden)
                .interactiveDismissDisabled()
        case .overlay:
            EditorPhoneOverlaySheet(session: session, pitchEnabled: model.capabilities.limits.editPitch)
                .presentationDetents([.medium, .large])
                .presentationBackgroundInteraction(.enabled(upThrough: .medium))
                .interactiveDismissDisabled()
        case .volume:
            EditorPhoneVolumeSheet(session: session)
                .presentationDetents([.height(210), .medium])
        case .add(let mode):
            EditorPhoneAddSheet(model: model, session: session, mode: mode)
                .presentationDetents([.medium, .large])
        case .render:
            EditorPhoneRenderSheet(model: model, session: session, close: close)
                .presentationDetents([.medium])
        }
    }
}

/// `conflictTitle` / `conflictBody` with `useTheirs` and `keepMine`, stacked for a phone's width.
struct EditorPhoneConflictBanner: View {
    let session: EditSession

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: Symbol.Editor.missing)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(CobaltColor.errorText)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(Copy.Editor.conflictTitle)
                        .font(CobaltType.bodyMedium)
                        .foregroundStyle(CobaltColor.text)
                    Text(Copy.Editor.conflictBody)
                        .font(CobaltType.captionSmall)
                        .foregroundStyle(CobaltColor.caption)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            ButtonRow {
                Button(Copy.Editor.useTheirs) { Task { await session.resolveConflict(keepMine: false) } }
                    .buttonStyle(.cobaltSecondary(compact: true))
                Button(Copy.Editor.keepMine) { Task { await session.resolveConflict(keepMine: true) } }
                    .buttonStyle(.cobaltPrimary(compact: true))
            }
        }
        .padding(.horizontal, Metrics.gutter)
        .padding(.vertical, 10)
        .background(CobaltColor.error.opacity(0.12))
        .accessibilityElement(children: .contain)
    }
}

/// The line under the transport when something stops a render: a file that would not come (a `try again` icon), a deleted file
/// (`removeMissing`). Silent when all is well.
struct EditorPhoneProblemStrip: View {
    let session: EditSession

    var body: some View {
        if !session.sourceFailures.isEmpty {
            HStack(spacing: 8) {
                Image(systemName: Symbol.Editor.missing)
                    .accessibilityHidden(true)
                Text(Copy.Editor.sourceFailed)
                Spacer(minLength: 8)
                Button { retryAll() } label: { Label(Copy.Editor.tryAgain, systemImage: Symbol.Editor.retry) }
                    .buttonStyle(.cobaltIcon(.small, tint: CobaltColor.linkBlue))
            }
            .font(CobaltType.captionSmall)
            .foregroundStyle(CobaltColor.errorText)
            .padding(.horizontal, Metrics.gutter)
        } else if session.hasMissingSources {
            Label(Copy.Editor.removeMissing, systemImage: Symbol.Editor.missing)
                .font(CobaltType.captionSmall)
                .foregroundStyle(CobaltColor.errorText)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, Metrics.gutter)
                .padding(.vertical, 4)
        }
    }

    private func retryAll() {
        for item in session.sourceFailures.keys { session.retrySource(item) }
    }
}
#endif
