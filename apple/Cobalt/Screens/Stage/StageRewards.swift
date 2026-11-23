import CobaltKit
import SwiftUI

// The five rewards (APP-API-CONTRACT 30.2, 30.11): summon, chaos, shuffle, pin and skip as real Twitch channel point rewards. A row
// says what it costs and its cooldown, and has an on / off switch; a tap on the row opens the reward in the screen pane
// (`StageRewardPage`: the canvas, and cost and cooldown). A change goes to Twitch too, so a cost changed here is changed on Twitch.

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
    @Environment(Pane.self) private var pane: Pane?

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Button {
                pane?.open(.reward(reward.action.rawValue))
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
