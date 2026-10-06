import AVFoundation
import CobaltKit
import Combine
import SwiftUI

// The focus state (CONTRACT-ORBIT section 2). When the star's morph lands, the new planet lifts out of
// its band into focus: hero size (about 60 % of the content width, real aspect), elevated on a Liquid
// Glass bezel, playing muted (tap = sound). The planet IS the card: choices sit under it (public share,
// convert to webp, save to photos, close); converting shows the decoded frames as ticks along its bottom
// edge, sharing sweeps light around its edge, and either ends in a diagonal specular shimmer after which
// the planet carries a badge (sparkles for the webp, link for the hosted original) and the result's
// actions appear (copy link, share). Close, or swipe down, returns the planet to band 0.

enum FocusMotion {
    /// The star becoming the planet in its band (the hero rides the morph).
    static let morph = Animation.spring(duration: 0.8, bounce: 0.2)
    static let lift = Animation.spring(duration: 0.72, bounce: 0.18)
    static let land = Animation.spring(duration: 0.55, bounce: 0.1)
    static let content = Animation.spring(duration: 0.5, bounce: 0.2)
    static let crossfade = Animation.easeInOut(duration: 0.4)
}

/// What the planet is doing at its edge.
enum HeroProgress: Equatable {
    case none
    /// Decoded frames so far: ticks along the bottom edge light up.
    case decoding(done: Int, total: Int)
    /// Open-ended: the ticks stay lit and the planet breathes.
    case packing
    /// Nothing counted yet: the planet breathes.
    case working
}

// MARK: - the layer

struct FocusLayer: View {
    let model: AppModel
    let pipeline: Pipeline
    /// The home column's width (the planet is about 60 % of it).
    let contentWidth: CGFloat
    /// Where the planet is heading: the star's dot, its slot in band 0, or the lifted hero. The one hero
    /// view rides between these poses (HeroFlight.swift).
    let phase: FocusPhase
    /// True once the planet has lifted into focus; false while it is in its band (the return).
    let lifted: Bool
    /// The focused planet's player: owned by the home screen so the orbit can take it over, still playing,
    /// when the planet goes back to its band.
    let player: FocusPlayerHolder
    /// The home screen is on screen (the save tab, no detail pushed over it): off screen the video
    /// pauses and the audio session is given back.
    var visible = true
    /// A throwaway instance mounted once at idle (HomeScreen's warm-up) so the first real focus does not pay the
    /// first-use cost of these views (SwiftUI's layout descriptors, glass, the player surface) in the middle of the
    /// morph. It draws nothing, takes no touches and touches no state of the run.
    var warm = false
    /// Room kept free at the top of a single-column layout for the tray's pill (JobTray.swift): the pill sits under
    /// the title while a planet is in focus and must not cover it.
    var topReserve: CGFloat = 0
    /// A gallery's `open`: the home screen pushes the media's detail (by the media's id) over the focus.
    var onOpen: (String) -> Void = { _ in }
    /// Close or swipe down.
    let onClose: () -> Void

