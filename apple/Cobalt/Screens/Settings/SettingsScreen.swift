import CobaltKit
import SwiftUI

/// Settings: the server and its key (paste only, no text fields), how webps are made, how it feels.
/// A native grouped `Form` with `LabeledContent` rows, a `Picker` and `Toggle`s; the paste actions
/// are buttons inside their rows. A tab on iPhone and iPad, the `Settings` scene (⌘,) on the Mac.
struct SettingsScreen: View {
    let model: AppModel

    @State private var keyError: String?
    @State private var serverError: String?
    @State private var confirmClear = false
    @State private var featuresOpen = false
    /// A limit below what is stored asks first: the choice waits here for the dialog's answer.
    @State private var pendingLimit: StorageLimit?
    @State private var pendingFree: Int64 = 0
    @Environment(\.scenePhase) private var scenePhase
    #if os(iOS)
    @Environment(\.openURL) private var openURL
    #endif

    private var settings: CobaltKit.Settings { model.settings }
    private var summary: ServerSummary { model.serverSummary }

    var body: some View {
        Form {
            serverSection
            makingSection
            SharingSettingsSection(model: model)
            shareSheetSection
            storageSection
            PhotosSettingsSection(model: model)
            FolderSettingsSection(model: model)
            liveSection
            TelemetrySettingsSection(model: model)
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
            Toggle(isOn: Binding(get: { settings.shareFullSheet }, set: { settings.shareFullSheet = $0 })) {
                Label(Copy.Sync.fullSheet, systemImage: "rectangle.expand.vertical")
            }
            // The countdown only runs on a sheet that opened as the full sheet (CONTRACT-SHARE-QUICK
            // decision 7): with the quick card it has nothing to count down.
            Toggle(isOn: Binding(get: { settings.autoContinue }, set: { settings.autoContinue = $0 })) {
                Label(Copy.Sync.autoContinue, systemImage: Symbol.Sync.autoContinue)
            }
            .disabled(!settings.shareFullSheet)
            Picker(selection: Binding(get: { settings.autoContinueSeconds }, set: { settings.autoContinueSeconds = $0 })) {
                ForEach(CobaltKit.Settings.autoContinueChoices, id: \.self) { seconds in
                    Text(Copy.Sync.seconds(seconds)).tag(seconds)
                }
            } label: {
                Label(Copy.Sync.wait, systemImage: Symbol.Sync.wait)
            }
            .pickerStyle(.menu)
            .disabled(!settings.shareFullSheet || !settings.autoContinue)
        } header: {
            header(Copy.Sync.shareGroup)
        } footer: {
            footer(settings.shareFullSheet ? Copy.Sync.autoContinueFooter : Copy.Sync.quickFooter)
        }
        #endif
    }

    /// "on this iphone" (CONTRACT-OFFLINE decision 11): keep new saves offline, what is offline, what downloads,
    /// the cache and its limit, and clear the cache. Turning the toggle off deletes nothing: it is a policy for
    /// new saves.
    private var storageSection: some View {
        let usage = model.store.offlineUsage
        let limit = model.store.limitBytes
        let downloads = model.offlineDownloads.summary
        return Section {
            if model.store.canKeep {
                Toggle(isOn: Binding(get: { settings.keepVideosOnDevice }, set: { settings.keepVideosOnDevice = $0 })) {
                    Label(Copy.Offline.keepNewSaves, systemImage: Symbol.device)
                }
                row(Copy.Offline.rowOffline, Symbol.offlineAll) {
                    value(Copy.Storage.usage(count: usage.offline.mediaCount, bytes: usage.offline.bytes, limit: nil))
                        .monospacedDigit()
                }
                #if os(iOS)
                if let url = model.showInFilesURL(nil) {
                    Button(Copy.Offline.openInFiles, systemImage: Symbol.showInFiles) { openURL(url) }
                }
                #endif
                if downloads.left > 0 {
                    row(Copy.Offline.rowDownloading, Symbol.keepOffline) {
                        value(Copy.Offline.queueLine(left: downloads.left, bytes: downloads.bytes, total: downloads.total))
                            .monospacedDigit()
                    }
                    Button(Copy.Offline.stopAll, systemImage: Symbol.stopDownloading) { stopAll() }
                }
            }
            Picker(selection: Binding(get: { settings.storageLimit }, set: chooseLimit)) {
                ForEach(StorageLimit.allCases, id: \.self) { choice in
                    Text(Copy.Storage.limitName(choice)).tag(choice)
                }
            } label: {
                Label(Copy.Storage.limit, systemImage: Symbol.storage)
            }
            .pickerStyle(.menu)
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
                    Label(Copy.Offline.rowCache, systemImage: Symbol.cache)
                    Text(Copy.Storage.usage(count: usage.cache.mediaCount, bytes: usage.cache.bytes, limit: limit))
                        .font(Font.cobalt(12.5))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .padding(.leading, 34)
                }
                if let limit, limit > 0 {
                    ProgressView(value: min(Double(usage.cache.bytes), Double(limit)), total: Double(limit))
                        .progressViewStyle(.linear)
                        .tint(CobaltColor.text)
                        .accessibilityHidden(true)
                }
            }
            .accessibilityElement(children: .combine)
            Button(Copy.Offline.clearCache, systemImage: Symbol.clearOffline, role: .destructive) { confirmClear = true }
                .disabled(usage.cache.count == 0)
                .confirmationDialog(Copy.Offline.clearCacheTitle, isPresented: $confirmClear, titleVisibility: .visible) {
                    Button(Copy.Offline.clear, role: .destructive) { Task { await model.store.clearCache() } }
                    Button(Copy.keep, role: .cancel) {}
                } message: {
                    Text(Copy.Offline.clearCacheMessage)
                }
        } header: {
            header(Copy.Storage.group)
        } footer: {
            footer(Copy.Offline.footer)
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

    /// "stop all": every media with a download running or queued. CONTRACT-OFFLINE section 5 pins no stop-all, so
    /// this goes through `stopDownloading(_:)` for each media the model knows (the device's, and the library's).
    private func stopAll() {
        var seen = Set<String>()
        let items = model.store.media.map { model.mediaItem(for: $0) } + model.library.posts.map { model.mediaItem(for: $0) }
        for item in items where seen.insert(item.id).inserted {
            if OfflinePlan(item: item, model: model).active { model.stopDownloading(item) }
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
#Preview("settings · offline") {
    PreviewHost(.offline, tab: .settings) { SettingsScreen(model: $0) }
}
#Preview("settings · empty store") {
    PreviewHost(.emptyOrbit, tab: .settings) { SettingsScreen(model: $0) }
}
#endif
