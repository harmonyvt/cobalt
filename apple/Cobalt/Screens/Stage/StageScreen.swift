import CobaltKit
import SwiftUI

// The studio tab (APP-API-CONTRACT section 30.11): a remote for the stream canvas OBS loads. Header (on air / off air, copy
// obs link, go live / stop), the preview, the spotlight bar, the pool, the sliders, then Twitch, the four rewards, the
// redemptions feed and the links with the store lock. Wide windows (the Mac, an iPad on its side) are two columns like the Mac
// board: the controls left, a 360 pt column right. Compact is one column like the iPhone board, with a rewards · feed · links
// segmented control. The state is `model.stage`; every tap goes through a `StageController`.

struct StageScreen: View {
    let model: AppModel
    let tier: Tier

    @Environment(\.scenePhase) private var scenePhase
    @State private var controller: StageController

    init(model: AppModel, tier: Tier) {
        self.model = model
        self.tier = tier
        _controller = State(initialValue: StageController(model: model))
    }

    private var store: StageStore { model.stage }

    private enum Phase {
        case loading
        case failed(StageError)
        case ready(StageSettings)
    }

    private var phase: Phase {
        if let stage = store.stage { return .ready(stage) }
        if case .failed(let error) = store.state { return .failed(error) }
        return .loading
    }

    var body: some View {
        content
            .background(CobaltColor.bg)
            .navigationTitle(Copy.Stage.title)
            .toolbar {
                #if os(iOS)
                QueueToolbarItem(model: model)
                #endif
                #if os(macOS)
                ToolbarItem(placement: .primaryAction) {
                    Button(Copy.Stage.refresh, systemImage: Symbol.retry) { Task { await store.load() } }
                        .disabled(store.state == .loading)
                        .keyboardShortcut("r", modifiers: .command)
                        .help(Copy.Stage.refresh)
                }
                #endif
            }
            .task { await store.load() }
            .task { await loadCollections() }
            .onAppear { syncPolling() }
            .onDisappear { store.stopPolling() }
            .onChange(of: scenePhase) { _, _ in syncPolling() }
            .onChange(of: model.selectedTab) { _, _ in syncPolling() }
            .stagePresentations(controller)
    }

    /// The collections and sets the pool picker lists.
    private func loadCollections() async {
        if model.capabilities.shareCollections || model.capabilities.shareGroups { await model.shareSets.refresh() }
    }

    /// The feed is read only while this screen is in front of an active app.
    private func syncPolling() {
        if scenePhase == .active && model.selectedTab == .stage {
            store.startPolling()
        } else {
            store.stopPolling()
        }
    }

    @ViewBuilder
    private var content: some View {
        switch phase {
        case .loading:
            VStack(spacing: 10) {
                ProgressView()
                Text(Copy.Stage.loading).font(CobaltType.caption).foregroundStyle(CobaltColor.caption)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityElement(children: .combine)
        case .failed(let error):
            ContentUnavailableView {
                Label(Copy.Stage.failedTitle, systemImage: Symbol.error).font(CobaltType.body)
            } description: {
                Text(Copy.Stage.failedBody(error)).font(CobaltType.caption)
            } actions: {
                Button(Copy.Stage.retry, systemImage: Symbol.retry) { Task { await store.load() } }
                    .buttonStyle(.cobaltSecondary(fullWidth: false))
            }
        case .ready(let stage):
            StageBody(model: model, controller: controller, stage: stage, tier: tier)
        }
    }
}

// MARK: - the loaded studio

/// Both layouts of the loaded studio. Measures its own width: the column only goes two-up where the 360 pt column leaves
/// the controls room (a window or an iPad on its side, not a split view).
private struct StageBody: View {
    let model: AppModel
    let controller: StageController
    let stage: StageSettings
    let tier: Tier

    @State private var width: CGFloat = 0

    private var store: StageStore { controller.store }

    private var wide: Bool {
        if width > 0 { return width >= 780 }
        return tier != .compact
    }

