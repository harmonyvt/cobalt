import AuthenticationServices
import CobaltKit
import SwiftUI

/// Settings › account (APP-API-CONTRACT 42.6), in place of the api key row on a server with `features.accounts`: who is
/// signed in (the Access email, "through cloudflare access"), the signed-in devices (sign out each, or every other one),
/// the keys for tools (revoke; "old paste" tags the keys apps used before accounts; keys are made on the web), a line on
/// private links, and sign out. Every sign-out and revoke asks first. Grouped rows like settings › mcp, on the Mac too.
struct AccountSettingsSection: View {
    let model: AppModel

    private enum Pending: Equatable {
        case signOutSelf
        case signOut(AccountSession)
        case signOutOthers(Int)
        case revoke(AccountKey)
    }

    @State private var pending: Pending?
    @State private var working = false
    @State private var actionError: String?
    @State private var doneTick = 0
    @State private var failTick = 0
    @Environment(\.webAuthenticationSession) private var webAuthentication
    @Environment(\.shell) private var shell

    private var store: AccountStore { model.account }
    private var signedIn: Bool { model.settings.hasAPIKey && !model.signInPinned }
    /// This device still sends a key pasted before accounts (known locally before `/auth/me` answers).
    private var usesPastedKey: Bool { store.me.map { $0.caller.kind == .key } ?? !model.settings.keyIsSession }

    var body: some View {
        if model.capabilities.accounts {
            accountSection
                .task(id: model.settings.hasAPIKey) { await store.refresh() }
                .confirmationDialog(dialogTitle, isPresented: dialogShown, titleVisibility: .visible) {
                    Button(dialogAction, role: .destructive) { Task { await confirm() } }
                    Button(Copy.Account.cancel, role: .cancel) { pending = nil }
                } message: {
                    Text(dialogBody)
                }
                .haptic(.success, trigger: doneTick)
                .haptic(.error, trigger: failTick)
            if signedIn && !usesPastedKey && store.phase == .ready {
                devicesSection
            }
            if signedIn && store.phase == .ready {
                keysSection
            }
            endSection
        }
    }

    // MARK: who

    private var accountSection: some View {
        Section {
            if !signedIn {
                row(Copy.Account.signedOutRow, Symbol.Account.signedOut) {
                    Text(Copy.Account.signedOutHint).font(Font.cobalt(12)).foregroundStyle(.secondary)
                        .multilineTextAlignment(.trailing).lineLimit(3)
                }
                signInButton(Copy.Account.signInAgain)
            } else if usesPastedKey {
                row(Copy.Account.usesOldKey, Symbol.Account.oldKey) { EmptyView() }
                signInButton(Copy.Account.switchNow)
            } else {
                switch store.phase {
                case .idle, .loading:
                    HStack(spacing: 10) {
                        ProgressView().controlSize(.small)
                        Text(Copy.Account.loading).foregroundStyle(.secondary)
                    }
                case .failed:
                    HStack(spacing: 8) {
                        Text(Copy.Account.loadFailed).font(Font.cobalt(12.5)).foregroundStyle(CobaltColor.errorText)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Button { Task { await store.refresh() } } label: {
                            Label(Copy.Account.retry, systemImage: Symbol.Mcp.rotate)
                        }
                        .buttonStyle(.cobaltIcon(.small))
                    }
                case .ready:
                    row(Copy.Account.through, Symbol.Account.access) { value(Copy.Account.access) }
                    if let email = store.email {
                        row(Copy.Account.email, Symbol.Account.email) {
                            value(email).textSelection(.enabled)
                        }
                    }
                }
            }
            if let actionError {
                Text(actionError).font(Font.cobalt(12.5)).foregroundStyle(CobaltColor.errorText)
            }
        } header: {
            header(Copy.Account.group)
        } footer: {
            if signedIn && !usesPastedKey { footer(Copy.Account.accountFooter) }
        }
    }

