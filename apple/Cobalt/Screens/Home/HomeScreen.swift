import CobaltKit
import Combine
import SwiftUI

/// The save tab: the orbit, the two glass circles, and what the tapped circle opens into. While a video
/// is being fetched, saved and read, that is the work capsule (the circle morphs into it, matching
/// `glassEffectID`) and the star above it; when the video is read, the star morphs into the newest slot
/// of the orbit and the planet lifts into focus (FocusView.swift). The orbit stays solid underneath.
struct HomeScreen: View {
    let model: AppModel
    let tier: Tier

    @Namespace private var glass
    @Namespace private var zoom
    @State private var freshID: String?
    /// The orbit's star: born when a video starts to be fetched, morphs into its thumbnail, or implodes.
    @State private var star = StarState.none
    /// The last signal the star gathered while it was alive (`shownSignal`).
    @State private var heldSignal = StarSignal()
    @State private var starToken = UUID()
    /// Where the glass circles (the planet) sit, where the orbit layer is, and where this screen is,
    /// all in global space.
    @State private var contentFrame: CGRect = .zero
    @State private var orbitFrame: CGRect = .zero
    @State private var homeFrame: CGRect = .zero
    @State private var topInset: CGFloat = 60
    /// The planet that was tapped: its detail is pushed with a zoom transition.
    @State private var openedID: String?
    #if os(macOS)
    @State private var openedSheet: PlanetID?
    #endif
    /// Top of the capsule stack (global y): the star stays above it.
    @State private var stackTop: CGFloat = 0
    /// The two circles with their captions (global space): a tap there is theirs, not a planet's.
    @State private var circlesFrame: CGRect = .zero
    /// A finger is down on the orbit: it holds still so a planet can be tapped deliberately.
    @GestureState private var holding = false
    #if DEBUG
    @State private var openedFirst = false
    @State private var anotherRequested = false
    #endif
    @State private var failureToken = 0
    @State private var inspectorOpen = true
    /// The width the home column itself gets (the inspector and the sidebar already taken out).
    @State private var contentWidth: CGFloat = 0
    @State private var lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled

