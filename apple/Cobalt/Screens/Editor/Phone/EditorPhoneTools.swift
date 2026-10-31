#if os(iOS)
import CobaltKit
import SwiftUI

/// The tool tray (apple/CONTRACT-EDITOR.md 4.4): `trim` `split` `crop` `speed` `overlay` `volume`, icons (hold one
/// for its name), 56 pt.
/// `trim`, `crop` and `speed` open the clip sheet on that section; `split` cuts at the playhead; `overlay` opens the overlay
/// sheet (or the add sheet in overlay mode when none is selected); `volume` opens the small volume sheet. A tool that needs a
/// main clip takes the one under the playhead when nothing is selected.
struct EditorPhoneToolTray: View {
    let session: EditSession
    let open: (EditorPhoneSheet) -> Void

    @Environment(EditorHost.self) private var host
    @State private var splitTick = 0
    /// The playhead as the buttons see it, set by `EditorPlayheadSpotReader` when it changes (nil until the first report: the
    /// body then reads the session once).
    @State private var spot: EditorPlayheadSpot?

    private var currentSpot: EditorPlayheadSpot { spot ?? EditorPlayheadSpot(session) }

    /// A main clip is selected, or one is under the playhead.
    private var hasClip: Bool { session.selectedMain != nil || currentSpot.clipID != nil }

    private var splitReady: Bool {
        if case .overlay = session.selection { return false }
        return currentSpot.canSplit
    }

    var body: some View {
        GlassEffectContainer(spacing: 6) { tools }
            .padding(.horizontal, 6)
            .padding(.top, 8)
            .padding(.bottom, 2)
            .modifier(EditorPhoneSplitHaptic(tick: splitTick))
            .background { EditorPlayheadSpotReader(session: session) { spot = $0 } }
            .accessibilityElement(children: .contain)
    }

    private var tools: some View {
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
        let ready: Bool
        if case .overlay = session.selection { ready = false } else { ready = session.canSplitAtPlayhead }   // live, not `spot`
        guard ready else {
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

/// One tool: a `.cobaltIcon()` circle whose word shows on a long press (and comes back beside it at accessibility text sizes).
/// A tool that cannot be used is dimmed; one with a `hint` (split) stays tappable, dimmed, and answers a tap with that line.
private struct ToolButton: View {
    let title: String
    let symbol: String
    let enabled: Bool
    var hint: String?
    let action: () -> Void

    var body: some View {
        Button(action: action) { Label(title, systemImage: symbol) }
            .buttonStyle(.cobaltIcon())
            .disabled(!enabled && hint == nil)
            // the style dims a disabled button itself; a tool kept tappable for its hint is dimmed here
            .opacity(!enabled && hint != nil ? 0.45 : 1)
            .frame(maxWidth: .infinity, minHeight: 56)
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
