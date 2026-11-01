import AuthenticationServices
import CobaltKit
import SwiftUI

/// Settings › account (APP-API-CONTRACT 42.6), in place of the api key row on a server with `features.accounts`: who is
/// signed in (the Access email, "through cloudflare access"), the signed-in devices (sign out each, or every other one),
/// the keys for tools (make, rename, delete; APP-API-CONTRACT 50; "old paste" tags the keys apps used before accounts), a
/// line on private links, and sign out. Every sign-out and delete asks first. Grouped rows like settings › mcp, on the Mac
/// too. A new key is shown once, in `NewKeySheet`.
struct AccountSettingsSection: View {
    let model: AppModel

    /// Owned by the settings screen, so the confirm, the new key sheet and the rename hang off the whole form, not off
    /// rows that come and go (a sheet on a section is copied onto every row, and two copies close each other).
    @Bindable var state: AccountSettingsState
    @Environment(\.webAuthenticationSession) private var webAuthentication
    @Environment(\.shell) private var shell

    private var store: AccountStore { model.account }
    private var signedIn: Bool { model.settings.hasAPIKey && !model.signInPinned }
    /// This device still sends a key pasted before accounts (known locally before `/auth/me` answers).
    private var usesPastedKey: Bool { store.me.map { $0.caller.kind == .key } ?? !model.settings.keyIsSession }

