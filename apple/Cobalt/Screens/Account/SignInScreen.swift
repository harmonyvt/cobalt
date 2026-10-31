import AuthenticationServices
import CobaltKit
import SwiftUI

/// First launch, or a device that never signed in and has no key (APP-API-CONTRACT 42.6): one "sign in" that opens
/// Cloudflare Access, and a small "have an old api key?" that still takes a pasted key. Stands in for the whole shell
/// (`AppShell`) until there is a token.
struct SignInScreen: View {
    let model: AppModel

    @Environment(\.webAuthenticationSession) private var webAuthentication
    @Environment(\.shell) private var shell
    @State private var problem: String?
    @State private var pasting = false
    @State private var failTick = 0
    @State private var doneTick = 0

    private var signingIn: Bool { model.account.signingIn }

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 24)
            mark
            Text(Copy.appName)
                .font(CobaltType.title)
                .padding(.top, 14)
            Text(Copy.Account.tagline)
                .font(CobaltType.body)
                .foregroundStyle(.secondary)
                .padding(.top, 6)
            VStack(spacing: 12) {
                Button { signIn() } label: {
                    Label(signingIn ? Copy.Account.signingIn : Copy.Account.signIn, systemImage: Symbol.Account.signIn)
                }
                .buttonStyle(.cobaltPrimary())
                .disabled(signingIn)
                Text(Copy.Account.signInHint)
                    .font(CobaltType.captionSmall)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                if let problem {
                    Text(problem)
                        .font(Font.cobalt(12.5))
                        .foregroundStyle(CobaltColor.errorText)
                        .multilineTextAlignment(.center)
                        .transition(.opacity)
                }
            }
            .frame(maxWidth: 320)
            .padding(.top, 26)
            Spacer(minLength: 24)
            Button(Copy.Account.oldKey) { pasting = true }
                .buttonStyle(.plain)
                .font(CobaltType.caption)
                .foregroundStyle(.secondary)
                .frame(minHeight: Metrics.hit)
                .padding(.bottom, 12)
        }
        .padding(.horizontal, 26)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(CobaltColor.bg.ignoresSafeArea())
        .animation(Motion.fade, value: problem)
        .haptic(.error, trigger: failTick)
        .haptic(.success, trigger: doneTick)
        .sheet(isPresented: $pasting) {
            OldKeySheet(model: model) { pasting = false }
                .cobaltRoot(model: model)
        }
    }

    /// The app's mark: the mockup's green-to-blue tile.
    private var mark: some View {
        RoundedRectangle(cornerRadius: 18, style: .continuous)
            .fill(LinearGradient(colors: [CobaltColor.success, CobaltColor.focus], startPoint: .topLeading, endPoint: .bottomTrailing))
            .frame(width: 64, height: 64)
            .overlay {
                Image(systemName: Symbol.Account.mark)
                    .font(.system(size: 30, weight: .semibold))
                    .foregroundStyle(.black)
            }
            .accessibilityHidden(true)
    }

    private func signIn() {
        problem = nil
        Task {
            switch await AccountSignIn.run(model, session: webAuthentication) {
            case .signedIn:
                doneTick += 1
                shell.showStatus(Copy.Account.signedIn)
            case .cancelled:
                break
            case .failed(let line):
                problem = line
                failTick += 1
            }
        }
    }
}

/// "have an old api key?": the key paste as settings had it (paste only, no text field). A pasted key works at once; the
/// move-over offers the switch to an account afterwards.
struct OldKeySheet: View {
    let model: AppModel
    let done: () -> Void

    @State private var problem: String?
    @State private var working = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                Text(Copy.Account.oldKeyTitle).font(CobaltType.sheetTitle)
                Spacer(minLength: 0)
                CloseButton(cancels: true, action: done)
            }
            Text(Copy.Account.oldKeyBody).font(CobaltType.body).foregroundStyle(.secondary)
            if let problem {
                Text(problem).font(Font.cobalt(12.5)).foregroundStyle(CobaltColor.errorText)
            }
            Button { paste() } label: { Label(Copy.Account.pasteKey, systemImage: Symbol.Account.paste) }
                .buttonStyle(.cobaltPrimary())
                .disabled(working)
        }
        .padding(24)
        .frame(minWidth: 320, idealWidth: 440)
        #if os(iOS)
        .presentationDetents([.medium])
        #endif
        .haptic(.error, trigger: problem) { $0 != nil }
    }

    private func paste() {
        problem = nil
        guard let text = Pasteboard.string() else { problem = Copy.notAKey; return }
        working = true
        Task {
            defer { working = false }
            do {
                try await model.setAPIKey(pasted: text)
                done()
            } catch {
                problem = (error as? KeyInputError) == .couldNotSave ? Copy.keyNotSaved : Copy.notAKey
            }
        }
    }
}

#if DEBUG
#Preview("sign in · first launch") {
    PreviewHost(.firstLaunch) { SignInScreen(model: $0) }
}
#Preview("sign in · old key") {
    PreviewHost(.firstLaunch) { OldKeySheet(model: $0) {} }
}
#endif
