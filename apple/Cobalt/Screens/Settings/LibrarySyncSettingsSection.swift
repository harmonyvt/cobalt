import CobaltKit
import SwiftUI

/// "library sync": the switch for the on-device library (the sync engine). The engine is started once
/// at launch, so the switch only stores the choice; a line says to reopen the app while the stored
/// choice and the running engine differ.
struct LibrarySyncSettingsSection: View {
    let model: AppModel

    private var settings: CobaltKit.Settings { model.settings }
    /// The engine this launch started (it has a status exactly when it is running).
    private var running: Bool { model.library.syncStatus != nil }

    var body: some View {
        Section {
            Toggle(isOn: Binding(
                get: { settings.syncEngine },
                set: { settings.syncEngine = $0 })) {
                Label(Copy.LibrarySync.toggle, systemImage: Symbol.LibrarySync.toggle)
            }
            .accessibilityIdentifier("library-sync-toggle")
            if settings.syncEngine != running {
                Label(
                    settings.syncEngine ? Copy.LibrarySync.turnsOnNextOpen : Copy.LibrarySync.turnsOffNextOpen,
                    systemImage: Symbol.LibrarySync.restart)
                    .font(Font.cobalt(12.5))
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("library-sync-restart")
            }
        } header: {
            Text(Copy.LibrarySync.group).font(CobaltType.caption).textCase(nil)
        } footer: {
            Text(Copy.LibrarySync.footer).font(CobaltType.captionSmall).lineSpacing(2)
        }
    }
}

#if DEBUG
#Preview("settings · library sync") {
    PreviewHost(.happy, tab: .settings) { model in
        Form { LibrarySyncSettingsSection(model: model) }.formStyle(.grouped)
    }
}
#endif
