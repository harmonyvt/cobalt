import CobaltKit
import SwiftUI

// The links (APP-API-CONTRACT 29.4, 29.11): the OBS browser source link, masked to its last 4 characters (copy puts the whole
// link on the pasteboard; rotate makes a new one and the old one stops working at once, after a confirm), and the store for
// viewers with its lock. The store is locked unless the owner opens it: a locked store and its sign-in are gone for everyone.

struct StageLinksCard: View {
    let stage: StageSettings
    let controller: StageController

    @Environment(\.shell) private var shell

    var body: some View {
        StageCard(title: Copy.Stage.links) {
            obs
            Divider().overlay(CobaltColor.hairline)
            store
        }
    }

    // MARK: obs

    private var obs: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(Copy.Stage.obsLink)
                .font(CobaltType.captionSmall)
                .foregroundStyle(CobaltColor.caption)
            Text(stage.maskedLiveLink)
                .font(CobaltType.body)
                .foregroundStyle(CobaltColor.text)
                .lineLimit(1)
                .truncationMode(.middle)
                .accessibilityLabel(Copy.Stage.obsLink)
            ButtonRow {
                copyButton(.obs, title: Copy.Stage.copy) { controller.copyObsLink(shell: shell) }
                Button(Copy.Stage.rotate, systemImage: Symbol.stageRotate) { controller.confirmingRotate = true }
                    .buttonStyle(.cobaltSecondary(compact: true))
                    .disabled(controller.isBusy("rotate"))
            }
        }
    }

    // MARK: the store

    private var store: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(Copy.Stage.storeForViewers)
                    .font(CobaltType.captionSmall)
                    .foregroundStyle(CobaltColor.caption)
                Spacer(minLength: 8)
                Label(
                    stage.storeOpen ? Copy.Stage.storePublic : Copy.Stage.storeLocked,
                    systemImage: stage.storeOpen ? Symbol.stageUnlocked : Symbol.stageLocked
                )
                .font(CobaltType.pill)
                .foregroundStyle(stage.storeOpen ? CobaltColor.text : CobaltColor.caption)
            }
            Text(stage.storeLinkText)
                .font(CobaltType.body)
                .foregroundStyle(CobaltColor.text)
                .lineLimit(1)
                .truncationMode(.middle)
            ButtonRow {
                copyButton(.store, title: Copy.Stage.copyStoreLink) { controller.copyStoreLink(shell: shell) }
            }
            Toggle(isOn: Binding(
                get: { stage.storeOpen },
                set: { controller.setStoreOpen($0, shell: shell) })
            ) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(Copy.Stage.storeOpen).font(CobaltType.bodySemibold)
                    Text(stage.storeOpen ? Copy.Stage.storeOpenNote : Copy.Stage.storeLockedNote)
                        .font(CobaltType.badge)
                        .foregroundStyle(CobaltColor.caption)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .toggleStyle(.switch)
            .tint(CobaltColor.success)
            .frame(minHeight: Metrics.hit)
            .disabled(controller.isBusy("store"))
        }
    }

    // MARK: shared

    @ViewBuilder
    private func copyButton(_ what: StageController.Copied, title: String, action: @escaping () -> Void) -> some View {
        if controller.copied == what {
            Button(Copy.Stage.copied, systemImage: Symbol.checkmark, action: action)
                .buttonStyle(.cobaltDone(compact: true))
        } else {
            Button(title, systemImage: Symbol.stageCopy, action: action)
                .buttonStyle(.cobaltSecondary(compact: true))
        }
    }
}
