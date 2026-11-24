import CobaltKit
import SwiftUI

/// Settings (apple 04-PHASE4 4.1): a short hub of four groups, each a page pushed from it (`SettingsGroup`): account &
/// server, downloads & storage, media & webp, live & integrations. Every section of the old flat list is on one of them.
///
/// Where it lives decides what is around it, so it works in each of these without help:
/// - pushed into a navigation stack (the iPad's settings tab, the iPhone's "more" list): the hub is the stack's content;
/// - inside the stack of a sheet (the gear in the iPhone's header): `NavigationStack { SettingsScreen(model:) }` plus its
///   own Done button; the group pages push into that stack and the back button returns to the hub;
/// - the Mac's `Settings` scene (⌘,) and the main window's detail, which have no stack: the Mac wraps the hub in its own.
/// The group rows are destination links, not value links, so they work in a stack that holds a typed path of its own.
struct SettingsScreen: View {
    let model: AppModel

    @State private var account = AccountSettingsState()
    #if DEBUG
    /// `-previewSettingsGroup account|downloads|media|live` (simulator evidence): opens on that group's page.
    @State private var openGroup: SettingsGroup? = UserDefaults.standard.string(forKey: "previewSettingsGroup").flatMap(SettingsGroup.init(rawValue:))
    #endif
    @Environment(\.lifecycle) private var lifecycle

    var body: some View {
        #if os(macOS)
        NavigationStack { content }
        #else
        content
        #endif
    }

    @ViewBuilder
    private var content: some View {
        #if DEBUG
        if let state = StorageDebug.state {
            StorageDebugScreen(model: model, state: state)
        } else {
            hub
        }
        #else
        hub
        #endif
    }

    private var hub: some View {
        Form {
            Section {
                ForEach(SettingsGroup.allCases) { group in
                    NavigationLink {
                        SettingsGroupPage(model: model, group: group, account: account)
                    } label: {
                        hubRow(group)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .labelStyle(SettingsRowLabelStyle())
        .font(CobaltType.body)
        .navigationTitle(Copy.settings)
        #if DEBUG
        .navigationDestination(item: $openGroup) { group in
            SettingsGroupPage(model: model, group: group, account: account)
        }
        #endif
        // back from system Settings (the owner may have changed photos access there) and first appearance
        .task { await model.photosSync.refresh() }
        // a key pasted since the library last refused it: opening Settings lifts the pull's auth pause and asks once more (13.8)
        .task { await model.savePull.resume() }
        .onChange(of: lifecycle.phase) { _, phase in
            if phase == .active { Task { await model.photosSync.refresh() } }
        }
    }

    private func hubRow(_ group: SettingsGroup) -> some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(group.title)
                Text(group.detail).font(Font.cobalt(11.5)).foregroundStyle(.secondary)
            }
        } icon: {
            Image(systemName: group.symbol)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("settings.group.\(group.rawValue)")
    }
}

#if DEBUG
#Preview("settings · happy") {
    PreviewHost(.happy, tab: .settings) { model in NavigationStack { SettingsScreen(model: model) } }
}
#Preview("settings · signed out (accounts)") {
    PreviewHost(.signedOut, tab: .settings) { model in NavigationStack { SettingsScreen(model: model) } }
}
#Preview("settings · revoked key") {
    PreviewHost(.revokedKey, tab: .settings) { model in NavigationStack { SettingsScreen(model: model) } }
}
#Preview("settings · plain cobalt") {
    PreviewHost(.plainCobalt, tab: .settings) { model in NavigationStack { SettingsScreen(model: model) } }
}
#Preview("settings · legacy fork") {
    PreviewHost(.legacyFork, tab: .settings) { model in NavigationStack { SettingsScreen(model: model) } }
}
#Preview("settings · offline") {
    PreviewHost(.offline, tab: .settings) { model in NavigationStack { SettingsScreen(model: model) } }
}
#Preview("settings · empty store") {
    PreviewHost(.emptyOrbit, tab: .settings) { model in NavigationStack { SettingsScreen(model: model) } }
}
#Preview("settings · sheet with done") {
    PreviewHost(.happy, tab: .settings) { model in
        NavigationStack {
            SettingsScreen(model: model)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("done") {} } }
        }
    }
}
#Preview("settings · account & server") {
    PreviewHost(.happy, tab: .settings) { model in
        NavigationStack { SettingsGroupPage(model: model, group: .account, account: AccountSettingsState()) }
    }
}
#Preview("settings · downloads & storage") {
    PreviewHost(.happy, tab: .settings) { model in
        NavigationStack { SettingsGroupPage(model: model, group: .downloads, account: AccountSettingsState()) }
    }
}
#Preview("settings · media & webp") {
    PreviewHost(.happy, tab: .settings) { model in
        NavigationStack { SettingsGroupPage(model: model, group: .media, account: AccountSettingsState()) }
    }
}
#Preview("settings · live & integrations") {
    PreviewHost(.happy, tab: .settings) { model in
        NavigationStack { SettingsGroupPage(model: model, group: .live, account: AccountSettingsState()) }
    }
}
#endif