    // the orbit's eased state, and the focus state
    @State private var orbit = OrbitDynamics()
    @State private var orbitBusy = false
    @State private var busyToken = UUID()
    /// Band 0's newest slot is held for the planet that is being born or is in focus.
    @State private var focusReserved = false
    /// The focus layer is mounted.
    @State private var focusActive = false
    /// The focus layer's one-off warm-up (see `FocusLayer.warm`): mounted invisibly once per launch, while the
    /// home is idle (right after the first frame, where the launch itself is still settling), so the first real
    /// star-to-planet morph does not stall on first-use costs.
    @State private var warming = false
    @State private var warmPlayer = FocusPlayerHolder()
    private static var warmedUp = false
    @State private var focusLifted = false
    /// Where the focus layer's one planet is heading: the star's dot, its slot in band 0, the lifted hero.
    @State private var focusPhase = FocusPhase.hidden
    /// The focused planet's player: handed to the orbit's pool, still playing, when the planet goes back.
    @State private var focusPlayer = FocusPlayerHolder()
    /// The orbit's players (owned here so the planet's player can move between the focus layer, the orbit
    /// and the detail without a restart).
    @State private var pool = OrbitPlayerPool()
    /// The one arrival that pops in (a webp that finishes while the orbit is at rest); a planet that comes
    /// back from focus does not pop: it was already there.
    @State private var popID: String?
    /// The player of the planet whose detail is open (shown there, still playing; back in the orbit after).
    @State private var lentPlayer: LentPlayer?
    @State private var focusClosing = false
    @State private var focusTask: Task<Void, Never>?
    /// Entries the orbit has already seen: one that arrives while the orbit is at rest (a webp that
    /// finishes after the focus was closed) pops in with the fresh outline.
    @State private var knownIDs: Set<String> = []
    @State private var knownReady = false

    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.shell) private var shell
    @Environment(\.photoImport) private var photoImport
    @Environment(\.hapticsEnabled) private var haptics

    private var pipeline: Pipeline { model.pipeline }

    private var now: Double { Date.timeIntervalSinceReferenceDate }

    // MARK: stage

    private enum Stage: Equatable {
        case idle, capsule, failure, focus, picker, image
    }

    private var stage: Stage {
        switch pipeline.state {
        case .idle:
            // a photo or video being copied out of the library (or that could not be) has the card before
            // the pipeline has a file to start with
            if photoImport?.isLoading == true { return .capsule }
            return photoImport?.failure != nil ? .failure : .idle
        case .fetching, .uploading, .saving, .reading: return .capsule
        case .ready, .rendering, .done, .savedLocally: return .focus
        case .failed(let f):
            if isBlocking(f) { return .idle }
            return keepsFocus(f) ? .focus : .failure
        case .picker: return .picker
        case .image: return .image
        }
    }

    private func keepsFocus(_ f: PipelineFailure) -> Bool {
        f.keepsTrim && pipeline.media != nil && pipeline.sessionID != nil
    }

    /// A missing or revoked key blocks everything: it is an alert with a way to settings, not a
    /// card on the page.
    private func isBlocking(_ f: PipelineFailure) -> Bool { f == .keyMissing || f == .keyInvalid }

    private var failure: PipelineFailure? {
        if case .failed(let f) = pipeline.state { return f }
        return nil
    }

    private var cardKind: CardKind? {
        switch stage {
        case .idle, .picker, .focus: return nil
        case .capsule: return .progress
        case .failure: return .failure
        case .image: return .image
        }
    }

    /// The home screen is what the owner is looking at: the save tab is selected and no planet's detail
    /// (pushed on the phone, a sheet on the Mac) covers it.
    private var homeVisible: Bool {
        guard model.selectedTab == .save else { return false }
        #if os(iOS)
        return openedID == nil
        #else
        return openedSheet == nil
        #endif
    }

    private var motionAllowed: Bool { !reduceMotion && !lowPower && scenePhase == .active && homeVisible }

    /// How fast the orbit turns: 1 at rest, about 0.3 behind a focused planet, still under Reduce Motion,
    /// Low Power Mode and when the app is not on screen.
    private var orbitSpeed: Double { orbitSpeed(lifted: focusActive && focusLifted) }

    private func orbitSpeed(lifted: Bool) -> Double {
        guard motionAllowed else { return 0 }
        #if DEBUG
        if UserDefaults.standard.bool(forKey: "previewOrbitPaused") { return 0 }
        #endif
        if holding, stage == .idle { return 0 }
        return lifted ? 0.3 : 1
    }

    /// How far the orbit dims behind the capsule or the focused planet (it dims rather than shrinks).
    private var orbitDim: Double {
        switch stage {
        case .idle: return 1
        case .capsule, .failure, .picker: return 0.55
        // the orbit brightens as the planet goes home, so it is at full light when the planet is handed back
        case .focus: return focusClosing ? 1 : (focusLifted ? 0.4 : 0.55)
        case .image: return 0.35
        }
    }

    private var starRuns: Bool {
        switch star.phase {
        case .none: return false
        case .alive: return !reduceMotion
        default: return true
        }
    }

    /// The run's media: the one the pipeline adds to ("another webp"), or that holds its stored original or
    /// its session (CONTRACT-MEDIA 1.6: by media, never by session, so a reopened session cannot split it).
    private func isRunMedia(_ m: StoredMedia) -> Bool {
        if let id = pipeline.mediaID, m.id == id { return true }
        if let sid = pipeline.sessionID, m.sessionIDs.contains(sid) { return true }
        if let id = pipeline.stored?.id, m.renditions.contains(where: { $0.id == id }) { return true }
        if case .savedLocally(let v) = pipeline.state, m.renditions.contains(where: { $0.id == v.id }) { return true }
        return false
    }

    /// The planets: one per media on this device, newest by latest activity first (CONTRACT-MEDIA 1.1, 1.5).
    /// While a run is being read (the star), born, or in focus, that run's media is not in the orbit (the star
    /// and the focus layer draw it: a keep-original that lands while the star still reads must not show a
    /// planet under it; a media that gets another webp leaves its slot and springs back into the newest one).
    private var orbitMedia: [StoredMedia] {
        let cap = CurrentOrbitGeometry.maxItems - (focusReserved ? 1 : 0)
        var real = model.store.latestMedia(CurrentOrbitGeometry.maxItems)
        if focusReserved || stage == .capsule { real = real.filter { !isRunMedia($0) } }
        #if DEBUG
        // `-previewOrbitCount 30` stretches the preview data to that many planets (design review), with
        // a spread of file types so the badges can be judged. 1...9 shows the newest media as they are.
        let n = UserDefaults.standard.integer(forKey: "previewOrbitCount")
        if n > 0, !real.isEmpty {
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
        #endif
        return Array(real.prefix(cap))
    }

    /// What the orbit knows about its entries: the reserved focus slot, then every media with the shape of its
    /// face (a webp made with a crop is square or 4:5: the planet's box springs to it).
    private var orbitEntries: [OrbitEntry] {
        (focusReserved ? [OrbitEntry(id: OrbitScene.focusID)] : []) + orbitMedia.map { m in
            OrbitEntry(id: m.id, width: CGFloat(m.face.width ?? 720), height: CGFloat(m.face.height ?? 1280))
        }
    }

    /// The planet: midpoint of the circles, in the orbit layer's own coordinates.
    private var orbitCenter: CGPoint {
        guard contentFrame != .zero, orbitFrame != .zero else {
            return CGPoint(x: orbitFrame.width / 2, y: orbitFrame.height * 0.8)
        }
        // 16 pt bottom padding + 4 + caption + gap + the circle's radius
        return CGPoint(x: contentFrame.midX - orbitFrame.minX, y: contentFrame.maxY - 80 - orbitFrame.minY)
    }

    /// Everything the orbit and this screen both need to ask about where the planets are.
    private var scene: OrbitScene {
        OrbitScene(
            size: orbitFrame.size, center: orbitCenter, topInset: max(60, homeFrame.minY - orbitFrame.minY, topInset),
            starCeiling: stackTop > 0 ? stackTop - orbitFrame.minY : nil,
            dynamics: orbit)
    }

    /// Where a tap is chrome's, not the orbit's (the circles and their captions, with slack).
    private func isChrome(_ point: CGPoint) -> Bool {
        !circlesFrame.isEmpty && circlesFrame.insetBy(dx: -14, dy: -12).contains(point)
    }

    private var canInspect: Bool { tier == .wide && stage == .focus && focusLifted }

    private var inspectorBinding: Binding<Bool> {
        Binding(
            get: { canInspect && inspectorOpen },
            set: { if canInspect { inspectorOpen = $0 } })
    }

    private var glassID: String {
        if case .file = pipeline.input { return "file" }
        if photoImport?.isLoading == true || photoImport?.failure != nil { return "file" }
        return "paste"
    }

    // MARK: body

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                // The orbit is the page: full-bleed, under the status bar, the tab bar and the
                // toolbar (and, on iPad and the Mac, extended under the sidebar). Everything else
                // floats over it as glass.
                orbitLayer
                ScrollView {
                    column(height: proxy.size.height)
                        .environment(\.homeHeight, proxy.size.height)
                        .frame(minHeight: proxy.size.height)
                        .padding(.horizontal, tier == .compact ? Metrics.gutter : 28)
                        .frame(maxWidth: Metrics.columnMax)
                        .frame(maxWidth: .infinity)
                }
                .scrollBounceBehavior(.basedOnSize)
                .scrollIndicators(.hidden)
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { contentWidth = $0 }
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { contentFrame = $0 }
                if focusActive {
                    FocusLayer(
                        model: model, pipeline: pipeline, contentWidth: contentWidth, phase: focusPhase,
                        lifted: focusLifted, player: focusPlayer, visible: homeVisible, onClose: closeFocus)
                        // a run that takes over (a share-sheet job resumed) is a new planet: new layer state
                        .id(pipeline.runID)
                        .environment(\.homeHeight, proxy.size.height)
                        .transition(.opacity)
                } else if warming {
                    FocusLayer(
                        model: model, pipeline: pipeline, contentWidth: contentWidth, phase: .hidden, lifted: false,
                        player: warmPlayer, visible: false, warm: true, onClose: {})
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                        .environment(\.homeHeight, proxy.size.height)
                }
            }
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { homeFrame = $0 }
            .onGeometryChange(for: CGFloat.self) { $0.safeAreaInsets.top } action: { topInset = $0 }
        }
        .inspector(isPresented: inspectorBinding) {
            InspectorColumn(model: model)
                .inspectorColumnWidth(min: 280, ideal: Metrics.inspector, max: 420)
        }
        .navigationTitle(Copy.appName)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #else
        .navigationSubtitle(subtitle)
        #endif
        .toolbar {
            #if os(iOS)
            ToolbarItem(placement: .principal) {
                // the title in Plex Mono (a navigation title cannot take it), the count quietly under it
                VStack(spacing: 1) {
                    Text(Copy.appName)
                        .font(Font.cobalt(17, .semibold, relativeTo: .headline))
                        .accessibilityAddTraits(.isHeader)
                    Text(subtitle)
                        .font(Font.cobalt(12, .regular, relativeTo: .caption))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
            }
            #else
            ToolbarItemGroup(placement: .primaryAction) {
                PasteFileButtons(showsFile: model.capabilities.showsFileButton)
            }
            #endif
            if canInspect {
                ToolbarItem(placement: .primaryAction) {
                    Button { inspectorOpen.toggle() } label: {
                        Label(Copy.inspectorToggle, systemImage: Symbol.inspector)
                    }
                    .help(Copy.inspectorToggle)
                }
            }
        }
        .sheet(isPresented: pickerBinding) { pickerSheet }
        .alert(failure.map(Copy.failure) ?? "", isPresented: keyAlertBinding) {
            Button(Copy.openSettings) {
                pipeline.reset()
                shell.openSettings()
            }
            Button(Copy.ok, role: .cancel) { pipeline.reset() }
        }
        .onChange(of: stage) { old, new in stageChanged(from: old, to: new) }
        .task {
            guard !Self.warmedUp else { return }
            Self.warmedUp = true
            try? await Task.sleep(for: .milliseconds(250))
            // only while nothing is going on: a run that has started is the owner's, not ours to stall
            guard stage == .idle, !focusActive, homeVisible else { Self.warmedUp = false; return }
            AudioPolicy.ambient()
            warming = true
            try? await Task.sleep(for: .milliseconds(700))
            warming = false
        }
        .onChange(of: openedID) { _, id in
            // the detail went away: its planet's player is the orbit's again
            if id == nil { pool.lent = nil; lentPlayer = nil }
        }
        .onChange(of: pipeline.runID) { _, _ in
            // The run behind the focused planet was replaced without leaving the focus stage (a job taken
            // over while a finished result was showing): lift the new run's planet.
            if focusActive, stage == .focus { enterFocus(fromWork: false) }
        }
        .onChange(of: model.store.media.map(\.id), initial: true) { _, ids in noteArrivals(ids) }
        .onChange(of: failure, initial: true) { _, new in
            if new != nil { failureToken += 1 }
        }
        .haptic(.error, trigger: failure, enabled: haptics) { $0 != nil }
        .onReceive(NotificationCenter.default.publisher(for: .NSProcessInfoPowerStateDidChange).receive(on: RunLoop.main)) { _ in
            lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
        }
        .onChange(of: starCategory) { old, new in advanceStar(from: old, to: new) }
        .onChange(of: starSignal) { _, new in if starCategory == .working { heldSignal = new } }
        .onChange(of: orbitEntries, initial: true) { _, _ in syncOrbit() }
        .onChange(of: orbitFrame.size) { _, _ in syncOrbit() }
        .onChange(of: orbitSpeed, initial: true) { old, new in
            // a finger stops the orbit quickly; letting go (or coming back to the screen) eases it up gently
            let rate: Double? = holding ? 9 : (old == 0 && new > 0 ? 1.4 : nil)
            orbit.clock.retarget(speed: new, at: now, instant: reduceMotion || (new == 0 && !holding), rate: rate)
            kick()
        }
        .onChange(of: roomTarget, initial: true) { _, new in
            orbit.room.retarget(new, at: now, instant: reduceMotion)
            kick()
        }
        .task { await model.store.backfillPreviewFrames() }
        #if DEBUG
        // `-previewOrbitPaused YES` freezes the orbit at a fixed time, so a planet can be tapped at a
        // known spot; `-previewOrbitDump YES` writes where every planet is to the app's Documents.
        .task {
            if UserDefaults.standard.bool(forKey: "previewOrbitPaused") { orbit.clock.freeze(at: 0, now: now) }
        }
        .task(id: orbitFrame.size) {
            guard UserDefaults.standard.bool(forKey: "previewOrbitDump"), orbitFrame != .zero else { return }
            try? await Task.sleep(for: .seconds(1.2))
            dumpOrbit()
        }
        // `-previewOrbitAudit YES` logs (os_log, category orbit-audit) and writes Documents/orbit-audit.txt:
        // band radii and gaps for 3 / 7 / 14 / 16 / 24 / 35 items at rest and in the capsule states.
        .task(id: orbitFrame.size) {
            guard UserDefaults.standard.bool(forKey: "previewOrbitAudit"), orbitFrame != .zero else { return }
            try? await Task.sleep(for: .seconds(1.2))
            scene.writeAudit()
        }
        // `-previewOrbitSelfTest YES` runs the orbit's deterministic self-test (OrbitSelfTest) and writes
        // Documents/orbit-selftest.txt: the plan for 0-35 media in the reference's format, and the transitions.
        .task {
            guard UserDefaults.standard.bool(forKey: "previewOrbitSelfTest") else { return }
            OrbitSelfTest.write()
        }
        // `-previewOpenFirst YES` opens the newest planet's detail once (design review, no tap needed).
        .task {
            guard UserDefaults.standard.bool(forKey: "previewOpenFirst"), !openedFirst else { return }
            openedFirst = true
            try? await Task.sleep(for: .seconds(1.2))
            if let first = orbitMedia.first { open(first) }
            // `-previewOpenBack 3`: pop the detail again after 3 s (evidence of the way back)
            let back = UserDefaults.standard.double(forKey: "previewOpenBack")
            guard back > 0 else { return }
            try? await Task.sleep(for: .seconds(back))
            #if os(iOS)
            openedID = nil
            #endif
        }
        // `-previewAnotherWebp 2` makes "another webp" of the newest media 2 s after launch: the same call the
        // detail's button makes (CONTRACT-MEDIA 1.11), so the focus flow can be recorded without a finger.
        // With `-previewConvert 2 -previewMake 3` (FocusView) the webp is made and the planet comes home.
        .task {
            let after = UserDefaults.standard.double(forKey: "previewAnotherWebp")
            guard after > 0, !anotherRequested else { return }
            anotherRequested = true
            try? await Task.sleep(for: .seconds(after))
            guard let first = orbitMedia.first else { return }
            await model.makeWebp(for: model.mediaItem(for: baseMedia(first)))
        }
        #endif
        #if os(iOS)
        .navigationDestination(item: $openedID) { id in
            if let media = model.store.media(id: baseID(id)) {
                MediaDetail(model: model, item: model.mediaItem(for: media))
                    .environment(\.lentPlayer, lentPlayer)
                    .navigationTransition(.zoom(sourceID: id, in: zoom))
            }
        }
        #else
        .sheet(item: $openedSheet) { item in
            if let media = model.store.media(id: baseID(item.id)) {
                NavigationStack { MediaDetail(model: model, item: model.mediaItem(for: media)) }.frame(minWidth: 460, minHeight: 560)
            }
        }
        #endif
        .cobaltPage()
    }

    private var orbitLayer: some View {
        let solo = soloCaption
        return OrbitView(
            media: orbitMedia, scene: scene, running: orbitRuns, dim: orbitDim, freshID: freshID,
            popID: popID, pool: pool, playersEnabled: motionAllowed,
            flipbooksEnabled: !(focusActive && focusLifted),
            star: star, signal: shownSignal, poster: pipeline.posterFrame,
            lowPower: lowPower, zoom: zoom,
            caption: { media in solo?.id == media.id ? solo?.caption : nil },
            onFrame: { orbitFrame = $0 })
            .ignoresSafeArea()
            .modifier(ExtendUnderSidebar(enabled: tier != .compact))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Copy.orbitA11y)
            .accessibilityValue(orbitSummary)
            // while a planet is in focus the orbit behind it offers nothing to open
            .accessibilityActions { if !focusActive { orbitActions } }
    }

    /// The orbit's timeline runs while the orbit turns, the star lives, or something is still easing
    /// (and never while another tab or a planet's detail is on screen).
    private var orbitRuns: Bool { homeVisible && (orbitSpeed > 0 || starRuns || orbitBusy) }

    /// Keeps the timeline running while eased values settle (a second or two).
    private func kick() {
        orbitBusy = true
        let token = UUID()
        busyToken = token
        Task {
            try? await Task.sleep(for: .seconds(2.4))
            if busyToken == token { orbitBusy = false }
        }
    }

    private var keyAlertBinding: Binding<Bool> {
        Binding(
            get: { failure.map(isBlocking) ?? false },
            set: { if !$0, let f = failure, isBlocking(f) { pipeline.reset() } })
    }

    private func column(height: CGFloat) -> some View {
        let isIdle = stage == .idle
        return VStack(spacing: 12) {
            Spacer(minLength: 0)
            GlassEffectContainer(spacing: 2) {
                VStack(spacing: 12) {
                    if let kind = cardKind {
                        WorkCard(kind: kind, glassID: glassID, glass: glass, failureToken: failureToken) { cardContent }
                    }
                    if isIdle { circles }
                }
            }
            .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).minY } action: { stackTop = $0 }
        }
        .padding(.top, 8)
        .padding(.bottom, 16)
        // A tap on the empty page lands on whichever planet is under the finger.
        .background {
            Color.clear
                .contentShape(Rectangle())
                .gesture(SpatialTapGesture(coordinateSpace: .global).onEnded { openPlanet(atGlobal: $0.location) })
                // press and hold stops the orbit (a tap needs a still planet)
                .simultaneousGesture(DragGesture(minimumDistance: 0).updating($holding) { _, state, _ in state = true })
        }
        .motion(Motion.morph, value: stage, reduced: .fade)
    }

    // MARK: pieces

    /// "13 videos · 54 MB on this iphone", the quiet line under the title (above the orbit's top band,
    /// never over a planet).
    private var subtitle: String {
        let usage = model.store.usage
        #if DEBUG
        // `-previewOrbitCount N` (design review): the line counts the planets that are drawn
        if UserDefaults.standard.integer(forKey: "previewOrbitCount") > 0 {
            return Copy.offline(count: orbitMedia.count, bytes: usage.bytes)
        }
        #endif
        return usage.mediaCount == 0 && model.store.media.isEmpty
            ? Copy.emptyOrbit : Copy.offline(count: usage.mediaCount, bytes: usage.bytes)
    }

    private var circles: some View {
        HStack(alignment: .top, spacing: 28) {
            CircleLabel(id: "paste", glass: glass, title: Copy.paste, systemImage: Symbol.paste, a11y: Copy.pasteA11y) { shell.paste() }
            if model.capabilities.showsFileButton {
                CircleLabel(id: "file", glass: glass, title: Copy.file, systemImage: Symbol.file, a11y: Copy.fileA11y, menu: true) {}
            }
        }
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { circlesFrame = $0 }
        .frame(maxWidth: .infinity)
        .padding(.bottom, 4)
    }

    @ViewBuilder
    private var cardContent: some View {
        switch pipeline.state {
        case .idle:
            if let photoImport { photoImportCard(photoImport) }
        case .fetching, .uploading, .saving, .reading:
            if let story = pipeline.progressStory { ProgressCard(story: story) }
        case .failed(let f) where !keepsFocus(f) && !isBlocking(f):
            InlineStatus(message: Copy.failure(f)) {
                Button(Copy.ok, systemImage: Symbol.checkmark) { pipeline.reset() }.buttonStyle(.cobaltSecondary(fullWidth: false))
            }
        case .image(let info):
            ImageCardContent(pipeline: pipeline, info: info) { pipeline.reset() }
        default:
            EmptyView()
        }
    }

    /// The card while a picked photo or video is copied out of the library: the same progress card as an
    /// upload, with a way out (an iCloud original can take a while), or the failure with its "ok".
    @ViewBuilder
    private func photoImportCard(_ photoImport: PhotoImport) -> some View {
        switch photoImport.phase {
        case .loading(let fraction):
            VStack(alignment: .leading, spacing: 10) {
                ProgressCard(story: .photoImport(fraction: fraction))
                Button(Copy.cancel, systemImage: Symbol.close) { photoImport.cancel() }
                    .buttonStyle(.cobaltSecondary(fullWidth: false))
            }
        case .failed(let f):
            InlineStatus(message: Copy.failure(f)) {
                Button(Copy.ok, systemImage: Symbol.checkmark) { photoImport.dismissFailure() }.buttonStyle(.cobaltSecondary(fullWidth: false))
            }
        case .idle:
            EmptyView()
        }
    }

    // MARK: picker

    private var pickerBinding: Binding<Bool> {
        Binding(
            get: { if case .picker = pipeline.state { return true } else { return false } },
            set: { if !$0, case .picker = pipeline.state { pipeline.reset() } })
    }

    @ViewBuilder
    private var pickerSheet: some View {
        if case .picker(let items) = pipeline.state {
            PickerSheet(
                pipeline: pipeline, items: items,
                webpAvailable: model.capabilities.kind == .fork && model.capabilities.studio && model.capabilities.upload)
        }
    }

    // MARK: the star

    private enum StarCategory: Equatable { case idle, working, landed, picker, failed, other }

    private var starCategory: StarCategory {
        switch pipeline.state {
        case .idle: return .idle
        case .fetching, .uploading, .saving, .reading: return .working
        case .ready, .image, .savedLocally: return .landed
        case .picker: return .picker
        case .failed(let f): return f.keepsTrim ? .other : .failed
        case .rendering, .done: return .other
        }
    }

    /// The star reads the progress card's own value (`ProgressStory`): bytes over total, the waking flag,
    /// frames developed. Before the first frame is read it is as grown as it was when the save finished.
    private var starSignal: StarSignal {
        guard let story = pipeline.progressStory else { return StarSignal() }
        switch story.phase {
        case .fetching: return StarSignal(waking: story.waking)
        case .uploading, .saving: return StarSignal(fraction: story.fraction)
        case .reading: return StarSignal(fraction: story.framesRead == 0 ? 1 : nil, developed: story.framesRead)
        default: return StarSignal()
        }
    }

    /// What the star wears while it draws. Once the work is over (the morph, the implosion, the fade) it
    /// keeps what it had gathered, so the rings and the size carry into the handoff instead of resetting
    /// the frame the pipeline says "ready".
    private var shownSignal: StarSignal { starCategory == .working ? starSignal : heldSignal }

    /// While the star lives the inner bands make room for it: 1.14 fetching, 1.14 to 1.32 saving, 1.32 reading.
    private var roomTarget: Double {
        guard star.phase == .alive else { return 1 }
        let s = starSignal
        if s.developed > 0 { return 1.32 }
        if let f = s.fraction { return 1.14 + 0.18 * f }
        return 1.14
    }

    private func advanceStar(from old: StarCategory, to new: StarCategory) {
        let next: StarPhase?
        switch (old, new) {
        case (_, .working): next = .alive
        case (.working, .landed):
            let m = pipeline.media
            let aspect = (m?.width).flatMap { w in (m?.height).map { h in h > 0 ? CGFloat(w) / CGFloat(h) : 9.0 / 16 } } ?? 9.0 / 16
            var lands = true
            if case .image = pipeline.state { lands = false }
            next = .morphing(aspect: aspect, lands: lands)
        case (.working, .failed), (.idle, .failed): next = .imploding
        case (.working, .idle), (.working, .picker): next = .fading
        default: next = nil
        }
        guard let phase = next else { return }
        let token = UUID()
        starToken = token
        star = StarState(phase: phase, since: Date())
        kick()
        let duration = star.duration
        guard duration.isFinite else { return }
        Task {
            try? await Task.sleep(for: .seconds(duration + 0.1))
            if starToken == token { star = .none }
        }
    }

    // MARK: orbit dynamics

    /// A new entry list (an arrival, a deletion, a face with another shape): planets whose slot changed hold
    /// their angle, then slide to the new one; the bands' radii and the planets' box ease; a band the count
    /// needs is born and one it does not need undraws (`OrbitScene.sync`, orbit E).
    private func syncOrbit() {
        var sc = scene
        sc.sync(entries: orbitEntries, now: now, instant: reduceMotion)
        guard sc.dynamics != orbit else { return }
        orbit = sc.dynamics
        kick()
    }

    // MARK: focus

    private func stageChanged(from old: Stage, to new: Stage) {
        // A run took over (the detail's "trim a new webp", the library's, a share-sheet handoff): the
        // planet's detail goes away so the work and then the focus are what the owner sees.
        if new != .idle, old == .idle {
            #if os(iOS)
            openedID = nil
            #else
            openedSheet = nil
            #endif
        }
        if new == .focus, old != .focus {
            enterFocus(fromWork: old == .capsule)
        } else if old == .focus, new != .focus, focusActive, !focusClosing {
            // the run was replaced (a new link) or failed for good: no return trip
            dropFocus()
        }
    }

    /// The pipeline landed. Slot 0 of band 0 is reserved at once (the other planets glide over) and band 0
    /// is held so the newborn lands in view. The focus layer's planet is born as the star's dot, rides the
    /// morph into the slot, and a moment later lifts out of its band into focus: ONE view all the way, so
    /// the picture moves and scales with the frame and is never crossfaded.
    private func enterFocus(fromWork: Bool) {
        focusTask?.cancel()
        // a run that took over: the old planet's player does not outlive it
        focusPlayer.stop()
        focusClosing = false
        focusReserved = true
        focusLifted = false
        focusPhase = .hidden
        syncOrbit()
        focusActive = true
        guard fromWork else {
            // resumed from a share-sheet handoff or the library: there was no star, so no lift
            focusTask = Task { @MainActor in
                withAnimation(reduceMotion ? Motion.fade : FocusMotion.content) { focusLifted = true }
                focusPhase = .lifted
            }
            return
        }
        if let hold = scene.holdOffset(landingIn: 0.8, now: now) {
            orbit.offset0.retarget(orbit.offset0.target + hold, at: now, instant: reduceMotion)
        }
        if reduceMotion {
            focusTask = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(350))
                guard !Task.isCancelled, stage == .focus else { return }
                focusPhase = .lifted
                focusLifted = true
            }
            return
        }
        focusPhase = .born(starRectInHome())
        focusTask = Task { @MainActor in
            // let the dot be drawn, then morph: by the time the bands have settled the planet is in its slot
            try? await Task.sleep(for: .milliseconds(40))
            guard !Task.isCancelled, stage == .focus else { return }
            if let slot = slotRectInHome(at: now + 0.8) { focusPhase = .slot(slot, closing: false) }
            try? await Task.sleep(for: .milliseconds(760))
            guard !Task.isCancelled, stage == .focus else { return }
            withAnimation(FocusMotion.lift) { focusLifted = true }
            focusPhase = .lifted
        }
    }

    /// Close (or swipe down): the planet springs back into the newest slot of band 0, the orbit brightens
    /// and resumes its speed, then the planet hands over to its real place in the orbit, with its player.
    private func closeFocus() {
        guard focusActive, !focusClosing else { return }
        focusClosing = true
        focusTask?.cancel()
        // the run being closed: 620 ms from now it may have been replaced, and then it is not ours to end
        let run = pipeline.runID
        let handover = 0.62
        // While the planet was in focus its band went on turning: hold band 0 so the newest slot is in the
        // open part of the band when the planet lands in it (a slot at the band's faded end shows nothing).
        if !reduceMotion {
            // judged against the orbit as it will turn from now on (back to full speed), not as it turns behind the planet
            var resumed = scene
            resumed.dynamics.clock.retarget(speed: orbitSpeed(lifted: false), at: now)
            if let hold = resumed.holdOffset(landingIn: handover, now: now) {
                orbit.offset0.retarget(orbit.offset0.target + hold, at: now)
            }
        }
        guard !reduceMotion, let slot = slotRectInHome(at: now + handover, lifted: false) else {
            finishClose(run: run)
            return
        }
        focusPhase = .slot(slot, closing: true)
        withAnimation(FocusMotion.land) { focusLifted = false }
        focusTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(Int(handover * 1000)))
            guard !Task.isCancelled else { return }
            finishClose(run: run)
        }
    }

    /// The planet is back in its band. Closing does not end the work: a render, a publish or a keep-original
    /// in flight carries on in the background (`detach`), and its webp or link badge shows up on the orbit
    /// when it completes (from the store). Only a run that is still the one that was closed is detached.
    private func finishClose(run: UUID) {
        guard focusClosing else { return }
        let sameRun = pipeline.runID == run
        // the run's media (by id, CONTRACT-MEDIA 1.6), read before the run is detached
        var mine = pipeline.mediaID.flatMap { model.store.media(id: $0) }
        if mine == nil, case .savedLocally(let v) = pipeline.state { mine = model.store.media(containing: v.id) }
        // The orbit's planet takes over the picture: the very player the focus layer was playing, no restart
        // (only while the face is still the video: a webp face has no player).
        if sameRun, motionAllowed, let mine, mine.face.kind == .original, let given = focusPlayer.release() {
            pool.adopt(id: mine.id, player: given.player, looper: given.looper)
        } else {
            focusPlayer.stop()
        }
        if sameRun { pipeline.detach() }
        focusActive = false
        focusReserved = false
        focusLifted = false
        focusPhase = .hidden
        focusClosing = false
        // the media comes home in this same update: the planet takes the held slot, wearing its new face
        syncOrbit()
        guard sameRun else { return }
        if let mine { markFresh(mine.id, pop: false) }
    }

    private func markFresh(_ id: String, pop: Bool) {
        freshID = id
        popID = pop ? id : nil
        Task {
            try? await Task.sleep(for: .seconds(4))
            if freshID == id { freshID = nil }
            if popID == id { popID = nil }
        }
    }

    /// Entries that arrive while the orbit is at rest (a webp that finishes after the focus was closed)
    /// pop in. During a run the star and the focus layer own the arrivals.
    private func noteArrivals(_ ids: [String]) {
        let set = Set(ids)
        defer { knownIDs = set; knownReady = true }
        guard knownReady, stage == .idle, !focusReserved else { return }
        if let arrival = ids.first(where: { !knownIDs.contains($0) }) { markFresh(arrival, pop: true) }
    }

    private func dropFocus() {
        focusTask?.cancel()
        focusPlayer.stop()
        focusActive = false
        focusReserved = false
        focusLifted = false
        focusPhase = .hidden
        focusClosing = false
        syncOrbit()
    }

    /// Where band 0's newest slot is `at` wall time, in this screen's space (the focus layer's space). With
    /// `lifted: false` the orbit is taken to have resumed its speed from now on (the planet is on its way back).
    private func slotRectInHome(at t: Double, lifted: Bool = false) -> CGRect? {
        var sc = scene
        if !lifted { sc.dynamics.clock.retarget(speed: orbitSpeed(lifted: false), at: now, instant: reduceMotion) }
        guard let slot = sc.slot(0, at: t) else { return nil }
        let m = pipeline.media
        let stored: StoredVideo? = pipeline.stored ?? { if case .savedLocally(let v) = pipeline.state { return v } else { return nil } }()
        var w = CGFloat(m?.width ?? stored?.width ?? 720), h = CGFloat(m?.height ?? stored?.height ?? 1280)
        // on its way home the planet takes the shape of the face it will wear (a webp with a crop is square)
        if focusClosing, let face = pipeline.mediaID.flatMap({ model.store.media(id: $0) })?.face,
           let fw = face.width, let fh = face.height, fw > 0, fh > 0 {
            w = CGFloat(fw)
            h = CGFloat(fh)
        }
        let box = CurrentOrbitGeometry.box(width: w, height: h, fit: slot.fit)
        let bw = box.width * slot.scale, bh = box.height * slot.scale
        let ox = orbitFrame.minX - homeFrame.minX, oy = orbitFrame.minY - homeFrame.minY
        return CGRect(x: ox + slot.position.x - bw / 2, y: oy + slot.position.y - bh / 2, width: bw, height: bh)
    }

    /// The star's dot in this screen's space: where the planet is born.
    private func starRectInHome() -> CGRect {
        let p = scene.starPoint
        let d: CGFloat = 20.6
        let ox = orbitFrame.minX - homeFrame.minX, oy = orbitFrame.minY - homeFrame.minY
        return CGRect(x: ox + p.x - d / 2, y: oy + p.y - d / 2, width: d, height: d)
    }

    // MARK: orbit access

    /// The planet's id without the debug suffix that `-previewOrbitCount` adds.
    private func baseID(_ id: String) -> String { String(id.split(separator: "#").first ?? Substring(id)) }

    private var orbitSummary: String {
        let usage = model.store.usage
        return Copy.offline(count: usage.mediaCount, bytes: usage.bytes)
    }

    /// VoiceOver: every visible planet is a custom action ("open instagram …") on the orbit.
    @ViewBuilder
    private var orbitActions: some View {
        ForEach(orbitMedia) { media in
            Button(Copy.Media.planetA11y(title: media.title, webps: media.webps.count, hasVideo: media.original != nil)) { open(media) }
        }
    }

    /// The real media behind a planet (the debug suffix that `-previewOrbitCount` adds stripped).
    private func baseMedia(_ media: StoredMedia) -> StoredMedia {
        model.store.media(id: baseID(media.id)) ?? media
    }

    /// Opens the media's detail (CONTRACT-MEDIA 1.8): on the face's tab. On the phone the planet's own
    /// player is lent to it when the face is the video, so the zoom carries the picture and nothing restarts.
    private func open(_ media: StoredMedia) {
        #if os(macOS)
        openedSheet = PlanetID(id: media.id)
        #else
        if media.face.kind == .original, let lent = pool.lend(media.id) {
            // the detail knows the video by its record id
            lentPlayer = LentPlayer(id: media.face.id, player: lent.player)
        } else {
            lentPlayer = nil
        }
        openedID = media.id
        #endif
    }

    /// The two lines under a media that is alone in the orbit: "instagram · Dd7P496wolG" and
    /// "10.1 s · 480×480 · 2 webps" (service · ref, length · size). Built once per screen update.
    private var soloCaption: (id: String, caption: OrbitCaption)? {
        guard orbitMedia.count == 1, !focusReserved, let media = orbitMedia.first else { return nil }
        let item = model.mediaItem(for: baseMedia(media))
        let title = (item.service != nil && item.ref != nil) ? Copy.focusTitle(service: item.service ?? "", ref: item.ref ?? "") : media.title
        let face = media.face
        var parts: [String] = []
        if let d = face.duration { parts.append(Format.seconds(d)) }
        if let w = face.width, let h = face.height { parts.append(Format.size(w, h)) }
        if media.webps.count > 0 { parts.append(media.webps.count == 1 ? "1 webp" : "\(media.webps.count) webps") }
        return (media.id, OrbitCaption(title: title, detail: parts.joined(separator: " · ")))
    }

    /// A tap on the empty page opens whichever planet is under the finger: the same slots the orbit view
    /// draws, evaluated at the moment of the tap (so a moving planet is hit where it is).
    private func openPlanet(atGlobal point: CGPoint) {
        guard stage == .idle, orbitFrame != .zero, !isChrome(point) else { return }
        let local = CGPoint(x: point.x - orbitFrame.minX, y: point.y - orbitFrame.minY)
        let media = orbitMedia
        guard !media.isEmpty else { return }
        let t = now
        let sc = scene
        let layout = sc.geometry(at: t)
        let slots = sc.slots(at: t, geometry: layout, orbitTime: sc.orbitTime(at: t))
        if let id = layout.hit(local, slots: slots), let tapped = media.first(where: { $0.id == id }) {
            open(tapped)
        }
    }

    #if DEBUG
    /// Writes where every planet is (in screen points) to Documents/orbit-slots.json.
    private func dumpOrbit() {
        let media = orbitMedia
        let t = now
        let sc = scene
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
    #endif
}

