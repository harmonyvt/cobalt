import CobaltKit
import SwiftUI

/// The save tab (05 · strata): offline saves arranged chronologically as a geological core sample
/// with a cumulative megabyte ruler down the leading edge, full-width Liquid Glass surface layers
/// for active downloads, queued work, faults and pulled core samples, and Paste + File controls
/// directly in the navigation bar.
struct HomeScreen: View {
    let model: AppModel
    let tier: Tier

    @State private var selectedMediaID: String?
    @State private var freshID: String?
    @State private var knownIDs: Set<String> = []
    @State private var knownReady = false
    @State private var openedID: String?
    #if os(macOS)
    @State private var openedSheet: MediaSheetID?
    #endif
    @State private var inspectorOpen = true
    @State private var contentWidth: CGFloat = 0
    @State private var focusActive = false
    @State private var focusPlayer = FocusPlayerHolder()

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.shell) private var shell
    @Environment(Pane.self) private var pane: Pane?
    @Environment(\.photoImport) private var photoImport
    @Environment(\.hapticsEnabled) private var haptics

    private var pipeline: Pipeline { model.pipeline }

    // MARK: stage

    private enum Stage: Equatable {
        case idle, capsule, failure, focus, picker, image
    }

    private var stage: Stage {
        switch pipeline.state {
        case .idle:
            if photoImport?.isLoading == true { return .capsule }
            return photoImport?.failure != nil ? .failure : .idle
        case .fetching, .uploading, .saving, .reading: return .capsule
        case .ready, .rendering, .done, .savedLocally: return .focus
        case .gallery: return .focus
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

    private func isBlocking(_ f: PipelineFailure) -> Bool { f == .keyMissing || f == .keyInvalid }

    private var failure: PipelineFailure? {
        if case .failed(let f) = pipeline.state { return f }
        return nil
    }

    private var homeVisible: Bool {
        guard model.selectedTab == .save else { return false }
        #if os(iOS)
        return openedID == nil && !model.queueShown
        #else
        return openedSheet == nil
        #endif
    }

    private var paneBeside: Bool { pane.map { $0.placement != .compact } ?? false }

    private var canInspect: Bool {
        if case .gallery = pipeline.state { return false }
        return paneBeside && stage == .focus && focusActive
    }

    private var savePaneID: String? {
        canInspect && inspectorOpen ? model.queue.focusedID?.uuidString : nil
    }

    // MARK: strata data

    private var strataMedia: [StoredMedia] {
        let real = model.visibleStoredMedia
        if let stretched = DebugPreviewFlags.stretchedOrbit(real, cap: 35) { return stretched }
        return real
    }

    private var strataColumn: StrataColumn {
        StrataLayout.build(from: strataMedia)
    }

    /// The media shown in the surface core-sample card: whichever thumbnail was tapped,
    /// or (on unfolded/regular split layouts) the newest offline save by default.
    private func resolvedSample(in column: StrataColumn) -> (media: StoredMedia, layerTitle: String?, isDefault: Bool)? {
        if let selectedMediaID {
            for layer in column.layers {
                if let match = layer.media.first(where: { $0.id == selectedMediaID }) {
                    return (match, Copy.Strata.bucketTitle(layer.bucket), false)
                }
            }
        }
        guard tier != .compact, let firstLayer = column.layers.first, let newest = firstLayer.media.first else {
            return nil
        }
        return (newest, Copy.Strata.bucketTitle(firstLayer.bucket), true)
    }

    private var subtitle: String {
        let usage = model.store.usage
        if DebugPreviewFlags.orbitCount > 0 {
            return Copy.offline(count: strataMedia.count, bytes: usage.bytes)
        }
        return usage.mediaCount == 0 && model.store.media.isEmpty
            ? Copy.emptyOrbit
            : Copy.offline(count: usage.mediaCount, bytes: usage.bytes)
    }

    // MARK: body

    var body: some View {
        let column = strataColumn
        let sample = resolvedSample(in: column)

        return GeometryReader { proxy in
            ZStack {
                if tier == .compact {
                    compactLayout(column: column, sample: sample)
                } else {
                    splitLayout(column: column, sample: sample)
                }

                if focusActive {
                    CobaltColor.bg.opacity(0.96)
                        .ignoresSafeArea()
                        .transition(.opacity)
                    FocusLayer(
                        model: model, pipeline: pipeline, contentWidth: contentWidth,
                        phase: .lifted, lifted: true, player: focusPlayer,
                        visible: homeVisible, topReserve: 0,
                        onOpen: { id in if let media = model.store.media(id: baseID(id)) { openDetail(media) } },
                        onClose: closeFocus)
                        .id(pipeline.runID)
                        .environment(\.homeHeight, proxy.size.height)
                        .transition(.opacity)
                }
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { contentWidth = $0 }
        }
        .modifier(HomeSavePane(pane: pane, wanted: savePaneID, inspectorOpen: $inspectorOpen))
        .navigationTitle(Copy.appName)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #else
        .navigationSubtitle(subtitle)
        #endif
        .toolbar {
            #if os(iOS)
            ToolbarItemGroup(placement: .topBarLeading) {
                HomeCaptureToolbarButtons(showsFile: model.capabilities.showsFileButton)
            }
            .duoVisibilityPriority(.high)

            ToolbarItem(placement: .principal) {
                Text(Copy.appName)
                    .font(Font.cobalt(17, .semibold, relativeTo: .headline))
                    .lineLimit(1)
                    .accessibilityAddTraits(.isHeader)
            }

            QueueToolbarItem(model: model)
            #else
            ToolbarItemGroup(placement: .primaryAction) {
                HomeCaptureToolbarButtons(showsFile: model.capabilities.showsFileButton)
            }
            #endif

            if canInspect {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        inspectorOpen.toggle()
                        if inspectorOpen, let id = model.queue.focusedID?.uuidString { pane?.open(.save(id)) }
                    } label: {
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
        .onChange(of: stage, initial: true) { old, new in stageChanged(from: old, to: new) }
        .onChange(of: model.requestedMediaID, initial: true) { _, id in
            guard let id else { return }
            model.requestedMediaID = nil
            if let media = model.store.media(id: id) { openDetail(media) }
        }
        .onAppear {
            model.queue.trayIsShown = true
        }
        .onChange(of: model.requestedJobs, initial: true) { _, asked in
            guard asked else { return }
            model.requestedJobs = false
            #if os(iOS)
            model.queueShown = true
            #endif
        }
        .onChange(of: pipeline.runID) { _, _ in
            if stage == .focus {
                focusPlayer.stop()
                focusActive = true
            }
        }
        .onChange(of: model.store.media.map(\.id), initial: true) { _, ids in noteArrivals(ids) }
        .haptic(.error, trigger: failure, enabled: haptics) { $0 != nil }
        .task { await model.store.backfillPreviewFrames() }
        .debugHomeAutomation(automation)
        #if os(iOS)
        .navigationDestination(item: $openedID) { id in
            if let media = model.store.media(id: baseID(id)) {
                MediaDetail(model: model, item: model.mediaItem(for: media))
            }
        }
        .mediaDetailDestination(model: model)
        #else
        .sheet(item: $openedSheet) { item in
            if let media = model.store.media(id: baseID(item.id)) {
                NavigationStack {
                    MediaDetail(model: model, item: model.mediaItem(for: media))
                        .sheetClose { openedSheet = nil }
                }
                .modifier(MacSheetSize())
            }
        }
        #endif
        .cobaltPage()
    }

    // MARK: layouts

    /// iPhone & iPhone Duo Outer: single scrollable column with quiet storage summary,
    /// full-width surface layer (active saves / queue / faults / pulled sample), and chronological strata.
    private func compactLayout(
        column: StrataColumn,
        sample: (media: StoredMedia, layerTitle: String?, isDefault: Bool)?
    ) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                storageHeader
                surface(sample: sample)
                strataCore(column: column)
            }
            .padding(.horizontal, Metrics.gutter)
            .padding(.top, 8)
            .padding(.bottom, 24)
            .frame(maxWidth: Metrics.columnMax)
            .frame(maxWidth: .infinity)
        }
        .scrollBounceBehavior(.basedOnSize)
        .scrollIndicators(.hidden)
    }

    /// iPhone Duo Unfolded, iPad, and macOS: `DuoSplit` puts the geological strata core on the
    /// primary (leading) display half and the live surface (active saves / queue / faults / sample)
    /// on the secondary (trailing) display half. Never nested inside a ScrollView.
    private func splitLayout(
        column: StrataColumn,
        sample: (media: StoredMedia, layerTitle: String?, isDefault: Bool)?
    ) -> some View {
        DuoSplit(ratio: 0.54, axes: [.horizontal, .vertical], spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    #if os(iOS)
                    storageHeader
                    #endif
                    strataCore(column: column)
                }
                .padding(.horizontal, 20)
                .padding(.top, 12)
                .padding(.bottom, 24)
            }
            .scrollBounceBehavior(.basedOnSize)
            .scrollIndicators(.hidden)
        } secondary: {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    surface(sample: sample)
                    if sample == nil && stage == .idle && model.queue.alongside.isEmpty {
                        Text(Copy.Strata.emptyHint)
                            .font(Font.cobalt(12, .regular, relativeTo: .caption))
                            .foregroundStyle(CobaltColor.caption)
                            .padding(14)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .overlay(
                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    .strokeBorder(CobaltColor.border.opacity(0.5), style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
                            )
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 12)
                .padding(.bottom, 24)
            }
            .scrollBounceBehavior(.basedOnSize)
            .scrollIndicators(.hidden)
        }
    }

    private var storageHeader: some View {
        Text(subtitle)
            .font(Font.cobalt(12, .regular, relativeTo: .caption))
            .foregroundStyle(CobaltColor.caption)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
    }

    private func surface(sample: (media: StoredMedia, layerTitle: String?, isDefault: Bool)?) -> some View {
        StrataSurfaceView(
            model: model,
            pipeline: pipeline,
            photoImport: photoImport,
            showsProgress: stage == .capsule,
            showsFailure: stage == .failure,
            showsImage: stage == .image,
            sampleMedia: sample?.media,
            sampleLayerTitle: sample?.layerTitle,
            isDefaultNewest: sample?.isDefault ?? false,
            onCloseSample: sample?.isDefault == false ? {
                withAnimation(reduceMotion ? Motion.fade : Motion.card) {
                    selectedMediaID = nil
                }
            } : nil,
            onOpenDetail: { openDetail($0) })
            .animation(reduceMotion ? Motion.fade : Motion.card, value: stage)
            .animation(reduceMotion ? Motion.fade : Motion.card, value: selectedMediaID)
    }

    private func strataCore(column: StrataColumn) -> some View {
        StrataColumnView(
            model: model,
            column: column,
            selectedID: selectedMediaID,
            freshID: freshID,
            onSelect: { media in
                withAnimation(reduceMotion ? Motion.fade : Motion.card) {
                    if selectedMediaID == media.id, tier == .compact {
                        selectedMediaID = nil
                    } else {
                        selectedMediaID = media.id
                    }
                }
            },
            onOpenDetail: { openDetail($0) },
            onSeeAll: { model.selectedTab = .library })
    }

    // MARK: focus & lifecycle

    private func stageChanged(from old: Stage, to new: Stage) {
        if new != .idle, old == .idle {
            #if os(iOS)
            openedID = nil
            #else
            openedSheet = nil
            #endif
        }
        if new == .focus {
            withAnimation(reduceMotion ? Motion.fade : FocusMotion.content) {
                focusActive = true
            }
        } else if focusActive {
            focusPlayer.stop()
            withAnimation(reduceMotion ? Motion.fade : FocusMotion.content) {
                focusActive = false
            }
        }
    }

    private func closeFocus() {
        guard focusActive else { return }
        var mine = pipeline.mediaID.flatMap { model.store.media(id: $0) }
        if mine == nil, case .savedLocally(let v) = pipeline.state {
            mine = model.store.media(containing: v.id)
        }
        focusPlayer.stop()
        leaveFocus()
        withAnimation(reduceMotion ? Motion.fade : FocusMotion.content) {
            focusActive = false
        }
        if let mine {
            markFresh(mine.id)
        }
    }

    private func leaveFocus() {
        let queue = model.queue
        guard let job = queue.focused else {
            pipeline.detach()
            return
        }
        if job.isLive {
            model.activity.minimize(job.id)
        } else {
            queue.dismiss(job.id)
        }
    }

    private func markFresh(_ id: String) {
        freshID = id
        Task {
            try? await Task.sleep(for: .seconds(4))
            if freshID == id { freshID = nil }
        }
    }

    private func noteArrivals(_ ids: [String]) {
        let set = Set(ids)
        defer { knownIDs = set; knownReady = true }
        guard knownReady, stage == .idle, !focusActive else { return }
        if let arrival = ids.first(where: { !knownIDs.contains($0) }) {
            markFresh(arrival)
        }
    }

    // MARK: picker & key alert

    private var keyAlertBinding: Binding<Bool> {
        Binding(
            get: { !model.capabilities.accounts && (failure.map(isBlocking) ?? false) },
            set: { if !$0, let f = failure, isBlocking(f) { pipeline.reset() } })
    }

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

    // MARK: navigation & debug hooks

    private func baseID(_ id: String) -> String { String(id.split(separator: "#").first ?? Substring(id)) }

    private func baseMedia(_ media: StoredMedia) -> StoredMedia {
        model.store.media(id: baseID(media.id)) ?? media
    }

    private func openDetail(_ media: StoredMedia) {
        let realID = baseID(media.id)
        if let pane, pane.placement != .compact {
            pane.open(.post(realID))
            return
        }
        #if os(macOS)
        openedSheet = MediaSheetID(id: realID)
        #else
        openedID = realID
        #endif
    }

    private var automation: HomeAutomationHooks {
        HomeAutomationHooks(
            model: model,
            orbitSize: .zero,
            orbitFrame: { .zero },
            orbitMedia: { strataMedia },
            scene: { OrbitScene(size: .zero, center: .zero, topInset: 60, dynamics: OrbitDynamics()) },
            freezeOrbit: {},
            openMedia: { openDetail($0) },
            closeDetail: {
                #if os(iOS)
                openedID = nil
                #endif
            },
            baseMedia: { baseMedia($0) })
    }
}