    var body: some View {
        Group {
            if wide { twoColumns } else { oneColumn }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .motion(Motion.card, value: stage.onAir)
    }

    // MARK: wide

    private var twoColumns: some View {
        VStack(spacing: 0) {
            StageHeader(stage: stage, controller: controller, showsCopy: true)
                .padding(.horizontal, Metrics.gutter)
                .padding(.vertical, 10)
            HStack(alignment: .top, spacing: 16) {
                ScrollView {
                    VStack(spacing: 14) {
                        stale
                        controls
                    }
                    .padding(.bottom, 20)
                }
                ScrollView {
                    VStack(spacing: 14) {
                        StageTwitchCard(model: model, stage: stage, controller: controller)
                        StageRewardsCard(store: store, controller: controller)
                        StageFeedCard(store: store)
                        StageLinksCard(stage: stage, controller: controller)
                    }
                    .padding(.bottom, 20)
                }
                .frame(width: 360)
            }
            .padding(.horizontal, Metrics.gutter)
        }
    }

    // MARK: compact

    private var oneColumn: some View {
        ScrollView {
            VStack(spacing: 14) {
                StageHeader(stage: stage, controller: controller, showsCopy: false)
                stale
                controls
                panels
            }
            .padding(.horizontal, Metrics.gutter)
            .padding(.top, 8)
            .padding(.bottom, 24)
            .frame(maxWidth: Metrics.columnMax)
            .frame(maxWidth: .infinity)
        }
        .refreshable { await store.load() }
    }

    @ViewBuilder
    private var panels: some View {
        Picker(Copy.Stage.title, selection: Binding(get: { controller.panel }, set: { controller.panel = $0 })) {
            ForEach(StagePanel.allCases) { panel in
                Text(panel.title).tag(panel)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        #if os(iOS)
        .controlSize(.large)
        #endif
        .accessibilityLabel(Copy.Stage.title)
        switch controller.panel {
        case .rewards:
            StageTwitchCard(model: model, stage: stage, controller: controller)
            StageRewardsCard(store: store, controller: controller)
        case .feed:
            StageFeedCard(store: store)
        case .links:
            StageLinksCard(stage: stage, controller: controller)
        }
    }

    // MARK: shared

    /// The controls under the header: preview, spotlight, pool, sliders.
    @ViewBuilder
    private var controls: some View {
        StagePreviewCard(stage: stage)
        StageSpotlightBar(stage: stage, controller: controller)
        StagePoolPicker(model: model, stage: stage, controller: controller, compact: !wide)
        StageSliders(store: store, controller: controller)
    }

    @ViewBuilder
    private var stale: some View {
        if case .failed = store.state {
            Text(Copy.Stage.staleLine)
                .font(CobaltType.captionSmall)
                .foregroundStyle(CobaltColor.errorText)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - the header

/// "on air" / "off air", "copy obs link" (wide only: compact has it in the links panel) and "go live" / "stop".
private struct StageHeader: View {
    let stage: StageSettings
    let controller: StageController
    let showsCopy: Bool

    @Environment(\.shell) private var shell

    var body: some View {
        HStack(spacing: 10) {
            AirPill(onAir: stage.onAir)
            Spacer(minLength: 8)
            if showsCopy { copyButton }
            airButton
        }
    }

    @ViewBuilder
    private var copyButton: some View {
        if controller.copied == .obs {
            Button(Copy.Stage.copied, systemImage: Symbol.checkmark) {}
                .buttonStyle(.cobaltDone(fullWidth: false, compact: true))
        } else {
            Button(Copy.Stage.copyObsLink, systemImage: Symbol.stageCopy) { controller.copyObsLink(shell: shell) }
                .buttonStyle(.cobaltSecondary(fullWidth: false, compact: true))
        }
    }

    @ViewBuilder
    private var airButton: some View {
        if stage.onAir {
            Button(Copy.Stage.stop, systemImage: Symbol.stageStop) { controller.toggleAir(shell: shell) }
                .buttonStyle(.cobaltSecondary(fullWidth: false, compact: true))
                .disabled(controller.isBusy("air"))
        } else {
            Button(Copy.Stage.goLive, systemImage: Symbol.stageGoLive) { controller.toggleAir(shell: shell) }
                .buttonStyle(.cobaltPrimary(fullWidth: false, compact: true))
                .disabled(controller.isBusy("air"))
        }
    }
}

/// A dot and two words: red and "on air", grey and "off air".
private struct AirPill: View {
    let onAir: Bool

    var body: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(onAir ? CobaltColor.error : CobaltColor.caption)
                .frame(width: 8, height: 8)
            Text(onAir ? Copy.Stage.onAir : Copy.Stage.offAir)
                .font(CobaltType.pill)
                .foregroundStyle(CobaltColor.text)
        }
        .padding(.horizontal, 12)
        .frame(minHeight: 30)
        .background(CobaltColor.elevated, in: Capsule())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Copy.Stage.airA11y(onAir: onAir))
    }
}

// MARK: - a card

/// The surface every section of the studio sits on: an optional title, then the content.
struct StageCard<Content: View>: View {
    var title: String?
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let title {
                Text(title)
                    .font(CobaltType.bodySemibold)
                    .foregroundStyle(CobaltColor.text)
                    .accessibilityAddTraits(.isHeader)
            }
            content()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(CobaltColor.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

/// A small picture of a pool file (the store thumbnail, else the poster, else the picture itself) on the video-frame grey,
/// with a play mark on a video.
struct StageThumb: View {
    let item: StageItem?
    var size: CGFloat = 52

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Rectangle().fill(FrameGradient.fill(0))
            if let url = item?.thumbnail {
                AsyncImage(url: url) { phase in
                    if let image = phase.image { image.resizable().scaledToFill() }
                }
            }
            if item?.kind == .video {
                Image(systemName: Symbol.stagePlay)
                    .font(.system(size: max(8, size * 0.2)))
                    .foregroundStyle(CobaltColor.badgeInk)
                    .padding(4)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: Metrics.radius, style: .continuous))
        .accessibilityHidden(true)
    }
}