    @State private var showsTrim = false
    /// The crop editor's draft, while the editor is open over the planet (CONTRACT-ORBIT 2d).
    @State private var cropEditor: CropEditorModel?
    /// Plays the selection (looping) while the trim panel is open; the strip's playhead reads it.
    @State private var trimPreview = TrimPreview()
    @State private var showsWebp = false
    /// The output a tap on `make from it` chose: the combine sheet is up with it (a gallery).
    @State private var makeKind: GalleryMakeKind?
    @State private var shimmer = 0
    @State private var pulse = 0
    @State private var copiedWebp = false
    @State private var copiedLink = false
    @State private var muted = true
    /// The hero's media controls (CONTRACT-ORBIT 2, owner 1.3): what the bar reads and drives.
    @State private var transport = HeroTransport()
    /// The full-screen player or viewer, while it is up.
    @State private var fullScreen: HeroFullScreen?
    @State private var dragY: CGFloat = 0
    @State private var slot: CGRect = .zero
    /// The lift has landed (its spring is over): from here the planet's room changes with the rows under it.
    @State private var liftSettled = false
    /// When "publishing the video" began (its seconds count from here).
    @State private var hostSince = Date()
    @Namespace private var span
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.hapticsEnabled) private var haptics
    @Environment(\.homeHeight) private var homeHeight

    // MARK: derived

    private var capabilities: Capabilities { model.capabilities }
    /// Public hosting is a fork feature: plain cobalt only gets the system share sheet for the local file.
    private var isFork: Bool { capabilities.studio && capabilities.kind != .plainCobalt && pipeline.sessionID != nil }

    private var localVideo: StoredVideo? {
        // a gallery's stored items are photos (and clips) of its own, not the run's one video
        if isGallery { return nil }
        if case .savedLocally(let video) = pipeline.state { return video }
        if let stored = pipeline.stored { return stored }
        guard let sid = pipeline.sessionID else { return nil }
        return model.store.videos.first { $0.sessionID == sid && $0.kind == .original }
    }

    /// THIS run's webp: the stored record of the render the pipeline just made (CONTRACT-MEDIA 1.6). The
    /// media's other webps share its session, so the session no longer names it; the render's own URL does.
    private var storedWebp: StoredVideo? {
        guard let url = pipeline.webpResult?.url else { return nil }
        return model.store.videos.first { $0.kind == .webp && $0.remoteURL == url }
    }

    // MARK: gallery

    private var isGallery: Bool { if case .gallery = pipeline.state { return true } else { return false } }

    /// This gallery's media on the device, once its first item is stored.
    private var storedGallery: StoredMedia? { pipeline.mediaID.flatMap { model.store.media(id: $0) } }

    /// What the gallery focus says; nil for every other run.
    private var galleryFacts: GalleryFacts? {
        isGallery ? GalleryFacts(model: model, pipeline: pipeline, title: title) : nil
    }

    /// The count and the cover the hero wears (the stack only from 2 items).
    private var galleryHero: GalleryHero? {
        guard isGallery else { return nil }
        let items = pipeline.galleryItems
        let count = max(pipeline.galleryRun?.total ?? 0, items.count, 1)
        let stored = storedGallery?.items.first.flatMap { PlanetStills.picture(of: $0) }
        return GalleryHero(count: count, cover: GalleryCoverSource(file: stored, remote: items.first?.thumb))
    }

    /// The cover's shape: the first item's, until the library says, a 4:5 post.
    private var galleryAspect: CGFloat {
        if let first = pipeline.galleryItems.first, let w = first.width, let h = first.height, w > 0, h > 0 {
            return min(16.0 / 9.0, max(9.0 / 16.0, CGFloat(w) / CGFloat(h)))
        }
        return 4.0 / 5.0
    }

    /// The tick that says the gallery just landed (saved, or a make is done) or failed; the hero's shimmer and pulse follow it.
    private var galleryBeat: String {
        guard isGallery, let run = pipeline.galleryRun else { return "" }
        var beat = ""
        switch run.phase {
        case .saving: break
        case .saved: beat = "saved"
        case .failed: beat = "failed"
        }
        switch run.make {
        case .done(_, let result): beat += "|done:\(result.job)"
        case .failed: beat += "|makefail"
        default: break
        }
        return beat
    }

    private func chooseMake(_ kind: GalleryMakeKind) { makeKind = kind }

    /// `open`: the detail of this gallery's media on the device, pushed over the focus.
    private func openGallery() {
        guard let id = storedGallery?.id else { return }
        onOpen(id)
    }

    /// `try photo 7 again`: the post's failed items are fetched anew as a job of their own, and its run takes the
    /// focus (the hero then says `fetching photo 7 again`).
    private func retryGalleryItems() {
        guard let run = pipeline.galleryRun, let sid = pipeline.sessionID, !run.failures.isEmpty else { return }
        let queue = model.queue
        let previous = queue.focusedID
        let link: URL? = { if case .link(let info)? = pipeline.input { return info.url } else { return nil } }()
        let job = queue.addGallery(
            .retry(run.failures.keys.sorted()), session: sid, items: pipeline.galleryItems, media: pipeline.media, link: link,
            mediaID: pipeline.mediaID, failures: run.failures)
        GalleryRetry.mark(job.pipeline)
        queue.focus(job.id)
        if let previous { queue.dismiss(previous) }
    }

    /// The save failed for good (every item, the link, the server): the same link again.
    private func retryGallerySave() {
        guard let id = model.queue.focusedID else { return }
        model.queue.retry(id)
    }

    /// The make failed: the same plan again (the photos and the plan are untouched).
    private func remake() {
        guard let request = pipeline.galleryRun?.make.request else { return }
        Task { await pipeline.make(request) }
    }

    private var aspect: CGFloat {
        if isGallery { return galleryAspect }
        // a cropped webp has its own shape: the planet takes the real webp's aspect once it shows
        if showsWebp, let r = pipeline.webpResult, r.width > 0, r.height > 0 { return CGFloat(r.width) / CGFloat(r.height) }
        let w = pipeline.media?.width ?? localVideo?.width
        let h = pipeline.media?.height ?? localVideo?.height
        if let w, let h, w > 0, h > 0 { return CGFloat(w) / CGFloat(h) }
        return 9.0 / 16.0
    }

    private var isLong: Bool { (pipeline.media?.duration ?? 0) > pipeline.maxClipSeconds + 0.05 }

    // MARK: crop

    private var isCropping: Bool { cropEditor != nil }

    /// The server can crop (`features.crop`); `-previewCrop YES` shows the button over a preview scenario
    /// that does not say so (the preview server's capabilities are CobaltKit's).
    private var serverCrops: Bool {
        #if DEBUG
        if UserDefaults.standard.bool(forKey: "previewCrop") { return true }
        #endif
        return capabilities.crop
    }

    /// A crop can be set now: the server takes one, a webp can be made, and the frame is big enough for
    /// the server's 64 px minimum.
    private var canCrop: Bool {
        guard serverCrops, pipeline.canMakeWebp, let s = pipeline.sourceSize else { return false }
        return min(s.width, s.height) >= CGFloat(CropRect.minPixels)
    }

    /// "crop 1:1" / "crop", when this run has one.
    private var cropBadge: String? {
        pipeline.crop.map { CropCopy.badge($0, in: pipeline.sourceSize) }
    }

    private func openCrop() {
        guard canCrop, let source = pipeline.sourceSize else { return }
        let editor = CropEditorModel(source: source, outputWidth: model.settings.webpWidth, crop: pipeline.crop)
        withAnimation(reduceMotion ? Motion.fade : FocusMotion.content) { cropEditor = editor }
    }

    private func finishCrop() {
        guard let editor = cropEditor, editor.isValid else { return }
        pipeline.setCrop(editor.committed)
        withAnimation(reduceMotion ? Motion.fade : FocusMotion.content) { cropEditor = nil }
    }

    private var isTrimming: Bool {
        if case .ready = pipeline.state { return showsTrim }
        return false
    }

    /// The trim panel is open over a clip that is on this device: the planet shows the selection's preview.
    private var trimPreviewActive: Bool { isTrimming && originalURL != nil && visible }

    private var isRendering: Bool {
        if case .rendering = pipeline.state { return true }
        return false
    }

    /// Convert to webp is offered: a trimmed clip is waiting, or (long clips) another span can be chosen
    /// after one webp is made.
    private var canConvert: Bool {
        guard isFork else { return false }
        if pipeline.canMakeWebp { return true }
        if case .done = pipeline.state { return isLong }
        return false
    }

    private var heroProgress: HeroProgress {
        // queued, not started: the planet does not breathe for work nobody is doing yet
        if pipeline.line != nil { return .none }
        if isGallery, let run = pipeline.galleryRun {
            // the ticks along the planet's edge light up as the items land; a make in flight makes it breathe
            if case .saving = run.phase { return .decoding(done: run.done, total: max(1, run.total)) }
            if case .making = run.make { return .working }
            if case .sending = run.make { return .working }
            return .none
        }
        if case .rendering(let p) = pipeline.state {
            switch p {
            case .decoding(let done, let total): return .decoding(done: done, total: total)
            case .packing: return .packing
            case .working: return .working
            }
        }
        return .none
    }

    private var isHosting: Bool { pipeline.hosting == .working }

    /// The webp waits in the server's line (nothing has started): it can still be cancelled there.
    private var canCancelQueuedWebp: Bool {
        guard isRendering, model.queue.lineMode == .server, case .inLine? = pipeline.line else { return false }
        return pipeline.sessionID != nil
    }

    /// The edge sweep runs while hosting (`-previewSweepHold YES` holds it on for design review).
    private var heroSharing: Bool {
        #if DEBUG
        if UserDefaults.standard.bool(forKey: "previewSweepHold") { return true }
        #endif
        return isHosting
    }

    private var hasWebp: Bool { pipeline.webpResult != nil }
    private var hasLink: Bool { pipeline.hosting == .done && pipeline.hostedOriginalURL != nil }

    /// The video has sound to toggle: its file is here and the webp has not replaced it.
    private var hasSoundToggle: Bool { originalURL != nil && !showsWebp }
    /// The owner has the sound on, and the planet is where they can hear and see it.
    private var soundOn: Bool { !muted && !showsWebp && visible }

    /// What VoiceOver says about the planet: its title, its file type and the badges it wears.
    private var a11yValue: String {
        if let facts = galleryFacts { return [title, facts.countText].joined(separator: ", ") }
        var parts = [title, typeLabel]
        if hasLink { parts.append(Copy.linkBadgeA11y) }
        if hasWebp && showsWebp { parts.append(Copy.webpBadgeA11y) }
        return parts.joined(separator: ", ")
    }

    private var webpSource: AnimatedImageView.Source? {
        if let url = storedWebp?.fileURL, FileManager.default.fileExists(atPath: url.path) { return .file(url) }
        if let result = pipeline.webpResult { return .remote(result.url) }
        return nil
    }

    private var originalURL: URL? {
        guard let url = localVideo?.fileURL, FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }

    private var typeLabel: String {
        if let hero = galleryHero {
            if hero.count >= 2 { return "\(hero.count)" }
            return storedGallery?.items.first.map { PlanetType($0).label } ?? "jpg"
        }
        if showsWebp { return storedWebp.map { PlanetType($0).label } ?? "webp" }
        return localVideo.map { PlanetType($0).label } ?? "mp4"
    }

    /// The run's title (CONTRACT-LIBRARY2 decisions 1 and 9): what the owner typed (`pipeline.runTitle`, or the
    /// title this device already keeps for the media), else a link save's `service · ref`, else the file's name
    /// without its media extension (`from photos · 4 oct`, `IMG_0412`), else `cobalt`. A rename elsewhere shows
    /// here at once because the run's records carry it.
    private var title: String {
        var service: String?
        var ref: String?
        var fileName: String?
        if case .link(let info) = pipeline.input {
            service = info.service
            ref = info.ref
        } else {
            fileName = pipeline.media?.name ?? localVideo?.name
        }
        return MediaTitle.text(MediaTitle.resolve(
            custom: pipeline.runTitle ?? (isGallery ? storedGallery?.customTitle : localVideo?.title),
            service: service, ref: ref, fileName: fileName))
    }

    private var meta: String {
        if let facts = galleryFacts { return facts.countText }
        let m = pipeline.media
        let v = localVideo
        return Copy.focusMeta(seconds: m?.duration ?? v?.duration, width: m?.width ?? v?.width,
                              height: m?.height ?? v?.height, bytes: m?.bytes ?? v.map(\.bytes))
    }

    /// The failure shown under the planet, with how to retry it.
    private var failure: (message: String, retry: () -> Void)? {
        let lineMax = model.capabilities.limits.lineMax
        if case .failed(let f) = pipeline.state { return (TrayCopy.failure(f, lineMax: lineMax), { pipeline.makeWebp() }) }
        if case .failed(let f) = pipeline.hosting { return (TrayCopy.failure(f, lineMax: lineMax), { pipeline.hostOriginal() }) }
        return nil
    }

    private var failureKey: String {
        var key = ""
        if case .failed(let f) = pipeline.state { key += "s\(f)" }
        if case .failed(let f) = pipeline.hosting { key += "h\(f)" }
        return key
    }

    // MARK: layout

    private func heroRect(in slot: CGRect) -> CGRect {
        guard slot.width > 0, slot.height > 0 else { return .zero }
        let maxW = aspect >= 1 ? min(0.82 * contentWidth, 560) : min(0.6 * contentWidth, 420)
        let w = max(40, min(maxW, slot.width, (slot.height - 4) * aspect))
        let h = w / aspect
        return CGRect(x: slot.midX - w / 2, y: slot.midY - h / 2, width: w, height: h)
    }

    /// The pose the hero is heading for.
    private var pose: HeroPose {
        switch phase {
        case .born(let r):
            return HeroPose(rect: r, radius: min(r.width, r.height) / 2, chrome: 0)
        case .slot(let r, _):
            return HeroPose(rect: r, radius: Metrics.thumbRadius, chrome: 0)
        case .hidden, .lifted:
            return HeroPose(rect: heroRect(in: slot), radius: HeroPlanet.radius + HeroPlanet.bezel, chrome: 1)
        }
    }

    private var poseAnimation: Animation? {
        if reduceMotion { return Motion.fade }
        switch phase {
        case .hidden, .born: return nil
        case .slot(_, let closing): return closing ? FocusMotion.land : FocusMotion.morph
        // The lift itself is the slow spring. Once the planet is up, its room changes with the rows under it
        // (the trim strip arrives, the working row, the result card): it follows them on the rows' own spring,
        // so its lower edge never lags behind the card and sits on top of it.
        case .lifted: return liftSettled ? Motion.rows : FocusMotion.lift
        }
    }

    /// The hero is drawn: not before the star has handed over, and not before the layout has a place for it.
    private var heroShown: Bool {
        switch phase {
        case .hidden, .born: return false
        case .slot: return true
        case .lifted: return slot != .zero
        }
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            layout
            hero(pose: pose)
                .animation(poseAnimation, value: pose)
                .opacity(heroShown && visible ? 1 : 0)
                .animation(reduceMotion ? Motion.fade : .easeOut(duration: 0.22), value: heroShown && visible)
                .allowsHitTesting(lifted)
                // while the crop editor is up its own touches are the only ones on the planet
                .gesture(closeDrag, including: isCropping ? .subviews : .all)
                // the bar's buttons stay reachable for VoiceOver: the planet is a labelled group, not one element
                .accessibilityElement(children: controlsMode == nil ? .ignore : .contain)
                .accessibilityLabel(Copy.focusA11y)
                .accessibilityValue(a11yValue)
                .accessibilityHint(Copy.closeFocusHint)
                .accessibilityHidden(!lifted)
                .accessibilityActions {
                    if hasSoundToggle { Button(muted ? Copy.soundOn : Copy.soundOff) { toggleSound() } }
                    Button(Copy.closeA11y) { close() }
                }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        // the warm-up instance (HomeScreen) is built and laid out but never drawn: at idle its glass rows were
        // visible over the paste and file circles during the first second of every launch (owner, 2026-10-05)
        .opacity(warm ? 0 : 1)
        .coordinateSpace(name: "focusLayer")
        #if os(macOS)
        .background { escapeShortcut }
        #endif
        .heroFullScreen(item: $fullScreen) { closedFullScreen(at: $0) }
        .sheet(item: $makeKind) { GalleryCombineSheet(model: model, pipeline: pipeline, kind: $0) }
        // a gallery lands (saved, a make done) or fails: the shimmer or the pulse
        .onChange(of: galleryBeat) { old, new in
            guard !warm, !new.isEmpty else { return }
            let before = Set(old.split(separator: "|").map(String.init))
            for beat in new.split(separator: "|").map(String.init) where !before.contains(beat) {
                if beat == "failed" || beat == "makefail" { pulse += 1 } else { shimmer += 1 }
            }
        }
        // the bar follows the focused planet's player (made when the video first shows, handed away on the return)
        .onChange(of: player.player.map { ObjectIdentifier($0) }, initial: true) { _, _ in
            guard !warm else { return }
            transport.attach(player.player)
        }
        .onChange(of: pipeline.webpResult?.job) { old, new in
            guard new != nil, new != old else { return }
            shimmer += 1
            Task {
                try? await Task.sleep(for: .milliseconds(320))
                withAnimation(reduceMotion ? Motion.fade : FocusMotion.crossfade) { showsWebp = true }
            }
        }
        // The webp replaces the video: the video is silent and paused from then on (the sound toggle goes
        // with it), and the audio session is only ever `.playback` while the owner has sound on.
        .onChange(of: showsWebp) { _, shows in if shows { muted = true } }
        .onChange(of: soundOn) { _, on in if on { AudioPolicy.playback() } else { AudioPolicy.release() } }
        .onDisappear { if soundOn { AudioPolicy.release() } }
        .task(id: lifted) {
            liftSettled = false
            guard lifted else { return }
            try? await Task.sleep(for: .milliseconds(950))
            if !Task.isCancelled { liftSettled = true }
        }
        .onChange(of: pipeline.hosting) { old, new in
            if new == .working, old != .working { hostSince = Date() }
            if new == .done, old != .done { shimmer += 1 }
            if case .failed = new { pulse += 1 }
        }
        .onChange(of: failureKey) { _, new in if !new.isEmpty { pulse += 1 } }
        .onChange(of: pipeline.state) { _, new in
            if new != .ready { showsTrim = false; cropEditor = nil }
        }
        .task(id: TrimPreviewKey(active: trimPreviewActive, url: originalURL)) {
            if trimPreviewActive, let url = originalURL {
                trimPreview.start(
                    url: url, selection: pipeline.trim,
                    duration: pipeline.media?.duration ?? localVideo?.duration ?? pipeline.maxClipSeconds)
            } else {
                trimPreview.stop()
            }
        }
        .onDisappear {
            trimPreview.stop()
            transport.detach()
        }
        .onAppear {
            guard !warm else { return }
            showsWebp = pipeline.webpResult != nil
            // "trim a new webp" landed here: the trim is already open (a clip over 10 s)
            if TrimIntent.consume() || pipeline.takeTrimRequest(), isLong, case .ready = pipeline.state {
                withAnimation(reduceMotion ? Motion.fade : FocusMotion.content) { showsTrim = true }
            }
        }
        #if DEBUG
        // `-previewAutoClose 3`: close the focused planet 3 s after it has lifted (evidence of the return trip).
        .task(id: lifted) {
            let secs = UserDefaults.standard.double(forKey: "previewAutoClose")
            guard secs > 0, lifted else { return }
            try? await Task.sleep(for: .seconds(secs))
            if !Task.isCancelled { onClose() }
        }
        // `-previewConvert 2 -previewMake 3 -previewCopy 2`: press "convert to webp" 2 s after the planet has
        // lifted, then (a clip over 10 s: the trim strip is up) "make webp" 3 s later, then the copy button
        // 2 s after the webp has landed (evidence of the convert phase without a finger on the glass).
        .task(id: lifted) {
            let d = UserDefaults.standard
            let after = d.double(forKey: "previewConvert")
            guard after > 0, lifted else { return }
            try? await Task.sleep(for: .seconds(after))
            guard !Task.isCancelled else { return }
            convert()
            let make = d.double(forKey: "previewMake")
            guard make > 0 else { return }
            try? await Task.sleep(for: .seconds(make))
            if !Task.isCancelled, showsTrim { pipeline.makeWebp() }
        }
        .task(id: hasWebp) {
            let after = UserDefaults.standard.double(forKey: "previewCopy")
            guard after > 0, hasWebp else { return }
            try? await Task.sleep(for: .seconds(after))
            if !Task.isCancelled { pipeline.copyResultLink(); flash($copiedWebp) }
        }
        // `-previewCrop YES -previewCropOpen 1 -previewCropPreset 1:1 -previewCropDone 2 -previewCropMake 2`: once the
        // trim strip is up (a clip that fits a webp: once the planet has lifted) open the crop editor after 1 s,
        // pick the preset, press "done" 2 s later and "make webp" 2 s after that. The same functions the buttons
        // call; the gestures themselves are driven by hand.
        .task(id: "\(lifted)\(showsTrim)") {
            let d = UserDefaults.standard
            let after = d.double(forKey: "previewCropOpen")
            guard after > 0, lifted, showsTrim || !isLong else { return }
            try? await Task.sleep(for: .seconds(after))
            guard !Task.isCancelled, cropEditor == nil else { return }
            openCrop()
            if let label = d.string(forKey: "previewCropPreset"), let preset = CropRect.Aspect.allCases.first(where: { $0.label == label }) {
                try? await Task.sleep(for: .milliseconds(600))
                withAnimation(Motion.rows) { cropEditor?.choose(preset) }
            }
            let done = d.double(forKey: "previewCropDone")
            guard done > 0 else { return }
            try? await Task.sleep(for: .seconds(done))
            guard !Task.isCancelled else { return }
            finishCrop()
            let make = d.double(forKey: "previewCropMake")
            guard make > 0 else { return }
            try? await Task.sleep(for: .seconds(make))
            if !Task.isCancelled { pipeline.makeWebp() }
        }
        // A gallery's drivers (evidence without a finger on the glass; the same functions the buttons call):
        // `-previewGallerySheet webp|mp4|image` opens the combine sheet with that output once the planet has lifted;
        // `-previewGalleryMake webp|mp4|image -previewGalleryMakeAt 2` chooses that make N s after the lift, the way
        // the sheet does (`Pipeline.make`, held until the save is over); `-previewGalleryRetry 1` presses
        // `try photo 7 again` N s after the save ended with a failure.
        .task(id: lifted) {
            let d = UserDefaults.standard
            guard lifted, isGallery else { return }
            if let raw = d.string(forKey: "previewGallerySheet"), let kind = GalleryMakeKind(rawValue: raw) {
                try? await Task.sleep(for: .seconds(max(0.5, d.double(forKey: "previewGallerySheetAt"))))
                if !Task.isCancelled { makeKind = kind }
            }
        }
        .task(id: lifted) {
            let d = UserDefaults.standard
            guard lifted, isGallery, let raw = d.string(forKey: "previewGalleryMake"), let kind = GalleryMakeKind(rawValue: raw) else { return }
            try? await Task.sleep(for: .seconds(d.double(forKey: "previewGalleryMakeAt")))
            guard !Task.isCancelled else { return }
            let items = pipeline.galleryItems
            let ids = items.map(\.id)
            switch kind {
            case .webp: await pipeline.make(.slideshow(SlideshowPlan(format: .webp, items: ids)))
            case .mp4: await pipeline.make(.slideshow(SlideshowPlan(format: .mp4, items: ids)))
            case .image: await pipeline.make(.image(GalleryImagePlan(items: items.filter(\.isPhoto).map(\.id))))
            }
        }
        .task(id: galleryBeat) {
            let after = UserDefaults.standard.double(forKey: "previewGalleryRetry")
            guard after > 0, galleryBeat == "saved", galleryFacts?.failed.isEmpty == false else { return }
            try? await Task.sleep(for: .seconds(after))
            if !Task.isCancelled { retryGalleryItems() }
        }
        // `-previewGalleryRemake 1`: presses the make's `try again` N s after a make failed.
        .task(id: galleryBeat) {
            let after = UserDefaults.standard.double(forKey: "previewGalleryRemake")
            guard after > 0, galleryBeat.contains("makefail") else { return }
            try? await Task.sleep(for: .seconds(after))
            if !Task.isCancelled { remake() }
        }
        // `-previewGalleryOpen 1`: presses `open` N s after the gallery is saved (the detail of its media over the focus).
        .task(id: galleryBeat) {
            let after = UserDefaults.standard.double(forKey: "previewGalleryOpen")
            guard after > 0, galleryBeat == "saved", galleryFacts?.failed.isEmpty == true else { return }
            try? await Task.sleep(for: .seconds(after))
            if !Task.isCancelled { openGallery() }
        }
        // `-previewShimmerLoop YES` / `-previewPulseLoop YES`: replay the shimmer or the failure pulse every
        // 2.2 s so a screenshot can catch them mid-flight (design review only).
        .task {
            let d = UserDefaults.standard
            guard d.bool(forKey: "previewShimmerLoop") || d.bool(forKey: "previewPulseLoop") else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(2200))
                if d.bool(forKey: "previewShimmerLoop") { shimmer += 1 }
                if d.bool(forKey: "previewPulseLoop") { pulse += 1 }
            }
        }
        #endif
        .haptic(.success, trigger: shimmer, enabled: haptics) { $0 > 0 }
        .haptic(.error, trigger: pulse, enabled: haptics) { $0 > 0 }
        .haptic(.success, trigger: copiedWebp, enabled: haptics) { $0 }
        .haptic(.success, trigger: copiedLink, enabled: haptics) { $0 }
        .haptic(.success, trigger: pipeline.photos, enabled: haptics) { $0 == .done }
    }

    @ViewBuilder
    private var layout: some View {
        if homeHeight < 520 {
            HStack(alignment: .center, spacing: 20) {
                heroSlot
                VStack(spacing: Self.gap) {
                    Spacer(minLength: 0)
                    underHero
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: 420)
            }
            .padding(.horizontal, Metrics.gutter)
            .padding(.vertical, 8)
        } else {
            VStack(spacing: Self.gap) {
                heroSlot
                underHero
            }
            .padding(.horizontal, Metrics.gutter)
            .padding(.top, 6 + topReserve)
            .animation(reduceMotion ? Motion.fade : Motion.rows, value: topReserve)
            // clear of the floating tab bar (the layer sits outside the scroll view, which is what
            // gets the bar's inset): about 24 pt between the last row and the bar
            .padding(.bottom, 24)
            .frame(maxWidth: Metrics.columnMax)
            .frame(maxWidth: .infinity)
        }
    }

    /// Everything under the planet: a video's info card and choices, or a gallery's card and `make from it` row.
    @ViewBuilder
    private var underHero: some View {
        if let facts = galleryFacts {
            GalleryInfoCard(
                facts: facts, meta: meta, lineMax: model.capabilities.limits.lineMax, lifted: lifted,
                retryItems: retryGalleryItems, tryAgain: retryGallerySave, makeAgain: remake)
            GalleryControls(facts: facts, lifted: lifted, choose: chooseMake, open: openGallery, done: close)
        } else {
            infoCard
            controls
        }
    }

    /// The room the planet takes: it shrinks when the trim strip slides in under it.
    private var heroSlot: some View {
        Color.clear
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .frame(minHeight: 110)
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .named("focusLayer")) } action: { slot = $0 }
    }

    /// ONE grouped glass card under the planet (CONTRACT-ORBIT 2b): the title row (service, ref, length,
    /// size, bytes), then a row per finished link. The buttons are in the rows (icon-only copy and share)
    /// and under the card (one prominent, one secondary row).
    private var infoCard: some View {
        VStack(spacing: 0) {
            VStack(spacing: 3) {
                Text(title)
                    .font(CobaltType.bodySemibold)
                    .foregroundStyle(CobaltColor.text)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(meta)
                    .font(CobaltType.caption)
                    .foregroundStyle(CobaltColor.caption)
                    .monospacedDigit()
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .padding(.horizontal, 14)
            .accessibilityElement(children: .combine)
            if hasWebp, let result = pipeline.webpResult {
                cardDivider
                ResultRow(
                    kind: .webp, url: result.url, meta: "\(Format.size(result.width, result.height)) · \(Format.bytes(result.bytes))",
                    copied: copiedWebp
                ) {
                    pipeline.copyResultLink()
                    flash($copiedWebp)
                }
                .transition(.opacity)
            }
            if hasLink, let url = pipeline.hostedOriginalURL {
                cardDivider
                ResultRow(kind: .link, url: url, meta: nil, copied: copiedLink) {
                    Pasteboard.copy(url.absoluteString)
                    flash($copiedLink)
                }
                .transition(.opacity)
            }
        }
        .frame(maxWidth: Self.columnWidth)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .continuous))
        .appear(lifted)
        .offset(y: lifted ? 0 : 14)
        .animation(reduceMotion ? Motion.fade : FocusMotion.content.delay(lifted ? 0.2 : 0), value: lifted)
        .motion(Motion.rows, value: hasWebp)
        .motion(Motion.rows, value: hasLink)
        .accessibilityElement(children: .contain)
    }

    private var cardDivider: some View {
        Rectangle()
            .fill(CobaltColor.hairline)
            .frame(height: 1)
            .padding(.horizontal, 14)
            .accessibilityHidden(true)
    }

    // MARK: the planet

    /// What the planet's bar is wired to.
    private var controlsSetup: HeroPlanet.Controls? {
        guard let mode = controlsMode else { return nil }
        let full: (() -> Void)? = canFullScreen ? { openFullScreen() } : nil
        return HeroPlanet.Controls(mode: mode, transport: transport, onSound: { toggleSound() }, onFullScreen: full)
    }

    private func hero(pose: HeroPose) -> some View {
        HeroPlanet(
            pose: pose, drag: dragY, reference: HeroPlanet.reference(aspect: aspect),
            posterImage: isGallery ? nil : pipeline.posterFrame,
            posterURL: localVideo?.posterURL, original: originalURL, webp: webpSource, showsWebp: showsWebp,
            muted: muted || showsWebp || !visible, videoPlays: videoPlays, progress: heroProgress,
            sharing: heroSharing, typeLabel: typeLabel, hasWebp: hasWebp && showsWebp, hasLink: hasLink,
            shimmer: shimmer, pulse: pulse, sound: hasSoundToggle, player: player,
            trimPreview: trimPreviewActive ? trimPreview : nil, cropEditor: cropEditor,
            controls: controlsSetup, gallery: galleryHero)
    }

    // MARK: media controls

    /// The bar the planet wears: the whole bar for a video that plays here, a lone full-screen button for the webp, none
    /// while the trim or the crop is open over the picture (they have the touches then) or the planet is not up.
    private var controlsMode: HeroControlsMode? {
        guard !warm, visible, !isCropping, !isTrimming else { return nil }
        if showsWebp { return webpSource == nil ? nil : .webp }
        return originalURL == nil ? nil : .video
    }

    private var canFullScreen: Bool { showsWebp ? webpSource != nil : originalURL != nil }

    private func openFullScreen() {
        guard lifted, !isCropping else { return }
        let request: HeroFullScreen
        if showsWebp, let source = webpSource {
            request = .webp(source: source, aspect: aspect, name: title)
        } else if let url = originalURL {
            let start = player.player?.currentTime() ?? .zero
            player.player?.pause()
            request = .video(url: url, name: title, start: start.isValid ? start : .zero)
        } else { return }
        var transaction = Transaction()
        transaction.disablesAnimations = reduceMotion
        withTransaction(transaction) { fullScreen = request }
    }

    /// Back from the full-screen player: the same planet, muted, from where it got to.
    private func closedFullScreen(at time: CMTime?) {
        muted = true
        guard let queue = player.player else { return }
        queue.isMuted = true
        Task {
            if let time, time.isValid { await queue.seek(to: time) }
            if videoPlays { queue.play() }
        }
    }

    /// The video should be running (not the webp, not off screen, not under the trim's preview).
    private var videoPlays: Bool { !showsWebp && visible && !trimPreviewActive }

    /// Close, or swipe down: a clip the owner paused is set going again first, so the orbit takes over a moving picture.
    private func close() {
        transport.resumeIfPausedByUser()
        onClose()
    }

    #if os(macOS)
    /// Escape steps out of the planet on the Mac, one layer at a time: the trim panel first, then the focus
    /// itself. The crop editor keeps its own `done`. Only the live, lifted, on-screen instance listens.
    private var escapeShortcut: some View {
        Button(Copy.closeA11y) {
            if showsTrim {
                withAnimation(reduceMotion ? Motion.fade : FocusMotion.content) { showsTrim = false }
            } else {
                close()
            }
        }
        .keyboardShortcut(.cancelAction)
        .disabled(warm || !lifted || !visible || isCropping)
        .frame(width: 0, height: 0)
        .opacity(0)
        .accessibilityHidden(true)
    }
    #endif

    private var closeDrag: some Gesture {
        DragGesture(minimumDistance: 14)
            .onChanged { value in
                if abs(value.translation.height) > abs(value.translation.width) { dragY = max(0, value.translation.height) }
            }
            .onEnded { value in
                if value.translation.height > 90 || value.predictedEndTranslation.height > 220 {
                    dragY = 0
                    close()
                } else {
                    withAnimation(Motion.snap) { dragY = 0 }
                }
            }
    }

    /// Sound on takes the audio session (`.playback`, via `soundOn`); sound off, closing, the webp and
    /// leaving the screen give it back, so the orbit's muted autoplay never interrupts the owner's music.
    private func toggleSound() {
        muted.toggle()
    }

    // MARK: under the planet

    /// Spacing between everything under the planet, and the width the card and the buttons share.
    static let gap: CGFloat = 12
    static let columnWidth: CGFloat = 520

    /// The rows fade in one by one (opacity per row, never on the whole stack: a group opacity would
    /// flatten every glass pane in it into one faded layer).
    private var controls: some View {
        VStack(spacing: Self.gap) {
            if let failure, !isRendering {
                InlineStatus(message: failure.message) {
                    Button(Copy.tryAgain, systemImage: Symbol.retry, action: failure.retry)
                        .buttonStyle(.cobaltSecondary(fullWidth: false, compact: true))
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .frame(maxWidth: Self.columnWidth)
                .glassEffect(.regular, in: RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .continuous))
                .appear(lifted)
                .transition(.opacity)
            }
            if isRendering || isHosting { workingRow.appear(lifted) }
            if let cropEditor { CropPanel(model: cropEditor, onDone: finishCrop).appear(lifted).transition(.opacity) }
            else if isTrimming { trimPanel.appear(lifted) } else { choices }
        }
        .offset(y: lifted ? 0 : 20)
        .animation(reduceMotion ? Motion.fade : FocusMotion.content.delay(lifted ? 0.28 : 0), value: lifted)
        .motion(Motion.rows, value: isTrimming)
        .motion(Motion.rows, value: isCropping)
        .motion(Motion.rows, value: isRendering)
        .motion(Motion.rows, value: isHosting)
        .motion(Motion.rows, value: hasWebp)
        .motion(Motion.rows, value: hasLink)
        .motion(Motion.rows, value: failureKey)
    }

    private func flash(_ flag: Binding<Bool>) {
        flag.wrappedValue = true
        Task {
            try? await Task.sleep(for: .seconds(1.8))
            flag.wrappedValue = false
        }
    }

    // MARK: choices

    private var showsPublicShare: Bool { isFork && pipeline.canHostOriginal }

    private enum Choice: Hashable {
        case copyWebp, copyVideo, convert, anotherWebp, crop, publicShare, savePhotos, share, close
    }

    private var isWorking: Bool { isRendering || isHosting }

    /// The "save to photos" button (CONTRACT-SYNC.md decision 12): once the run's original is in the
    /// owner's album or library it says so and stops being a button; otherwise today's states.
    private var photosButton: (title: String, doneSymbol: String, done: Bool, placed: Bool) {
        switch pipeline.photosPlacement {
        case .inAlbum: return (Copy.Sync.inAlbum, Symbol.Sync.inPhotos, true, true)
        case .inLibrary: return (Copy.Sync.inLibrary, Symbol.Sync.inPhotos, true, true)
        case .none: return (pipeline.photos == .done ? Copy.savedPhotos : Copy.savePhotos, Symbol.checkmark, pipeline.photos == .done, false)
        }
    }

    /// EXACTLY ONE prominent button on the screen (CONTRACT-ORBIT 2b): copy the webp link once a webp
    /// exists, else the next sensible action: convert to webp, copy the video link, public share, and on
    /// plain cobalt (nothing to convert or host) save to photos. None while a job runs: its progress is
    /// the thing to look at, and every choice is secondary.
    private var primaryChoice: Choice? {
        guard !isWorking else { return nil }
        if hasWebp { return .copyWebp }
        if canConvert { return .convert }
        if hasLink { return .copyVideo }
        if showsPublicShare { return .publicShare }
        return .savePhotos
    }

    /// The secondary row: equal compact glass buttons. After a webp: another webp, save to photos, close
    /// (public share too while the original is not hosted yet).
    private var secondaryChoices: [Choice] {
        let primary = primaryChoice
        var out: [Choice] = []
        if canConvert, primary != .convert { out.append(hasWebp ? .anotherWebp : .convert) }
        // a clip that fits a webp has no trim stage: its crop button sits with the choices (longer clips
        // have it in the trim panel)
        if canCrop, !isLong, !isWorking { out.append(.crop) }
        if showsPublicShare, primary != .publicShare { out.append(.publicShare) }
        if primary != .savePhotos { out.append(.savePhotos) }
        if let file = localVideo?.fileURL, !isFork, FileManager.default.fileExists(atPath: file.path) { out.append(.share) }
        out.append(.close)
        return out
    }

    /// The primary button full width, then the secondary row under it. A secondary label is never
    /// wrapped: when the words do not fit side by side (the largest text sizes, narrow windows, four
    /// choices) the row falls back to two per line, then to one per line.
    private var choices: some View {
        let items = secondaryChoices
        return GlassEffectContainer(spacing: Self.gap) {
            VStack(spacing: Self.gap) {
                if let primary = primaryChoice { primaryButton(primary).appear(lifted) }
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: Self.gap) { ForEach(items, id: \.self) { secondaryButton($0, .stacked) } }
                    VStack(spacing: Self.gap) {
                        ForEach(Array(stride(from: 0, to: items.count, by: 2)), id: \.self) { i in
                            HStack(spacing: Self.gap) {
                                ForEach(Array(items[i..<min(i + 2, items.count)]), id: \.self) { secondaryButton($0, .stacked) }
                            }
                        }
                    }
                    VStack(spacing: Self.gap) { ForEach(items, id: \.self) { secondaryButton($0, .inline) } }
                }
            }
        }
        // on the wide tiers the rows do not stretch across the whole column
        .frame(maxWidth: Self.columnWidth)
        // A glass pane inside a `GlassEffectContainer` is drawn by the container, so the per-control `appear`
        // opacity above does not hide it: before the planet has lifted (the star's whole flight, and the
        // warm-up instance) "save to photos" and "close" showed through, half faded, over the circles. The
        // container itself is what is hidden until the lift.
        .opacity(lifted && !warm ? 1 : 0)
        .allowsHitTesting(lifted && !warm)
    }

    @ViewBuilder
    private func primaryButton(_ choice: Choice) -> some View {
        switch choice {
        case .copyWebp:
            PrimaryChoice(title: copiedWebp ? Copy.copied : Copy.copyWebpLink, symbol: Symbol.copyLink, done: copiedWebp) {
                pipeline.copyResultLink()
                flash($copiedWebp)
            }
        case .copyVideo:
            PrimaryChoice(title: copiedLink ? Copy.copied : Copy.copyVideoLink, symbol: Symbol.copyLink, done: copiedLink) {
                if let url = pipeline.hostedOriginalURL { Pasteboard.copy(url.absoluteString) }
                flash($copiedLink)
            }
        case .publicShare:
            PrimaryChoice(title: Copy.publicShare, symbol: Symbol.publicShare) { pipeline.hostOriginal() }
                .accessibilityHint(Copy.hostOriginal)
        case .savePhotos:
            let photos = photosButton
            PrimaryChoice(
                title: photos.title, symbol: Symbol.savePhotos, doneSymbol: photos.doneSymbol,
                done: photos.done, working: pipeline.photos == .working, inert: photos.placed
            ) { pipeline.saveToPhotos() }
        case .convert, .anotherWebp, .crop, .share, .close:
            PrimaryChoice(title: choice == .anotherWebp ? Copy.anotherWebp : Copy.convertToWebp, symbol: Symbol.convert) { convert() }
        }
    }

    @ViewBuilder
    private func secondaryButton(_ choice: Choice, _ layout: ChoiceLayout) -> some View {
        switch choice {
        case .convert, .anotherWebp:
            ChoiceButton(title: choice == .convert ? Copy.convertToWebp : Copy.anotherWebp, symbol: Symbol.convert, layout: layout) {
                convert()
            }
            .appear(lifted)
        case .crop:
            ChoiceButton(title: cropBadge ?? CropCopy.crop, symbol: CropCopy.symbol, layout: layout) { openCrop() }
                .accessibilityLabel(cropBadge ?? CropCopy.crop)
                .accessibilityHint(CropCopy.cropA11yHint)
                .appear(lifted)
        case .publicShare:
            ChoiceButton(title: Copy.publicShare, symbol: Symbol.publicShare, layout: layout) { pipeline.hostOriginal() }
                .accessibilityHint(Copy.hostOriginal)
                .appear(lifted)
        case .savePhotos:
            let photos = photosButton
            ChoiceButton(
                title: photos.title,
                symbol: photos.done ? photos.doneSymbol : Symbol.savePhotos,
                working: pipeline.photos == .working, inert: photos.placed, layout: layout
            ) {
                pipeline.saveToPhotos()
            }
            .symbolBounce(on: photos.done)
            .appear(lifted)
        case .share:
            // plain cobalt: no public hosting, so the system share sheet for the file on this device
            if let file = localVideo?.fileURL {
                ShareLink(item: file) { ChoiceLabel(title: Copy.share, symbol: Symbol.share, layout: layout) }
                    .buttonStyle(.plain)
                    .glassEffect(.regular.interactive(), in: .capsule)
                    .appear(lifted)
            }
        case .close:
            ChoiceButton(title: Copy.close, symbol: Symbol.close, layout: layout, action: close)
                .appear(lifted)
        case .copyWebp, .copyVideo:
            EmptyView()
        }
    }

    private func convert() {
        // A finished or failed run goes back to the trim first (a failed render keeps its trim).
        switch pipeline.state {
        case .done: pipeline.backToTrim()
        case .failed(let f) where f.keepsTrim: pipeline.backToTrim()
        default: break
        }
        if isLong {
            // over 10 s: the trim strip slides in under the planet first (only if there is a trim to show)
            let trimming: Bool = { if case .ready = pipeline.state { return true } else { return false } }()
            withAnimation(reduceMotion ? Motion.fade : FocusMotion.content) { showsTrim = trimming }
        } else {
            showsTrim = false
            pipeline.makeWebp()
        }
    }

    // MARK: trim

    private var trimPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                // with the crop badge beside it the readout drops its "of 00:14.8" so neither is cut
                Text(cropBadge == nil
                     ? Copy.timecodeOf(pipeline.trim, duration: pipeline.media?.duration ?? pipeline.maxClipSeconds)
                     : Copy.timecodeRange(pipeline.trim))
                    .font(CobaltType.caption)
                    .foregroundStyle(CobaltColor.caption)
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                if let cropBadge { CropBadge(text: cropBadge).transition(.opacity) }
                Spacer(minLength: 0)
                LengthReadout(seconds: pipeline.trim.length, over: pipeline.trimOverLimit)
                    .layoutPriority(1)
            }
            .motion(Motion.rows, value: cropBadge)
            TrimStrip(pipeline: pipeline, spanNamespace: span, preview: trimPreview)
                .padding(.top, 4)
            StripScale(duration: pipeline.media?.duration ?? pipeline.maxClipSeconds, developing: false)
            Text(Copy.trimNote(duration: pipeline.media?.duration, limit: pipeline.maxClipSeconds))
                .font(CobaltType.caption)
                .foregroundStyle(CobaltColor.caption)
                .fixedSize(horizontal: false, vertical: true)
            let makeWebp = Button(Copy.makeWebp, systemImage: Symbol.makeWebp) { pipeline.makeWebp() }
                .buttonStyle(.cobaltPrimary())
            let crop = Button(CropCopy.crop, systemImage: CropCopy.symbol) { openCrop() }
                .buttonStyle(.cobaltSecondary(fullWidth: true, compact: true))
                .accessibilityHint(CropCopy.cropA11yHint)
            let cancel = Button(Copy.cancelTrim, systemImage: Symbol.close) {
                withAnimation(reduceMotion ? Motion.fade : FocusMotion.content) { showsTrim = false }
            }
            .buttonStyle(.cobaltSecondary(fullWidth: true, compact: true))
            GlassEffectContainer(spacing: 10) {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 10) { makeWebp; if canCrop { crop }; cancel }
                    VStack(spacing: 10) { makeWebp; HStack(spacing: 10) { if canCrop { crop }; cancel } }
                }
            }
        }
        .padding(16)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .continuous))
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    // MARK: working

    /// The one progress card under the planet: "making your webp · frame 42 of 150" with its bar and stepper
    /// (the planet's own frame ticks stay), or "publishing the video" (indeterminate).
    @ViewBuilder
    private var workingRow: some View {
        if let story = isRendering ? pipeline.progressStory : (isHosting ? pipeline.hostingStory(since: hostSince) : nil) {
            VStack(alignment: .leading, spacing: 10) {
                ProgressCard(story: story)
                // A webp that is only queued on the server can be taken back (CONTRACT-PARALLEL 3.4); one that is
                // being made cannot be stopped, so there is no button for it: closing leaves it going alongside.
                if canCancelQueuedWebp, let id = model.queue.focusedID {
                    Button(Copy.cancel, systemImage: Symbol.close) { Task { await model.queue.cancel(id) } }
                        .buttonStyle(.cobaltSecondary(fullWidth: false, compact: true))
                        .accessibilityLabel(TrayCopy.cancelWebpA11y)
                        .transition(.opacity)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .frame(maxWidth: Self.columnWidth)
            .glassEffect(.regular, in: RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .continuous))
            .transition(.opacity)
        }
    }
}

