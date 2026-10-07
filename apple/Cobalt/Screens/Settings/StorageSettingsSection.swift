import CobaltKit
import SwiftUI

/// "on this iphone" / "on this mac" (CONTRACT-OFFLINE decision 11 and 13.10): keep new saves offline, what is offline,
/// what downloads, the cache and its limit, and clear the cache. Turning the toggle off deletes nothing: it is a policy for
/// new saves.
///
/// On the Mac this is the one section for everything on this computer, in the contract's order: the toggle, the folder
/// (where it is, choose, show in finder, back to the default, what is wrong with it), the offline row, the status of
/// "saves from other devices", the download queue, the cache limit, the cache, clear cache, and the footer. The old
/// "folder" section is folded in (`MacFolderRows`).
struct StorageSettingsSection: View {
    let model: AppModel

    @State private var confirmClear = false
    /// A limit below what is stored asks first: the choice waits here for the dialog's answer.
    @State private var pendingLimit: StorageLimit?
    @State private var pendingFree: Int64 = 0
    #if os(iOS)
    @Environment(\.openURL) private var openURL
    #endif

    private var settings: CobaltKit.Settings { model.settings }

    var body: some View {
        let usage = model.store.offlineUsage
        let limit = model.store.limitBytes
        let downloads = model.offlineDownloads.summary
        Section {
            if model.store.canKeep {
                Toggle(isOn: Binding(get: { settings.keepVideosOnDevice }, set: { model.setKeepNewSaves($0) })) {
                    Label(Copy.Offline.keepNewSaves, systemImage: Symbol.device)
                }
                MacFolderRows(model: model)
                row(Copy.Offline.rowOffline, Symbol.offlineAll) {
                    value(offlineLine(usage.offline)).monospacedDigit()
                }
                #if os(iOS)
                if let url = model.showInFilesURL(nil) {
                    Button(Copy.Offline.openInFiles, systemImage: Symbol.showInFiles) { openURL(url) }
                }
                #endif
                pullRow
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
                    Text(cacheLine(usage.cache, limit: limit))
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
            Text(Copy.Storage.group).font(CobaltType.caption).textCase(nil)
        } footer: {
            Text(Copy.Offline.footer).font(CobaltType.captionSmall).lineSpacing(2)
        }
    }

    // MARK: rows

    /// `24 files · 3.1 GB` on the Mac (a gallery is a folder of files); `24 videos · 3.1 GB` elsewhere.
    private func offlineLine(_ usage: StorageUsage) -> String {
        #if os(macOS)
        Copy.Offline.filesUsage(count: usage.count, bytes: usage.bytes, limit: nil)
        #else
        Copy.Storage.usage(count: usage.mediaCount, bytes: usage.bytes, limit: nil)
        #endif
    }

    /// `3 files · 210 MB of 5 GB` on the Mac; `3 videos · 210 MB of 5 GB` elsewhere.
    private func cacheLine(_ usage: StorageUsage, limit: Int64?) -> String {
        #if os(macOS)
        Copy.Offline.filesUsage(count: usage.count, bytes: usage.bytes, limit: limit)
        #else
        Copy.Storage.usage(count: usage.mediaCount, bytes: usage.bytes, limit: limit)
        #endif
    }

    /// "saves from other devices" (13.8, 13.10): when the pull last looked, what it is fetching, or why it waits.
    /// The Mac only (`SavePull.isAvailable`). The age of a check redraws every half minute.
    @ViewBuilder
    private var pullRow: some View {
        let status = model.savePull.status
        if status.available {
            row(Copy.Folder.pullRow, Symbol.Folder.pull) {
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    Text(Self.pullLine(status, now: context.date))
                        .font(Font.cobalt(12.5))
                        .foregroundStyle(status.paused == .auth ? CobaltColor.errorText : Color.secondary)
                        .multilineTextAlignment(.trailing)
                        .lineLimit(2)
                        .monospacedDigit()
                }
            }
        }
    }

    /// The pull's state in the contract's words.
    static func pullLine(_ status: SavePull.Status, now: Date) -> String {
        switch status.paused {
        case .keepOff: return Copy.Folder.pullKeepOff
        case .folderUnreachable: return Copy.Folder.pullFolderAway
        case .auth: return Copy.Folder.pullAuth
        case .noServer: return Copy.Folder.pullNoServer
        case nil: break
        }
        if status.pulling > 0 { return Copy.Folder.pullDownloading(status.pulling) }
        guard let last = status.lastChecked else { return Copy.Folder.pullNotChecked }
        return Copy.Folder.pullChecked(Copy.Folder.ago(seconds: now.timeIntervalSince(last)))
    }

    /// A settings row: icon first, the title, and the value on the trailing edge.
    private func row<V: View>(_ title: String, _ symbol: String, @ViewBuilder value: () -> V) -> some View {
        LabeledContent {
            value()
        } label: {
            Label(title, systemImage: symbol)
        }
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
}
