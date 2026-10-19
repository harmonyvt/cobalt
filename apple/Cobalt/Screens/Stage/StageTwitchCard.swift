import AuthenticationServices
import CobaltKit
import SwiftUI

// The Twitch card (APP-API-CONTRACT 30.8, 30.11): connect, reconnect and disconnect, and a status line for what Twitch says.
// Connecting opens the server's authorize page in a web authentication session whose callback is `cobalt-apple://stage`;
// viewers never need the app. Without Twitch the rest of the studio still works (the canvas and the store are the owner's).

struct StageTwitchCard: View {
    let model: AppModel
    let stage: StageSettings
    let controller: StageController

    @Environment(\.shell) private var shell
    @Environment(\.webAuthenticationSession) private var webAuthentication

    var body: some View {
        StageCard(title: Copy.Stage.twitch) {
            if let twitch = stage.twitch {
                connected(twitch)
            } else {
                notConnected
            }
        }
    }

    // MARK: connected

    private func connected(_ twitch: StageTwitch) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            status(twitch)
            buttons(twitch)
        }
    }

    @ViewBuilder
    private func status(_ twitch: StageTwitch) -> some View {
        switch twitch.status {
        case .ok:
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: Symbol.stageTwitch)
                    .font(.system(size: 18))
                    .foregroundStyle(CobaltColor.success)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(Copy.Stage.connectedAs(twitch.displayName))
                        .font(CobaltType.bodyMedium)
                        .foregroundStyle(CobaltColor.text)
                    Text(Copy.Stage.listening)
                        .font(CobaltType.captionSmall)
                        .foregroundStyle(CobaltColor.caption)
                    if let last = twitch.lastEventAt {
                        Text(Copy.Stage.lastRedemption(Copy.Stage.ago(last, now: Date())))
                            .font(CobaltType.badge)
                            .foregroundStyle(CobaltColor.caption)
                    }
                }
            }
            .accessibilityElement(children: .combine)
        case .reconnect:
            warning(Copy.Stage.needsReconnect, name: twitch.displayName)
        case .notAffiliate:
            warning(Copy.Stage.notAffiliate, name: twitch.displayName)
        case .settingUp:
            HStack(spacing: 10) {
                ProgressView()
                VStack(alignment: .leading, spacing: 2) {
                    Text(Copy.Stage.connectedAs(twitch.displayName))
                        .font(CobaltType.bodyMedium)
                        .foregroundStyle(CobaltColor.text)
                    Text(Copy.Stage.settingUp)
                        .font(CobaltType.captionSmall)
                        .foregroundStyle(CobaltColor.caption)
                }
            }
            .accessibilityElement(children: .combine)
        }
    }

    private func warning(_ line: String, name: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: Symbol.stageTwitchWarn)
                .font(.system(size: 17))
                .foregroundStyle(CobaltColor.errorText)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(Copy.Stage.connectedAs(name))
                    .font(CobaltType.bodyMedium)
                    .foregroundStyle(CobaltColor.text)
                Text(line)
                    .font(CobaltType.captionSmall)
                    .foregroundStyle(CobaltColor.errorText)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func buttons(_ twitch: StageTwitch) -> some View {
        ButtonRow {
            if twitch.status == .reconnect {
                Button(Copy.Stage.reconnect, systemImage: Symbol.stageConnect) {
                    controller.connectTwitch(using: webAuthentication, shell: shell)
                }
                .buttonStyle(.cobaltPrimary(compact: true))
                .disabled(controller.connecting || !model.capabilities.stageTwitch)
            }
            Button(Copy.Stage.disconnect, systemImage: Symbol.stageDisconnect) { controller.confirmingDisconnect = true }
                .buttonStyle(.cobaltSecondary(compact: true))
                .disabled(controller.isBusy("twitch"))
        }
    }

    // MARK: not connected

    private var notConnected: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(model.capabilities.stageTwitch ? Copy.Stage.notConnectedBody : Copy.Stage.message(for: StageError.twitchOff))
                .font(CobaltType.caption)
                .foregroundStyle(CobaltColor.caption)
            Button(controller.connecting ? Copy.Stage.connecting : Copy.Stage.connect, systemImage: Symbol.stageConnect) {
                controller.connectTwitch(using: webAuthentication, shell: shell)
            }
            .buttonStyle(.cobaltPrimary(compact: true))
            .disabled(controller.connecting || !model.capabilities.stageTwitch)
        }
    }
}
