import CobaltKit
import SwiftUI

// The studio in the screen pane (apple/CONTRACT-PANE.md section 5; "studio" in the app's copy, the Stage code here): a reward
// (`PaneItem.reward(<kind>)`, a tap on a row of the rewards card) and a pool video (`PaneItem.poolVideo(<item id>)`, a tap on a
// file of the pick sheet or on the spotlight bar). Spanned, the canvas is the media and the controls are the details.
//
// Both keep running: while the stage is on air the pane closes to the bar, which has the item, "on air" and a stop button, and
// reopens the page. Closing never takes the stage off air; "stop" is a button inside the page (and the bar's). Each page reports
// `stage.onAir` with `pane.setRunning(_:for:)` in every shape, the bar included.

// MARK: - a reward

/// `PaneItem.reward(id)`: one of the five rewards. The canvas for a hero; cost and cooldown, and the on / off switch, for the controls.
struct StageRewardPage: View {
    let model: AppModel
    let id: String

    @Environment(Pane.self) private var pane: Pane?
    @Environment(\.paneShape) private var shape
    @Environment(\.shell) private var shell
    @State private var controller: StageController

    init(model: AppModel, id: String) {
        self.model = model
        self.id = id
        _controller = State(initialValue: StageController(model: model))
    }

    private var store: StageStore { model.stage }
    private var kind: StageRewardKind? { StageRewardKind(rawValue: id) }

    var body: some View {
        Group {
            if let kind, let stage = store.stage, let reward = store.reward(kind) {
                page(kind, stage: stage, reward: reward)
            } else if store.stage != nil || store.state.isFailed || kind == nil {
                PaneGonePage(message: Copy.Stage.rewardNotThere)
            } else {
                PaneLoadingPage()
            }
        }
        .task { if store.stage == nil { await store.load() } }
        .onChange(of: store.stage?.onAir, initial: true) { _, onAir in
            if let onAir { pane?.setRunning(onAir, for: .reward(id)) }
        }
        .haptic(.success, trigger: controller.doneTick)
        .haptic(.error, trigger: controller.failTick)
    }

    private func page(_ kind: StageRewardKind, stage: StageSettings, reward: StageReward) -> some View {
        PanePage(
            title: Copy.Stage.rewardName(kind),
            subtitle: stage.onAir ? Copy.Stage.onAir : Copy.Stage.rewardLine(cost: reward.cost, cooldownSeconds: reward.cooldownSeconds)
        ) {
            if shape == .bar {
                StageBarThumb(onAir: stage.onAir, symbol: Self.symbol(kind))
            } else {
                StageCanvas(stage: stage)
                    .aspectRatio(16.0 / 9.0, contentMode: .fit)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(Copy.Stage.previewA11y)
            }
        } controls: {
            if shape == .bar {
                StageStopButton(stage: stage, controller: controller)
            } else {
                VStack(alignment: .leading, spacing: 14) {
                    StageRewardForm(controller: controller, reward: reward)
                    PaneActionGrid(StageAirActions.actions(stage: stage, controller: controller, shell: shell))
                }
            }
        } body: {
            VStack(alignment: .leading, spacing: 6) {
                Text(Copy.Stage.rewardInfo(kind))
                    .font(CobaltType.caption)
                    .foregroundStyle(CobaltColor.text)
                if !reward.synced {
                    Label(Copy.Stage.unsynced, systemImage: Symbol.stageUnsynced)
                        .font(CobaltType.badge)
                        .foregroundStyle(CobaltColor.errorText)
                }
                Text(Copy.Stage.rewardsNote)
                    .font(CobaltType.badge)
                    .foregroundStyle(CobaltColor.caption)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 16)
        }
    }

    static func symbol(_ kind: StageRewardKind) -> String {
        switch kind {
        case .summon: return Symbol.stageRewardSummon
        case .chaos: return Symbol.stageRewardChaos
        case .shuffle: return Symbol.stageRewardShuffle
        case .pin: return Symbol.stageRewardPin
        case .skip: return Symbol.stageSkip
        }
    }
}