#if DEBUG
#Preview("home · strata · happy") {
    PreviewHost(.happy) { HomeScreen(model: $0, tier: .compact) }
}
#Preview("home · strata · pipeline") {
    PreviewHost(.happy, script: .input) { HomeScreen(model: $0, tier: .compact) }
}
#Preview("home · strata · private post") {
    PreviewHost(.privatePost, script: .input) { HomeScreen(model: $0, tier: .compact) }
}
#Preview("home · strata · empty") {
    PreviewHost(.emptyOrbit) { HomeScreen(model: $0, tier: .compact) }
}
#Preview("home · strata · unfolded", traits: .fixedLayout(width: 820, height: 760)) {
    PreviewHost(.happy) { HomeScreen(model: $0, tier: .regular) }
}
#Preview("home · strata · wide", traits: .fixedLayout(width: 1280, height: 780)) {
    PreviewHost(.happy, script: .input) { HomeScreen(model: $0, tier: .wide) }
}
#endif

/// Shows the focused run's save page in the pane while its focus layer is open, and
/// forgets the owner's choice to have it when they close the pane.
private struct HomeSavePane: ViewModifier {
    let pane: Pane?
    let wanted: String?
    @Binding var inspectorOpen: Bool

    func body(content: Content) -> some View {
        content
            .onChange(of: wanted) { old, new in
                guard let pane else { return }
                if let new {
                    pane.openIfIdle(.save(new))
                } else if let old, !pane.isRunning {
                    pane.close(ifShowing: .save(old))
                }
            }
            .onChange(of: pane?.route) { _, route in
                guard let route, case .save? = route.item, !route.isVisible, inspectorOpen, wanted != nil else { return }
                inspectorOpen = false
            }
    }
}

#if os(macOS)
private struct MediaSheetID: Identifiable { let id: String }
#endif
