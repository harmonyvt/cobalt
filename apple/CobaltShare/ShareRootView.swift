import CobaltKit
import SwiftUI
import UIKit

/// Previews and the evidence harness cannot set the system's Reduce Motion (the environment value is
/// read-only), so they set this: the sheet behaves as if it were on.
private struct ShareReducesMotionKey: EnvironmentKey { static let defaultValue = false }

extension EnvironmentValues {
    var shareReducesMotion: Bool {
        get { self[ShareReducesMotionKey.self] }
        set { self[ShareReducesMotionKey.self] = newValue }
    }
}

/// The compact share sheet (`Share.dc.html`): the same progress card as the app, over
/// whatever app you were in. Clips up to 10 s finish here; longer ones hand off to cobalt on the
/// trim; closing mid-render keeps the render going and the app picks it up.
///
/// Layout: the content hugs its top (title, source chip, one card) and the card is as tall as what it
/// holds. While something is being fetched, saved or read the card is the progress card alone; once a
/// clip is ready it is a poster, the real frames, a length readout and the actions (one prominent).
struct ShareRootView: View {
    let model: ShareModel
    /// Called with the content's own height (every layout change): the controller sizes the sheet to
    /// it, so the sheet ends right under the card. Nil in previews.
    var onFit: ((CGFloat) -> Void)?