/// On / off, cost (channel points) and cooldown (seconds) of one reward. Only what changed is sent; a refusal shows under the
/// fields. The switch goes to Twitch at once, as the row's does.
private struct StageRewardForm: View {
    let controller: StageController
    let reward: StageReward

    @Environment(\.shell) private var shell
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var cost = ""
    @State private var cooldown = ""
    @State private var saving = false
    @State private var problem: String?
    @State private var saved = false
    @State private var seeded = false
    @FocusState private var focused: Field?

    private enum Field: Hashable { case cost, cooldown }

    private var store: StageStore { controller.store }
    private var kind: StageRewardKind { reward.action }
    private var costValue: Int? { Int(cost.filter(\.isNumber)) }
    private var cooldownValue: Int? { Int(cooldown.filter(\.isNumber)) }
    private var changed: Bool { costValue != reward.cost || cooldownValue != reward.cooldownSeconds }
    private var canSave: Bool { costValue != nil && cooldownValue != nil && changed && !saving }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle(isOn: Binding(
                get: { reward.enabled },
                set: { controller.setReward(kind, enabled: $0, shell: shell) })
            ) {
                Text(Copy.Stage.rewardOnTwitch)
                    .font(CobaltType.bodySemibold)
                    .foregroundStyle(CobaltColor.text)
            }
            .toggleStyle(.switch)
            .tint(CobaltColor.success)
            .disabled(controller.isBusy("reward-\(kind.rawValue)"))
            .accessibilityLabel(Copy.Stage.rewardToggleA11y(kind, on: reward.enabled))
            numberField(title: Copy.Stage.editCost, unit: Copy.Stage.editPoints, hint: Copy.Stage.costRange(), text: $cost, field: .cost)
            numberField(
                title: Copy.Stage.editCooldown, unit: Copy.Stage.editSeconds, hint: Copy.Stage.cooldownRange(), text: $cooldown,
                field: .cooldown)
            if let problem {
                Text(problem)
                    .font(CobaltType.caption)
                    .foregroundStyle(CobaltColor.errorText)
                    .accessibilityAddTraits(.updatesFrequently)
            }
            HStack(spacing: 10) {
                Button(Copy.Stage.editSave) { save() }
                    .buttonStyle(.cobaltPrimary(fullWidth: false, compact: true))
                    .disabled(!canSave)
                    .keyboardShortcut(.defaultAction)
                if saved && !changed {
                    Label(Copy.Stage.saved, systemImage: Symbol.checkmark)
                        .font(CobaltType.caption)
                        .foregroundStyle(CobaltColor.success)
                }
            }
        }
        .onAppear { seed() }
        .onChange(of: reward.cost) { _, now in if !changed || !focusedOnCost { cost = String(now) } }
        .onChange(of: reward.cooldownSeconds) { _, now in if !changed || !focusedOnCooldown { cooldown = String(now) } }
        .haptic(.error, trigger: problem) { $0 != nil }
    }

    private var focusedOnCost: Bool { focused == .cost }
    private var focusedOnCooldown: Bool { focused == .cooldown }

    private func seed() {
        guard !seeded else { return }
        seeded = true
        cost = String(reward.cost)
        cooldown = String(reward.cooldownSeconds)
    }

    private func numberField(title: String, unit: String, hint: String, text: Binding<String>, field: Field) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(CobaltType.captionSmall)
                .foregroundStyle(CobaltColor.caption)
            HStack(spacing: 8) {
                TextField(title, text: text)
                    .focused($focused, equals: field)
                    .font(CobaltType.body)
                    .foregroundStyle(CobaltColor.text)
                    .monospacedDigit()
                    #if os(iOS)
                    .keyboardType(.numberPad)
                    #endif
                    .accessibilityLabel(title)
                Text(unit)
                    .font(CobaltType.captionSmall)
                    .foregroundStyle(CobaltColor.caption)
            }
            .padding(.horizontal, 12)
            .frame(minHeight: Metrics.hit)
            .background(CobaltColor.elevated, in: RoundedRectangle(cornerRadius: Metrics.radius, style: .continuous))
            Text(hint)
                .font(CobaltType.badge)
                .foregroundStyle(CobaltColor.caption)
        }
    }

    private func save() {
        guard let newCost = costValue, let newCooldown = cooldownValue, !saving else { return }
        let changedCost = newCost == reward.cost ? nil : newCost
        let changedCooldown = newCooldown == reward.cooldownSeconds ? nil : newCooldown
        guard changedCost != nil || changedCooldown != nil else { return }
        saving = true
        problem = nil
        saved = false
        focused = nil
        Task {
            defer { saving = false }
            do {
                try await store.updateReward(kind, cost: changedCost, cooldownSeconds: changedCooldown)
                // the store clamps to the allowed range: show what it kept
                cost = String(store.reward(kind)?.cost ?? newCost)
                cooldown = String(store.reward(kind)?.cooldownSeconds ?? newCooldown)
                saved = true
            } catch {
                problem = Copy.Stage.message(for: error)
            }
        }
    }
}

