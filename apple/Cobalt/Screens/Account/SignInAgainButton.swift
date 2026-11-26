import AuthenticationServices
import CobaltKit
import SwiftUI

/// "sign in again" (APP-API-CONTRACT 42.6): the session ended or this device signed out, and the app kept its screen. The
/// button stays until signing in works; then the app stays where it is and reloads. Amber, like the mockup. A floating
/// capsule bottom-right on iPhone and iPad (`SignInAgainPin`), an item in the window toolbar on the Mac (`AppShell`).
struct SignInAgainButton: View {
    let model: AppModel

    @Environment(\.webAuthenticationSession) private var webAuthentication
    @Environment(\.shell) private var shell
    @State private var doneTick = 0
    @State private var failTick = 0

    private var signingIn: Bool { model.account.signingIn }

    var body: some View {
        Button { signIn() } label: {
            HStack(spacing: 8) {
                if signingIn {
                    ProgressView().controlSize(.small).tint(.black)
                } else {
                    Image(systemName: Symbol.Account.signInAgain)
                }
                Text(signingIn ? Copy.Account.signingIn : Copy.Account.signInAgain)
            }
            .font(CobaltType.button)
            .foregroundStyle(.black)
        }
        .buttonStyle(.glassProminent)
        .tint(CobaltColor.amber)
        .disabled(signingIn)
        .accessibilityLabel(Copy.Account.signInAgain)
        .accessibilityHint(Copy.Account.signedOutHint)
        .help(Copy.Account.signedOutHint)
        .haptic(.success, trigger: doneTick)
        .haptic(.error, trigger: failTick)
    }

    private func signIn() {
        Task {
            switch await AccountSignIn.run(model, session: webAuthentication) {
            case .signedIn:
                doneTick += 1
                shell.showStatus(Copy.Account.signedInAgain)
            case .cancelled:
                break
            case .failed(let line):
                failTick += 1
                shell.showStatus(line)
            }
        }
    }
}

/// iPhone and iPad: "sign in again" floats bottom-right over whatever screen is showing, relying on system
/// `safeAreaInset` so it clears both the bottom tab bar and iPhone Duo's asymmetric trailing vertical rail.
struct SignInAgainPin: ViewModifier {
    let model: AppModel

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .safeAreaInset(edge: .bottom, alignment: .trailing, spacing: 0) {
                if model.signInPinned {
                    SignInAgainButton(model: model)
                        .controlSize(.large)
                        #if os(iOS)
                        .buttonBorderShape(.capsule)
                        #endif
                        .shadow(color: .black.opacity(0.35), radius: 14, y: 6)
                        .padding(.trailing, 16)
                        .padding(.bottom, 12)
                        .transition(reduceMotion ? .opacity : .scale(scale: 0.6, anchor: .bottomTrailing).combined(with: .opacity))
                }
            }
            .animation(reduceMotion ? Motion.fade : Motion.card, value: model.signInPinned)
    }
}
