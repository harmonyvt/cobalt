import CobaltKit
import SwiftUI

/// "library sync": the switch for the on-device library (the sync engine) and a line that says what it
/// is doing. The switch starts and stops the engine at once (`LibraryModel.setSyncEnabled`); an error
/// stays here, with Retry and Dismiss, until the owner dismisses it or a later pass succeeds.
struct LibrarySyncSettingsSection: View {
    let model: AppModel

    private var settings: CobaltKit.Settings { model.settings }

    var body: some View {
        Section {
            Toggle(isOn: Binding(
                get: { settings.syncEngine },
                set: { model.library.setSyncEnabled($0) })) {
                Label(Copy.LibrarySync.toggle, systemImage: Symbol.LibrarySync.toggle)
            }
            .accessibilityIdentifier("library-sync-toggle")
            if settings.syncEngine, let status = model.library.syncStatus {
                statusRow(status)
            }
        } header: {
            Text(Copy.LibrarySync.group).font(CobaltType.caption).textCase(nil)
        } footer: {
            Text(Copy.LibrarySync.footer).font(CobaltType.captionSmall).lineSpacing(2)
        }
    }

    @ViewBuilder
    private func statusRow(_ status: SyncStatusSnapshot) -> some View {
        switch status.state {
        case .error(let code, let pending, let nextRetryAt):
            VStack(alignment: .leading, spacing: 8) {
                Label(Copy.LibrarySync.errorTitle, systemImage: Symbol.LibrarySync.error)
                    .font(CobaltType.bodyMedium)
                Text(Copy.LibrarySync.errorDetail(code: code))
                    .font(Font.cobalt(12.5))
                    .foregroundStyle(.secondary)
                if pending > 0 {
                    Text(Copy.LibrarySync.waiting(pending))
                        .font(Font.cobalt(12.5))
                        .foregroundStyle(.secondary)
                }
                if let nextRetryAt, nextRetryAt > Date() {
                    Text("\(Copy.LibrarySync.retryingIn) \(nextRetryAt, style: .timer)")
                        .font(Font.cobalt(12.5))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                HStack(spacing: 16) {
                    Button(Copy.LibrarySync.retry) { Task { await model.library.retrySync() } }
                        .accessibilityIdentifier("library-sync-retry")
                    Button(Copy.LibrarySync.dismiss) { model.library.dismissSyncError() }
                        .accessibilityIdentifier("library-sync-dismiss")
                }
                .buttonStyle(.borderless)
                .font(CobaltType.bodyMedium)
            }
            .padding(.vertical, 2)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("library-sync-error")
        case .idle:
            line(Symbol.LibrarySync.ok, idleText(status.lastSyncedAt))
        case .syncing:
            line(Symbol.LibrarySync.toggle, Text(Copy.LibrarySync.statusSyncing))
        case .repulling:
            line(Symbol.LibrarySync.toggle, Text(Copy.LibrarySync.statusRepulling))
        case .offline(let pending):
            line(Symbol.LibrarySync.offline, Text(Copy.LibrarySync.statusOffline(pending: pending)))
        case .disabled:
            line(Symbol.LibrarySync.error, Text(Copy.LibrarySync.statusDisabled))
        }
    }

    private func idleText(_ at: Date?) -> Text {
        guard let at else { return Text(Copy.LibrarySync.statusIdle) }
        return Text("\(Copy.LibrarySync.statusIdle) · \(at, format: .relative(presentation: .numeric))")
    }

    private func line(_ symbol: String, _ text: Text) -> some View {
        Label { text } icon: { Image(systemName: symbol) }
            .font(Font.cobalt(12.5))
            .foregroundStyle(.secondary)
            .accessibilityIdentifier("library-sync-status")
    }
}

#if DEBUG
#Preview("settings · library sync") {
    PreviewHost(.happy, tab: .settings) { model in
        Form { LibrarySyncSettingsSection(model: model) }.formStyle(.grouped)
    }
}
#endif