    @State private var copied = false
    /// What is typed in the inline title row (nil until the owner touches it: the row shows the default).
    @State private var titleDraft: String?
    @State private var sharing = false
    @AccessibilityFocusState private var stayFocused: Bool
    /// The countdown whose start has been announced (once per countdown, however many times the card
    /// is rebuilt as the run moves from saving to ready).
    @State private var announced: Date?
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.shareReducesMotion) private var forcedReduceMotion
    private var reduceMotion: Bool { systemReduceMotion || forcedReduceMotion }
    @Environment(\.hapticsEnabled) private var haptics

    private var pipeline: Pipeline { model.pipeline }

    /// What the ready card calls the clip: the owner's title when they typed one, else the media's name (a link
    /// save's ref), as before.
    private var name: String {
        if let title = pipeline.runTitle { return title }
        if let name = pipeline.media?.name { return name }
        if case .link(let info) = pipeline.input { return info.ref }
        return Copy.appName
    }

    /// The file being shared, while it uploads, saves and is read: the card's inline title row names it
    /// (CONTRACT-LIBRARY2 decision 3). Link shares get no field (their default is `service · ref`; rename later),
    /// and a server that cannot keep a title has nothing to send it to.
    private var titledFile: String? {
        guard model.capabilities.titles, case .file(let name, _, _) = pipeline.input else { return nil }
        switch pipeline.state {
        case .uploading, .saving, .reading: return name
        default: return nil
        }
    }

    private var duration: Double { pipeline.media?.duration ?? pipeline.maxClipSeconds }

    /// The first frame the pipeline has read: the poster.
    private var poster: Frame? { pipeline.frames.first(where: { $0 != nil }) ?? nil }

    var body: some View {
        // The content is as tall as what it holds: the sheet is sized to it (`SheetFitter`), and when
        // the screen cannot give that much the scroll view takes over (it never scrolls otherwise).
        ScrollView {
            VStack(spacing: 12) {
                header
                if case .link(let info) = pipeline.input {
                    LinkChip(service: info.service, ref: info.ref)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .transition(.chipIn(reduced: reduceMotion))
                }
                card
            }
            .padding(.horizontal, 16)
            .padding(.top, 10)
            .padding(.bottom, 20)
            .frame(maxWidth: .infinity)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { onFit?($0) }
        }
        .scrollBounceBehavior(.basedOnSize)
        .background(CobaltColor.bg.ignoresSafeArea())
        .dynamicTypeSize(...DynamicTypeSize.accessibility2)
        .environment(\.hapticsEnabled, true)
        // No animation on the layout here: the sheet animates its own height to the new content
        // (`SheetFitter`), and a second, SwiftUI-driven height animation would race it.
        .onChange(of: countdown?.endsAt, initial: true) { _, endsAt in announceCountdown(endsAt) }
        .haptic(.error, trigger: pipeline.state, enabled: haptics) { if case .failed = $0 { return true } else { return false } }
        .haptic(.success, trigger: pipeline.state, enabled: haptics) { if case .done = $0 { return true } else { return false } }
        .sheet(isPresented: $sharing) {
            if case .done(let result) = pipeline.state {
                ActivitySheet(items: [result.url]).presentationDetents([.medium, .large])
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Copy.shareSheetA11y)
    }

    // MARK: header

    private var header: some View {
        HStack {
            Text(Copy.appName)
                .font(Font.cobalt(16, .semibold, relativeTo: .headline))
                .foregroundStyle(CobaltColor.text)
                .accessibilityAddTraits(.isHeader)
            Spacer()
            CloseButton { close() }
        }
    }

    private func close() {
        commitTitle()
        Task { _ = await model.close() }
    }

    /// Whatever is typed in the title row goes to the run before anything that ends or hands off the sheet reads
    /// it (the share job carries `runTitle` to the app).
    private func commitTitle() {
        guard let draft = titleDraft, case .file(let name, _, _) = pipeline.input else { return }
        pipeline.setTitle(TitleText.custom(draft, default: MediaTitle.stripExtension(name)))
    }

    // MARK: card

    @ViewBuilder
    private var card: some View {
        if pipeline.state != .idle {
            let shape = RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .continuous)
            VStack(alignment: .leading, spacing: 12) {
                // outside the switch: the row keeps what is typed (and the keyboard) as the run moves from
                // uploading to saving to reading
                if let file = titledFile {
                    let fallback = MediaTitle.stripExtension(file)
                    TitleRow(
                        pipeline: pipeline, defaultTitle: fallback,
                        draft: Binding(get: { titleDraft ?? pipeline.runTitle ?? fallback }, set: { titleDraft = $0 }))
                        .transition(.opacity)
                }
                switch pipeline.state {
                case .picker(let items):
                    PickerContent(pipeline: pipeline, items: items, webpAvailable: model.webpAvailable)
                case .failed(let f) where !f.keepsTrim:
                    failure(f)
                case .fetching, .saving, .rendering, .gallery:         // `.gallery`: lane A4 replaces this with the compact sheet
                    working
                    continueBlock
                case .reading:
                    // the save is done, the frames are loading: a running countdown stays on screen
                    working
                    continueBlock
                case .uploading, .idle:
                    working
                case .done(let result):
                    doneBody(result)
                case .image(let info):
                    imageBody(info)
                case .savedLocally:
                    note(Copy.savedLocally)
                    photosBlock
                case .ready, .failed:
                    readyBody
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .background(CobaltColor.surface, in: shape)
            .transition(.opacity)
        }
    }

    /// Fetching, saving, reading, rendering: the progress card and nothing else (no empty placeholder
    /// for the video that does not exist yet).
    @ViewBuilder
    private var working: some View {
        if let story = pipeline.progressStory { ProgressCard(story: story).transition(.opacity) }
    }

    // MARK: ready

    @ViewBuilder
    private var readyBody: some View {
        HStack(alignment: .top, spacing: 12) {
            if let poster { PosterThumb(frame: poster).transition(.opacity) }
            VStack(alignment: .leading, spacing: 6) {
                Text(name)
                    .font(CobaltType.bodySemibold)
                    .foregroundStyle(CobaltColor.text)
                    .lineLimit(2)
                    .truncationMode(.middle)
                LengthReadout(seconds: pipeline.trim.length, over: pipeline.trimOverLimit, font: Font.cobalt(22, .medium, relativeTo: .title2))
                note(model.isLong ? Copy.overLimit(duration, limit: pipeline.maxClipSeconds) : Copy.wholeClipFits)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        strip
        readyActions
    }

    /// Real frames when CobaltKit has them; a shimmer while they load. Never the black frame base.
    @ViewBuilder
    private var strip: some View {
        if pipeline.frames.contains(where: { $0 != nil }) {
            TrimStrip(pipeline: pipeline, interactive: false, height: 64)
                .padding(.vertical, 6)
        } else if pipeline.framesFailed {
            note(ShareCopy.previewFailed)
        } else {
            StripPlaceholder(height: 64)
                .padding(.vertical, 6)
        }
    }

    @ViewBuilder
    private var readyActions: some View {
        if case .failed(let f) = pipeline.state {
            InlineStatus(message: Copy.failure(f))
            Button(f == .renderBusy ? Copy.tryAgain : Copy.makeItAgain, systemImage: Symbol.retry) { model.noteInteraction(); pipeline.makeWebp() }
                .buttonStyle(.cobaltPrimary())
        } else {
            GlassEffectContainer(spacing: 8) {
                VStack(spacing: 8) {
                    if model.isLong {
                        Button(Copy.trimInCobalt, systemImage: Symbol.openApp) { model.noteInteraction(); commitTitle(); Task { await model.handOffToApp() } }
                            .buttonStyle(.cobaltPrimary())
                    } else {
                        Button(Copy.makeWebp, systemImage: Symbol.makeWebp) { model.noteInteraction(); pipeline.makeWebp() }
                            .buttonStyle(.cobaltPrimary())
                    }
                    photosButton()
                }
            }
            photosStatus
            continueBlock
        }
    }

    // MARK: done

    private func doneBody(_ result: WebpResult) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                ResultTile(pipeline: pipeline, result: result, maxWidth: 104, maxHeight: 132)
                VStack(alignment: .leading, spacing: 6) {
                    Text(ShareCopy.webpReady)
                        .font(CobaltType.bodySemibold)
                        .foregroundStyle(CobaltColor.text)
                    note(resultMeta(result))
                    Text(displayURL(result.url))
                        .font(CobaltType.caption)
                        .foregroundStyle(CobaltColor.caption)
                        .lineLimit(2)
                        .truncationMode(.middle)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            GlassEffectContainer(spacing: 8) {
                VStack(spacing: 8) {
                    Button(copied ? Copy.copied : ShareCopy.copyWebpLink, systemImage: copied ? Symbol.checkmark : Symbol.copyLink) {
                        model.noteInteraction()
                        pipeline.copyResultLink()
                        copied = true
                        Task {
                            try? await Task.sleep(for: .seconds(1.8))
                            copied = false
                        }
                    }
                    .buttonStyle(copied ? .cobaltDone() : .cobaltPrimary())
                    .symbolBounce(on: copied)
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 8) { doneSecondaries }
                        VStack(spacing: 8) { doneSecondaries }
                    }
                }
            }
            photosStatus
            continueBlock
        }
    }

    @ViewBuilder
    private var doneSecondaries: some View {
        Button(ShareCopy.share, systemImage: ShareSymbol.share) { model.noteInteraction(); sharing = true }
            .buttonStyle(.cobaltSecondary(compact: true))
        photosButton(compact: true)
    }

    // MARK: save to photos

    /// "save to photos": its own icon in every state (`photo.badge.arrow.down`, never a retry arrow),
    /// a spinner while it works, "saved" with a checkmark when done. A failure keeps the button and
    /// says why underneath (`photosStatus`).
    @ViewBuilder
    private func photosButton(prominent: Bool = false, compact: Bool = false) -> some View {
        switch pipeline.photosPlacement {
        case .inAlbum: placedButton(Copy.Sync.inAlbum, compact: compact)
        case .inLibrary: placedButton(Copy.Sync.inLibrary, compact: compact)
        case .none: savePhotosButton(prominent: prominent, compact: compact)
        }
    }

    /// The original is already in the owner's photos (CONTRACT-SYNC.md decision 12): done style, not
    /// tappable, no bounce (nothing just happened).
    private func placedButton(_ title: String, compact: Bool) -> some View {
        Button(title, systemImage: Symbol.Sync.inPhotos) {}
            .buttonStyle(.cobaltDone(compact: compact))
            .allowsHitTesting(false)
            .accessibilityRemoveTraits(.isButton)
    }

    @ViewBuilder
    private func savePhotosButton(prominent: Bool, compact: Bool) -> some View {
        switch pipeline.photos {
        case .done:
            Button(Copy.savedPhotos, systemImage: Symbol.checkmark) {}
                .buttonStyle(.cobaltDone(compact: compact))
                .symbolBounce(on: true)
                .allowsHitTesting(false)
        case .working:
            Button {} label: {
                Label { Text(ShareCopy.savingPhotos(pipeline.photosStep)) } icon: { ProgressView().controlSize(.small) }
            }
            .buttonStyle(.cobaltSecondary(compact: compact))
            .disabled(true)
        case .idle, .failed:
            let failed: Bool = { if case .failed = pipeline.photos { return true } else { return false } }()
            let title = failed ? ShareCopy.tapToTryAgain : Copy.savePhotos
            if prominent && !failed {
                Button(title, systemImage: Symbol.savePhotos) { model.noteInteraction(); pipeline.saveToPhotos() }.buttonStyle(.cobaltPrimary())
            } else {
                Button(title, systemImage: Symbol.savePhotos) { model.noteInteraction(); pipeline.saveToPhotos() }
                    .buttonStyle(.cobaltSecondary(compact: compact))
            }
        }
    }

    @ViewBuilder
    private var photosStatus: some View {
        if case .failed(let f) = pipeline.photos {
            InlineStatus(message: ShareCopy.photosFailure(f)).transition(.opacity)
        }
    }

    private var photosBlock: some View {
        VStack(spacing: 8) {
            photosButton(prominent: true)
            photosStatus
            continueBlock
        }
    }

    // MARK: continue in background

    private var countdown: (endsAt: Date, seconds: Int)? {
        if case .counting(let endsAt, let seconds) = model.autoContinue { return (endsAt, seconds) }
        return nil
    }

    /// Shown while a save or a render is in flight: the sheet leaves, the work carries on. While the
    /// countdown runs it is one compact line under the card's actions (a draining ring, the seconds,
    /// stay); the countdown outlives the save, so the line stays through reading and ready
    /// (CONTRACT-SYNC.md decision 3, owner 2026-10-04) and never adds a second prominent button.
    /// Armed, stopped and off show the plain block. Once it has fired the sheet is closing: nothing.
    @ViewBuilder
    private var continueBlock: some View {
        if let countdown {
            countdownLine(endsAt: countdown.endsAt, seconds: countdown.seconds)
                .transition(.opacity.combined(with: .move(edge: .bottom)))
        } else if model.canContinueInBackground, model.autoContinue != .fired {
            plainContinueBlock
                .transition(.opacity.combined(with: .move(edge: .bottom)))
        }
    }

    private var plainContinueBlock: some View {
        VStack(spacing: 6) {
            Button(ShareCopy.continueInBackground, systemImage: ShareSymbol.background) {
                commitTitle()
                Task { await model.continueInBackground() }
            }
            .buttonStyle(.cobaltSecondary())
            Text(model.capabilities.notifyBridge ? ShareCopy.notifyWhenDone : ShareCopy.openLater)
                .font(CobaltType.caption)
                .foregroundStyle(CobaltColor.caption)
                .frame(maxWidth: .infinity, alignment: .center)
        }
    }

    /// `[ring + moon]  continuing in background in 5 s  ...  [stay]`, one line at the default text
    /// size. When it does not fit (large Dynamic Type) the caption wraps beside the ring and stay stays
    /// trailing. The icon carries the draining ring (plain icon under Reduce Motion: then the caption's
    /// whole seconds are the only signal). No separate continue button: the sheet continues by itself.
    private func countdownLine(endsAt: Date, seconds: Int) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 5) {
                countdownIcon(endsAt: endsAt, seconds: seconds)
                CountdownCaption(endsAt: endsAt, seconds: seconds, singleLine: true)
                Spacer(minLength: 3)
                stayButton
            }
            HStack(alignment: .center, spacing: 8) {
                HStack(alignment: .top, spacing: 8) {
                    countdownIcon(endsAt: endsAt, seconds: seconds)
                    CountdownCaption(endsAt: endsAt, seconds: seconds, singleLine: false)
                }
                Spacer(minLength: 8)
                stayButton
            }
        }
        .frame(minHeight: Metrics.hit)
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private func countdownIcon(endsAt: Date, seconds: Int) -> some View {
        if reduceMotion {
            Image(systemName: ShareSymbol.background)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(CobaltColor.text)
                .frame(width: 16, height: 16)
                .accessibilityHidden(true)
        } else {
            CountdownRing(endsAt: endsAt, seconds: seconds, symbol: ShareSymbol.background)
        }
    }

    /// First VoiceOver focus (sort priority above everything else on the sheet's row). A compact
    /// capsule, 44 pt tall to hit. The label never changes with the seconds.
    private var stayButton: some View {
        Button { model.stay() } label: {
            Label(ShareCopy.stay, systemImage: ShareSymbol.stay)
                .labelStyle(.titleAndIcon)
                .font(CobaltType.buttonSmall)
                .foregroundStyle(CobaltColor.text)
                .lineLimit(1)
                .padding(.horizontal, 8)
                .frame(height: 32)
                .background(CobaltColor.elevated, in: Capsule())
                .frame(minWidth: Metrics.hit, minHeight: Metrics.hit)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityFocused($stayFocused)
        .accessibilitySortPriority(1)
    }

    /// Once per countdown: VoiceOver gets the sentence and focus lands on stay. Focus first, the
    /// sentence a beat later so the focus change does not cut it off.
    private func announceCountdown(_ endsAt: Date?) {
        guard let endsAt, let countdown, announced != endsAt else { return }
        announced = endsAt
        guard UIAccessibility.isVoiceOverRunning else { return }
        let seconds = countdown.seconds
        Task {
            try? await Task.sleep(for: .milliseconds(350))
            stayFocused = true
            try? await Task.sleep(for: .milliseconds(450))
            UIAccessibility.post(notification: .announcement, argument: ShareCopy.continuingAnnouncement(seconds))
        }
    }

    // MARK: other states

    private func imageBody(_ info: MediaInfo) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            note(Copy.imageNote)
            // Publishing no longer copies the link by itself: once it is public the button copies it.
            StatusButton(title: pipeline.hosting == .done ? Copy.copyLink : Copy.hostAsIs, systemImage: Symbol.host, status: pipeline.hosting, prominent: true) {
                model.noteInteraction()
                if pipeline.hosting == .done, let url = pipeline.hostedOriginalURL {
                    UIPasteboard.general.string = url.absoluteString
                } else {
                    pipeline.hostOriginal()
                }
            }
        }
    }

    private func failure(_ f: PipelineFailure) -> some View {
        InlineStatus(message: Copy.failure(f)) {
            Button(Copy.ok, systemImage: Symbol.checkmark) { close() }.buttonStyle(.cobaltSecondary(fullWidth: false))
        }
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(CobaltType.caption)
            .foregroundStyle(CobaltColor.caption)
            .fixedSize(horizontal: false, vertical: true)
    }
}

