import CobaltKit
import SwiftUI

/// With the crop tool and a main clip selected, the canvas gives way to that clip's source with its crop frame on it
/// (apple/CONTRACT-EDITOR.md 4.3): corner and edge handles, drag inside to move, the aspect locked unless `free`, the outside
/// dimmed, and `done` / `reset` under it. Edits go to the session as they happen, so the timeline's block shows `crop` at once.
struct EditorCropStage: View {
    let session: EditSession
    let clip: EditClip

    @State private var startRect: CGRect?

    private static let space = "editorCrop"

    private var source: EditSource? { session.source(for: clip.item) }
    private var display: CGSize? {
        guard let d = source?.display else { return nil }
        return CGSize(width: d.w, height: d.h)
    }
    private var current: EditCrop { clip.crop ?? EditCrop(aspect: .free, x: 0, y: 0, w: 1, h: 1) }

    var body: some View {
        VStack(spacing: 10) {
            GeometryReader { geo in
                let aspect = display.map { $0.width / max(1, $0.height) } ?? (16.0 / 9.0)
                let size = EditorCanvasFit.size(aspect: aspect, in: geo.size)
                stage(size: size)
                    .frame(width: size.width, height: size.height)
                    .frame(width: geo.size.width, height: geo.size.height)
            }
            HStack(spacing: 8) {
                Button(Copy.Editor.cropReset) { reset() }
                    .buttonStyle(.cobaltSecondary(fullWidth: false, compact: true))
                Button(Copy.Editor.cropDone) { session.tool = .select }
                    .buttonStyle(.cobaltPrimary(fullWidth: false, compact: true))
            }
        }
    }

    private func stage(size: CGSize) -> some View {
        let c = current
        let frame = CGRect(x: c.x * size.width, y: c.y * size.height, width: c.w * size.width, height: c.h * size.height)
        return ZStack(alignment: .topLeading) {
            EditorPoster(url: source?.posterURL, fallback: EditorColor.clip(for: clip.item), maxPixel: 900)
                .frame(width: size.width, height: size.height)
            Dim(hole: frame)
                .fill(Color.black.opacity(0.55), style: FillStyle(eoFill: true))
                .frame(width: size.width, height: size.height)
                .allowsHitTesting(false)
            Rectangle()
                .strokeBorder(.white, lineWidth: 1.5)
                .frame(width: frame.width, height: frame.height)
                .contentShape(Rectangle())
                .offset(x: frame.minX, y: frame.minY)
                .gesture(dragGesture(.body, size: size))
            ForEach(EditorCropMath.Handle.grips, id: \.self) { handle in
                grip(handle, frame: frame, size: size)
            }
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .coordinateSpace(.named(Self.space))
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Copy.Editor.toolCrop)
    }

    private func grip(_ handle: EditorCropMath.Handle, frame: CGRect, size: CGSize) -> some View {
        let p = handle.point(in: frame)
        let corner = handle.isCorner
        return Rectangle()
            .fill(.white)
            .frame(width: corner ? 12 : 18, height: corner ? 12 : 18)
            .opacity(0.001)
            .overlay {
                Rectangle()
                    .fill(.white)
                    .frame(width: corner ? 10 : (handle.isHorizontalEdge ? 18 : 4), height: corner ? 10 : (handle.isHorizontalEdge ? 4 : 18))
            }
            .frame(width: 28, height: 28)
            .contentShape(Rectangle())
            .position(p)
            .gesture(dragGesture(handle, size: size))
            .accessibilityHidden(true)
    }

    private func dragGesture(_ handle: EditorCropMath.Handle, size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 1, coordinateSpace: .named(Self.space))
            .onChanged { value in
                let first = startRect ?? CGRect(x: current.x, y: current.y, width: current.w, height: current.h)
                startRect = first
                let ratio = lockedRatio
                let rect = EditorCropMath.apply(
                    handle, to: first, dx: Double(value.translation.width / max(1, size.width)),
                    dy: Double(value.translation.height / max(1, size.height)), ratioK: ratio)
                session.setCrop(
                    EditCrop(aspect: current.aspect, x: rect.minX, y: rect.minY, w: rect.width, h: rect.height), clip: clip.id)
            }
            .onEnded { _ in
                startRect = nil
                session.endGesture()
            }
    }

    /// The crop's width over height in fractions of the frame when the aspect is locked: ratio over the source's own ratio.
    private var lockedRatio: Double? {
        guard let r = current.aspect.ratio, let display, display.height > 0 else { return nil }
        return r / Double(display.width / display.height)
    }

    /// `reset`: the largest centred frame of the aspect (the whole frame for `free`).
    private func reset() {
        guard let display else {
            session.setCrop(EditCrop(aspect: current.aspect, x: 0, y: 0, w: 1, h: 1), clip: clip.id)
            return
        }
        session.setCrop(EditCrop.centred(current.aspect, display: display), clip: clip.id)
        session.endGesture()
    }

    /// The dim layer: the whole stage minus the crop frame (even-odd fill).
    private struct Dim: Shape {
        let hole: CGRect

        func path(in rect: CGRect) -> Path {
            var path = Path(rect)
            path.addRect(hole)
            return path
        }
    }
}