/// A glass circle with its caption underneath. The circle carries a `glassEffectID` so the card it
/// opens into can morph out of it.
struct CircleLabel: View {
    let id: String
    let glass: Namespace.ID
    let title: String
    let systemImage: String
    let a11y: String
    /// A circle that opens the file source menu (photos or files) instead of acting on tap.
    var menu = false
    let action: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var icon: some View {
        Image(systemName: systemImage)
            .font(.system(size: 26, weight: .medium))
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private var control: some View {
        if menu {
            FileSourceMenu { icon }
        } else {
            Button(action: action) { icon }
        }
    }

    var body: some View {
        VStack(spacing: 8) {
            control
            .buttonStyle(CircleButtonStyle())
            .glassEffectID(id, in: glass)
            .glassEffectTransition(reduceMotion ? .identity : .matchedGeometry)
            .accessibilityLabel(a11y)
            Text(title)
                .font(Font.cobalt(11.5, .regular, relativeTo: .caption))
                .foregroundStyle(CobaltColor.caption)
                .accessibilityHidden(true)
        }
    }
}

#if DEBUG
#Preview("home · happy · at rest") {
    PreviewHost(.happy) { HomeScreen(model: $0, tier: .compact) }
}
#Preview("home · happy · pipeline") {
    PreviewHost(.happy, script: .input) { HomeScreen(model: $0, tier: .compact) }
}
#Preview("home · happy · to the webp") {
    PreviewHost(.happy, script: .render) { HomeScreen(model: $0, tier: .compact) }
}
#Preview("home · happy · public share") {
    PreviewHost(.happy, script: .share) { HomeScreen(model: $0, tier: .compact) }
}
#Preview("home · cold start") {
    PreviewHost(.coldStart, script: .input) { HomeScreen(model: $0, tier: .compact) }
}
#Preview("home · no link") {
    PreviewHost(.noLink, script: .input) { HomeScreen(model: $0, tier: .compact) }
}
#Preview("home · private post") {
    PreviewHost(.privatePost, script: .input) { HomeScreen(model: $0, tier: .compact) }
}
#Preview("home · file over the limit") {
    PreviewHost(.tooBig, script: .input) { HomeScreen(model: $0, tier: .compact) }
}
#Preview("home · another webp is encoding") {
    PreviewHost(.renderBusy, script: .render) { HomeScreen(model: $0, tier: .compact) }
}
#Preview("home · webp lost") {
    PreviewHost(.renderLost, script: .render) { HomeScreen(model: $0, tier: .compact) }
}
#Preview("home · picker") {
    PreviewHost(.picker, script: .input) { HomeScreen(model: $0, tier: .compact) }
}
#Preview("home · image") {
    PreviewHost(.image, script: .input) { HomeScreen(model: $0, tier: .compact) }
}
#Preview("home · short clip") {
    PreviewHost(.shortClip, script: .input) { HomeScreen(model: $0, tier: .compact) }
}
#Preview("home · plain cobalt") {
    PreviewHost(.plainCobalt, script: .input) { HomeScreen(model: $0, tier: .compact) }
}
#Preview("home · legacy fork") {
    PreviewHost(.legacyFork, script: .input) { HomeScreen(model: $0, tier: .compact) }
}
#Preview("home · revoked key") {
    PreviewHost(.revokedKey, script: .input) { HomeScreen(model: $0, tier: .compact) }
}
#Preview("home · empty orbit") {
    PreviewHost(.emptyOrbit) { HomeScreen(model: $0, tier: .compact) }
}
#Preview("home · regular (preview beside trim)", traits: .fixedLayout(width: 820, height: 760)) {
    PreviewHost(.happy, script: .input) { HomeScreen(model: $0, tier: .regular) }
}
#Preview("home · wide (inspector)", traits: .fixedLayout(width: 1280, height: 780)) {
    PreviewHost(.happy, script: .input) { HomeScreen(model: $0, tier: .wide) }
}
#endif

/// On iPad and the Mac the orbit continues under the sidebar (the system's background extension);
/// on a phone there is no sidebar, so it is left alone.
private struct ExtendUnderSidebar: ViewModifier {
    let enabled: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if enabled { content.backgroundExtensionEffect() } else { content }
    }
}

#if os(macOS)
private struct PlanetID: Identifiable { let id: String }
#endif
