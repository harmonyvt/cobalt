import CobaltKit
import SwiftUI

/// The middle of the Mac and iPad screen (apple/CONTRACT-EDITOR.md 4.3): the canvas at its aspect as large as fits, black
/// around it, with the transport under it. With the select tool an overlay under the playhead can be dragged and resized
/// on the canvas; with the crop tool and a main clip selected the canvas gives way to that clip's source and its crop frame.
struct EditorPreviewPane: View {
    let session: EditSession

    var body: some View {
        VStack(spacing: 12) {
            stage
            EditorTransport(session: session)
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Copy.Editor.previewA11y)
    }

    @ViewBuilder
    private var stage: some View {
        if session.tool == .crop, let (_, clip) = session.selectedMain {
            EditorCropStage(session: session, clip: clip)
        } else {
            EditorCanvasView(session: session) { size in
                if session.tool != .crop, let overlay = session.selectedOverlay, Self.isVisible(overlay, in: session) {
                    EditorOverlayHandles(session: session, overlay: overlay, canvasSize: size)
                }
            }
        }
    }

    /// The overlay is on the canvas at the playhead (the compositor draws it only then).
    static func isVisible(_ overlay: EditOverlay, in session: EditSession) -> Bool {
        guard let index = session.timeline.overlay.firstIndex(where: { $0.id == overlay.id }),
              session.timing.overlay.indices.contains(index) else { return false }
        let slot = session.timing.overlay[index]
        return session.playhead >= slot.start && session.playhead < slot.start + slot.frames
    }
}

// MARK: - transport

/// `0:09.0`, back one frame, play / pause, forward one frame, `0:26.0` (shared with the iPad's narrow layouts).
struct EditorTransport: View {
    let session: EditSession

    var body: some View {
        HStack(spacing: 14) {
            Text(Copy.Editor.clockTenths(session.playheadSeconds))
                .frame(minWidth: 52, alignment: .trailing)
                .accessibilityLabel(Copy.Editor.transportTime)
            stepButton(Symbol.Editor.back, Copy.Editor.backOneFrame) { session.step(frames: -1) }
            Button { session.togglePlay() } label: {
                Label(
                    session.isPlaying ? Copy.Editor.pause : Copy.Editor.play,
                    systemImage: session.isPlaying ? Symbol.Editor.pause : Symbol.Editor.play)
            }
            .buttonStyle(.cobaltIcon(.small, prominent: true))
            .disabled(!session.isPlayerReady)
            stepButton(Symbol.Editor.forward, Copy.Editor.forwardOneFrame) { session.step(frames: 1) }
            Text(Copy.Editor.clockTenths(session.timing.seconds))
                .frame(minWidth: 52, alignment: .leading)
                .accessibilityLabel(Copy.Editor.a11yPlayheadValue(
                    Copy.Editor.clockTenths(session.playheadSeconds), of: Copy.Editor.clockTenths(session.timing.seconds)))
        }
        .font(Font.cobalt(12, .regular, relativeTo: .caption))
        .foregroundStyle(CobaltColor.caption)
        .monospacedDigit()
    }

    /// Space and ← → still play and step (EditorKeyboard); the icons' names are the plain actions.
    private func stepButton(_ symbol: String, _ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Label(label, systemImage: symbol) }
            .buttonStyle(.cobaltIcon(.small))
            .disabled(!session.isPlayerReady)
    }
}

// MARK: - the overlay on the canvas

/// The selected overlay on the canvas: an amber outline, drag inside to move, the four corners to resize with its aspect
/// kept. The session clamps every frame inside the canvas. VoiceOver gets an adjustable size and four moves of 5 %.
struct EditorOverlayHandles: View {
    let session: EditSession
    let overlay: EditOverlay
    /// The canvas on screen, in points.
    let canvasSize: CGSize

    @State private var start: EditFrame?

    private enum Corner: CaseIterable { case topLeft, topRight, bottomLeft, bottomRight }
    private static let space = "editorCanvas"
    private static let handle: CGFloat = 10

    private var canvas: EditCanvas { session.timeline.canvas }
    private var display: PixelSize { session.source(for: overlay.item)?.display ?? PixelSize(w: 16, h: 9) }
    private var scale: CGFloat { canvasSize.width / CGFloat(max(1, canvas.w)) }

    private var rect: CGRect {
        let px = EditGeometry.overlay(display: display, frame: overlay.frame, canvas: canvas)
        return CGRect(x: CGFloat(px.x) * scale, y: CGFloat(px.y) * scale, width: CGFloat(px.w) * scale, height: CGFloat(px.h) * scale)
    }

