import CobaltKit
import SwiftUI

// The booru filters (APP-API-CONTRACT 72): sort and refine, the blacklist, and what is always hidden. General only, with
// no level, presets or theme toggles (owner, 2026-11-23, 72.9): those are the server's and never a setting.

struct BooruFilterSheet: View {
    let model: AppModel

    /// "done" works in a sheet and in the spread pane alike (a plain `dismiss` did nothing in the pane, 8.34).
    var dismiss = SheetOrPaneDismiss()
    @State private var blacklist = ""
    @State private var blacklistState: SaveState = .idle

    private enum SaveState { case idle, saved, failed }

    private var store: BooruStore { model.booru }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    section(Copy.Booru.refine) { refine }
                    section(Copy.Booru.blacklist) { blacklistEditor }
                    section(Copy.DanbooruKey.header) { DanbooruKeyCard() }
                    section(Copy.Booru.alwaysHidden) {
                        VStack(spacing: 0) {
                            row(Copy.Booru.generalOnly, detail: Copy.Booru.generalOnlyDetail) {
                                Image(systemName: Symbol.Booru.lock).foregroundStyle(CobaltColor.caption)
                            }
                            Divider().overlay(CobaltColor.hairline)
                            row(Copy.Booru.hardBlock, detail: Copy.Booru.hardBlockDetail) {
                                Image(systemName: Symbol.Booru.lock).foregroundStyle(CobaltColor.errorText)
                            }
                        }
                        .card()
                    }
                    if let err = store.settingsError, err != "error.booru.not_ready" {
                        Text(Copy.Booru.saveFailed).font(CobaltType.caption).foregroundStyle(CobaltColor.errorText)
                    }
                }
                .padding(16)
                .frame(maxWidth: 640)
                .frame(maxWidth: .infinity)
            }
            .background(CobaltColor.bg)
            .navigationTitle(Copy.Booru.filters)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(Copy.Booru.done) { dismiss() }
                }
            }
        }
        .task {
            if !store.settingsLoaded { await store.loadSettings() }
            blacklist = store.settings?.blacklist ?? ""
        }
        .panelDrawsOwnClose()
    }

    // MARK: refine

    private var refine: some View {
        VStack(spacing: 0) {
            row(Copy.Booru.order, detail: nil) {
                Picker(Copy.Booru.order, selection: queryBinding(\.order)) {
                    ForEach(BooruOrder.allCases, id: \.self) { Text(Copy.Booru.order($0)).tag($0) }
                }
                .labelsHidden()
            }
            Divider().overlay(CobaltColor.hairline)
            row(Copy.Booru.minScore, detail: nil) {
                Picker(Copy.Booru.minScore, selection: queryBinding(\.minScore)) {
                    Text(Copy.Booru.any).tag(Int?.none)
                    ForEach([10, 50, 100, 500], id: \.self) { Text("\($0)").tag(Int?.some($0)) }
                }
                .labelsHidden()
            }
            Divider().overlay(CobaltColor.hairline)
            row(Copy.Booru.media, detail: nil) {
                Picker(Copy.Booru.media, selection: queryBinding(\.media)) {
                    Text(Copy.Booru.any).tag(BooruMedia?.none)
                    ForEach(BooruMedia.allCases, id: \.self) { Text(Copy.Booru.media($0)).tag(BooruMedia?.some($0)) }
                }
                .labelsHidden()
            }
            Divider().overlay(CobaltColor.hairline)
            row(Copy.Booru.shape, detail: nil) {
                Picker(Copy.Booru.shape, selection: queryBinding(\.shape)) {
                    Text(Copy.Booru.any).tag(BooruShape?.none)
                    ForEach(BooruShape.allCases, id: \.self) { Text(Copy.Booru.shape($0)).tag(BooruShape?.some($0)) }
                }
                .labelsHidden()
            }
        }
        .card()
    }

    private func queryBinding<V: Equatable>(_ key: WritableKeyPath<BooruQuery, V>) -> Binding<V> {
        Binding(get: { store.query[keyPath: key] }, set: { v in
            var q = store.query
            guard q[keyPath: key] != v else { return }
            q[keyPath: key] = v
            Task { await store.search(q) }
        })
    }

    // MARK: blacklist

    private var blacklistEditor: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextEditor(text: $blacklist)
                .font(CobaltType.body)
                .autocorrectionDisabled()
                #if os(iOS)
                .textInputAutocapitalization(.never)
                #endif
                .scrollContentBackground(.hidden)
                .frame(minHeight: 120)
                .padding(8)
                .background(CobaltColor.row, in: RoundedRectangle(cornerRadius: Metrics.radius))
                .onChange(of: blacklist) { _, _ in blacklistState = .idle }
            Text(Copy.Booru.blacklistHint).font(CobaltType.captionSmall).foregroundStyle(CobaltColor.caption)
            HStack {
                Button(Copy.Booru.saveBlacklist) {
                    Task {
                        let ok = await store.update(BooruSettingsPatch(blacklist: blacklist))
                        blacklistState = ok ? .saved : .failed
                    }
                }
                .buttonStyle(.cobaltSecondary(fullWidth: false, compact: true))
                .disabled(blacklist == (store.settings?.blacklist ?? ""))
                switch blacklistState {
                case .saved: Text(Copy.Booru.saved).font(CobaltType.caption).foregroundStyle(CobaltColor.success)
                case .failed: Text(Copy.Booru.saveFailed).font(CobaltType.caption).foregroundStyle(CobaltColor.errorText)
                case .idle: EmptyView()
                }
            }
        }
        .padding(12)
        .card()
    }

    // MARK: layout

    private func section<C: View>(_ title: String, @ViewBuilder content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(CobaltType.caption).foregroundStyle(CobaltColor.caption).padding(.horizontal, 4).padding(.top, 12)
            content()
        }
    }

    private func row<C: View>(_ title: String, detail: String?, @ViewBuilder trailing: () -> C) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(CobaltType.body)
                if let detail { Text(detail).font(CobaltType.captionSmall).foregroundStyle(CobaltColor.caption) }
            }
            Spacer(minLength: 8)
            trailing()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(minHeight: Metrics.hit)
    }
}

