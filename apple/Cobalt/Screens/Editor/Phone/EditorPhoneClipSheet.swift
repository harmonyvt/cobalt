#if os(iOS)
import CobaltKit
import SwiftUI

/// The clip sheet, the approved "iPhone A crop + speed + trim" board (apple/CONTRACT-EDITOR.md 4.5): `cancel` · `surf · clip 2`
/// · `done`; the clip's frame at the top with the crop frame on it; and below, `crop`, `speed` and `trim`. Opened from `trim`,
/// `crop` or `speed` it scrolls to that section. Changes reach the preview as they are made; `cancel` puts the clip back as it
/// was when the sheet opened.
struct EditorPhoneClipSheet: View {
    let session: EditSession
    let section: EditorPhoneClipSection
    var pitchEnabled = true

    @Environment(\.dismiss) private var dismiss
    @State private var original: EditClip?
    @State private var clipID: String

    init(session: EditSession, section: EditorPhoneClipSection, pitchEnabled: Bool = true) {
        self.session = session
        self.section = section
        self.pitchEnabled = pitchEnabled
        let clip = session.selectedMain?.clip
        _original = State(initialValue: clip)
        _clipID = State(initialValue: clip?.id ?? "")
    }

    private var clip: EditClip? { session.timeline.main.first { $0.id == clipID } }
    private var number: Int { (session.timeline.main.firstIndex { $0.id == clipID } ?? 0) + 1 }

    var body: some View {
        GeometryReader { geo in
            VStack(spacing: 0) {
                header
                stage
                    .frame(maxHeight: .infinity)
                panel
                    .frame(height: min(440, geo.size.height * 0.58))
            }
        }
        .background(CobaltColor.bg.ignoresSafeArea())
    }

    // MARK: header