#if DEBUG
private struct ShareHost: View {
    @State private var model: ShareModel
    private let scenario: PreviewScenario
    private let script: PreviewScript
    private let autoContinue: ((Date) -> AutoContinue)?
    private let placement: PhotosPlacement?
    private let waitReady: Bool

    /// `autoContinue` builds the pinned countdown state from "now" (so a counting row has time left);
    /// `waitReady` holds the pin until the run is ready (the countdown still counting at ready).
    init(
        _ scenario: PreviewScenario, script: PreviewScript = .input,
        autoContinue: ((Date) -> AutoContinue)? = nil, placement: PhotosPlacement? = nil, waitReady: Bool = false
    ) {
        _model = State(initialValue: ShareModel.preview(scenario))
        self.scenario = scenario
        self.script = script
        self.autoContinue = autoContinue
        self.placement = placement
        self.waitReady = waitReady
    }

    var body: some View {
        ShareRootView(model: model)
            .task {
                if let autoContinue, !waitReady { model.previewAutoContinue(autoContinue(.now)) }
                model.pipeline.previewPhotosPlacement(placement)
                await runPreviewScript(script, scenario: scenario, pipeline: model.pipeline)
                if let autoContinue, waitReady {
                    for _ in 0..<100 {
                        if case .ready = model.pipeline.state { break }
                        try? await Task.sleep(for: .milliseconds(100))
                    }
                    model.previewAutoContinue(autoContinue(.now))
                }
            }
    }
}