    var body: some View {
        let r = rect
        ZStack(alignment: .topLeading) {
            Color.clear
                .frame(width: r.width, height: r.height)
                .contentShape(Rectangle())
                .overlay { Rectangle().strokeBorder(EditorColor.overlay, lineWidth: 2) }
                .offset(x: r.minX, y: r.minY)
                .gesture(moveGesture)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Copy.Editor.overlaySize)
                .accessibilityValue("\(Int((overlay.frame.w * 100).rounded())) percent")
                .accessibilityAdjustableAction { direction in
                    switch direction {
                    case .increment: resize(by: 0.05)
                    case .decrement: resize(by: -0.05)
                    @unknown default: break
                    }
                }
                .accessibilityAction(named: Copy.Editor.moveLeft) { move(dx: -0.05, dy: 0) }
                .accessibilityAction(named: Copy.Editor.moveRight) { move(dx: 0.05, dy: 0) }
                .accessibilityAction(named: Copy.Editor.moveUp) { move(dx: 0, dy: -0.05) }
                .accessibilityAction(named: Copy.Editor.moveDown) { move(dx: 0, dy: 0.05) }
            ForEach(Corner.allCases, id: \.self) { corner in
                handleView(corner, in: r)
            }
        }
        .frame(width: canvasSize.width, height: canvasSize.height, alignment: .topLeading)
        .coordinateSpace(.named(Self.space))
    }

    // MARK: gestures

    private var moveGesture: some Gesture {
        DragGesture(minimumDistance: 1, coordinateSpace: .named(Self.space))
            .onChanged { value in
                let first = start ?? overlay.frame
                start = first
                session.setOverlayFrame(
                    id: overlay.id,
                    EditFrame(
                        x: first.x + Double(value.translation.width / max(1, canvasSize.width)),
                        y: first.y + Double(value.translation.height / max(1, canvasSize.height)), w: first.w))
            }
            .onEnded { _ in
                start = nil
                session.endGesture()
            }
    }

    private func handleView(_ corner: Corner, in r: CGRect) -> some View {
        let point: CGPoint
        switch corner {
        case .topLeft: point = CGPoint(x: r.minX, y: r.minY)
        case .topRight: point = CGPoint(x: r.maxX, y: r.minY)
        case .bottomLeft: point = CGPoint(x: r.minX, y: r.maxY)
        case .bottomRight: point = CGPoint(x: r.maxX, y: r.maxY)
        }
        return Rectangle()
            .fill(.white)
            .overlay { Rectangle().strokeBorder(EditorColor.overlay, lineWidth: 2) }
            .frame(width: Self.handle, height: Self.handle)
            .frame(width: 24, height: 24)
            .contentShape(Rectangle())
            .position(point)
            .gesture(resizeGesture(corner))
            .accessibilityHidden(true)
    }

    private func resizeGesture(_ corner: Corner) -> some Gesture {
        DragGesture(minimumDistance: 1, coordinateSpace: .named(Self.space))
            .onChanged { value in
                let first = start ?? overlay.frame
                start = first
                let dx = Double(value.translation.width / max(1, canvasSize.width))
                let h = EditGeometry.overlayHeightFraction(display: display, frame: first, canvas: canvas)
                var width = first.w
                switch corner {
                case .topRight, .bottomRight: width = first.w + dx
                case .topLeft, .bottomLeft: width = first.w - dx
                }
                width = min(1, max(0.05, width))
                let newH = h * width / max(0.001, first.w)
                var frame = EditFrame(x: first.x, y: first.y, w: width)
                if corner == .topLeft || corner == .bottomLeft { frame.x = first.x + first.w - width }
                if corner == .topLeft || corner == .topRight { frame.y = first.y + h - newH }
                session.setOverlayFrame(id: overlay.id, frame)
            }
            .onEnded { _ in
                start = nil
                session.endGesture()
            }
    }

    // MARK: accessibility moves

    private func move(dx: Double, dy: Double) {
        let f = overlay.frame
        session.setOverlayFrame(id: overlay.id, EditFrame(x: f.x + dx, y: f.y + dy, w: f.w))
        session.endGesture()
    }

    private func resize(by delta: Double) {
        let f = overlay.frame
        session.setOverlayFrame(id: overlay.id, EditFrame(x: f.x, y: f.y, w: f.w + delta))
        session.endGesture()
    }
}
