#if os(iOS)
import CobaltKit
import SwiftUI

/// The canvas of the iPhone editor (apple/CONTRACT-EDITOR.md 4.4): canvas-shaped, as large as the room between the header and
/// the timeline allows (360 pt on a 390 × 844 screen). A tap plays or pauses. With an overlay selected, drag it to move and
/// pinch to resize; the session clamps every frame inside the canvas.
struct EditorPhonePreview: View {
    let session: EditSession

    var body: some View {
        EditorCanvasView(session: session) { size in
            EditorPhoneCanvasLayer(session: session, size: size)
        }
        .padding(.horizontal, Metrics.gutter)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Copy.Editor.previewA11y)
    }
}

/// What sits on the canvas: a tap target for play and pause, a pinch for the selected overlay's size, and (while that overlay
/// is on the canvas at the playhead) its outline with the drag to move.
private struct EditorPhoneCanvasLayer: View {
    let session: EditSession
    let size: CGSize

    @State private var pinchStart: EditFrame?

    var body: some View {
        ZStack {
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture { session.togglePlay() }
                .gesture(pinch)
                .accessibilityHidden(true)
            overlayHandles
        }
        .frame(width: size.width, height: size.height)
    }

    @ViewBuilder
    private var overlayHandles: some View {
        if let overlay = session.selectedOverlay, EditorPreviewPane.isVisible(overlay, in: session) {
            EditorOverlayHandles(session: session, overlay: overlay, canvasSize: size)
        }
    }

    /// The pinch scales the overlay about its centre, aspect kept.
    private var pinch: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                guard let overlay = session.selectedOverlay else { return }
                let first = pinchStart ?? overlay.frame
                pinchStart = first
                session.setOverlayFrame(id: overlay.id, scaled(first, by: Double(value.magnification), overlay: overlay))
            }
            .onEnded { _ in
                pinchStart = nil
                session.endGesture()
            }
    }

    private func scaled(_ first: EditFrame, by factor: Double, overlay: EditOverlay) -> EditFrame {
        let canvas = session.timeline.canvas
        let display = session.source(for: overlay.item)?.display ?? PixelSize(w: 16, h: 9)
        let h0 = EditGeometry.overlayHeightFraction(display: display, frame: first, canvas: canvas)
        let w = min(1, max(0.05, first.w * factor))
        let h = h0 * w / max(0.001, first.w)
        let centerX = first.x + first.w / 2
        let centerY = first.y + h0 / 2
        return EditFrame(x: centerX - w / 2, y: centerY - h / 2, w: w)
    }
}

// MARK: - transport

/// `0:09.0 / 0:26.0`, play and pause, and the hint `pinch to zoom` (until the first pinch, then never again).
struct EditorPhoneTransport: View {
    let session: EditSession

    @AppStorage("editor.pinchHintSeen") private var pinchSeen = false

    var body: some View {
        HStack(spacing: 8) {
            Text("\(Copy.Editor.clockTenths(session.playheadSeconds)) / \(Copy.Editor.clockTenths(session.timing.seconds))")
                .font(Font.cobalt(11, .regular, relativeTo: .caption2))
                .foregroundStyle(CobaltColor.caption)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Copy.Editor.transportTime)
                .accessibilityValue(Copy.Editor.a11yPlayheadValue(
                    Copy.Editor.clockTenths(session.playheadSeconds), of: Copy.Editor.clockTenths(session.timing.seconds)))
            playButton
            hint
        }
        .padding(.horizontal, 18)
        .padding(.bottom, 2)
    }

    private var playButton: some View {
        Button { session.togglePlay() } label: {
            Label(
                session.isPlaying ? Copy.Editor.pause : Copy.Editor.play,
                systemImage: session.isPlaying ? Symbol.Editor.pause : Symbol.Editor.play)
        }
        .buttonStyle(.cobaltIcon(.small, prominent: true))
        .disabled(!session.isPlayerReady)
    }

    @ViewBuilder
    private var hint: some View {
        Text(pinchSeen ? "" : Copy.Editor.pinchToZoom)
            .font(Font.cobalt(11, .regular, relativeTo: .caption2))
            .foregroundStyle(CobaltColor.caption)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .frame(maxWidth: .infinity, alignment: .trailing)
            .motion(Motion.copy, value: pinchSeen)
            .accessibilityHidden(pinchSeen)
    }
}
#endif