    private func signInButton(_ title: String) -> some View {
        Button { signIn() } label: {
            Label(store.signingIn ? Copy.Account.signingIn : title, systemImage: Symbol.Account.signInAgain)
                .foregroundStyle(CobaltColor.amber)
        }
        .disabled(store.signingIn)
    }

    // MARK: devices

    private var devicesSection: some View {
        Section {
            ForEach(store.sessions) { session in
                LabeledContent {
                    if !session.current {
                        Button(role: .destructive) { ask(.signOut(session)) } label: {
                            Label(Copy.Account.signOutDevice, systemImage: Symbol.Account.signOut)
                        }
                        .buttonStyle(.cobaltIcon(.small, tint: CobaltColor.errorText))
                        .disabled(working)
                    }
                } label: {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(session.device).lineLimit(1)
                                if session.current {
                                    tag(Copy.Account.thisDevice, ink: CobaltColor.success, back: CobaltColor.success.opacity(0.15))
                                }
                            }
                            Text(Copy.Account.sessionLine(session)).font(Font.cobalt(11.5)).foregroundStyle(.secondary).lineLimit(1)
                        }
                    } icon: {
                        Image(systemName: Symbol.Account.platform(session.kind))
                    }
                }
                .accessibilityElement(children: .combine)
            }
            if !store.otherSessions.isEmpty {
                Button(role: .destructive) { ask(.signOutOthers(store.otherSessions.count)) } label: {
                    Label(Copy.Account.signOutOthers, systemImage: Symbol.Account.signOut)
                        .foregroundStyle(CobaltColor.errorText)
                }
                .disabled(working)
            }
        } header: {
            header(Copy.Account.devicesGroup)
        } footer: {
            footer(Copy.Account.devicesFooter)
        }
    }

    // MARK: keys for tools

    private var keysSection: some View {
        Section {
            if store.oldPasteCount > 0 {
                Label {
                    Text(Copy.Account.oldPasteNote(store.oldPasteCount)).font(Font.cobalt(12))
                } icon: {
                    Image(systemName: "info.circle").foregroundStyle(CobaltColor.amber)
                }
            }
            if store.keys.isEmpty {
                Text(Copy.Account.noKeys).font(Font.cobalt(12.5)).foregroundStyle(.secondary)
            }
            ForEach(store.keys) { key in
                LabeledContent {
                    Button(role: .destructive) { ask(.revoke(key)) } label: {
                        Label(Copy.Account.revoke, systemImage: Symbol.reset)
                    }
                    .buttonStyle(.cobaltIcon(.small, tint: CobaltColor.errorText))
                    .disabled(working)
                } label: {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(key.name).lineLimit(1)
                                if key.oldPaste { tag(Copy.Account.oldPaste, ink: CobaltColor.amber, back: CobaltColor.amberBack) }
                            }
                            Text(Copy.Account.keyLine(key)).font(Font.cobalt(11.5)).foregroundStyle(.secondary).lineLimit(1)
                        }
                    } icon: {
                        Image(systemName: key.oldPaste ? Symbol.Account.oldPaste : Symbol.Account.tool)
                    }
                }
                .accessibilityElement(children: .combine)
            }
        } header: {
            header(Copy.Account.keysGroup)
        } footer: {
            footer(Copy.Account.keysFooter)
        }
    }

    // MARK: private links, sign out

    private var endSection: some View {
        Section {
            if model.settings.hasAPIKey {
                Button(role: .destructive) { ask(.signOutSelf) } label: {
                    Label(Copy.Account.signOut, systemImage: Symbol.Account.signOut)
                        .foregroundStyle(CobaltColor.errorText)
                }
                .disabled(working)
            }
        } footer: {
            Label {
                Text(Copy.Account.privateLinks)
            } icon: {
                Image(systemName: Symbol.Account.privateLink)
            }
            .font(CobaltType.captionSmall)
            .lineSpacing(2)
        }
    }

    // MARK: pieces

    private func row<V: View>(_ title: String, _ symbol: String, @ViewBuilder value: () -> V) -> some View {
        LabeledContent {
            value()
        } label: {
            Label(title, systemImage: symbol)
        }
    }

    private func value(_ text: String) -> some View {
        Text(text).font(Font.cobalt(12.5)).foregroundStyle(.secondary).multilineTextAlignment(.trailing).lineLimit(1)
            .truncationMode(.middle)
    }

    private func tag(_ text: String, ink: Color, back: Color) -> some View {
        Text(text)
            .font(CobaltType.pill)
            .foregroundStyle(ink)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(back, in: Capsule())
            .fixedSize()
    }

    private func header(_ text: String) -> some View {
        Text(text).font(CobaltType.caption).textCase(nil)
    }

    private func footer(_ text: String) -> some View {
        Text(text).font(CobaltType.captionSmall).lineSpacing(2)
    }

    // MARK: the confirm

    private var dialogShown: Binding<Bool> {
        Binding(get: { pending != nil }, set: { if !$0 { pending = nil } })
    }

    private var dialogTitle: String {
        switch pending {
        case .signOutSelf: return Copy.Account.signOutSelfTitle
        case .signOut(let s): return Copy.Account.signOutDeviceTitle(s.device)
        case .signOutOthers(let n): return Copy.Account.signOutOthersTitle(n)
        case .revoke(let k): return Copy.Account.revokeTitle(k.name)
        case nil: return ""
        }
    }

    private var dialogBody: String {
        switch pending {
        case .signOutSelf: return Copy.Account.signOutSelfBody
        case .signOut: return Copy.Account.signOutDeviceBody
        case .signOutOthers: return Copy.Account.signOutOthersBody
        case .revoke: return Copy.Account.revokeBody
        case nil: return ""
        }
    }

    private var dialogAction: String {
        switch pending {
        case .signOutSelf, .signOut: return Copy.Account.signOutDevice
        case .signOutOthers(let n): return Copy.Account.signOutOthersAction(n)
        case .revoke: return Copy.Account.revoke
        case nil: return ""
        }
    }

    // MARK: actions

    private func ask(_ next: Pending) {
        guard !working else { return }
        actionError = nil
        pending = next
    }

    private func confirm() async {
        guard let next = pending, !working else { return }
        pending = nil
        working = true
        defer { working = false }
        do {
            switch next {
            case .signOutSelf:
                await model.signOut()
                shell.showStatus(Copy.Account.signedOut)
            case .signOut(let session):
                try await store.signOut(session)
                shell.showStatus(Copy.Account.signedOutDevice(session.device))
            case .signOutOthers:
                let n = try await store.signOutOthers()
                shell.showStatus(Copy.Account.signedOutOthers(n))
            case .revoke(let key):
                try await store.revoke(key)
                shell.showStatus(Copy.Account.revoked(key.name))
            }
            doneTick += 1
        } catch {
            actionError = Copy.Account.message(for: error) ?? Copy.Account.message(for: AccountError.failed)
            failTick += 1
        }
    }

    private func signIn() {
        actionError = nil
        Task {
            switch await AccountSignIn.run(model, session: webAuthentication) {
            case .signedIn:
                doneTick += 1
                shell.showStatus(Copy.Account.signedInAgain)
            case .cancelled:
                break
            case .failed(let line):
                actionError = line
                failTick += 1
            }
        }
    }
}

#if DEBUG
#Preview("settings · account") {
    PreviewHost(.happy, tab: .settings) { model in
        Form { AccountSettingsSection(model: model) }.formStyle(.grouped)
    }
}
#Preview("settings · account signed out") {
    PreviewHost(.signedOut, tab: .settings) { model in
        Form { AccountSettingsSection(model: model) }.formStyle(.grouped)
    }
}
#Preview("settings · account move-over") {
    PreviewHost(.moveOver, tab: .settings) { model in
        Form { AccountSettingsSection(model: model) }.formStyle(.grouped)
    }
}
#endif
