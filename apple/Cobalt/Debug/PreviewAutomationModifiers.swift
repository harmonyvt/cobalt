import CobaltKit
import SwiftUI

// Screenshot and design-review automation for the home screen and the focus layer (debug builds only).
//
// These used to sit inside `HomeScreen.body` and `FocusLayer.body` as `#if DEBUG` `.task` blocks. They are the
// same code, moved here: the same UserDefaults keys (launch arguments such as `-previewOrbitDump YES`), the same
// timings, the same order among the other modifiers (the call sites sit where the blocks used to), and the
// same state (the screens hand over closures that read their own `@State` live, as the old `.task` closures did).
// In a release build `.debugHomeAutomation` and `.debugFocusAutomation` return the view unchanged and never
// build their hooks (the argument is an `@autoclosure`).
//
// Not covered by `CobaltUITests`: it drives `-previewScenario`, `-previewTab`, `-paneReset` and `-previewSwarm`
// only. These keys are for hand-run simulator evidence.

// MARK: - what the screens hand over (compiled in release too, so the call sites are the same)

/// What `HomeScreen`'s automation needs from it. Closures read the screen's current state when called.
struct HomeAutomationHooks {
    let model: AppModel
    /// `orbitFrame.size`: the id the dump and audit tasks restart on.
    let orbitSize: CGSize
    let orbitFrame: @MainActor () -> CGRect
    /// The planets as drawn (`orbitMedia`, with `-previewOrbitCount` applied).
    let orbitMedia: @MainActor () -> [StoredMedia]
    let scene: @MainActor () -> OrbitScene
    /// `orbit.clock.freeze(at: 0, now:)`.
    let freezeOrbit: @MainActor () -> Void
    /// Opens a planet's detail (what a tap does).
    let openMedia: @MainActor (StoredMedia) -> Void
    /// Pops the pushed detail again (a no-op where the detail is a sheet).
    let closeDetail: @MainActor () -> Void
    let baseMedia: @MainActor (StoredMedia) -> StoredMedia
}

/// What `FocusLayer`'s automation needs from it. The first four are the ids the tasks restart on (read in the
/// screen's body, as before); the closures read the screen's current state when called.
struct FocusAutomationHooks {
    let pipeline: Pipeline
    let lifted: Bool
    let showsTrim: Bool
    let hasWebp: Bool
    let galleryBeat: String
    let onClose: @MainActor () -> Void
    let trimIsShown: @MainActor () -> Bool
    let isLong: @MainActor () -> Bool
    let isGallery: @MainActor () -> Bool
    /// `galleryFacts?.failed.isEmpty`: nil when this is not a gallery.
    let galleryFailedIsEmpty: @MainActor () -> Bool?
    let hasCropEditor: @MainActor () -> Bool
    let convert: @MainActor () -> Void
    let openCrop: @MainActor () -> Void
    let finishCrop: @MainActor () -> Void
    let chooseCropPreset: @MainActor (CropRect.Aspect) -> Void
    let setMakeKind: @MainActor (GalleryMakeKind) -> Void
    let retryGalleryItems: @MainActor () -> Void
    let remake: @MainActor () -> Void
    let openGallery: @MainActor () -> Void
    let flashCopiedWebp: @MainActor () -> Void
    let bumpShimmer: @MainActor () -> Void
    let bumpPulse: @MainActor () -> Void
}

#if DEBUG

// MARK: - flags read inside computed properties (debug)

/// Launch arguments the screens read inline, not as a task: `-previewOrbitPaused YES` (the orbit stands still),
/// `-previewOrbitCount N` (stretch the data to N planets), `-previewCrop YES` (show the crop button over a scenario
/// that does not say the server crops), `-previewSweepHold YES` (hold the edge sweep on). Read on every call, as before.
enum DebugPreviewFlags {
    static var orbitPaused: Bool { UserDefaults.standard.bool(forKey: "previewOrbitPaused") }
    static var orbitCount: Int { UserDefaults.standard.integer(forKey: "previewOrbitCount") }
    static var cropButton: Bool { UserDefaults.standard.bool(forKey: "previewCrop") }
    static var sweepHold: Bool { UserDefaults.standard.bool(forKey: "previewSweepHold") }

