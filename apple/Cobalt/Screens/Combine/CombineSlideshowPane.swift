import CobaltKit
import SwiftUI

/// The slideshow's settings (webp and mp4): a live preview that plays the plan, a proportional timeline, one slider for
/// every photo, the crossfade, the frame and (mp4 with a video ticked) the sound (apple/CONTRACT-GALLERY.md 1.15, board
/// `Gallery-Combine`). Everything it shows is computed from the same `SlideshowPlan` the make sends.
struct CombineSlideshowPane: View {
    @Bindable var combine: CombineModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            CombinePreviewPlayer(combine: combine)
            if !combine.motionItems.isEmpty {
                Text(Copy.Gallery.videosInFull(combine.motionList))
                    .font(CobaltType.captionSmall)
                    .foregroundStyle(CobaltColor.caption)
            }
            secondsSlider
            crossfade
            frameRow
            if combine.showsSound { soundRow }
            if combine.output == .slideshowWebp {
                Text(Copy.Combine.webpSettings(quality: app.settings.webpQuality.rawValue, width: combine.slideshowPlan(.webp).width ?? 480))
                    .font(CobaltType.badge)
                    .foregroundStyle(CobaltColor.caption)
            }
        }
    }

    private var app: AppModel { combine.app }

    // MARK: one slider for every photo

    private var secondsSlider: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(Copy.Gallery.eachPhoto)
                    .font(CobaltType.captionSmall)
                    .foregroundStyle(CobaltColor.caption)
                Spacer()
                Text(Copy.Gallery.length(combine.seconds))
                    .font(.cobalt(12.5, .semibold, relativeTo: .caption))
                    .monospacedDigit()
            }
            Slider(
                value: Binding(get: { combine.seconds }, set: { combine.seconds = SlideshowPlan.snapped($0) }),
                in: SlideshowPlan.secondsRange, step: SlideshowPlan.secondsStep
            )
            .tint(CobaltColor.text)
            .frame(minHeight: Metrics.hit)
            .accessibilityLabel(Copy.Gallery.eachPhoto)
            .accessibilityValue(Copy.Combine.secondsA11y(Copy.Gallery.length(combine.seconds)))
            Text(combine.output == .slideshowWebp ? Copy.Combine.secondsNoteWebp : Copy.Combine.secondsNoteMp4)
                .font(CobaltType.badge)
                .foregroundStyle(CobaltColor.caption)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: crossfade, frame, sound

    private var crossfade: some View {
        Toggle(isOn: $combine.fade) {
            VStack(alignment: .leading, spacing: 1) {
                Text(Copy.Gallery.crossfade).font(CobaltType.bodySemibold)
                Text(fadeNote)
                    .font(CobaltType.badge)
                    .foregroundStyle(CobaltColor.caption)
            }
        }
        .toggleStyle(.switch)
        .tint(CobaltColor.success)
        .frame(minHeight: Metrics.hit)
    }

    private var fadeNote: String {
        if combine.output == .slideshowWebp {
            let adds = max(0, combine.webpBytes(fade: true) - combine.webpBytes(fade: false))
            return Copy.Combine.fadeNoteWebp(on: combine.fade, adds: Copy.Gallery.size(adds))
        }
        return Copy.Combine.fadeNoteMp4(on: combine.fade)
    }

    private var frameRow: some View {
        pickerRow(Copy.Gallery.frame) {
            Picker(Copy.Gallery.frame, selection: $combine.frame) {
                Text(Copy.Gallery.asPosted).tag(SlideshowPlan.Frame.asPosted)
                Text(Copy.Combine.frameShortStory).tag(SlideshowPlan.Frame.story)
                Text(Copy.Combine.frameShortSquare).tag(SlideshowPlan.Frame.square)
            }
        }
    }

    private var soundRow: some View {
        pickerRow(Copy.Gallery.sound) {
            Picker(Copy.Gallery.sound, selection: $combine.sound) {
                Text(Copy.Gallery.soundNone).tag(SlideshowPlan.Sound.none)
                Text(Copy.Gallery.soundOwn).tag(SlideshowPlan.Sound.own)
            }
        }
    }

    private func pickerRow<P: View>(_ label: String, @ViewBuilder picker: () -> P) -> some View {
        HStack(spacing: 12) {
            Text(label)
                .font(CobaltType.captionSmall)
                .foregroundStyle(CobaltColor.caption)
            picker()
                .pickerStyle(.segmented)
                .labelsHidden()
                #if os(iOS)
                .controlSize(.large)
                #endif
                .frame(maxWidth: 260)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }
}