    var body: some View {
        if model.capabilities.accounts {
            accountSection
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
            if let actionError = state.actionError {
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
                        .disabled(state.working)
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
                .disabled(state.working)
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
                    HStack(spacing: 6) {
                        if store.canMakeKeys {
                            Button { startRename(key) } label: {
                                Label(Copy.Account.rename, systemImage: Symbol.Account.rename)
                            }
                            .buttonStyle(.cobaltIcon(.small))
                        }
                        Button(role: .destructive) { ask(.delete(key)) } label: {
                            Label(Copy.Account.delete, systemImage: Symbol.Account.delete)
                        }
                        .buttonStyle(.cobaltIcon(.small, tint: CobaltColor.errorText))
                    }
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
                .contextMenu {
                    if store.canMakeKeys {
                        Button(Copy.Account.rename, systemImage: Symbol.Account.rename) { startRename(key) }
                    }
                    Button(Copy.Account.delete, systemImage: Symbol.Account.delete, role: .destructive) { ask(.delete(key)) }
                }
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    Button(role: .destructive) { ask(.delete(key)) } label: {
                        Label(Copy.Account.delete, systemImage: Symbol.Account.delete)
                    }
                    .tint(.red)
                    if store.canMakeKeys {
                        Button { startRename(key) } label: {
                            Label(Copy.Account.rename, systemImage: Symbol.Account.rename)
                        }
                    }
                }
            }
            if store.canMakeKeys {
                Button { state.actionError = nil; state.makingKey = true } label: {
                    Label(Copy.Account.newKey, systemImage: Symbol.Account.newKey)
                }
                .disabled(state.working)
            } else {
                Text(Copy.Account.signInToMake).font(Font.cobalt(12.5)).foregroundStyle(.secondary)
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
                .disabled(state.working)
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

    // MARK: actions

    private func ask(_ next: AccountSettingsState.Pending) {
        if case .delete = next {} else if state.working { return }
        state.actionError = nil
        state.pending = next
    }

    private func startRename(_ key: AccountKey) {
        state.actionError = nil
        state.newName = key.name
        state.renaming = key
    }

    /// 1...40 characters after trimming (the server checks again).
    static func nameFits(_ raw: String) -> Bool {
        let n = raw.trimmingCharacters(in: .whitespacesAndNewlines).count
        return n >= 1 && n <= AccountStore.maxKeyNameLength && !raw.contains(where: \.isNewline)
    }

    /// "https://api.example.com" (no trailing slash) for the claude code line.
    static func base(_ url: URL) -> String {
        var s = url.absoluteString
        while s.hasSuffix("/") { s.removeLast() }
        return s
    }

    private func signIn() {
        state.actionError = nil
        Task {
            switch await AccountSignIn.run(model, session: webAuthentication) {
            case .signedIn:
                state.doneTick += 1
                shell.showStatus(Copy.Account.signedInAgain)
            case .cancelled:
                break
            case .failed(let line):
                state.actionError = line
                state.failTick += 1
            }
        }
    }
}

/// Settings › account's passing state: the confirm, the new key sheet, the rename and the last error. `SettingsScreen`
/// owns it and hangs `accountSettingsPresentations` on its `Form`.
@MainActor @Observable
final class AccountSettingsState {
    enum Pending: Equatable {
        case signOutSelf
        case signOut(AccountSession)
        case signOutOthers(Int)
        case delete(AccountKey)
    }

    var pending: Pending?
    /// A sign-out is running (deletes and renames show at once and never block the screen).
    var working = false
    var actionError: String?
    var doneTick = 0
    var failTick = 0
    var makingKey = false
    var renaming: AccountKey?
    var newName = ""
}

extension View {
    /// The account section's confirm, new key sheet and rename, on one stable view (the settings `Form`), plus its load.
    func accountSettingsPresentations(model: AppModel, state: AccountSettingsState) -> some View {
        modifier(AccountSettingsPresentations(model: model, state: state))
    }
}

private struct AccountSettingsPresentations: ViewModifier {
    let model: AppModel
    @Bindable var state: AccountSettingsState
    @Environment(\.shell) private var shell

    private var store: AccountStore { model.account }

    func body(content: Content) -> some View {
        content
            .task(id: model.capabilities.accounts && model.settings.hasAPIKey) {
                if model.capabilities.accounts { await store.refresh() }
            }
            .confirmationDialog(dialogTitle, isPresented: dialogShown, titleVisibility: .visible) {
                Button(dialogAction, role: .destructive) { confirm() }
                Button(Copy.Account.cancel, role: .cancel) { state.pending = nil }
            } message: {
                Text(dialogBody)
            }
            .sheet(isPresented: $state.makingKey) {
                NewKeySheet(store: store, base: AccountSettingsSection.base(model.settings.serverURL)) { made in
                    if let made { shell.showStatus(Copy.Account.madeTitle(made.item.name)) }
                }
            }
            .alert(Copy.Account.renameTitle, isPresented: renameShown) {
                TextField(Copy.Account.keyNamePlaceholder, text: $state.newName)
                Button(Copy.Account.save) { saveRename() }
                    .disabled(!AccountSettingsSection.nameFits(state.newName))
                Button(Copy.Account.cancel, role: .cancel) { state.renaming = nil }
            } message: {
                Text(Copy.Account.keyNameHint)
            }
            .haptic(.success, trigger: state.doneTick)
            .haptic(.error, trigger: state.failTick)
    }

    // MARK: the confirm

    private var dialogShown: Binding<Bool> {
        Binding(get: { state.pending != nil }, set: { if !$0 { state.pending = nil } })
    }

    private var dialogTitle: String {
        switch state.pending {
        case .signOutSelf: return Copy.Account.signOutSelfTitle
        case .signOut(let s): return Copy.Account.signOutDeviceTitle(s.device)
        case .signOutOthers(let n): return Copy.Account.signOutOthersTitle(n)
        case .delete(let k): return Copy.Account.deleteTitle(k.name)
        case nil: return ""
        }
    }

    private var dialogBody: String {
        switch state.pending {
        case .signOutSelf: return Copy.Account.signOutSelfBody
        case .signOut: return Copy.Account.signOutDeviceBody
        case .signOutOthers: return Copy.Account.signOutOthersBody
        case .delete: return Copy.Account.deleteBody
        case nil: return ""
        }
    }

    private var dialogAction: String {
        switch state.pending {
        case .signOutSelf, .signOut: return Copy.Account.signOutDevice
        case .signOutOthers(let n): return Copy.Account.signOutOthersAction(n)
        case .delete: return Copy.Account.delete
        case nil: return ""
        }
    }

    private func confirm() {
        guard let next = state.pending else { return }
        state.pending = nil
        // A key leaves the list at once (the store puts it back if the server says no); nothing waits on it.
        if case .delete(let key) = next {
            Task {
                do {
                    try await store.revoke(key)
                    shell.showStatus(Copy.Account.deleted(key.name))
                    state.doneTick += 1
                } catch {
                    fail(error)
                }
            }
            return
        }
        guard !state.working else { return }
        state.working = true
        Task {
            defer { state.working = false }
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
                case .delete:
                    break
                }
                state.doneTick += 1
            } catch {
                fail(error)
            }
        }
    }

    // MARK: rename

    private var renameShown: Binding<Bool> {
        Binding(get: { state.renaming != nil }, set: { if !$0 { state.renaming = nil } })
    }

    /// The new name shows at once; the store puts the old one back if the server says no.
    private func saveRename() {
        guard let key = state.renaming else { return }
        state.renaming = nil
        let name = state.newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard name != key.name, AccountSettingsSection.nameFits(name) else { return }
        Task {
            do {
                try await store.rename(key, to: name)
                state.doneTick += 1
            } catch {
                fail(error)
            }
        }
    }

    private func fail(_ error: Error) {
        state.actionError = Copy.Account.message(for: error) ?? Copy.Account.message(for: AccountError.failed)
        state.failTick += 1
    }
}

