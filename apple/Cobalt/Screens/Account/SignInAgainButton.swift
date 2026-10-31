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

/// iPhone and iPad: "sign in again" floats bottom-right over whatever screen is showing, clear of the tab bar (which sits at
/// the bottom only in the compact layout; the iPad's sidebar-adaptable bar is at the top).
struct SignInAgainPin: ViewModifier {
    let model: AppModel
    /// The bottom tab bar is showing (compact width).
    let overTabBar: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .bottomTrailing) {
                if model.signInPinned {
                    SignInAgainButton(model: model)
                        .controlSize(.large)
                        #if os(iOS)
                        .buttonBorderShape(.capsule)
                        #endif
                        .shadow(color: .black.opacity(0.35), radius: 14, y: 6)
                        .padding(.trailing, 16)
                        // the floating iOS 26 tab bar is about 62 pt tall above the home indicator's inset
                        .padding(.bottom, overTabBar ? 74 : 20)
                        .transition(reduceMotion ? .opacity : .scale(scale: 0.6, anchor: .bottomTrailing).combined(with: .opacity))
                }
            }
            .animation(reduceMotion ? Motion.fade : Motion.card, value: model.signInPinned)
    }
}