// MARK: - a pool video

/// `PaneItem.poolVideo(id)`: a file of the pool. The canvas for a hero; "spotlight it", pin, skip and go live / stop as the
/// controls, the file itself in the body.
struct StagePoolVideoPage: View {
    let model: AppModel
    let id: String

    @Environment(Pane.self) private var pane: Pane?
    @Environment(\.paneShape) private var shape
    @Environment(\.shell) private var shell
    @State private var controller: StageController
    @State private var looked = false

    init(model: AppModel, id: String) {
        self.model = model
        self.id = id
        _controller = State(initialValue: StageController(model: model))
    }

    private var store: StageStore { model.stage }

    /// The file: the pool's (once read), else the one the spotlight holds.
    private var item: StageItem? {
        if let found = store.poolItems.first(where: { $0.id == id }) { return found }
        if let held = store.stage?.spotlight?.item, held.id == id { return held }
        return nil
    }

    var body: some View {
        Group {
            if let item, let stage = store.stage {
                page(item, stage: stage)
            } else if looked {
                PaneGonePage()
            } else {
                PaneLoadingPage()
            }
        }
        .task {
            if store.stage == nil { await store.load() }
            if item == nil, store.poolItems.isEmpty, store.poolState != .loading { await store.loadPool() }
            while item == nil, store.poolHasMore {
                let before = store.poolItems.count
                await store.loadMorePool()
                if store.poolItems.count == before { break }
            }
            looked = true
        }
        .onChange(of: store.stage?.onAir, initial: true) { _, onAir in
            if let onAir { pane?.setRunning(onAir, for: .poolVideo(id)) }
        }
        .haptic(.success, trigger: controller.doneTick)
        .haptic(.error, trigger: controller.failTick)
    }

