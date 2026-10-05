import CobaltKit
import SwiftUI

/// Settings: the server and its key (paste only, no text fields), how webps are made, how it feels.
/// A native grouped `Form` with `LabeledContent` rows, a `Picker` and `Toggle`s; the paste actions
/// are buttons inside their rows. A tab on iPhone and iPad, the `Settings` scene (⌘,) on the Mac.
struct SettingsScreen: View {
    let model: AppModel

    @State private var keyError: String?
    @State private var serverError: String?
    @State private var confirmRemove = false
    @State private var confirmClear = false
    @State private var featuresOpen = false
    /// A limit below what is stored asks first: the choice waits here for the dialog's answer.
    @State private var pendingLimit: StorageLimit?
    @State private var pendingFree: Int64 = 0
    @Environment(\.scenePhase) private var scenePhase

    private var settings: CobaltKit.Settings { model.settings }
    private var summary: ServerSummary { model.serverSummary }

    var body: some View {
        Form {
            serverSection
            makingSection
            shareSheetSection
            storageSection
            PhotosSettingsSection(model: model)
            liveSection
            feelSection
        }
        .formStyle(.grouped)
        .labelStyle(SettingsRowLabelStyle())
        .font(CobaltType.body)
        .navigationTitle(Copy.settings)
        // back from system Settings (the owner may have changed photos access there) and first appearance
        .task { await model.photosSync.refresh() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await model.photosSync.refresh() } }
        }
        .confirmationDialog(Copy.removeVideosTitle, isPresented: $confirmRemove, titleVisibility: .visible) {
            Button(Copy.remove, role: .destructive) { Task { await model.store.dropFilesKeepingPosters() } }
            Button(Copy.keep, role: .cancel) { settings.keepVideosOnDevice = true }
        } message: {
            Text(Copy.removeVideosMessage)
        }
    }

    // MARK: sections

    private var serverSection: some View {
        Section {
            row(Copy.api, Symbol.api) { value(summary.host) }
            row(Copy.thisServer, Symbol.server) { value(Copy.serverKind(summary, checking: model.isCheckingServer)) }
            if summary.kind != .unreachable, summary.kind != .notCobalt {
                DisclosureGroup(isExpanded: $featuresOpen) {
                    ForEach(Copy.serverFeatures(model.capabilities)) { feature in
                        LabeledContent {
                            Text(feature.on ? Copy.featureOn : Copy.featureOff)
                                .font(Font.cobalt(12.5))
                                .foregroundStyle(feature.on ? Color.primary : Color.secondary)
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(feature.name)
                                Text(feature.detail).font(Font.cobalt(11.5)).foregroundStyle(.secondary)
                            }
                        }
                        .accessibilityElement(children: .combine)
                    }
                } label: {
                    Label(Copy.serverFeaturesTitle, systemImage: Symbol.quality)
                }
            }
            row(Copy.apiKey, Symbol.key) {
                if !settings.hasAPIKey {
                    value(Copy.noKey)
                } else if summary.key == .invalid {
                    Text(Copy.keyRevoked).font(Font.cobalt(12.5)).foregroundStyle(CobaltColor.errorText)
                } else {
                    value(summary.keyName.map { Copy.keyLine(name: $0) } ?? Copy.keySet).lineLimit(1).minimumScaleFactor(0.8)
                }
            }
            Button(settings.hasAPIKey ? Copy.pasteNewKey : Copy.pasteKey, systemImage: Symbol.paste) { pasteKey() }
            if let keyError { problem(keyError) }
            Button(Copy.pasteServerURL, systemImage: Symbol.paste) { pasteServer() }
            Button(Copy.reset, systemImage: Symbol.reset, role: .destructive) { resetServer() }
                .disabled(settings.serverURL == CobaltKit.Settings.defaultServer)
            if let serverError { problem(serverError) }
        } header: {
            header(Copy.groupServer)
        } footer: {
            footer(Copy.keyFootnote)
        }
    }

    private var makingSection: some View {
        Section {
            Picker(selection: Binding(get: { settings.webpQuality }, set: { settings.webpQuality = $0 })) {
                ForEach(WebpQuality.allCases, id: \.self) { q in
                    Text(Copy.qualityName(q)).tag(q)
                }
            } label: {
                Label(Copy.webpQuality, systemImage: Symbol.quality)
            }
        } header: {
            header(Copy.groupMaking)
        }
    }

    /// "share sheet": whether sharing a link to cobalt carries on by itself after a short wait.
    /// iPhone and iPad only: the Mac has no share sheet.
    @ViewBuilder
    private var shareSheetSection: some View {
        #if os(iOS)
        Section {
            Toggle(isOn: Binding(get: { settings.autoContinue }, set: { settings.autoContinue = $0 })) {
                Label(Copy.Sync.autoContinue, systemImage: Symbol.Sync.autoContinue)
            }
            Picker(selection: Binding(get: { settings.autoContinueSeconds }, set: { settings.autoContinueSeconds = $0 })) {
                ForEach(CobaltKit.Settings.autoContinueChoices, id: \.self) { seconds in
                    Text(Copy.Sync.seconds(seconds)).tag(seconds)
                }
            } label: {
                Label(Copy.Sync.wait, systemImage: Symbol.Sync.wait)
            }
            .pickerStyle(.menu)
            .disabled(!settings.autoContinue)
        } header: {
            header(Copy.Sync.shareGroup)
        } footer: {
            footer(Copy.Sync.autoContinueFooter)
        }
        #endif
    }

    /// "on this iphone": keep videos, how much, what is stored, and clear (CONTRACT-LIVE.md 4.3).
    private var storageSection: some View {
        let usage = model.store.usage
        let limit = model.store.limitBytes
        return Section {
            Toggle(isOn: Binding(
                get: { settings.keepVideosOnDevice },
                set: { newValue in
                    settings.keepVideosOnDevice = newValue
                    if !newValue, model.store.usage.count > 0 { confirmRemove = true }
                })) {
                Label(Copy.keepVideos, systemImage: Symbol.device)
            }
            Picker(selection: Binding(get: { settings.storageLimit }, set: chooseLimit)) {
                ForEach(StorageLimit.allCases, id: \.self) { choice in
                    Text(Copy.Storage.limitName(choice)).tag(choice)
                }
            } label: {
                Label(Copy.Storage.limit, systemImage: Symbol.storage)
            }
            .pickerStyle(.menu)
            .disabled(!settings.keepVideosOnDevice)
            .confirmationDialog(
                Copy.Storage.lowerTitle(freeing: pendingFree),
                isPresented: Binding(get: { pendingLimit != nil }, set: { if !$0 { pendingLimit = nil } }),
                titleVisibility: .visible
            ) {
                Button(Copy.remove, role: .destructive) {
                    if let choice = pendingLimit { applyLimit(choice) }
                    pendingLimit = nil
                }
                Button(Copy.keep, role: .cancel) { pendingLimit = nil }
            }
            VStack(alignment: .leading, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Label(Copy.Storage.stored, systemImage: Symbol.offlineOn)
                    Text(Copy.Storage.usage(count: usage.count, bytes: usage.bytes, limit: limit))
                        .font(Font.cobalt(12.5))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .padding(.leading, 34)
                }
                if let limit, limit > 0 {
                    ProgressView(value: min(Double(usage.bytes), Double(limit)), total: Double(limit))
                        .progressViewStyle(.linear)
                        .tint(CobaltColor.text)
                        .accessibilityHidden(true)
                }
            }
            Button(Copy.Storage.clear, systemImage: Symbol.clearOffline, role: .destructive) { confirmClear = true }
                .disabled(model.store.videos.isEmpty)
                .confirmationDialog(Copy.Storage.clearTitle, isPresented: $confirmClear, titleVisibility: .visible) {
                    Button(Copy.remove, role: .destructive) { Task { await model.store.clearAll() } }
                    Button(Copy.keep, role: .cancel) {}
                } message: {
                    Text(Copy.Storage.clearMessage)
                }
        } header: {
            header(Copy.Storage.group)
        } footer: {
            footer(Copy.Storage.footer)
        }
    }

    /// "live activity": whether the island follows a run while cobalt is closed. Hidden on the Mac.
    @ViewBuilder
    private var liveSection: some View {
        if let status = Copy.Live.status(model.liveStatus) {
            Section {
                row(Copy.Live.row, Symbol.liveActivity) { value(status) }
            } footer: {
                footer(Copy.Live.rowFooter)
            }
        }
    }

    private var feelSection: some View {
        Section {
            Toggle(isOn: Binding(get: { settings.haptics }, set: { settings.haptics = $0 })) {
                Label(Copy.haptics, systemImage: Symbol.haptics)
            }
            row(Copy.motion, Symbol.motion) { value(Copy.motionFollows) }
        } header: {
            header(Copy.groupFeel)
        } footer: {
            footer(Copy.settingsFooter)
        }
    }

    /// A settings row: icon first, the title, and the value on the trailing edge.
    private func row<V: View>(_ title: String, _ symbol: String, @ViewBuilder value: () -> V) -> some View {
        LabeledContent {
            value()
        } label: {
            Label(title, systemImage: symbol)
        }
    }

    // MARK: pieces

    private func header(_ text: String) -> some View {
        Text(text).font(CobaltType.caption).textCase(nil)
    }

    private func footer(_ text: String) -> some View {
        Text(text).font(CobaltType.captionSmall).lineSpacing(2)
    }

    private func problem(_ text: String) -> some View {
        Text(text).font(Font.cobalt(12.5)).foregroundStyle(CobaltColor.errorText)
    }

    private func value(_ text: String) -> some View {
        Text(text)
            .font(Font.cobalt(12.5))
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.trailing)
            .lineLimit(2)
    }

    // MARK: actions

    /// A lower limit that would remove videos asks first (the picker snaps back unless confirmed).
    private func chooseLimit(_ choice: StorageLimit) {
        let free = model.store.bytesToFree(for: choice.bytes)
        if free > 0 {
            pendingFree = free
            pendingLimit = choice
        } else {
            applyLimit(choice)
        }
    }

    private func applyLimit(_ choice: StorageLimit) {
        settings.storageLimit = choice
        Task { await model.store.setLimit(choice.bytes) }
    }

    private func pasteKey() {
        keyError = nil
        guard let text = Pasteboard.string() else { keyError = Copy.notAKey; return }
        Task {
            do {
                try await model.setAPIKey(pasted: text)
            } catch {
                // a real key this device would not store is not "not a key"
                keyError = (error as? KeyInputError) == .couldNotSave ? Copy.keyNotSaved : Copy.notAKey
            }
        }
    }

    private func pasteServer() {
        serverError = nil
        guard let text = Pasteboard.string() else { serverError = Copy.notAURL; return }
        Task {
            do { try await model.setServer(pasted: text) } catch { serverError = Copy.notAURL }
        }
    }

    private func resetServer() {
        serverError = nil
        settings.resetServer()
        Task {
            do { try await model.setServer(pasted: CobaltKit.Settings.defaultServer.absoluteString) } catch { serverError = Copy.notAURL }
        }
    }
}

/// Icon first in a fixed-width column, so every row's title lines up (system Settings style).
private struct SettingsRowLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 10) {
            configuration.icon.frame(width: 24)
            configuration.title
        }
    }
}

#if DEBUG
#Preview("settings · happy") {
    PreviewHost(.happy, tab: .settings) { SettingsScreen(model: $0) }
}
#Preview("settings · revoked key") {
    PreviewHost(.revokedKey, tab: .settings) { SettingsScreen(model: $0) }
}
#Preview("settings · plain cobalt") {
    PreviewHost(.plainCobalt, tab: .settings) { SettingsScreen(model: $0) }
}
#Preview("settings · legacy fork") {
    PreviewHost(.legacyFork, tab: .settings) { SettingsScreen(model: $0) }
}
#Preview("settings · empty store") {
    PreviewHost(.emptyOrbit, tab: .settings) { SettingsScreen(model: $0) }
}
#endif