private struct TrimPreviewKey: Hashable {
    let active: Bool
    let url: URL?
}

// MARK: - the hero planet

struct HeroPlanet: View, @preconcurrency Animatable {
    /// Where the planet is and what it wears; interpolated by SwiftUI, re-read every frame.
    var pose: HeroPose
    /// How far a close-drag has pulled it down (it follows the finger, then springs back).
    var drag: CGFloat
    /// The media is laid out at this size, once, and only ever scaled (never relaid out) as the frame animates.
    let reference: CGSize
    let posterImage: CGImage?
    let posterURL: URL?
    let original: URL?
    let webp: AnimatedImageView.Source?
    let showsWebp: Bool
    let muted: Bool
    /// The video plays (false once the webp has replaced it, or off screen): it is paused, not just hidden.
    var videoPlays = true
    let progress: HeroProgress
    /// Hosting the original: an indeterminate sweep of light round the edge.
    let sharing: Bool
    let typeLabel: String
    let hasWebp: Bool
    let hasLink: Bool
    let shimmer: Int
    let pulse: Int
    let sound: Bool
    let player: FocusPlayerHolder
    /// The selection's looping preview, laid over the (paused) video while the trim panel is open.
    var trimPreview: TrimPreview?
    /// The crop editor drawn over the picture while it is open (the planet's picture is its preview).
    var cropEditor: CropEditorModel?
    /// The media controls over the picture (nil: none, the trim or the crop has the touches).
    var controls: Controls?
    /// A gallery's cover and count: its picture is the cover, the planet wears two card edges and the count badge.
    var gallery: GalleryHero?