    /// `-previewOrbitCount 30` stretches the preview data to that many planets (design review), with
    /// a spread of file types so the badges can be judged. 1...9 shows the newest media as they are.
    /// nil when the flag is off (or there is nothing to stretch).
    static func stretchedOrbit(_ real: [StoredMedia], cap: Int) -> [StoredMedia]? {
        let n = orbitCount
        guard n > 0, !real.isEmpty else { return nil }
        let types = ["mp4", "mp4", "mov", "gif", "png", "jpg", "mp4"]
        return (0..<min(n, cap)).compactMap { i in
            guard i >= real.count else { return real[i] }
            let base = real[i % real.count]
            var original = base.original
            original?.id = "\(base.id)#\(i)"
            if original != nil, base.webps.isEmpty {
                original?.fileURL = URL(fileURLWithPath: "/nonexistent/orbit-\(i).\(types[i % types.count])")
            }
            var webps = base.webps
            for k in webps.indices { webps[k].id = "\(webps[k].id)#\(i)" }
            return StoredMedia(id: "\(base.id)#\(i)", original: original, webps: webps)
        }
    }
}

// MARK: - home

extension View {
    /// The home screen's launch-argument automation (debug builds): see `DebugHomeAutomation`.
    func debugHomeAutomation(_ hooks: @autoclosure () -> HomeAutomationHooks) -> some View {
        modifier(DebugHomeAutomation(hooks: hooks()))
    }
}

private struct DebugHomeAutomation: ViewModifier {
    let hooks: HomeAutomationHooks
    @State private var openedFirst = false
    @State private var anotherRequested = false