/// A file share: the card with the inline title row while the upload runs.
private struct ShareFileHost: View {
    @State private var model = ShareModel.preview(.happy)

    var body: some View {
        ShareRootView(model: model)
            .task {
                guard model.pipeline.state == .idle else { return }
                model.pipeline.start(file: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("IMG_0412.mov"))
            }
    }
}

private func counting(_ seconds: Int) -> (Date) -> AutoContinue {
    { now in .counting(endsAt: now.addingTimeInterval(Double(seconds)), seconds: seconds) }
}

#Preview("share · short clip") { ShareHost(.shortClip, script: .render) }
#Preview("share · long clip (hands off)") { ShareHost(.happy) }
#Preview("share · file, title row") { ShareFileHost() }
#Preview("share · cold start") { ShareHost(.coldStart) }
#Preview("share · no link") { ShareHost(.noLink) }
#Preview("share · private post") { ShareHost(.privatePost) }
#Preview("share · picker") { ShareHost(.picker) }
#Preview("share · image") { ShareHost(.image) }
#Preview("share · render busy") { ShareHost(.renderBusy, script: .render) }
#Preview("share · render lost") { ShareHost(.renderLost, script: .render) }
#Preview("share · plain cobalt") { ShareHost(.plainCobalt) }
#Preview("share · legacy fork") { ShareHost(.legacyFork) }
#Preview("share · revoked key") { ShareHost(.revokedKey) }

// auto continue (CONTRACT-SYNC.md section 6)
#Preview("share · counting 5 s") { ShareHost(.coldStart, autoContinue: counting(5)) }
#Preview("share · counting 5 s · reduce motion") {
    ShareHost(.coldStart, autoContinue: counting(5)).environment(\.shareReducesMotion, true)
}
#Preview("share · counting, still at ready") { ShareHost(.shortClip, autoContinue: counting(3), waitReady: true) }
#Preview("share · stopped by stay") { ShareHost(.coldStart, autoContinue: { _ in .stopped(.stay) }) }
#Preview("share · armed") { ShareHost(.coldStart, autoContinue: { _ in .armed }) }

// the save-to-photos button, placed
#Preview("share · in your cobalt album") {
    ShareHost(.shortClip, autoContinue: { _ in .off }, placement: .inAlbum, waitReady: true)
}
#Preview("share · in your photos") {
    ShareHost(.shortClip, autoContinue: { _ in .off }, placement: .inLibrary, waitReady: true)
}
#endif
