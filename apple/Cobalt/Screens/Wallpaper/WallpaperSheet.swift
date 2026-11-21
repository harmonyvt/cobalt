#if os(iOS)
import CobaltKit
import CoreImage
import SwiftUI

// The wallpaper maker (apple/CONTRACT-WALLPAPER.md): a post's video, webp, gif or picture → a Lock Screen Live Photo
// (or a still) with the depth painted in, saved to Photos. Wide (Duo spread, iPad): the Lock Screen preview on the left,
// the controls on the right. Narrow: preview on top, controls under it.

/// The post file the sheet is open on.
struct WallpaperPick: Identifiable {
    let rendition: Rendition
    var id: String { rendition.id }

    /// Any file the device has or can fetch.
    static func canMake(_ r: Rendition?) -> Bool {
        guard let r else { return false }
        return r.hasFileHere || r.file != nil
    }
}

struct WallpaperSheet: View {
    let model: AppModel
    let rendition: Rendition
    let close: () -> Void

    private enum Brush: Equatable { case none, add, remove }

    @State private var maker: WallpaperMaker?
    @State private var failed = false
    @State private var start: Double = 0
    @State private var look = WallpaperLook()
    @State private var target: WallpaperTarget = .lockScreen
    @State private var frame: WallpaperMaker.Frame?
    @State private var preview: WallpaperMaker.Preview?
    @State private var showsDepth = false
    @State private var brush: Brush = .none
    @State private var brushSize: Double = 0.06
    @State private var drawing: WallpaperStroke?
    @State private var progress: Double?
    @State private var status: String?
    @State private var saved = false
    @State private var madeTick = 0
    @State private var failTick = 0

    private var length: Double { maker.map { $0.range(start: start, length: WallpaperLimits.maxClip).length } ?? 0 }
    private var isPicture: Bool { maker?.source.kind == .picture }
    /// The still the Lock Screen keeps: the last frame of the range.
    private var keyTime: Double { isPicture ? 0 : start + length }

    var body: some View {
        GeometryReader { geo in
            let wide = geo.size.width >= 680
            Group {
                if wide {
                    HStack(alignment: .top, spacing: 20) {
                        stage.frame(maxWidth: .infinity, maxHeight: .infinity)
                        ScrollView { controls }.frame(width: min(380, geo.size.width * 0.45))
                    }
                } else {
                    VStack(spacing: 12) {
                        stage.frame(maxWidth: .infinity).frame(height: geo.size.height * 0.5)
                        ScrollView { controls }
                    }
                }
            }
            .padding(16)
        }
        .background(CobaltColor.bg)
        .interactiveDismissDisabled(progress != nil)
        .haptic(.success, trigger: madeTick)
        .haptic(.error, trigger: failTick)
        .task { await open() }
        .task(id: keyTime) { await loadFrame() }
        .task(id: PreviewKey(look: look, frame: frame.map { ObjectIdentifier($0.image) }, drawing: drawing)) {
            await refreshPreview()
        }
    }

    private struct PreviewKey: Equatable {
        var look: WallpaperLook
        var frame: ObjectIdentifier?
        var drawing: WallpaperStroke?
    }

    // MARK: the preview

    /// One Lock Screen (or the Duo's two, with the hinge), the picture filling it.
    @ViewBuilder
    private var stage: some View {
        let aspect: CGFloat = target == .duoPair ? 762.0 / 800.0 : 1179.0 / 2556.0
        ZStack {
            if let preview {
                GeometryReader { geo in
                    let image = showsDepth ? preview.depth : preview.picture
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: geo.size.width, height: geo.size.height)
                        .clipped()
                        .mediaMask()
                        .overlay { if !showsDepth { lockScreenChrome(width: geo.size.width) } }
                        .overlay { if target == .duoPair { hinge(width: geo.size.width) } }
                        .contentShape(Rectangle())
                        .gesture(brushGesture(size: geo.size, picture: preview.size), including: brush == .none ? .none : .all)
                }
            } else if failed {
                Text(Copy.Wallpaper.unreadable)
                    .font(CobaltType.captionSmall)
                    .foregroundStyle(CobaltColor.caption)
                    .multilineTextAlignment(.center)
                    .padding()
            } else {
                ProgressView(Copy.Wallpaper.loading).font(CobaltType.captionSmall)
            }
        }
        .aspectRatio(aspect, contentMode: .fit)
        .background(CobaltColor.surface)
        .clipShape(RoundedRectangle(cornerRadius: target == .duoPair ? 22 : 34, style: .continuous))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Where iOS puts the date and clock, so the owner sees what the clock covers.
    private func lockScreenChrome(width: CGFloat) -> some View {
        let screen = target == .duoPair ? width * (372.0 / 762.0) : width
        return VStack(spacing: 0) {
            Text(Date.now, format: .dateTime.weekday(.wide).day().month(.wide))
                .font(.system(size: screen * 0.045, weight: .semibold, design: .rounded))
            Text(Date.now, format: .dateTime.hour(.defaultDigits(amPM: .omitted)).minute())
                .font(.system(size: screen * 0.28, weight: .bold, design: .rounded))
        }
        .foregroundStyle(.white)
        .shadow(color: .black.opacity(0.25), radius: 10, y: 2)
        .frame(width: screen)
        .padding(.top, screen * 0.36)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: target == .duoPair ? .topLeading : .top)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func hinge(width: CGFloat) -> some View {
        Rectangle()
            .fill(Color.black.opacity(0.85))
            .frame(width: max(2, width * WallpaperLimits.hingeShare))
            .allowsHitTesting(false)
    }