    func body(content: Content) -> some View {
        content
            // `-previewOrbitPaused YES` freezes the orbit at a fixed time, so a planet can be tapped at a
            // known spot; `-previewOrbitDump YES` writes where every planet is to the app's Documents.
            .task {
                if UserDefaults.standard.bool(forKey: "previewOrbitPaused") { hooks.freezeOrbit() }
            }
            .task(id: hooks.orbitSize) {
                guard UserDefaults.standard.bool(forKey: "previewOrbitDump"), hooks.orbitFrame() != .zero else { return }
                try? await Task.sleep(for: .seconds(1.2))
                dumpOrbit()
            }
            // `-previewOrbitAudit YES` logs (os_log, category orbit-audit) and writes Documents/orbit-audit.txt:
            // band radii and gaps for 3 / 7 / 14 / 16 / 24 / 35 items at rest and in the capsule states.
            .task(id: hooks.orbitSize) {
                guard UserDefaults.standard.bool(forKey: "previewOrbitAudit"), hooks.orbitFrame() != .zero else { return }
                try? await Task.sleep(for: .seconds(1.2))
                hooks.scene().writeAudit()
            }
            // `-previewOrbitSelfTest YES` runs the orbit's deterministic self-test (OrbitSelfTest) and writes
            // Documents/orbit-selftest.txt: the plan for 0-35 media in the reference's format, and the transitions.
            .task {
                guard UserDefaults.standard.bool(forKey: "previewOrbitSelfTest") else { return }
                OrbitSelfTest.write()
            }
            // `-previewGalleryImages <dir>` gives a gallery's placeholder items real pictures (GalleryPreviewHooks).
            .task { await GalleryPreviewImages.run(hooks.model) }
            // `-previewOpenFirst YES` opens the newest planet's detail once (design review, no tap needed).
            .task {
                guard UserDefaults.standard.bool(forKey: "previewOpenFirst"), !openedFirst else { return }
                openedFirst = true
                try? await Task.sleep(for: .seconds(1.2))
                if let first = hooks.orbitMedia().first { hooks.openMedia(first) }
                // `-previewOpenBack 3`: pop the detail again after 3 s (evidence of the way back)
                let back = UserDefaults.standard.double(forKey: "previewOpenBack")
                guard back > 0 else { return }
                try? await Task.sleep(for: .seconds(back))
                hooks.closeDetail()
            }
            // `-previewAnotherWebp 2` makes "another webp" of the newest media 2 s after launch: the same call the
            // detail's button makes (CONTRACT-MEDIA 1.11), so the focus flow can be recorded without a finger.
            // With `-previewConvert 2 -previewMake 3` (FocusView) the webp is made and the planet comes home.
            .task {
                let after = UserDefaults.standard.double(forKey: "previewAnotherWebp")
                guard after > 0, !anotherRequested else { return }
                anotherRequested = true
                try? await Task.sleep(for: .seconds(after))
                guard let first = hooks.orbitMedia().first else { return }
                await hooks.model.makeWebp(for: hooks.model.mediaItem(for: hooks.baseMedia(first)))
            }
            // `-previewTray 4` pastes that many links as a batch 1.5 s after launch (design review): the tray with real
            // jobs. With `-previewTrayFocus YES` the first one is a single paste that takes the focus, the rest go alongside.
            .task {
                let n = UserDefaults.standard.integer(forKey: "previewTray")
                guard n > 0 else { return }
                try? await Task.sleep(for: .seconds(1.5))
                let keys = ["Dd7P496wolG", "Dd8RkQ2xLpe", "De1Hj4tYm0Z", "De2Ab9cQwEr", "De3Zx7LkPoN", "De4Mn5BvCxS", "De5Qw8ErTyU"]
                let links = keys.prefix(n).compactMap { URL(string: "https://www.instagram.com/reel/\($0)/") }
                if UserDefaults.standard.bool(forKey: "previewTrayFocus"), let first = links.first {
                    hooks.model.queue.add([.link(first)], via: .paste)
                    hooks.model.queue.add(links.dropFirst().map { .link($0) }, via: .review)
                } else {
                    hooks.model.queue.add(links.map { .link($0) }, via: .review)
                }
            }
    }

    /// Writes where every planet is (in screen points) to Documents/orbit-slots.json.
    private func dumpOrbit() {
        let media = hooks.orbitMedia()
        let orbitFrame = hooks.orbitFrame()
        let t = Date.timeIntervalSinceReferenceDate
        let sc = hooks.scene()
        let layout = sc.geometry(at: t)
        let slots = sc.slots(at: t, geometry: layout, orbitTime: sc.orbitTime(at: t))
        let rows: [[String: Any]] = slots.compactMap { slot in
            guard let m = media.first(where: { $0.id == slot.entry }) else { return nil }
            let box = slot.box
            return [
                "index": slot.index, "id": m.id, "name": m.title, "ring": slot.ring, "face": m.face.kind == .webp ? "webp" : "video",
                "webps": m.webps.count,
                "cx": Double(orbitFrame.minX + slot.position.x), "cy": Double(orbitFrame.minY + slot.position.y),
                "w": Double(box.width * slot.scale), "h": Double(box.height * slot.scale), "opacity": slot.opacity,
            ]
        }
        let root: [String: Any] = [
            "orbitFrame": [Double(orbitFrame.minX), Double(orbitFrame.minY), Double(orbitFrame.width), Double(orbitFrame.height)],
            "center": [Double(orbitFrame.minX + sc.center.x), Double(orbitFrame.minY + sc.center.y)],
            "topInset": Double(sc.topInset), "unit": Double(layout.unit), "rings": layout.plan.rings,
            "counts": layout.plan.counts, "r0": Double(layout.r0), "top": Double(layout.top), "planets": rows,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys]),
              let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        try? data.write(to: docs.appendingPathComponent("orbit-slots.json"))
    }
}

// MARK: - focus