    struct Controls {
        let mode: HeroControlsMode
        let transport: HeroTransport
        let onSound: () -> Void
        var onFullScreen: (() -> Void)?
    }

    static let bezel: CGFloat = 5
    static let radius: CGFloat = 18

    /// The fixed layout size of the picture: never more than the largest the hero gets, so the picture is only
    /// ever scaled down from it.
    static func reference(aspect: CGFloat) -> CGSize {
        let w: CGFloat = aspect >= 1 ? 560 : 420
        return CGSize(width: w, height: w / max(aspect, 0.2))
    }

    var animatableData: AnimatablePair<HeroPose, Double> {
        get { AnimatablePair(pose, Double(drag)) }
        set { pose = newValue.first; drag = CGFloat(newValue.second) }
    }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var scheme
    @State private var lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled

    private var breathing: Bool {
        if reduceMotion || lowPower { return false }
        return progress == .packing || progress == .working
    }

    private var chrome: Double { min(1, max(0, pose.chrome)) }

    private func mix(_ a: Double, _ b: Double) -> Double { a + (b - a) * chrome }

    /// The picture: gradient, poster, the playing video, the webp. One stack at the reference size.
    ///
    /// Every layer is held to exactly the reference box. The planet's shape is not always the layers' own
    /// (a cropped webp is square over a tall poster and video); a layer that reports a bigger size than the
    /// box (an aspect-fill picture, a player view) makes the whole stack bigger than its frame, and the
    /// webp then lands zoomed and off centre.
    private var media: some View {
        let box = reference
        return ZStack {
            Rectangle().fill(FrameGradient.fill(1))
            if let gallery {
                GalleryPicture(source: gallery.cover).frame(width: box.width, height: box.height).clipped()
            } else if let posterImage {
                Color.clear.overlay { Image(decorative: posterImage, scale: 1).resizable().scaledToFill() }
                    .frame(width: box.width, height: box.height).clipped()
            } else if let posterURL {
                StillImage(url: posterURL).frame(width: box.width, height: box.height)
            }
            if let original {
                FocusVideoView(url: original, muted: muted, playing: videoPlays, holder: player)
                    .frame(width: box.width, height: box.height).clipped()
                    .opacity(showsWebp ? 0 : 1)
            }
            if let trimPreview {
                TrimPreviewSurface(preview: trimPreview).frame(width: box.width, height: box.height).clipped()
            }
            if let webp {
                AnimatedImageView(source: webp).frame(width: box.width, height: box.height).clipped()
                    .opacity(showsWebp ? 1 : 0)
            }
        }
        .frame(width: box.width, height: box.height)
        .clipped()
    }

