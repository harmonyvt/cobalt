import CobaltKit
import SwiftUI

// The four rewards (APP-API-CONTRACT 29.2, 29.11): summon, chaos, shuffle and pin as real Twitch channel point rewards. A row
// says what it costs and its cooldown, and has an on / off switch; a tap on the row opens the editor for cost and cooldown.
// A change goes to Twitch too, so a cost changed here is changed on Twitch.

struct StageRewardsCard: View {
    let store: StageStore
    let controller: StageController

    var body: some View {
        StageCard(title: Copy.Stage.rewards) {
            if store.rewards.isEmpty {
                Text(Copy.Stage.rewardsEmpty)
                    .font(CobaltType.caption)
                    .foregroundStyle(CobaltColor.caption)
            } else {
                VStack(spacing: 0) {
                    ForEach(store.rewards) { reward in
                        if reward.action != store.rewards.first?.action { Divider().overlay(CobaltColor.hairline) }
                        StageRewardRow(reward: reward, controller: controller)
                    }
                }
                Text(Copy.Stage.rewardsNote)
                    .font(CobaltType.badge)
                    .foregroundStyle(CobaltColor.caption)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct StageRewardRow: View {
    let reward: StageReward
    let controller: StageController

    @Environment(\.shell) private var shell

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Button {
                controller.editingReward = reward.action
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(Copy.Stage.rewardName(reward.action))
                        .font(CobaltType.bodySemibold)
                        .foregroundStyle(CobaltColor.text)
                    Text(Copy.Stage.rewardLine(cost: reward.cost, cooldownSeconds: reward.cooldownSeconds))
                        .font(CobaltType.caption)
                        .foregroundStyle(CobaltColor.caption)
                    Text(Copy.Stage.rewardInfo(reward.action))
                        .font(CobaltType.captionSmall)
                        .foregroundStyle(CobaltColor.caption)
                        .multilineTextAlignment(.leading)
                    if !reward.synced {
                        Label(Copy.Stage.unsynced, systemImage: Symbol.stageUnsynced)
                            .font(CobaltType.badge)
                            .foregroundStyle(CobaltColor.errorText)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint(Copy.Stage.editHint)
            Toggle(isOn: Binding(
                get: { reward.enabled },
                set: { controller.setReward(reward.action, enabled: $0, shell: shell) })
            ) {
                Text(Copy.Stage.rewardToggleA11y(reward.action, on: reward.enabled))
            }
            .labelsHidden()
            .toggleStyle(.switch)
            .tint(CobaltColor.success)
            .disabled(controller.isBusy("reward-\(reward.action.rawValue)"))
        }
        .padding(.vertical, 10)
        .frame(minHeight: Metrics.hit)
    }
}

// MARK: - the editor

/// Cost (channel points) and cooldown (seconds) of one reward. Only what changed is sent; a refusal shows inside the sheet,
/// which stays open.
struct StageRewardSheet: View {
    let controller: StageController
    let kind: StageRewardKind

    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var cost = ""
    @State private var cooldown = ""
    @State private var saving = false
    @State private var problem: String?
    @State private var seeded = false
    @FocusState private var focused: Field?

    private enum Field: Hashable { case cost, cooldown }

    private var store: StageStore { controller.store }
    private var reward: StageReward? { store.reward(kind) }

    private var costValue: Int? { Int(cost.filter(\.isNumber)) }
    private var cooldownValue: Int? { Int(cooldown.filter(\.isNumber)) }
    private var canSave: Bool { costValue != nil && cooldownValue != nil && !saving }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(Copy.Stage.editTitle(kind))
                .font(Font.cobalt(16, .semibold, relativeTo: .headline))
                .foregroundStyle(CobaltColor.text)
                .accessibilityAddTraits(.isHeader)
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
            buttons
        }
        .padding(.horizontal, 16)
        .padding(.top, 20)
        .padding(.bottom, 12)
        #if os(macOS)
        .frame(width: 420)
        #else
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .presentationDetents(typeSize.isAccessibilitySize ? [.large] : [.height(380), .large])
        .presentationDragIndicator(.visible)
        #endif
        .background(CobaltColor.bg)
        .interactiveDismissDisabled(saving)
        .onAppear { seed() }
        .haptic(.error, trigger: problem) { $0 != nil }
    }

    private func seed() {
        guard !seeded, let reward else { return }
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

    private var buttons: some View {
        ButtonRow {
            Button(Copy.Stage.editSave) { save() }
                .buttonStyle(.cobaltPrimary(compact: true))
                .disabled(!canSave)
                .keyboardShortcut(.defaultAction)
            Button(Copy.Stage.editCancel) { dismiss() }
                .buttonStyle(.cobaltSecondary(compact: true))
                .keyboardShortcut(.cancelAction)
        }
    }

    private func save() {
        guard let newCost = costValue, let newCooldown = cooldownValue, !saving else { return }
        let changedCost = newCost == reward?.cost ? nil : newCost
        let changedCooldown = newCooldown == reward?.cooldownSeconds ? nil : newCooldown
        guard changedCost != nil || changedCooldown != nil else {
            dismiss()
            return
        }
        saving = true
        problem = nil
        Task {
            defer { saving = false }
            do {
                try await store.updateReward(kind, cost: changedCost, cooldownSeconds: changedCooldown)
                dismiss()
            } catch {
                problem = Copy.Stage.message(for: error)
            }
        }
    }
}