extension View {
    /// The focus layer's launch-argument automation (debug builds): see `DebugFocusAutomation`.
    func debugFocusAutomation(_ hooks: @autoclosure () -> FocusAutomationHooks) -> some View {
        modifier(DebugFocusAutomation(hooks: hooks()))
    }
}

private struct DebugFocusAutomation: ViewModifier {
    let hooks: FocusAutomationHooks

    func body(content: Content) -> some View {
        content
            // `-previewAutoClose 3`: close the focused planet 3 s after it has lifted (evidence of the return trip).
            .task(id: hooks.lifted) {
                let secs = UserDefaults.standard.double(forKey: "previewAutoClose")
                guard secs > 0, hooks.lifted else { return }
                try? await Task.sleep(for: .seconds(secs))
                if !Task.isCancelled { hooks.onClose() }
            }
            // `-previewConvert 2 -previewMake 3 -previewCopy 2`: press "convert to webp" 2 s after the planet has
            // lifted, then (a clip over 10 s: the trim strip is up) "make webp" 3 s later, then the copy button
            // 2 s after the webp has landed (evidence of the convert phase without a finger on the glass).
            .task(id: hooks.lifted) {
                let d = UserDefaults.standard
                let after = d.double(forKey: "previewConvert")
                guard after > 0, hooks.lifted else { return }
                try? await Task.sleep(for: .seconds(after))
                guard !Task.isCancelled else { return }
                hooks.convert()
                let make = d.double(forKey: "previewMake")
                guard make > 0 else { return }
                try? await Task.sleep(for: .seconds(make))
                if !Task.isCancelled, hooks.trimIsShown() { hooks.pipeline.makeWebp() }
            }
            .task(id: hooks.hasWebp) {
                let after = UserDefaults.standard.double(forKey: "previewCopy")
                guard after > 0, hooks.hasWebp else { return }
                try? await Task.sleep(for: .seconds(after))
                if !Task.isCancelled { hooks.pipeline.copyResultLink(); hooks.flashCopiedWebp() }
            }
            // `-previewCrop YES -previewCropOpen 1 -previewCropPreset 1:1 -previewCropDone 2 -previewCropMake 2`: once the
            // trim strip is up (a clip that fits a webp: once the planet has lifted) open the crop editor after 1 s,
            // pick the preset, press "done" 2 s later and "make webp" 2 s after that. The same functions the buttons
            // call; the gestures themselves are driven by hand.
            .task(id: "\(hooks.lifted)\(hooks.showsTrim)") {
                let d = UserDefaults.standard
                let after = d.double(forKey: "previewCropOpen")
                guard after > 0, hooks.lifted, hooks.trimIsShown() || !hooks.isLong() else { return }
                try? await Task.sleep(for: .seconds(after))
                guard !Task.isCancelled, !hooks.hasCropEditor() else { return }
                hooks.openCrop()
                if let label = d.string(forKey: "previewCropPreset"), let preset = CropRect.Aspect.allCases.first(where: { $0.label == label }) {
                    try? await Task.sleep(for: .milliseconds(600))
                    withAnimation(Motion.rows) { hooks.chooseCropPreset(preset) }
                }
                let done = d.double(forKey: "previewCropDone")
                guard done > 0 else { return }
                try? await Task.sleep(for: .seconds(done))
                guard !Task.isCancelled else { return }
                hooks.finishCrop()
                let make = d.double(forKey: "previewCropMake")
                guard make > 0 else { return }
                try? await Task.sleep(for: .seconds(make))
                if !Task.isCancelled { hooks.pipeline.makeWebp() }
            }
            // A gallery's drivers (evidence without a finger on the glass; the same functions the buttons call):
            // `-previewGallerySheet webp|mp4|image` opens the combine sheet with that output once the planet has lifted;
            // `-previewGalleryMake webp|mp4|image -previewGalleryMakeAt 2` chooses that make N s after the lift, the way
            // the sheet does (`Pipeline.make`, held until the save is over); `-previewGalleryRetry 1` presses
            // `try photo 7 again` N s after the save ended with a failure.
            .task(id: hooks.lifted) {
                let d = UserDefaults.standard
                guard hooks.lifted, hooks.isGallery() else { return }
                if let raw = d.string(forKey: "previewGallerySheet"), let kind = GalleryMakeKind(rawValue: raw) {
                    try? await Task.sleep(for: .seconds(max(0.5, d.double(forKey: "previewGallerySheetAt"))))
                    if !Task.isCancelled { hooks.setMakeKind(kind) }
                }
            }
            .task(id: hooks.lifted) {
                let d = UserDefaults.standard
                guard hooks.lifted, hooks.isGallery(), let raw = d.string(forKey: "previewGalleryMake"), let kind = GalleryMakeKind(rawValue: raw) else { return }
                try? await Task.sleep(for: .seconds(d.double(forKey: "previewGalleryMakeAt")))
                guard !Task.isCancelled else { return }
                let items = hooks.pipeline.galleryItems
                let ids = items.map(\.id)
                switch kind {
                case .webp: await hooks.pipeline.make(.slideshow(SlideshowPlan(format: .webp, items: ids)))
                case .mp4: await hooks.pipeline.make(.slideshow(SlideshowPlan(format: .mp4, items: ids)))
                case .image: await hooks.pipeline.make(.image(GalleryImagePlan(items: items.filter(\.isPhoto).map(\.id))))
                }
            }
            .task(id: hooks.galleryBeat) {
                let after = UserDefaults.standard.double(forKey: "previewGalleryRetry")
                guard after > 0, hooks.galleryBeat == "saved", hooks.galleryFailedIsEmpty() == false else { return }
                try? await Task.sleep(for: .seconds(after))
                if !Task.isCancelled { hooks.retryGalleryItems() }
            }
            // `-previewGalleryRemake 1`: presses the make's `try again` N s after a make failed.
            .task(id: hooks.galleryBeat) {
                let after = UserDefaults.standard.double(forKey: "previewGalleryRemake")
                guard after > 0, hooks.galleryBeat.contains("makefail") else { return }
                try? await Task.sleep(for: .seconds(after))
                if !Task.isCancelled { hooks.remake() }
            }
            // `-previewGalleryOpen 1`: presses `open` N s after the gallery is saved (the detail of its media over the focus).
            .task(id: hooks.galleryBeat) {
                let after = UserDefaults.standard.double(forKey: "previewGalleryOpen")
                guard after > 0, hooks.galleryBeat == "saved", hooks.galleryFailedIsEmpty() == true else { return }
                try? await Task.sleep(for: .seconds(after))
                if !Task.isCancelled { hooks.openGallery() }
            }
            // `-previewShimmerLoop YES` / `-previewPulseLoop YES`: replay the shimmer or the failure pulse every
            // 2.2 s so a screenshot can catch them mid-flight (design review only).
            .task {
                let d = UserDefaults.standard
                guard d.bool(forKey: "previewShimmerLoop") || d.bool(forKey: "previewPulseLoop") else { return }
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(2200))
                    if d.bool(forKey: "previewShimmerLoop") { hooks.bumpShimmer() }
                    if d.bool(forKey: "previewPulseLoop") { hooks.bumpPulse() }
                }
            }
    }
}

#else

// MARK: - release: nothing

enum DebugPreviewFlags {
    static var orbitPaused: Bool { false }
    static var orbitCount: Int { 0 }
    static var cropButton: Bool { false }
    static var sweepHold: Bool { false }
    static func stretchedOrbit(_ real: [StoredMedia], cap: Int) -> [StoredMedia]? { nil }
}

extension View {
    /// Release: the view as it is; the hooks are never built.
    func debugHomeAutomation(_ hooks: @autoclosure () -> HomeAutomationHooks) -> some View { self }
    func debugFocusAutomation(_ hooks: @autoclosure () -> FocusAutomationHooks) -> some View { self }
}

#endif