// MARK: - the preview

/// One slide of the plan, in play order.
private struct Slide: Identifiable {
    var id: Int { item.id }
    let item: GalleryItem
    let start: Double
    let length: Double
}

/// Plays the plan in a frame of the make's shape: a photo for `each photo` seconds, a video or gif for its own length, a
/// crossfade as an opacity ramp over the last 0.3 s, an item of another shape on a blurred, darkened copy of itself
/// (the server's `frame`). The timeline under it is a row of buttons sized by seconds: press one to jump there.
struct CombinePreviewPlayer: View {
    let combine: CombineModel
    @State private var playing = true
    @State private var anchor = Date()
    @State private var base = 0.0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var slides: [Slide] {
        var start = 0.0
        return combine.chosenItems.map { item in
            let length = max(0.1, item.isMotion ? (item.duration ?? 1) : combine.seconds)
            defer { start += length }
            return Slide(item: item, start: start, length: length)
        }
    }

    var body: some View {
        let slides = slides
        let total = slides.reduce(0) { $0 + $1.length }
        VStack(alignment: .leading, spacing: 10) {
            TimelineView(.animation(paused: !playing)) { context in
                let t = time(at: context.date, total: total)
                player(slides: slides, t: t, total: total)
            }
            timeline(slides: slides, total: total)
        }
        .onChange(of: combine.tickedIDs) { _, _ in restart() }
        // Reduce Motion: the preview waits for the owner to press play
        .onAppear { if reduceMotion { playing = false } }
    }

    private func time(at date: Date, total: Double) -> Double {
        guard total > 0 else { return 0 }
        let raw = base + (playing ? date.timeIntervalSince(anchor) : 0)
        return raw.truncatingRemainder(dividingBy: total)
    }

    private func restart() {
        base = 0
        anchor = Date()
    }

    private func toggle(total: Double) {
        let now = Date()
        if playing { base = time(at: now, total: total) } else { anchor = now }
        playing.toggle()
    }

    private func seek(to start: Double) {
        base = start
        anchor = Date()
    }

    // MARK: player

    private func player(slides: [Slide], t: Double, total: Double) -> some View {
        let frame = combine.frameSize
        let box = Self.box(for: frame, longest: 168)
        let current = slides.lastIndex { t >= $0.start } ?? 0
        let slide = slides.isEmpty ? nil : slides[current]
        let remaining = slide.map { $0.length - (t - $0.start) } ?? 1
        let mix = combine.fade && current < slides.count - 1 && remaining < SlideshowPlan.crossfadeSeconds
            ? 1 - remaining / SlideshowPlan.crossfadeSeconds : 0
        let name = slides.isEmpty ? Copy.Combine.nothingTicked : Copy.Combine.slide(current + 1, of: slides.count)
        return HStack(alignment: .bottom, spacing: 14) {
            ZStack {
                Color.black
                if let slide { layer(slide.item, box: box) }
                if mix > 0, current + 1 < slides.count { layer(slides[current + 1].item, box: box).opacity(mix) }
            }
            .frame(width: box.width, height: box.height)
            .clipShape(.rect(cornerRadius: 8))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Copy.Combine.previewA11y(name))

            VStack(alignment: .leading, spacing: 6) {
                Button { toggle(total: total) } label: {
                    Image(systemName: playing ? "pause.fill" : "play.fill")
                        .font(.system(size: 15, weight: .semibold))
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
                #if os(iOS)
                .controlSize(.large)
                #endif
                .accessibilityLabel(playing ? Copy.Combine.pauseA11y : Copy.Combine.playA11y)
                Text("\(clock(t)) / \(clock(total))")
                    .font(CobaltType.captionSmall)
                    .monospacedDigit()
                Text(name).font(CobaltType.captionSmall).foregroundStyle(CobaltColor.caption)
                Text(Copy.Combine.frameSize(frame)).font(CobaltType.captionSmall).foregroundStyle(CobaltColor.caption).monospacedDigit()
            }
        }
    }

