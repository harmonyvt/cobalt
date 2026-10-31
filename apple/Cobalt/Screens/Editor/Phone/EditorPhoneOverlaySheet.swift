#if os(iOS)
import CobaltKit
import SwiftUI

/// The overlay sheet (apple/CONTRACT-EDITOR.md 4.5): `overlay` · `done` · the close (cancel) top right; how long it stays up (a stepper and a
/// slider, 0.1 s to the room it has), its size and opacity, its volume (a video only), and `delete overlay`. Where it sits is
/// set by dragging on the preview above, which stays in view at the medium height. `cancel` puts the overlay back as it was.
struct EditorPhoneOverlaySheet: View {
    let session: EditSession
    var pitchEnabled = true

    @Environment(\.dismiss) private var dismiss
    @State private var original: EditOverlay?
    @State private var overlayID: String
    @State private var cutoutOf: EditSource?

    init(session: EditSession, pitchEnabled: Bool = true) {
        self.session = session
        self.pitchEnabled = pitchEnabled
        let overlay = session.selectedOverlay
        _original = State(initialValue: overlay)
        _overlayID = State(initialValue: overlay?.id ?? "")
    }

    private var overlay: EditOverlay? { session.timeline.overlay.first { $0.id == overlayID } }

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if let overlay {
                        EditorOverlayLayerRows(session: session, overlay: overlay) {
                            cutoutOf = session.source(for: overlay.item)
                        }
                        lengthSection(overlay)
                        sizeSection(overlay)
                        opacitySection(overlay)
                        volumeSection(overlay)
                        if pitchEnabled && session.source(for: overlay.item)?.kind == .video { pitchSection(overlay) }
                        IconRow(alignment: .leading) {
                            EditorInspectorButton(title: Copy.Editor.deleteOverlay, symbol: Symbol.Editor.delete, destructive: true) {
                                session.remove(.overlay(overlay.id))
                                dismiss()
                            }
                        }
                    }
                }
                .padding(.horizontal, Metrics.gutter)
                .padding(.top, 8)
                .padding(.bottom, 28)
            }
            .scrollIndicators(.hidden)
        }
        .background(CobaltColor.surface.ignoresSafeArea())
        .sheet(item: $cutoutOf) { picture in
            EditorCutoutSheet(session: session, source: picture, replacing: overlayID) { cutoutOf = nil }
                .presentationDetents([.large])
        }
    }

    // MARK: header

    private var header: some View {
        HStack(spacing: 8) {
            Text(Copy.Editor.overlay)
                .font(Font.cobalt(12.5, .semibold, relativeTo: .subheadline))
                .foregroundStyle(CobaltColor.text)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityAddTraits(.isHeader)
            Button(Copy.Editor.done) { dismiss() }
                .buttonStyle(.cobaltPrimary(fullWidth: false, compact: true))
            CloseButton(cancels: true) { cancel() }     // cancel is the sheet's close, top right
        }
        .padding(.horizontal, Metrics.gutter)
        .padding(.top, 14)
        .padding(.bottom, 8)
    }

    private func cancel() {
        defer { dismiss() }
        guard let original, let now = overlay else { return }
        if now.out != original.out { session.setOverlayLength(id: original.id, seconds: original.length) }
        if now.frame != original.frame { session.setOverlayFrame(id: original.id, original.frame) }
        if now.opacity != original.opacity { session.setOverlayOpacity(id: original.id, original.opacity) }
        if now.volume != original.volume { session.setOverlayVolume(id: original.id, original.volume) }
        if now.pitch != original.pitch { session.setOverlayPitch(original.pitch, overlay: original.id) }
        if now.muted != original.muted { session.setOverlayMuted(id: original.id, original.muted) }
        if now.track != original.track { session.setOverlayTrack(id: original.id, original.track) }
        session.endGesture()
    }

    // MARK: length

    /// The longest it can stay up from where it starts: the rest of the edit, and for a video the rest of the file.
    private func longest(_ overlay: EditOverlay) -> Double {
        var most = max(0.1, session.timing.seconds - overlay.at)
        if let source = session.source(for: overlay.item), source.kind == .video, let duration = source.duration {
            most = min(most, max(0.1, duration - overlay.in))
        }
        return max(0.2, most)
    }

    private func lengthSection(_ overlay: EditOverlay) -> some View {
        let most = longest(overlay)
        return EditorSection(Copy.Editor.length, trailing: Copy.Editor.clockTenths(overlay.length)) {
            HStack(spacing: 6) {
                stepButton("minus", Copy.Editor.lengthShorter) { setLength(overlay.length - 0.1) }
                Slider(
                    value: Binding(get: { min(most, max(0.1, overlay.length)) }, set: { setLength($0) }),
                    in: 0.1...most, step: 0.1
                ) { editing in
                    if !editing { session.endGesture() }
                }
                .accessibilityLabel(Copy.Editor.length)
                .accessibilityValue(Copy.Editor.clockTenths(overlay.length))
                stepButton("plus", Copy.Editor.lengthLonger) { setLength(overlay.length + 0.1) }
            }
        }
    }

    private func setLength(_ seconds: Double) {
        session.setOverlayLength(id: overlayID, seconds: seconds)
        session.endGesture()
    }

    /// VoiceOver adjusts the slider instead, so these stay hidden from it; the name is the long press's tag.
    private func stepButton(_ symbol: String, _ name: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Label(name, systemImage: symbol) }
            .buttonStyle(.cobaltIcon(.small))
            .accessibilityHidden(true)
    }

    // MARK: size, opacity, volume

    private func sizeSection(_ overlay: EditOverlay) -> some View {
        EditorSection(Copy.Editor.size, trailing: "\(Int((overlay.frame.w * 100).rounded()))%") {
            EditorSlider(
                value: Binding(
                    get: { overlay.frame.w },
                    set: { session.setOverlayFrame(id: overlay.id, EditFrame(x: overlay.frame.x, y: overlay.frame.y, w: $0)) }),
                range: 0.05...1, step: 0.01, label: Copy.Editor.size, onEnd: { session.endGesture() })
        }
    }

    private func opacitySection(_ overlay: EditOverlay) -> some View {
        EditorSection(Copy.Editor.opacity, trailing: "\(Int((overlay.opacity * 100).rounded()))%") {
            EditorSlider(
                value: Binding(get: { overlay.opacity }, set: { session.setOverlayOpacity(id: overlay.id, $0) }),
                range: 0.1...1, step: 0.01, label: Copy.Editor.opacity, onEnd: { session.endGesture() })
        }
    }

    private func pitchSection(_ overlay: EditOverlay) -> some View {
        EditorSection(Copy.Editor.pitch, trailing: Copy.Editor.pitchValue(overlay.pitch)) {
            EditorPitchRow(
                pitch: overlay.pitch,
                set: { session.setOverlayPitch($0, overlay: overlay.id) }, onEnd: { session.endGesture() })
        }
    }

    private func volumeSection(_ overlay: EditOverlay) -> some View {
        EditorSection(Copy.Editor.volume) {
            EditorVolumeRow(
                volume: overlay.volume, muted: overlay.muted,
                setVolume: { session.setOverlayVolume(id: overlay.id, $0) },
                setMuted: { session.setOverlayMuted(id: overlay.id, $0) },
                onEnd: { session.endGesture() },
                silent: session.source(for: overlay.item)?.kind != .video)
        }
    }
}
#endif