    private var header: some View {
        HStack(spacing: 8) {
            Button(Copy.Editor.cancel) { cancel() }
                .buttonStyle(.cobaltSecondary(fullWidth: false, compact: true))
            Text(title)
                .font(Font.cobalt(12.5, .semibold, relativeTo: .subheadline))
                .foregroundStyle(CobaltColor.text)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity)
                .accessibilityAddTraits(.isHeader)
            Button(Copy.Editor.done) { dismiss() }
                .buttonStyle(.cobaltPrimary(fullWidth: false, compact: true))
        }
        .padding(.horizontal, Metrics.gutter)
        .padding(.top, 14)
        .padding(.bottom, 8)
    }

    private var title: String {
        guard let clip else { return Copy.Editor.clipN(number) }
        return Copy.Editor.sheetTitle(session.source(for: clip.item)?.shortName ?? "", number)
    }

    /// Puts the clip back as it was: the trim first (the speed is limited by the length), then speed, crop and fit.
    private func cancel() {
        defer { dismiss() }
        guard let original, let now = clip else { return }
        if now.in != original.in || now.out != original.out {
            session.trim(clip: original.id, in: original.in, out: original.out)
        }
        if now.speed != original.speed { session.setSpeed(original.speed, clip: original.id) }
        if now.pitch != original.pitch { session.setPitch(original.pitch, clip: original.id) }
        if now.crop != original.crop { session.setCrop(original.crop, clip: original.id) }
        if now.fit != original.fit { session.setFit(original.fit, clip: original.id) }
        session.endGesture()
    }

    // MARK: the frame

    @ViewBuilder
    private var stage: some View {
        if let clip {
            EditorPhoneCropStage(session: session, clip: clip)
                .padding(.horizontal, 24)
                .padding(.vertical, 10)
        } else {
            Color.clear
        }
    }

    // MARK: the settings

    private var panel: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if let clip {
                        cropSection(clip).id(EditorPhoneClipSection.crop.rawValue)
                        speedSection(clip).id(EditorPhoneClipSection.speed.rawValue)
                        if pitchEnabled { pitchSection(clip) }
                        trimSection(clip).id(EditorPhoneClipSection.trim.rawValue)
                        EditorInspectorButton(title: Copy.Editor.deleteClip, symbol: Symbol.Editor.delete, destructive: true) {
                            session.remove(.main(clip.id))
                            dismiss()
                        }
                    }
                }
                .padding(.horizontal, Metrics.gutter)
                .padding(.top, 18)
                .padding(.bottom, 28)
            }
            .scrollIndicators(.hidden)
            .task { proxy.scrollTo(section.rawValue, anchor: .top) }
        }
        .frame(maxWidth: .infinity)
        .background(
            CobaltColor.surface,
            in: UnevenRoundedRectangle(topLeadingRadius: 22, topTrailingRadius: 22, style: .continuous))
    }

    private func cropSection(_ clip: EditClip) -> some View {
        let display = session.source(for: clip.item)?.display
        return EditorSection(Copy.Editor.crop, trailing: Copy.Editor.pinchAndDrag) {
            EditorCropRows(
                crop: clip.crop, fit: clip.fit, display: display.map { CGSize(width: $0.w, height: $0.h) },
                onCrop: { crop in
                    session.setCrop(crop, clip: clip.id)
                    session.endGesture()
                },
                onFit: { session.setFit($0, clip: clip.id) })
        }
    }

    private func speedSection(_ clip: EditClip) -> some View {
        EditorSection(Copy.Editor.speed, trailing: Copy.Editor.speedValue(clip.speed)) {
            VStack(alignment: .leading, spacing: 8) {
                EditorLogSlider(
                    speed: clip.speed, marks: true,
                    set: { session.setSpeed($0, clip: clip.id) }, onEnd: { session.endGesture() })
                Text("\(Copy.Editor.becomes((clip.out - clip.in) / max(0.25, clip.speed))) · \(Copy.Editor.pitchKept)")
                    .font(Font.cobalt(11, .regular, relativeTo: .caption2))
                    .foregroundStyle(CobaltColor.caption)
                    .monospacedDigit()
            }
        }
    }

    private func pitchSection(_ clip: EditClip) -> some View {
        EditorSection(Copy.Editor.pitch, trailing: Copy.Editor.pitchValue(clip.pitch)) {
            EditorPitchRow(
                pitch: clip.pitch,
                set: { session.setPitch($0, clip: clip.id) }, onEnd: { session.endGesture() })
        }
    }

    private func trimSection(_ clip: EditClip) -> some View {
        EditorSection(Copy.Editor.trim) {
            VStack(alignment: .leading, spacing: 8) {
                EditorPhoneTrimStrip(session: session, clip: clip, source: session.source(for: clip.item))
                HStack {
                    Text(Copy.Editor.inAt(Copy.Editor.clockCentis(clip.in)))
                    Spacer(minLength: 8)
                    Text(Copy.Editor.outAt(Copy.Editor.clockCentis(clip.out)))
                }
                .font(Font.cobalt(11, .regular, relativeTo: .caption2))
                .foregroundStyle(CobaltColor.caption)
                .monospacedDigit()
            }
        }
    }
}

// MARK: - the trim filmstrip

/// The whole source as a filmstrip with what the clip uses framed in blue and the rest dimmed; a handle at each end moves the
/// clip's `in` and `out` (the session keeps them at least 0.1 s apart and inside the file).
struct EditorPhoneTrimStrip: View {
    let session: EditSession
    let clip: EditClip
    let source: EditSource?

    @State private var base: (inPoint: Double, outPoint: Double)?

    private static let height: CGFloat = 48

    private var duration: Double { max(0.2, source?.duration ?? clip.out) }

