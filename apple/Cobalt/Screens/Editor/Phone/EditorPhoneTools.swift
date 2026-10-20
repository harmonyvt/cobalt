#if os(iOS)
import CobaltKit
import SwiftUI

/// The tool tray (apple/CONTRACT-EDITOR.md 4.4): `trim` `split` `crop` `speed` `overlay` `volume`, icon over label, 56 pt.
/// `trim`, `crop` and `speed` open the clip sheet on that section; `split` cuts at the playhead; `overlay` opens the overlay
/// sheet (or the add sheet in overlay mode when none is selected); `volume` opens the small volume sheet. A tool that needs a
/// main clip takes the one under the playhead when nothing is selected.
struct EditorPhoneToolTray: View {
    let session: EditSession
    let open: (EditorPhoneSheet) -> Void

    @Environment(EditorHost.self) private var host
    @State private var splitTick = 0

    /// A main clip is selected, or one is under the playhead.
    private var hasClip: Bool { session.selectedMain != nil || session.clipUnderPlayhead != nil }

    private var splitReady: Bool {
        if case .overlay = session.selection { return false }
        return session.canSplitAtPlayhead
    }

    var body: some View {
        HStack(spacing: 0) {
            ToolButton(title: Copy.Editor.toolTrim, symbol: Symbol.Editor.trim, enabled: hasClip) { openClip(.trim) }
            ToolButton(title: Copy.Editor.toolSplit, symbol: Symbol.Editor.split, enabled: splitReady, hint: Copy.Editor.nothingToSplit) { split() }
            ToolButton(title: Copy.Editor.toolCrop, symbol: Symbol.Editor.toolCrop, enabled: hasClip) { openClip(.crop) }
            ToolButton(title: Copy.Editor.toolSpeed, symbol: Symbol.Editor.speed, enabled: hasClip) { openClip(.speed) }
            ToolButton(title: Copy.Editor.toolOverlay, symbol: Symbol.Editor.overlay, enabled: true) { openOverlay() }
            ToolButton(title: Copy.Editor.toolVolume, symbol: Symbol.Editor.volume, enabled: hasClip || session.selectedOverlay != nil) {
                openVolume()
            }
        }
        .padding(.horizontal, 6)
        .padding(.top, 8)
        .padding(.bottom, 2)
        .modifier(EditorPhoneSplitHaptic(tick: splitTick))
        .accessibilityElement(children: .contain)
    }

    // MARK: actions

    /// Selects the clip under the playhead when no main clip is selected. False when there is none.
    private func ensureClip() -> Bool {
        if session.selectedMain != nil { return true }
        guard let hit = session.clipUnderPlayhead else { return false }
        session.selection = .main(hit.clip.id)
        return true
    }

    private func openClip(_ section: EditorPhoneClipSection) {
        guard ensureClip() else { return }
        open(.clip(section))
    }

    private func split() {
        guard splitReady else {
            host.show(Copy.Editor.nothingToSplit)
            return
        }
        session.splitAtPlayhead()
        splitTick += 1
    }

    private func openOverlay() {
        if session.selectedOverlay != nil {
            open(.overlay)
        } else {
            open(.add(.overlay))
        }
    }

    private func openVolume() {
        if session.selectedOverlay == nil, !ensureClip() { return }
        open(.volume)
    }
}

/// One tool: the icon over its word, 56 pt tall. A tool that cannot be used is dimmed; one with a `hint` (split) still
/// answers a tap with that line.
private struct ToolButton: View {
    let title: String
    let symbol: String
    let enabled: Bool
    var hint: String?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: symbol)
                    .font(.system(size: 19, weight: .regular))
                    .frame(height: 22)
                Text(title)
                    .font(Font.cobalt(10.5, .regular, relativeTo: .caption2))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .foregroundStyle(CobaltColor.text)
            .frame(maxWidth: .infinity, minHeight: 56)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(enabled ? 1 : 0.4)
        .disabled(!enabled && hint == nil)
        .accessibilityLabel(title)
        .accessibilityHint(enabled ? "" : (hint ?? ""))
    }
}

private struct EditorPhoneSplitHaptic: ViewModifier {
    let tick: Int

    func body(content: Content) -> some View {
        content.haptic(.impact(weight: .light), trigger: tick)
    }
}

// MARK: - volume

/// `volume`: a slider and the mute button for the selected clip (or the selected overlay, when it is a video), and `done`.
struct EditorPhoneVolumeSheet: View {
    let session: EditSession

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text(Copy.Editor.volume)
                    .font(CobaltType.sheetTitle)
                    .foregroundStyle(CobaltColor.text)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 8)
                Button(Copy.Editor.done) { dismiss() }
                    .buttonStyle(.cobaltPrimary(fullWidth: false, compact: true))
            }
            row
            Spacer(minLength: 0)
        }
        .padding(Metrics.gutter)
        .padding(.top, 6)
    }

    @ViewBuilder
    private var row: some View {
        if let overlay = session.selectedOverlay {
            EditorVolumeRow(
                volume: overlay.volume, muted: overlay.muted,
                setVolume: { session.setOverlayVolume(id: overlay.id, $0) },
                setMuted: { session.setOverlayMuted(id: overlay.id, $0) },
                onEnd: { session.endGesture() },
                silent: session.source(for: overlay.item)?.kind != .video)
        } else if let selected = session.selectedMain {
            EditorVolumeRow(
                volume: selected.clip.volume, muted: selected.clip.muted,
                setVolume: { session.setVolume($0, clip: selected.clip.id) },
                setMuted: { session.setMuted($0, clip: selected.clip.id) },
                onEnd: { session.endGesture() })
        }
    }
}
#endif