    private func page(_ item: StageItem, stage: StageSettings) -> some View {
        let current = stage.spotlight?.item.id == item.id
        let pinned = current && (stage.spotlight?.isPinned(now: Date()) ?? false)
        let busy = controller.isBusy("action")
        return PanePage(
            title: item.title,
            subtitle: current ? Copy.Stage.inTheSpotlight : Copy.Stage.videoLine(code: item.code, duration: item.duration)
        ) {
            if shape == .bar {
                StageThumb(item: item, size: 40)
            } else {
                StageCanvas(stage: stage)
                    .aspectRatio(16.0 / 9.0, contentMode: .fit)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(Copy.Stage.previewA11y)
            }
        } controls: {
            if shape == .bar {
                StageStopButton(stage: stage, controller: controller)
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    PaneActionGrid([
                        PaneAction(
                            current ? Copy.Stage.inTheSpotlight : Copy.Stage.spotlightIt, systemImage: Symbol.stagePick,
                            disabled: !stage.onAir || current || busy
                        ) { controller.perform(.spotlight(itemID: item.id), shell: shell) },
                        PaneAction(
                            pinned ? Copy.Stage.pinned : Copy.Stage.pin, systemImage: pinned ? Symbol.stagePinned : Symbol.stagePin,
                            disabled: !stage.onAir || !current || busy
                        ) { controller.togglePin(pinned: pinned, shell: shell) },
                        PaneAction(Copy.Stage.skip, systemImage: Symbol.stageSkip, disabled: !stage.onAir || !current || busy) {
                            controller.perform(.skip, shell: shell)
                        },
                        StageAirActions.air(stage: stage, controller: controller, shell: shell),
                    ])
                    if !stage.onAir {
                        Text(Copy.Stage.spotlightOffAir)
                            .font(CobaltType.captionSmall)
                            .foregroundStyle(CobaltColor.caption)
                    }
                }
            }
        } body: {
            HStack(spacing: 12) {
                StageThumb(item: item, size: 88)
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.title)
                        .font(CobaltType.bodySemibold)
                        .foregroundStyle(CobaltColor.text)
                        .lineLimit(3)
                    Text(Copy.Stage.videoLine(code: item.code, duration: item.duration))
                        .font(CobaltType.captionSmall)
                        .foregroundStyle(CobaltColor.caption)
                }
                Spacer(minLength: 0)
            }
            .accessibilityElement(children: .combine)
            .padding(.horizontal, 16)
        }
    }
}

// MARK: - shared

/// "go live" / "stop" and "copy obs link" as pane actions.
private enum StageAirActions {
    @MainActor
    static func air(stage: StageSettings, controller: StageController, shell: ShellActions) -> PaneAction {
        PaneAction(
            stage.onAir ? Copy.Stage.stop : Copy.Stage.goLive,
            systemImage: stage.onAir ? Symbol.stageStop : Symbol.stageGoLive, disabled: controller.isBusy("air")
        ) { controller.toggleAir(shell: shell) }
    }

    @MainActor
    static func actions(stage: StageSettings, controller: StageController, shell: ShellActions) -> [PaneAction] {
        [
            air(stage: stage, controller: controller, shell: shell),
            PaneAction(
                controller.copied == .obs ? Copy.Stage.copied : Copy.Stage.copyObsLink,
                systemImage: controller.copied == .obs ? Symbol.checkmark : Symbol.stageCopy
            ) { controller.copyObsLink(shell: shell) },
        ]
    }
}

/// The bar's one control: stop (the stage goes off air and the bar goes away).
private struct StageStopButton: View {
    let stage: StageSettings
    let controller: StageController

    @Environment(\.shell) private var shell

    var body: some View {
        Button { controller.toggleAir(shell: shell) } label: {
            Image(systemName: stage.onAir ? Symbol.stageStop : Symbol.stageGoLive)
                .font(.system(size: 15, weight: .semibold))
        }
        .buttonStyle(.glass)
        .buttonBorderShape(.circle)
        .disabled(controller.isBusy("air"))
        .help(stage.onAir ? Copy.Stage.stop : Copy.Stage.goLive)
        .accessibilityLabel(stage.onAir ? Copy.Stage.stop : Copy.Stage.goLive)
    }
}

/// The bar's thumb of a reward: its symbol on the canvas grey, with a red dot while on air.
private struct StageBarThumb: View {
    let onAir: Bool
    let symbol: String

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Rectangle().fill(CobaltColor.frameBase)
            Image(systemName: symbol)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(CobaltColor.badgeInk)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            if onAir {
                Circle().fill(CobaltColor.error).frame(width: 8, height: 8).padding(4)
            }
        }
    }
}

private extension StageStore.State {
    var isFailed: Bool { if case .failed = self { true } else { false } }
}