/// The crop frame's maths in fractions of the source's display frame: nine grips, each moving some edges, with the aspect
/// locked (`ratioK`: width over height in those fractions) or free.
enum EditorCropMath {
    enum Handle: Hashable {
        case topLeft, top, topRight, left, right, bottomLeft, bottom, bottomRight, body

        static let grips: [Handle] = [.topLeft, .top, .topRight, .left, .right, .bottomLeft, .bottom, .bottomRight]

        var isCorner: Bool {
            switch self {
            case .topLeft, .topRight, .bottomLeft, .bottomRight: return true
            default: return false
            }
        }

        var isHorizontalEdge: Bool { self == .top || self == .bottom }

        func point(in r: CGRect) -> CGPoint {
            switch self {
            case .topLeft: return CGPoint(x: r.minX, y: r.minY)
            case .top: return CGPoint(x: r.midX, y: r.minY)
            case .topRight: return CGPoint(x: r.maxX, y: r.minY)
            case .left: return CGPoint(x: r.minX, y: r.midY)
            case .right: return CGPoint(x: r.maxX, y: r.midY)
            case .bottomLeft: return CGPoint(x: r.minX, y: r.maxY)
            case .bottom: return CGPoint(x: r.midX, y: r.maxY)
            case .bottomRight: return CGPoint(x: r.maxX, y: r.maxY)
            case .body: return CGPoint(x: r.midX, y: r.midY)
            }
        }

        var movesLeft: Bool { self == .left || self == .topLeft || self == .bottomLeft }
        var movesRight: Bool { self == .right || self == .topRight || self == .bottomRight }
        var movesTop: Bool { self == .top || self == .topLeft || self == .topRight }
        var movesBottom: Bool { self == .bottom || self == .bottomLeft || self == .bottomRight }
    }

    /// The smallest side, as a fraction (the session enforces 64 px on top of this).
    static let minimum = 0.06

    static func apply(_ handle: Handle, to start: CGRect, dx: Double, dy: Double, ratioK: Double?) -> CGRect {
        if handle == .body {
            return CGRect(
                x: min(max(0, start.minX + dx), 1 - start.width), y: min(max(0, start.minY + dy), 1 - start.height),
                width: start.width, height: start.height)
        }
        var left = start.minX, right = start.maxX, top = start.minY, bottom = start.maxY
        if handle.movesLeft { left += dx }
        if handle.movesRight { right += dx }
        if handle.movesTop { top += dy }
        if handle.movesBottom { bottom += dy }
        left = min(max(0, left), right - minimum)
        right = max(min(1, right), left + minimum)
        top = min(max(0, top), bottom - minimum)
        bottom = max(min(1, bottom), top + minimum)
        guard let k = ratioK, k > 0 else {
            return CGRect(x: left, y: top, width: right - left, height: bottom - top)
        }
        return locked(handle, start: start, width: right - left, height: bottom - top, k: k)
    }

    /// The frame with width : height = `k`, anchored at the opposite corner (or edge middle) and kept inside 0...1.
    private static func locked(_ handle: Handle, start: CGRect, width w: Double, height h: Double, k: Double) -> CGRect {
        var wd: Double
        if handle.isCorner {
            wd = (w + h * k) / 2
            let room = Swift.min(
                handle.movesLeft ? start.maxX : 1 - start.minX, (handle.movesTop ? start.maxY : 1 - start.minY) * k)
            wd = Swift.min(wd, room)
        } else if handle.isHorizontalEdge {
            wd = h * k
            let vertical = handle.movesTop ? start.maxY : 1 - start.minY
            wd = Swift.min(wd, vertical * k, 2 * Swift.min(start.midX, 1 - start.midX))
        } else {
            wd = w
            let horizontal = handle.movesLeft ? start.maxX : 1 - start.minX
            wd = Swift.min(wd, horizontal, 2 * Swift.min(start.midY, 1 - start.midY) * k)
        }
        wd = Swift.max(wd, minimum)
        let hd = wd / k
        let x: Double, y: Double
        if handle.isCorner {
            x = handle.movesLeft ? start.maxX - wd : start.minX
            y = handle.movesTop ? start.maxY - hd : start.minY
        } else if handle.isHorizontalEdge {
            x = start.midX - wd / 2
            y = handle.movesTop ? start.maxY - hd : start.minY
        } else {
            x = handle.movesLeft ? start.maxX - wd : start.minX
            y = start.midY - hd / 2
        }
        return CGRect(x: Swift.min(Swift.max(0, x), 1 - wd), y: Swift.min(Swift.max(0, y), 1 - hd), width: wd, height: hd)
    }
}