    var body: some View {
        let bezel = Self.bezel * CGFloat(chrome)
        let width = CGFloat(pose.w), height = CGFloat(pose.h)
        let inner = CGSize(width: max(1, width - 2 * bezel), height: max(1, height - 2 * bezel))
        let outerRadius = max(0, CGFloat(pose.radius))
        let outer = RoundedRectangle(cornerRadius: outerRadius, style: .continuous)
        let innerShape = RoundedRectangle(cornerRadius: max(0, outerRadius - bezel), style: .continuous)
        // aspect fill at THIS instant's size: the picture scales with the frame, whatever the frame's shape
        let fill = max(inner.width / reference.width, inner.height / reference.height)
        Color.clear
            .frame(width: inner.width, height: inner.height)
            .overlay { media.scaleEffect(fill) }
            .overlay {
                if let cropEditor {
                    // the picture's rectangle inside the planet's inner frame: the editor maps crop to it
                    let pw = reference.width * fill, ph = reference.height * fill
                    CropEditorView(
                        model: cropEditor,
                        picture: CGRect(x: (inner.width - pw) / 2, y: (inner.height - ph) / 2, width: pw, height: ph))
                        .transition(.opacity)
                }
            }
            .overlay {
                ZStack {
                    RenderTicks(progress: progress, width: inner.width)
                    EdgeSweep(active: sharing, animated: !reduceMotion && !lowPower, radius: Self.radius)
                    ShimmerSweep(token: shimmer, radius: Self.radius)
                    if sound, cropEditor == nil, controls == nil, trimPreview == nil {
                        // no bar (the planet is on its way): the sound's state stays in the corner
                        Image(systemName: muted ? Symbol.soundOff : Symbol.soundOn)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(CobaltColor.badgeInk)
                            .frame(width: 24, height: 24)
                            .glassEffect(.regular.tint(CobaltColor.badgeBack), in: .circle)
                            .padding(8)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                            .accessibilityHidden(true)
                    }
                }
                .opacity(chrome)
            }
            .overlay {
                if let controls {
                    HeroControls(
                        transport: controls.transport, mode: controls.mode, muted: muted, onSound: controls.onSound,
                        onFullScreen: controls.onFullScreen)
                        .opacity(chrome)
                        .allowsHitTesting(chrome > 0.9)
                }
            }
            .clipShape(innerShape)
            .overlay(alignment: .topTrailing) {
                ZStack(alignment: .topTrailing) {
                    HeroBadges(typeLabel: typeLabel, hasWebp: hasWebp, hasLink: hasLink, stack: (gallery?.count ?? 0) >= 2)
                    ImplosionPulse(token: pulse).padding(.top, 2).padding(.trailing, 6)
                }
                .padding(8)
                .opacity(chrome)
            }
            .padding(bezel)
            .background {
                // the glass bezel, fading in as the planet lifts out of its band
                if chrome > 0.001 {
                    Color.clear.glassEffect(.regular, in: outer).opacity(chrome)
                }
            }
            .overlay {
                // the bezel's specular edge
                outer.strokeBorder(
                    LinearGradient(colors: [.white.opacity(0.75), .white.opacity(0.05), .white.opacity(0.3)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing),
                    lineWidth: 1)
                    .opacity(chrome)
                    .allowsHitTesting(false)
            }
            .frame(width: width, height: height)
            .background {
                // a gallery: two card edges peek out behind, up and to the right (the orbit's planet wears the same)
                if let gallery, gallery.count >= 2 {
                    CardEdges(
                        size: CGSize(width: width, height: height), radius: outerRadius,
                        step: CardEdges.step(forShort: min(width, height)))
                }
            }
            // a bare planet in its band has the orbit's own shadow; the lifted one is elevated
            .shadow(color: .black.opacity(mix(0.35, scheme == .dark ? 0.55 : 0.28)), radius: mix(8, 26), y: mix(5, 16))
            .shadow(color: .white.opacity(scheme == .dark && !lowPower ? 0.10 * chrome : 0), radius: 34)
            .modifier(Breathing(active: breathing))
            .scaleEffect(1 - min(0.12, drag / 1200), anchor: .center)
            .position(x: pose.cx, y: pose.cy + Double(drag))
            .onReceive(NotificationCenter.default.publisher(for: .NSProcessInfoPowerStateDidChange).receive(on: RunLoop.main)) { _ in
                lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
            }
    }
}

/// The planet breathes (a slow 1.5 % swell) while the server packs the webp, where there is no count. One
/// structure whether it breathes or not: wrapping the planet in a different container when the work starts
/// would rebuild the picture (and restart the video) under it.
private struct Breathing: ViewModifier {
    let active: Bool
    @State private var swollen = false

