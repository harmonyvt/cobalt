import CobaltKit
import SwiftUI

// The redemptions feed (APP-API-CONTRACT 30.9, 30.11): what viewers spent their channel points on, newest first, and the
// owner's own actions ("you"). Read every 4 s while the screen is visible (`StageStore.startPolling`); a refunded or failed
// one says why.

struct StageFeedCard: View {
    let store: StageStore

    var body: some View {
        StageCard(title: Copy.Stage.feed) {
            if store.feedProblem {
                Text(Copy.Stage.feedProblem)
                    .font(CobaltType.captionSmall)
                    .foregroundStyle(CobaltColor.errorText)
            }
            if store.redemptions.isEmpty {
                Text(Copy.Stage.feedEmpty)
                    .font(CobaltType.caption)
                    .foregroundStyle(CobaltColor.caption)
            } else {
                // "3 min" moves on without a new read
                TimelineView(.periodic(from: .now, by: 20)) { context in
                    VStack(spacing: 0) {
                        ForEach(store.redemptions) { redemption in
                            if redemption.id != store.redemptions.first?.id { Divider().overlay(CobaltColor.hairline) }
                            StageFeedRow(redemption: redemption, now: context.date)
                        }
                    }
                }
            }
        }
        .motion(Motion.rows, value: store.redemptions.map(\.id))
    }
}

private struct StageFeedRow: View {
    let redemption: StageRedemption
    let now: Date

    private var failed: Bool { redemption.status != .done }

    var body: some View {
        let when = Copy.Stage.ago(redemption.createdAt, now: now)
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(Copy.Stage.by(redemption.userName, owner: redemption.isOwner))
                        .font(CobaltType.bodySemibold)
                        .foregroundStyle(CobaltColor.text)
                        .lineLimit(1)
                    Text(redemption.action)
                        .font(CobaltType.pill)
                        .foregroundStyle(CobaltColor.captionOnElevated)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(CobaltColor.elevated, in: Capsule())
                    if failed {
                        Image(systemName: Symbol.stageRefunded)
                            .font(.system(size: 11))
                            .foregroundStyle(CobaltColor.errorText)
                            .accessibilityHidden(true)
                    }
                }
                Text(Copy.Stage.detail(redemption))
                    .font(CobaltType.captionSmall)
                    .foregroundStyle(failed ? CobaltColor.errorText : CobaltColor.caption)
                    .lineLimit(2)
            }
            Spacer(minLength: 6)
            Text(when)
                .font(CobaltType.captionSmall)
                .foregroundStyle(CobaltColor.caption)
                .lineLimit(1)
        }
        .padding(.vertical, 8)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Copy.Stage.rowA11y(redemption, when: when))
    }
}
