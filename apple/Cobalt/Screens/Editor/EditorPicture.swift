import CobaltKit
import SwiftUI

// The touchable picture (apple/CONTRACT-EDITOR.md 15.3).

/// On the canvas: a tap plays or pauses, a pinch sizes the selected overlay about its centre (aspect kept), and while that
/// overlay is on the canvas at the playhead its outline with the drag and the corner handles. Step 4 replaces this with the
/// touchable picture of 15.3.
struct EditorShellCanvasLayer: View {
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
            if session.tool != .crop, let overlay = session.selectedOverlay, EditorPreviewPane.isVisible(overlay, in: session) {
                EditorOverlayHandles(session: session, overlay: overlay, canvasSize: size)
            }
        }
        .frame(width: size.width, height: size.height)
    }

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