    // MARK: brush

    /// Maps a point in the stage (the picture filling it) to the picture's unit square.
    private func unit(_ p: CGPoint, stage: CGSize, picture: CGSize) -> CGPoint {
        let scale = max(stage.width / picture.width, stage.height / picture.height)
        let shown = CGSize(width: picture.width * scale, height: picture.height * scale)
        let origin = CGPoint(x: (stage.width - shown.width) / 2, y: (stage.height - shown.height) / 2)
        return CGPoint(x: (p.x - origin.x) / shown.width, y: (p.y - origin.y) / shown.height)
    }

    private func brushGesture(size: CGSize, picture: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                let p = unit(value.location, stage: size, picture: picture)
                if drawing == nil {
                    drawing = WallpaperStroke(points: [p], radius: brushSize, adds: brush == .add)
                } else {
                    drawing?.points.append(p)
                }
            }
            .onEnded { _ in
                if let drawing { look.strokes.append(drawing) }
                drawing = nil
            }
    }

    // MARK: controls

    private var controls: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(Copy.Wallpaper.title).font(CobaltType.sheetTitle).foregroundStyle(CobaltColor.text)
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                CloseButton(cancels: true, action: close).disabled(progress != nil)
            }
            if let maker {
                if isPicture {
                    note(Copy.Wallpaper.pictureNote)
                } else {
                    rangePicker(maker)
                }
                targetPicker
                depthControls
                makeButton
                note(Copy.Wallpaper.iosDecides)
            }
            if let status {
                Text(status).font(CobaltType.captionSmall).foregroundStyle(CobaltColor.text)
            }
            if saved {
                note(Copy.Wallpaper.howTo)
                Button(Copy.Wallpaper.openPhotos, systemImage: Symbol.Wallpaper.openPhotos) { WallpaperPhotos.openPhotos() }
                    .buttonStyle(.cobaltSecondary())
            }
        }
    }

    private func note(_ text: String) -> some View {
        Text(text).font(CobaltType.captionSmall).foregroundStyle(CobaltColor.caption)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func section(_ title: String, hint: String? = nil) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(title).font(CobaltType.bodySemibold).foregroundStyle(CobaltColor.text)
            if let hint { Text(hint).font(CobaltType.captionSmall).foregroundStyle(CobaltColor.caption) }
        }
    }

    private func rangePicker(_ maker: WallpaperMaker) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            section(Copy.Wallpaper.pickRange, hint: Copy.Wallpaper.pickRangeHint)
            let top = max(0, maker.source.duration - length)
            Slider(value: $start, in: 0...max(top, 0.001))
                .disabled(top <= 0 || progress != nil)
            HStack {
                Text(Self.clock(start))
                Spacer()
                Label(Self.clock(start + length), systemImage: Symbol.Wallpaper.live)
                Spacer()
                Text(Self.clock(maker.source.duration))
            }
            .font(CobaltType.captionSmall.monospacedDigit())
            .foregroundStyle(CobaltColor.caption)
        }
    }

    private var targetPicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            section(Copy.Wallpaper.target)
            Picker(Copy.Wallpaper.target, selection: $target) {
                Label(Copy.Wallpaper.lockScreen, systemImage: Symbol.Wallpaper.lockScreen).tag(WallpaperTarget.lockScreen)
                Label(Copy.Wallpaper.duoPair, systemImage: Symbol.Wallpaper.duoPair).tag(WallpaperTarget.duoPair)
            }
            .pickerStyle(.segmented)
            .disabled(progress != nil)
            note(target == .duoPair ? Copy.Wallpaper.duoPairNote : Copy.Wallpaper.lockScreenNote)
        }
    }

    private var depthControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                section(Copy.Wallpaper.depth)
                Spacer()
                Button(showsDepth ? Copy.Wallpaper.showPicture : Copy.Wallpaper.showDepth, systemImage: Symbol.Wallpaper.depth) {
                    showsDepth.toggle()
                }
                .buttonStyle(.cobaltSecondary(fullWidth: false, compact: true))
            }
            HStack(spacing: 8) {
                brushButton(.add, Copy.Wallpaper.subjectIn, Symbol.Wallpaper.subjectIn)
                brushButton(.remove, Copy.Wallpaper.subjectOut, Symbol.Wallpaper.subjectOut)
                Button(Copy.Wallpaper.undo, systemImage: Symbol.Wallpaper.undo) { _ = look.strokes.popLast() }
                    .buttonStyle(.cobaltSecondary(fullWidth: false, compact: true))
                    .disabled(look.strokes.isEmpty)
            }
            Toggle(Copy.Wallpaper.findSubject, isOn: $look.findsSubject)
                .font(CobaltType.captionSmall)
            if frame != nil, frame?.found == nil, look.strokes.isEmpty {
                note(Copy.Wallpaper.noSubject)
            }
            slider(Copy.Wallpaper.brushSize, value: $brushSize, in: 0.01...0.2)
            slider(Copy.Wallpaper.blur, value: $look.blur, in: 0...1)
            if !isPicture { slider(Copy.Wallpaper.parallax, value: $look.parallax, in: 0...1) }
            slider(Copy.Wallpaper.softness, value: $look.softness, in: 0...1)
        }
        .disabled(progress != nil)
    }

    private func brushButton(_ kind: Brush, _ title: String, _ symbol: String) -> some View {
        Button(title, systemImage: symbol) { brush = brush == kind ? .none : kind }
            .buttonStyle(CobaltButtonStyle(kind: brush == kind ? .primary : .secondary, fullWidth: false, compact: true))
            .accessibilityAddTraits(brush == kind ? .isSelected : [])
    }

    private func slider(_ title: String, value: Binding<Double>, in range: ClosedRange<Double>) -> some View {
        HStack(spacing: 10) {
            Text(title).font(CobaltType.captionSmall).foregroundStyle(CobaltColor.caption).frame(width: 120, alignment: .leading)
            Slider(value: value, in: range)
        }
    }

    private var makeButton: some View {
        Button {
            Task { await make() }
        } label: {
            if let progress {
                Label("\(Copy.Wallpaper.making) \(Int(progress * 100))%", systemImage: Symbol.Wallpaper.make)
            } else {
                Label(Copy.Wallpaper.make, systemImage: Symbol.Wallpaper.make)
            }
        }
        .buttonStyle(.cobaltPrimary())
        .disabled(progress != nil || maker == nil)
    }

    // MARK: work

    /// Off the main thread (apple/ARCHITECTURE.md rule 1).
    @concurrent
    nonisolated private static func exists(_ url: URL) async -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    private func open() async {
        do {
            let url: URL
            if let local = rendition.local?.fileURL, await Self.exists(local) {
                url = local
            } else if let file = rendition.file {
                url = try await model.library.localCopy(file)
            } else {
                failed = true
                return
            }
            let source = try await WallpaperSource.open(url)
            maker = WallpaperMaker(source: source)
            if source.kind != .picture {
                start = max(0, source.duration - WallpaperLimits.maxClip) / 2
            }
        } catch {
            failed = true
        }
    }

    private func loadFrame() async {
        guard let maker else { return }
        try? await Task.sleep(nanoseconds: 150_000_000)   // the slider settles first
        guard !Task.isCancelled else { return }
        let time = keyTime
        frame = try? await Task.detached(priority: .userInitiated) { try await maker.previewFrame(at: time) }.value
    }

    private func refreshPreview() async {
        guard let maker, let frame else { return }
        try? await Task.sleep(nanoseconds: 60_000_000)
        guard !Task.isCancelled else { return }
        var shown = look
        if let drawing { shown.strokes.append(drawing) }
        let next = await Task.detached(priority: .userInitiated) { maker.preview(frame, look: shown) }.value
        guard !Task.isCancelled else { return }
        preview = next
    }

    private func make() async {
        guard let maker else { return }
        progress = 0
        status = nil
        saved = false
        let start = start, look = look, target = target
        let report: @Sendable (Double) -> Void = { value in Task { @MainActor in if progress != nil { progress = value } } }
        do {
            let files = try await Task.detached(priority: .userInitiated) {
                try await maker.make(start: start, length: WallpaperLimits.maxClip, look: look, target: target, progress: report)
            }.value
            let inAlbum = try await WallpaperPhotos.save(files)
            status = inAlbum ? Copy.Wallpaper.savedAlbum : Copy.Wallpaper.saved
            saved = true
            madeTick += 1
        } catch WallpaperPhotos.Failure.denied {
            status = Copy.Wallpaper.denied
            failTick += 1
        } catch {
            status = Copy.Wallpaper.failed
            failTick += 1
        }
        progress = nil
    }

    private static func clock(_ seconds: Double) -> String {
        let s = max(0, seconds)
        return String(format: "%d:%04.1f", Int(s) / 60, s.truncatingRemainder(dividingBy: 60))
    }
}

/// Presents the wallpaper sheet on the file `target` names.
struct WallpaperPresenter: ViewModifier {
    let model: AppModel
    @Binding var target: WallpaperPick?

    func body(content: Content) -> some View {
        content.fullScreenCover(item: $target) { picked in
            WallpaperSheet(model: model, rendition: picked.rendition) { target = nil }
        }
    }
}
#endif