/// Make a key for a tool: name it, then the key once, with copy and a ready `claude mcp add` line. Closing forgets the
/// key (only its first 8 characters stay in the list). Close top right; it can't be swiped away before copying.
private struct NewKeySheet: View {
    let store: AccountStore
    let base: String
    let finished: (AccountKeyCreated?) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var made: AccountKeyCreated?
    @State private var working = false
    @State private var error: String?
    @State private var copiedKey = false
    @State private var copiedCommand = false
    @FocusState private var nameFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                Text(made.map { Copy.Account.madeTitle($0.item.name) } ?? Copy.Account.newKeyTitle).font(CobaltType.sheetTitle)
                Spacer(minLength: 0)
                CloseButton(cancels: made == nil) { close() }
            }
            if let made {
                reveal(made)
            } else {
                form
            }
        }
        .padding(24)
        .frame(minWidth: 320, idealWidth: 460)
        #if os(iOS)
        .presentationDetents([.medium, .large])
        #endif
        .interactiveDismissDisabled(made != nil && !copiedKey && !copiedCommand)
        .haptic(.success, trigger: made?.item.id) { $0 != nil }
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(Copy.Account.keyNamePrompt).font(CobaltType.body).foregroundStyle(.secondary)
            TextField(Copy.Account.keyNamePlaceholder, text: $name)
                .textFieldStyle(.roundedBorder)
                .focused($nameFocused)
                .submitLabel(.done)
                .onSubmit { Task { await make() } }
                #if os(iOS)
                .textInputAutocapitalization(.never)
                #endif
            Text(error ?? Copy.Account.keyNameHint)
                .font(CobaltType.captionSmall)
                .foregroundStyle(error == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(CobaltColor.errorText))
            Button { Task { await make() } } label: {
                Label(working ? Copy.Account.making : Copy.Account.make, systemImage: Symbol.Account.newKey)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(working || !AccountSettingsSection.nameFits(name))
        }
        .onAppear { nameFocused = true }
    }

    private func reveal(_ made: AccountKeyCreated) -> some View {
        let command = Copy.Account.claudeCommand(base: base, key: made.key)
        return VStack(alignment: .leading, spacing: 12) {
            Text(Copy.Account.madeWarning).font(CobaltType.body).foregroundStyle(.secondary)
            Text(made.key)
                .font(.system(size: 13, design: .monospaced))
                .textSelection(.enabled)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            Button(copiedKey ? Copy.Account.copied : Copy.Account.copyKey, systemImage: Symbol.Account.copy) {
                Pasteboard.copy(made.key)
                copiedKey = true
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .haptic(.success, trigger: copiedKey) { $0 }
            Text(Copy.Account.claudeCode).font(CobaltType.caption).foregroundStyle(.secondary).padding(.top, 4)
            Text(command)
                .font(.system(size: 11.5, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .lineLimit(4)
            Button(copiedCommand ? Copy.Account.copied : Copy.Account.copyCommand, systemImage: Symbol.Account.copy) {
                Pasteboard.copy(command)
                copiedCommand = true
            }
            .buttonStyle(.bordered)
            .haptic(.success, trigger: copiedCommand) { $0 }
        }
    }

    private func make() async {
        guard !working, made == nil, AccountSettingsSection.nameFits(name) else { return }
        working = true
        error = nil
        defer { working = false }
        do {
            made = try await store.create(name: name)
        } catch {
            self.error = Copy.Account.message(for: error) ?? Copy.Account.message(for: AccountError.failed)
        }
    }

    private func close() {
        finished(made)
        made = nil
        dismiss()
    }
}

#if DEBUG
private struct AccountSettingsPreview: View {
    let model: AppModel
    @State private var state = AccountSettingsState()

    var body: some View {
        Form { AccountSettingsSection(model: model, state: state) }
            .formStyle(.grouped)
            .accountSettingsPresentations(model: model, state: state)
    }
}

#Preview("settings · account") {
    PreviewHost(.happy, tab: .settings) { model in
        AccountSettingsPreview(model: model)
    }
}
#Preview("settings · account signed out") {
    PreviewHost(.signedOut, tab: .settings) { model in
        AccountSettingsPreview(model: model)
    }
}
#Preview("settings · account move-over") {
    PreviewHost(.moveOver, tab: .settings) { model in
        AccountSettingsPreview(model: model)
    }
}
#Preview("new key sheet") {
    PreviewHost(.happy, tab: .settings) { model in
        NewKeySheet(store: model.account, base: "https://api.capybaraharmony.com") { _ in }
    }
}
#endif