    func body(content: Content) -> some View {
        content
            .scaleEffect(swollen ? 1.016 : 1)
            .onChange(of: active, initial: true) { _, on in
                if on {
                    withAnimation(.easeInOut(duration: 1.3).repeatForever(autoreverses: true)) { swollen = true }
                } else {
                    withAnimation(.easeOut(duration: 0.3)) { swollen = false }
                }
            }
    }
}

// MARK: edge effects

/// A row of frame ticks along the planet's bottom edge that light up per decoded frame; once the
/// server packs, they all stay lit.
private struct RenderTicks: View {
    let progress: HeroProgress
    let width: CGFloat

    private var active: Bool {
        switch progress {
        case .decoding, .packing, .working: return true
        default: return false
        }
    }

    var body: some View {
        let count = max(12, min(40, Int((width - 24) / 8)))
        let lit: Int = {
            switch progress {
            case .decoding(let done, let total): return total > 0 ? Int((Double(done) / Double(total) * Double(count)).rounded(.down)) : 0
            case .packing: return count
            default: return 0
            }
        }()
        ZStack(alignment: .bottom) {
            if active {
                LinearGradient(colors: [.clear, .black.opacity(0.5)], startPoint: .center, endPoint: .bottom)
                    .allowsHitTesting(false)
                HStack(spacing: 2) {
                    ForEach(0..<count, id: \.self) { i in
                        Capsule()
                            .fill(.white.opacity(i < lit ? 0.95 : 0.28))
                            .frame(maxWidth: .infinity)
                            .frame(height: i < lit ? 8 : 5)
                            .animation(.easeOut(duration: 0.18), value: i < lit)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 10)
            }
        }
        .animation(.easeOut(duration: 0.25), value: active)
        .accessibilityHidden(true)
    }
}

/// Hosting the original: a bright arc travels round the planet's edge, open-ended, at 30 frames a
/// second at most. Under Reduce Motion and Low Power Mode the edge simply glows steadily.
private struct EdgeSweep: View {
    let active: Bool
    let animated: Bool
    let radius: CGFloat

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        Group {
            if active {
                if !animated {
                    shape.strokeBorder(.white.opacity(0.7), lineWidth: 3)
                } else {
                    TimelineView(.animation(minimumInterval: 1.0 / 30)) { context in
                        let phase = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.6) / 1.6
                        shape.strokeBorder(
                            AngularGradient(
                                stops: [
                                    .init(color: .white.opacity(0), location: 0),
                                    .init(color: .white.opacity(0.1), location: 0.5),
                                    .init(color: .white.opacity(0.55), location: 0.85),
                                    .init(color: .white.opacity(1), location: 0.985),
                                    .init(color: .white.opacity(0), location: 1),
                                ],
                                center: .center, angle: .degrees(phase * 360)),
                            lineWidth: 5)
                            .blendMode(.plusLighter)
                    }
                }
            }
        }
        .allowsHitTesting(false)
        .animation(.easeOut(duration: 0.25), value: active)
        .accessibilityHidden(true)
    }
}