private extension View {
    func card() -> some View {
        background(CobaltColor.surface, in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(CobaltColor.hairline))
    }
}

/// The owner's Danbooru login and API key (APP-API-CONTRACT 72.12), kept in this device's keychain only. Used by "find on
/// booru" to ask Danbooru's own picture search; saving checks the key against Danbooru first.
private struct DanbooruKeyCard: View {
    @State private var login = ""
    @State private var key = ""
    @State private var saved: DanbooruAccount? = DanbooruAccount.load()
    @State private var state: KeyState = .idle

    private enum KeyState: Equatable { case idle, checking, ok(String), failed(String) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let saved {
                HStack {
                    Label(Copy.DanbooruKey.signedIn(saved.login), systemImage: "checkmark.seal.fill").foregroundStyle(CobaltColor.success)
                    Spacer()
                    Button(Copy.DanbooruKey.remove, role: .destructive) {
                        try? DanbooruAccount.clear()
                        self.saved = nil
                        state = .idle
                    }
                    .buttonStyle(.cobaltSecondary(fullWidth: false, compact: true))
                }
                .font(CobaltType.body)
            } else {
                TextField(Copy.DanbooruKey.login, text: $login)
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    #endif
                    .textContentType(.username)
                    .padding(8)
                    .background(CobaltColor.row, in: RoundedRectangle(cornerRadius: Metrics.radius))
                SecureField(Copy.DanbooruKey.key, text: $key)
                    .textContentType(.password)
                    .padding(8)
                    .background(CobaltColor.row, in: RoundedRectangle(cornerRadius: Metrics.radius))
                HStack {
                    Button(Copy.DanbooruKey.save) { Task { await save() } }
                        .buttonStyle(.cobaltSecondary(fullWidth: false, compact: true))
                        .disabled(login.isEmpty || key.isEmpty || state == .checking)
                    if state == .checking { ProgressView().controlSize(.small) }
                    if case .failed(let why) = state {
                        Text(why).font(CobaltType.caption).foregroundStyle(CobaltColor.errorText)
                    }
                }
            }
            Text(Copy.DanbooruKey.hint).font(CobaltType.captionSmall).foregroundStyle(CobaltColor.caption)
        }
        .padding(12)
        .background(CobaltColor.surface, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(CobaltColor.hairline))
    }

    private func save() async {
        let account = DanbooruAccount(login: login, apiKey: key)
        state = .checking
        do {
            let name = try await account.check()
            try account.save()
            saved = DanbooruAccount(login: name, apiKey: account.apiKey)
            key = ""
            state = .ok(name)
        } catch CobaltError.network {
            state = .failed(Copy.DanbooruKey.offline)
        } catch {
            state = .failed(Copy.DanbooruKey.refused)
        }
    }
}