    /// One slide in the frame: the whole picture, centred; over a blurred, darkened copy that fills the frame when its shape is
    /// not the frame's.
    private func layer(_ item: GalleryItem, box: CGSize) -> some View {
        let frameAspect = box.width / box.height
        let aspect = combineAspect(item)
        let differs = abs(aspect - frameAspect) / frameAspect >= 0.01
        let sources = combine.pictureSources(item.id)
        return ZStack {
            if differs {
                CombinePicture(sources: sources, maxPixel: 200, item: item, number: item.id, showsNumber: false)
                    .frame(width: box.width, height: box.height)
                    .blur(radius: 9)
                    .brightness(-0.15)
                    .clipped()
            }
            CombinePicture(sources: sources, maxPixel: 480, item: item, number: item.id, fills: false)
                .aspectRatio(aspect, contentMode: .fit)
                .frame(width: box.width, height: box.height)
        }
        .frame(width: box.width, height: box.height)
    }

    /// The frame fitted to a square of `longest` points.
    static func box(for frame: CGSize, longest: CGFloat) -> CGSize {
        guard frame.width > 0, frame.height > 0 else { return CGSize(width: longest, height: longest) }
        let aspect = frame.width / frame.height
        return aspect >= 1
            ? CGSize(width: longest, height: (longest / aspect).rounded())
            : CGSize(width: (longest * aspect).rounded(), height: longest)
    }

    private func clock(_ x: Double) -> String {
        let m = Int(x) / 60
        let r = x - Double(m * 60)
        return String(format: "%02d:%04.1f", m, r)
    }

    // MARK: timeline

    private func timeline(slides: [Slide], total: Double) -> some View {
        let parts = slides.map { slide in
            Copy.Combine.segmentA11y(combine.name(slide.item.id), seconds: Copy.Gallery.length(slide.length))
        }
        return TimelineView(.animation(paused: !playing)) { context in
            let t = time(at: context.date, total: total)
            let current = slides.lastIndex { t >= $0.start } ?? 0
            GeometryReader { proxy in
                let gaps = CGFloat(max(0, slides.count - 1)) * 2
                let available = max(0, proxy.size.width - gaps)
                HStack(spacing: 2) {
                    ForEach(Array(slides.enumerated()), id: \.element.id) { index, slide in
                        let width = max(3, available * slide.length / max(total, 0.1))
                        let progress = index == current ? min(1, max(0, (t - slide.start) / slide.length)) : (index < current ? 1 : 0)
                        Button { seek(to: slide.start) } label: {
                            segment(slide, width: width, progress: progress, active: index == current)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(parts[index])
                    }
                }
            }
            .frame(height: Metrics.hit)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Copy.Combine.timelineA11y(parts))
    }

    private func segment(_ slide: Slide, width: CGFloat, progress: Double, active: Bool) -> some View {
        ZStack(alignment: .leading) {
            Rectangle().fill(slide.item.isMotion ? CobaltColor.border : CobaltColor.elevated)
            Rectangle().fill(CobaltColor.text.opacity(0.28)).frame(width: width * progress)
            if width > 22 {
                Text("\(slide.item.id + 1)")
                    .font(.cobalt(9, .regular, relativeTo: .caption2))
                    .foregroundStyle(CobaltColor.text)
                    .frame(maxWidth: .infinity)
            }
        }
        .frame(width: width, height: 30)
        .clipShape(.rect(cornerRadius: 3))
        .overlay { if active { RoundedRectangle(cornerRadius: 3).strokeBorder(CobaltColor.text.opacity(0.5), lineWidth: 1) } }
        .frame(width: width, height: Metrics.hit)
        .contentShape(.rect)
    }
}