/// The diagonal specular light sweep that ends a conversion or a share (about 0.8 s). Under Reduce
/// Motion a brief highlight crossfade instead.
private struct ShimmerSweep: View {
    let token: Int
    let radius: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private struct Value {
        var progress: Double = -0.4
        var alpha: Double = 0
    }

    var body: some View {
        let reduced = reduceMotion
        GeometryReader { proxy in
            let w = proxy.size.width, h = proxy.size.height
            Color.clear
                .keyframeAnimator(initialValue: Value(), trigger: token) { _, value in
                    ZStack {
                        if reduced {
                            Color.white.opacity(0.32 * value.alpha)
                        } else {
                            LinearGradient(
                                colors: [.white.opacity(0), .white.opacity(0.28), .white.opacity(0.62), .white.opacity(0.28), .white.opacity(0)],
                                startPoint: .leading, endPoint: .trailing)
                                .frame(width: max(w, h) * 0.5, height: max(w, h) * 2.4)
                                .rotationEffect(.degrees(22))
                                .position(x: -w * 0.3 + (w * 1.6) * value.progress, y: h / 2)
                                .opacity(value.alpha)
                                .blendMode(.plusLighter)
                        }
                    }
                } keyframes: { _ in
                    KeyframeTrack(\.progress) {
                        LinearKeyframe(-0.4, duration: 0.001)
                        CubicKeyframe(1.1, duration: 0.8)
                    }
                    KeyframeTrack(\.alpha) {
                        LinearKeyframe(1, duration: 0.12)
                        LinearKeyframe(1, duration: reduced ? 0.15 : 0.56)
                        LinearKeyframe(0, duration: reduced ? 0.3 : 0.12)
                    }
                }
        }
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// The badge area's small implosion pulse when a conversion or a share fails: a ring collapses into
/// the corner, then a short shockwave. A brief tint under Reduce Motion.
private struct ImplosionPulse: View {
    let token: Int
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private struct Value {
        var scale: Double = 0
        var alpha: Double = 0
    }

    var body: some View {
        let reduced = reduceMotion
        Circle()
            .strokeBorder(CobaltColor.error, lineWidth: 2)
            .frame(width: 30, height: 30)
            .keyframeAnimator(initialValue: Value(), trigger: token) { view, value in
                view.scaleEffect(reduced ? 1 : value.scale).opacity(value.alpha)
            } keyframes: { _ in
                KeyframeTrack(\.scale) {
                    LinearKeyframe(1.9, duration: 0.001)
                    CubicKeyframe(0.25, duration: 0.32)
                    CubicKeyframe(1.5, duration: 0.3)
                }
                KeyframeTrack(\.alpha) {
                    LinearKeyframe(0.95, duration: 0.2)
                    LinearKeyframe(0.9, duration: 0.14)
                    LinearKeyframe(0, duration: 0.28)
                }
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

/// The planet's corner: the result badges (link, webp) beside the file-type capsule, never on top of it.
private struct HeroBadges: View {
    let typeLabel: String
    let hasWebp: Bool
    let hasLink: Bool
    /// A gallery: the stack symbol leads the count.
    var stack = false

    var body: some View {
        GlassEffectContainer(spacing: 6) {
            HStack(spacing: 6) {
                if hasLink { icon(Symbol.linkBadge, Copy.linkBadgeA11y).transition(.chip) }
                if hasWebp { icon(Symbol.webpBadge, Copy.webpBadgeA11y).transition(.chip) }
                HStack(spacing: 4) {
                    if stack { Image(systemName: Symbol.Gallery.gallery).font(.system(size: 10, weight: .semibold)) }
                    Text(typeLabel)
                }
                    .font(Font.cobalt(11, .medium, relativeTo: .caption))
                    .dynamicTypeSize(...DynamicTypeSize.large)
                    .foregroundStyle(CobaltColor.badgeInk)
                    .lineLimit(1)
                    .fixedSize()
                    .padding(.horizontal, 9)
                    .frame(height: 24)
                    .glassEffect(.regular.tint(CobaltColor.badgeBack), in: .capsule)
                    .contentTransition(.opacity)
            }
        }
        .animation(Motion.chip, value: hasWebp)
        .animation(Motion.chip, value: hasLink)
    }

    private func icon(_ symbol: String, _ label: String) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(CobaltColor.badgeInk)
            .frame(width: 24, height: 24)
            .glassEffect(.regular.tint(CobaltColor.badgeBack), in: .circle)
            .accessibilityLabel(label)
    }
}

private extension AnyTransition {
    /// A result badge settling on the corner: it lands from larger, with a fade.
    static var chip: AnyTransition { .scale(scale: 1.7).combined(with: .opacity) }
}

// MARK: video

/// The preview's picture, laid over the planet's paused video while the trim panel is open. It appears
/// once the first frame is decoded (so the planet never flashes black).
struct TrimPreviewSurface: View {
    let preview: TrimPreview

    var body: some View {
        if let player = preview.player {
            PlayerSurface(player: player)
                .opacity(preview.isReady ? 1 : 0)
                .animation(.easeOut(duration: 0.12), value: preview.isReady)
        }
    }
}

/// The focused planet's looping player. Owned by the home screen, not by the view: when the planet goes
/// back to its band the orbit takes this very player over (`release`), so the picture goes on playing
/// without a restart or a black frame.
@MainActor @Observable
final class FocusPlayerHolder {
    var player: AVQueuePlayer?
    @ObservationIgnored private var looper: AVPlayerLooper?
    @ObservationIgnored private var url: URL?

    func start(url: URL, muted: Bool, playing: Bool) {
        // already playing this very file (the layer was rebuilt): keep it
        if player != nil, self.url == url { return }
        stop()
        AudioPolicy.ambient()
        let queue = AVQueuePlayer()
        queue.isMuted = muted
        queue.preventsDisplaySleepDuringVideoPlayback = false
        looper = AVPlayerLooper(player: queue, templateItem: AVPlayerItem(url: url))
        self.url = url
        player = queue
        if playing { queue.play() }
    }

    func setPlaying(_ playing: Bool) {
        if playing { player?.play() } else { player?.pause() }
    }

    /// Gives the player away, still playing, to whoever draws the planet next.
    func release() -> (player: AVQueuePlayer, looper: AVPlayerLooper)? {
        guard let player, let looper else { return nil }
        self.player = nil
        self.looper = nil
        url = nil
        return (player, looper)
    }

    func stop() {
        player?.pause()
        looper?.disableLooping()
        looper = nil
        player = nil
        url = nil
    }
}

/// The focused planet's video: autoplaying and looping; muted until the planet is tapped.
private struct FocusVideoView: View {
    let url: URL
    let muted: Bool
    let playing: Bool
    let holder: FocusPlayerHolder

    var body: some View {
        Group {
            if let player = holder.player { PlayerSurface(player: player) } else { Color.clear }
        }
        .task(id: url) { holder.start(url: url, muted: muted, playing: playing) }
        .onChange(of: muted) { _, now in holder.player?.isMuted = now }
        .onChange(of: playing) { _, now in holder.setPlaying(now) }
    }
}

// MARK: choices and results

/// An icon over its word (`stacked`), or beside it (`inline`, the fallback when the words do not fit
/// side by side). The word is one line, always: it sets the choice's width instead of wrapping.
private enum ChoiceLayout { case stacked, inline }

/// The compact secondary choice: a glass capsule, 52 pt tall in both layouts so a row is even.
private struct ChoiceLabel: View {
    let title: String
    let symbol: String
    var working = false
    var layout: ChoiceLayout = .stacked

    private var word: some View {
        Text(title)
            .font(Font.cobalt(11.5, .medium, relativeTo: .caption))
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
    }

    private var icon: some View {
        Image(systemName: symbol)
            .font(.system(size: layout == .stacked ? 19 : 17, weight: .medium))
            .frame(height: 22)
            .symbolEffect(.pulse, isActive: working)
    }

    var body: some View {
        Group {
            switch layout {
            case .stacked:
                VStack(spacing: 3) { icon; word }
            case .inline:
                HStack(spacing: 8) { icon; word }
            }
        }
        .foregroundStyle(CobaltColor.text)
        .padding(.horizontal, layout == .stacked ? 8 : 14)
        .frame(maxWidth: .infinity, minHeight: 52)
        .contentShape(.capsule)
    }
}

private extension View {
    /// Fades one control in with the lift. Applied per control, not to the stack that holds them: an
    /// opacity over a group of glass panes renders the whole group as one faded layer.
    func appear(_ on: Bool) -> some View { opacity(on ? 1 : 0) }
}

private struct ChoiceButton: View {
    let title: String
    let symbol: String
    var working = false
    /// A statement, not an action ("in your cobalt album"): drawn like a done button, never tappable.
    var inert = false
    var layout: ChoiceLayout = .stacked
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ChoiceLabel(title: title, symbol: symbol, working: working, layout: layout)
        }
        .buttonStyle(.plain)
        .disabled(working)
        .glassEffect(inert ? .regular : .regular.interactive(), in: .capsule)
        .allowsHitTesting(!inert)
        .accessibilityRemoveTraits(inert ? .isButton : [])
    }
}

/// THE prominent button: the system's `.glassProminent` (cobalt's monochrome tint), full width. It turns
/// green with a checkmark once it has done its job (copied, saved).
private struct PrimaryChoice: View {
    let title: String
    let symbol: String
    var doneSymbol = Symbol.checkmark
    var done = false
    var working = false
    /// A statement, not an action ("in your cobalt album"): the done style, never tappable.
    var inert = false
    let action: () -> Void

    var body: some View {
        Group {
            if done {
                Button(title, systemImage: doneSymbol, action: action).buttonStyle(.cobaltDone())
                    .allowsHitTesting(!inert)
                    .accessibilityRemoveTraits(inert ? .isButton : [])
            } else {
                Button(title, systemImage: symbol, action: action).buttonStyle(.cobaltPrimary())
            }
        }
        .symbolBounce(on: done)
        .symbolEffect(.pulse, isActive: working)
        .disabled(working)
    }
}

/// A round glass button inside the info card. On the Mac a glass button over the glass card washes out,
/// so it takes the platform's bordered circle (as `CobaltButtonStyle.secondary` does).
private struct RowIconButton: ViewModifier {
    func body(content: Content) -> some View {
        #if os(macOS)
        content.buttonStyle(.bordered).buttonBorderShape(.circle)
        #else
        content.buttonStyle(.glass).buttonBorderShape(.circle)
        #endif
    }
}

/// A link row inside the info card: where it lives, and two icon-only glass buttons (44 pt targets,
/// labelled for VoiceOver): copy (bounces to a checkmark) and the system share sheet.
private struct ResultRow: View {
    enum Kind { case webp, link }
    let kind: Kind
    let url: URL
    let meta: String?
    let copied: Bool
    let onCopy: () -> Void

    private var copyLabel: String { kind == .webp ? Copy.copyWebpLink : Copy.copyVideoLink }
    private var shareLabel: String { kind == .webp ? Copy.shareWebpLink : Copy.shareVideoLink }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: kind == .webp ? Symbol.webpBadge : Symbol.linkBadge)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(CobaltColor.text)
                .frame(width: 22)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(kind == .webp ? Copy.webpLink : Copy.videoLink)
                    .font(CobaltType.bodySemibold)
                    .foregroundStyle(CobaltColor.text)
                Text(meta ?? displayURL(url))
                    .font(CobaltType.captionSmall)
                    .foregroundStyle(CobaltColor.caption)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .monospacedDigit()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
            GlassEffectContainer(spacing: 8) {
                HStack(spacing: 8) {
                    Button(action: onCopy) {
                        Image(systemName: copied ? Symbol.checkmark : Symbol.copyLink)
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(copied ? CobaltColor.success : CobaltColor.text)
                            .frame(width: Metrics.hit - 12, height: Metrics.hit - 12)
                    }
                    .modifier(RowIconButton())
                    .symbolBounce(on: copied)
                    .accessibilityLabel(copied ? Copy.copied : copyLabel)
                    ShareLink(item: url) {
                        Image(systemName: Symbol.share)
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(CobaltColor.text)
                            .frame(width: Metrics.hit - 12, height: Metrics.hit - 12)
                    }
                    .modifier(RowIconButton())
                    .accessibilityLabel(shareLabel)
                }
            }
        }
        .padding(.leading, 14)
        .padding(.trailing, 8)
        .padding(.vertical, 8)
        .accessibilityElement(children: .contain)
    }
}
