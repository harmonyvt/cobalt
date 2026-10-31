import CobaltKit
import SwiftUI

/// "capystore has accounts now" (APP-API-CONTRACT 42.6): a device with a key pasted before accounts, never signed in, is
/// offered the switch once. "sign in to switch" runs the sign-in with the pasted key as `old_key` (the token then takes the
/// key's place in the keychain, so the share sheet and Shortcuts follow); "later" keeps the key.
struct MoveOverPresenter: ViewModifier {
    let model: AppModel

    @State private var shown = false
    @Environment(\.shell) private var shell

    func body(content: Content) -> some View {
        content
            .onChange(of: model.offersMoveOver, initial: true) { _, offers in
                guard offers else { return }
                model.settings.moveOverAsked = true            // once, whatever the answer
                shown = true
            }
            .sheet(isPresented: $shown) {
                MoveOverSheet(model: model) { switched in
                    shown = false
                    if switched { shell.showStatus(Copy.Account.switched) }
                }
                .cobaltRoot(model: model)
            }
    }
}

struct MoveOverSheet: View {
    let model: AppModel
    /// Closes the sheet; true after the switch worked.
    let done: (_ switched: Bool) -> Void

    @Environment(\.webAuthenticationSession) private var webAuthentication
    @State private var problem: String?
    @State private var failTick = 0
    @State private var doneTick = 0

    private var signingIn: Bool { model.account.signingIn }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: Symbol.Account.oldKey)
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(CobaltColor.amber)
                    .frame(width: 44, height: 44)
                    .background(CobaltColor.amberBack, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .accessibilityHidden(true)
                Spacer(minLength: 0)
                CloseButton(cancels: true) { done(false) }
            }
            Text(Copy.Account.moveTitle).font(CobaltType.sheetTitle)
            Text(Copy.Account.moveBody).font(CobaltType.body).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 10) {
                point(Symbol.Account.library, Copy.Account.moveLibrary)
                point(Symbol.Account.devices, Copy.Account.moveDevices)
                point(Symbol.Account.keyStays, Copy.Account.moveOldKey)
            }
            if let problem {
                Text(problem).font(Font.cobalt(12.5)).foregroundStyle(CobaltColor.errorText)
            }
            VStack(spacing: 8) {
                Button { switchNow() } label: {
                    Label(signingIn ? Copy.Account.signingIn : Copy.Account.moveSwitch, systemImage: Symbol.Account.signIn)
                }
                .buttonStyle(.cobaltPrimary())
                .disabled(signingIn)
                Button(Copy.Account.moveLater) { done(false) }
                    .buttonStyle(.cobaltSecondary())
                    .disabled(signingIn)
            }
        }
        .padding(24)
        .frame(minWidth: 320, idealWidth: 460)
        #if os(iOS)
        .presentationDetents([.medium, .large])
        #endif
        .interactiveDismissDisabled(signingIn)
        .haptic(.error, trigger: failTick)
        .haptic(.success, trigger: doneTick)
    }

    private func point(_ symbol: String, _ text: String) -> some View {
        Label {
            Text(text).font(CobaltType.body)
        } icon: {
            Image(systemName: symbol).foregroundStyle(CobaltColor.success)
        }
    }

    private func switchNow() {
        problem = nil
        Task {
            switch await AccountSignIn.run(model, session: webAuthentication) {
            case .signedIn:
                doneTick += 1
                done(true)
            case .cancelled:
                break
            case .failed(let line):
                problem = line
                failTick += 1
            }
        }
    }
}

#if DEBUG
#Preview("move-over") {
    PreviewHost(.moveOver) { MoveOverSheet(model: $0) { _ in } }
}
#endif