    var body: some View {
        GeometryReader { geo in
            strip(width: geo.size.width)
        }
        .frame(height: Self.height)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func strip(width: CGFloat) -> some View {
        let left = width * CGFloat(min(1, max(0, clip.in / duration)))
        let right = width * CGFloat(min(1, max(0, clip.out / duration)))
        return ZStack(alignment: .topLeading) {
            filmstrip(width: width)
            Rectangle().fill(.black.opacity(0.65)).frame(width: left, height: Self.height)
            Rectangle().fill(.black.opacity(0.65)).frame(width: max(0, width - right), height: Self.height).offset(x: right)
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(EditorColor.selection, lineWidth: 2)
                .frame(width: max(2, right - left), height: Self.height)
                .offset(x: left)
                .allowsHitTesting(false)
            handles(width: width, left: left, right: right)
        }
        .frame(width: width, height: Self.height, alignment: .topLeading)
    }

    private func filmstrip(width: CGFloat) -> some View {
        let count = max(1, Int((width / Metrics.stripCell).rounded(.up)))
        return HStack(spacing: 0) {
            ForEach(0..<count, id: \.self) { _ in
                EditorPoster(url: source?.posterURL, fallback: EditorColor.clip(for: clip.item), maxPixel: 120)
                    .frame(width: Metrics.stripCell, height: Self.height)
            }
        }
        .frame(width: width, height: Self.height, alignment: .leading)
        .background(EditorColor.clip(for: clip.item))
        .clipped()
        .accessibilityHidden(true)
    }

    private func handles(width: CGFloat, left: CGFloat, right: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            EditorPhoneHitZone(height: Self.height, onDrag: { dragIn($0, width: width) }, onEnd: finish)
                .offset(x: left - 10)
            EditorPhoneHitZone(height: Self.height, onDrag: { dragOut($0, width: width) }, onEnd: finish)
                .offset(x: right - Metrics.hit + 10)
            TimelineTrimHandle(
                edge: .leading, height: Self.height, valueText: Copy.Editor.clockCentis(clip.in),
                onDrag: { dragIn($0, width: width) }, onEnd: finish,
                step: { n in nudge(inPoint: n) })
                .offset(x: left)
            TimelineTrimHandle(
                edge: .trailing, height: Self.height, valueText: Copy.Editor.clockCentis(clip.out),
                onDrag: { dragOut($0, width: width) }, onEnd: finish,
                step: { n in nudge(outPoint: n) })
                .offset(x: right - TimelineTrimHandle.hitWidth)
        }
    }

    private func capture() -> (inPoint: Double, outPoint: Double) {
        if let base { return base }
        let first = (inPoint: clip.in, outPoint: clip.out)
        base = first
        return first
    }

    private func dragIn(_ dx: CGFloat, width: CGFloat) {
        let first = capture()
        session.trim(clip: clip.id, in: first.inPoint + Double(dx / max(1, width)) * duration, out: nil)
    }

    private func dragOut(_ dx: CGFloat, width: CGFloat) {
        let first = capture()
        session.trim(clip: clip.id, in: nil, out: first.outPoint + Double(dx / max(1, width)) * duration)
    }

    private func nudge(inPoint n: Int) {
        session.trim(clip: clip.id, in: clip.in + Double(n) / Double(max(1, session.timing.fps)), out: nil)
        session.endGesture()
    }

    private func nudge(outPoint n: Int) {
        session.trim(clip: clip.id, in: nil, out: clip.out + Double(n) / Double(max(1, session.timing.fps)))
        session.endGesture()
    }

    private func finish() {
        base = nil
        session.endGesture()
    }
}

// MARK: - the crop frame

/// The clip's frame (its poster; the kit has no frame still) with the crop frame on it: corner marks, drag inside to move,
/// drag a corner or an edge to resize, pinch to scale about the middle. The outside is dimmed. The aspect is locked unless it is
/// `free`. Edits go to the session as they happen, so the preview behind the sheet follows.
struct EditorPhoneCropStage: View {
    let session: EditSession
    let clip: EditClip

    @State private var startRect: CGRect?
    @State private var pinchRect: CGRect?

    private static let space = "phoneCrop"

    private var source: EditSource? { session.source(for: clip.item) }
    private var display: CGSize? {
        guard let d = source?.display else { return nil }
        return CGSize(width: d.w, height: d.h)
    }
    private var current: EditCrop { clip.crop ?? EditCrop(aspect: .free, x: 0, y: 0, w: 1, h: 1) }
    private var currentRect: CGRect { CGRect(x: current.x, y: current.y, width: current.w, height: current.h) }

    var body: some View {
        GeometryReader { geo in
            let aspect = display.map { $0.width / max(1, $0.height) } ?? (16.0 / 9.0)
            let size = EditorCanvasFit.size(aspect: aspect, in: geo.size)
            stage(size: size)
                .frame(width: size.width, height: size.height)
                .frame(width: geo.size.width, height: geo.size.height)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Copy.Editor.toolCrop)
    }

