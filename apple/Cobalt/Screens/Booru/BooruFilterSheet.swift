import CobaltKit
import SwiftUI

// The booru filters (APP-API-CONTRACT 72): this device's content level (general, sensitive, questionable; raising it asks
// for Face ID), presets, the theme modes, sort and refine, the blacklist, and the one block that is never a setting.

struct BooruFilterSheet: View {
    let model: AppModel

    @Environment(\.dismiss) private var dismiss
    @State private var blacklist = ""
    @State private var blacklistState: SaveState = .idle
    @State private var busy = false

    private enum SaveState { case idle, saved, failed }

    private var store: BooruStore { model.booru }
    private var level: BooruLevel { store.settings?.level ?? .general }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    section(Copy.Booru.contentLevel) { levelCard }
                    Text(Copy.Booru.thisDevice).font(CobaltType.captionSmall).foregroundStyle(CobaltColor.caption).padding(.horizontal, 4)
                    section(Copy.Booru.presets) { presets }
                    section(Copy.Booru.themes) { themes }
                    Text(Copy.Booru.themesHint).font(CobaltType.captionSmall).foregroundStyle(CobaltColor.caption).padding(.horizontal, 4)
                    section(Copy.Booru.alwaysHidden) {
                        row(Copy.Booru.hardBlock, detail: Copy.Booru.hardBlockDetail) {
                            Image(systemName: Symbol.Booru.lock).foregroundStyle(CobaltColor.errorText)
                        }
                        .card()
                    }
                    section(Copy.Booru.refine) { refine }
                    section(Copy.Booru.blacklist) { blacklistEditor }
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
    }

    // MARK: level

    private var levelCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                ForEach(BooruLevel.allCases, id: \.self) { l in
                    Button { setLevel(l) } label: {
                        VStack(spacing: 3) {
                            Circle().fill(BooruLevelColor.of(l)).frame(width: 10, height: 10)
                            Text(Copy.Booru.level(l)).font(CobaltType.bodyMedium).lineLimit(1).minimumScaleFactor(0.8)
                            Text(Copy.Booru.levelDetail(l)).font(CobaltType.captionSmall).foregroundStyle(l == level ? CobaltColor.onText.opacity(0.75) : CobaltColor.caption)
                                .lineLimit(1).minimumScaleFactor(0.8)
                        }
                        .padding(.vertical, 10)
                        .frame(maxWidth: .infinity, minHeight: 64)
                        .foregroundStyle(l == level ? CobaltColor.onText : CobaltColor.text)
                        .background(l == level ? CobaltColor.text : CobaltColor.elevated, in: RoundedRectangle(cornerRadius: Metrics.radius))
                        .contentShape(RoundedRectangle(cornerRadius: Metrics.radius))
                    }
                    .buttonStyle(.plain)
                    .disabled(busy)
                }
            }
            Text(Copy.Booru.noExplicit).font(CobaltType.captionSmall).foregroundStyle(CobaltColor.caption)
        }
        .padding(12)
        .card()
    }

    /// Lowering is free; raising asks for the device owner first.
    private func setLevel(_ l: BooruLevel, themes: [String: BooruThemeMode]? = nil) {
        guard l != level || themes != nil else { return }
        Task {
            busy = true
            defer { busy = false }
            if l > level {
                guard await HiddenLock.authenticate(reason: Copy.Booru.raiseReason) == .unlocked else { return }
            }
            await store.update(BooruSettingsPatch(level: l, themes: themes))
        }
    }

    // MARK: presets

    private var presets: some View {
        let list: [(String, String, BooruLevel, [String: BooruThemeMode])] = [
            (Copy.Booru.presetSafe, Copy.Booru.presetSafeDetail, .general, ["violence": .hide, "horror": .hide]),
            (Copy.Booru.presetCozy, Copy.Booru.presetCozyDetail, .sensitive, ["revealing": .show, "suggestive": .show, "violence": .hide, "horror": .hide]),
            (Copy.Booru.presetSpicy, Copy.Booru.presetSpicyDetail, .questionable,
             ["revealing": .show, "suggestive": .show, "partial": .blur, "nudity": .hide, "violence": .hide, "horror": .hide]),
        ]
        return LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 6)], spacing: 6) {
            ForEach(list, id: \.0) { p in
                Button { setLevel(p.2, themes: p.3) } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(p.0).font(CobaltType.bodySemibold)
                        Text(p.1).font(CobaltType.captionSmall).foregroundStyle(CobaltColor.caption).multilineTextAlignment(.leading)
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, minHeight: 64, alignment: .topLeading)
                    .background(CobaltColor.surface, in: RoundedRectangle(cornerRadius: 14))
                    .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(level == p.2 ? CobaltColor.text : CobaltColor.hairline))
                    .contentShape(RoundedRectangle(cornerRadius: 14))
                }
                .buttonStyle(.plain)
                .disabled(busy)
            }
        }
    }

    // MARK: themes

    @ViewBuilder private var themes: some View {
        if let s = store.settings {
            VStack(spacing: 0) {
                ForEach(Array(s.themeList.enumerated()), id: \.element.id) { i, theme in
                    if i > 0 { Divider().overlay(CobaltColor.hairline) }
                    row(theme.label, detail: theme.minLevel > level ? Copy.Booru.aboveLevel : theme.detail) {
                        Picker(theme.label, selection: Binding(
                            get: { s.mode(theme) },
                            set: { m in Task { await store.update(BooruSettingsPatch(themes: [theme.id: m])) } })
                        ) {
                            ForEach(BooruThemeMode.allCases, id: \.self) { Text(Copy.Booru.mode($0)).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .frame(width: 168)
                    }
                    .opacity(theme.minLevel > level ? 0.55 : 1)
                }
            }
            .card()
        } else {
            Text(Copy.Booru.loading).font(CobaltType.caption).foregroundStyle(CobaltColor.caption)
        }
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