    private func stage(size: CGSize) -> some View {
        let c = current
        let frame = CGRect(x: c.x * size.width, y: c.y * size.height, width: c.w * size.width, height: c.h * size.height)
        return ZStack(alignment: .topLeading) {
            EditorPoster(url: source?.posterURL, fallback: EditorColor.clip(for: clip.item), maxPixel: 900)
                .frame(width: size.width, height: size.height)
            PhoneDim(hole: frame)
                .fill(Color.black.opacity(0.6), style: FillStyle(eoFill: true))
                .frame(width: size.width, height: size.height)
                .allowsHitTesting(false)
            Rectangle()
                .strokeBorder(.white, lineWidth: 1.5)
                .frame(width: frame.width, height: frame.height)
                .contentShape(Rectangle())
                .offset(x: frame.minX, y: frame.minY)
                .gesture(dragGesture(.body, size: size))
            PhoneCornerMarks(rect: frame)
                .stroke(.white, style: StrokeStyle(lineWidth: 3, lineCap: .square))
                .frame(width: size.width, height: size.height)
                .allowsHitTesting(false)
            ForEach(EditorCropMath.Handle.grips, id: \.self) { handle in
                grip(handle, frame: frame, size: size)
            }
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .coordinateSpace(.named(Self.space))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .simultaneousGesture(pinch)
    }

    /// A drag zone on a corner (44 pt) or along an edge (32 pt thick), invisible: the marks are drawn apart.
    private func grip(_ handle: EditorCropMath.Handle, frame: CGRect, size: CGSize) -> some View {
        let zone: CGSize
        if handle.isCorner {
            zone = CGSize(width: 44, height: 44)
        } else if handle.isHorizontalEdge {
            zone = CGSize(width: max(20, frame.width - 60), height: 32)
        } else {
            zone = CGSize(width: 32, height: max(20, frame.height - 60))
        }
        return Color.clear
            .frame(width: zone.width, height: zone.height)
            .contentShape(Rectangle())
            .position(handle.point(in: frame))
            .gesture(dragGesture(handle, size: size))
            .accessibilityHidden(true)
    }

    private func dragGesture(_ handle: EditorCropMath.Handle, size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 1, coordinateSpace: .named(Self.space))
            .onChanged { value in
                let first = startRect ?? currentRect
                startRect = first
                let rect = EditorCropMath.apply(
                    handle, to: first, dx: Double(value.translation.width / max(1, size.width)),
                    dy: Double(value.translation.height / max(1, size.height)), ratioK: lockedRatio)
                write(rect)
            }
            .onEnded { _ in
                startRect = nil
                session.endGesture()
            }
    }

    /// Pinch: the frame grows or shrinks about its middle with its shape kept, and stays inside the picture.
    private var pinch: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                let first = pinchRect ?? currentRect
                pinchRect = first
                let smallest = max(0.001, min(first.width, first.height))
                let largest = max(0.001, max(first.width, first.height))
                let factor = min(1 / largest, max(EditorCropMath.minimum / smallest, Double(value.magnification)))
                let w = first.width * factor
                let h = first.height * factor
                let x = min(max(0, first.midX - w / 2), 1 - w)
                let y = min(max(0, first.midY - h / 2), 1 - h)
                write(CGRect(x: x, y: y, width: w, height: h))
            }
            .onEnded { _ in
                pinchRect = nil
                session.endGesture()
            }
    }

    private func write(_ rect: CGRect) {
        session.setCrop(EditCrop(aspect: current.aspect, x: rect.minX, y: rect.minY, w: rect.width, h: rect.height), clip: clip.id)
    }

    /// The crop's width over height in fractions of the frame when the aspect is locked.
    private var lockedRatio: Double? {
        guard let r = current.aspect.ratio, let display, display.height > 0 else { return nil }
        return r / Double(display.width / display.height)
    }
}

/// The picture minus the crop frame (even-odd fill).
private struct PhoneDim: Shape {
    let hole: CGRect

    func path(in rect: CGRect) -> Path {
        var path = Path(rect)
        path.addRect(hole)
        return path
    }
}

/// The four white corner marks of the board, 18 pt long.
private struct PhoneCornerMarks: Shape {
    let rect: CGRect

    func path(in bounds: CGRect) -> Path {
        var path = Path()
        let len = min(18, rect.width / 2, rect.height / 2)
        path.move(to: CGPoint(x: rect.minX, y: rect.minY + len))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.minX + len, y: rect.minY))
        path.move(to: CGPoint(x: rect.maxX - len, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + len))
        path.move(to: CGPoint(x: rect.minX, y: rect.maxY - len))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX + len, y: rect.maxY))
        path.move(to: CGPoint(x: rect.maxX - len, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - len))
        return path
    }
}
#endif
