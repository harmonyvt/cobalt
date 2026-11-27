import CobaltKit
import SwiftUI

/// The four pages the settings hub opens (apple 04-PHASE4 4.1). Every section the flat list had lives on exactly one of
/// them; none was removed and none changed what it does.
///
///     account & server       server · account (sign in, devices, keys)
///     downloads & storage    saving · share sheet · on this device (storage, finder) · photos · library sync
///     media & webp           making (webp quality) · post frame on save · private links · hidden
///     live & integrations    live activity · claude and chatgpt (mcp) · menu bar · from other apps · diagnostics · feel
///
/// Twitch and 7tv have no settings of their own: they connect from their screens (the Live tab), so there is nothing to
/// move for them here.
enum SettingsGroup: String, CaseIterable, Identifiable, Hashable {
    case account, downloads, media, live

    var id: String { rawValue }

    var title: String {
        switch self {
        case .account: Copy.SettingsHub.account
        case .downloads: Copy.SettingsHub.downloads
        case .media: Copy.SettingsHub.media
        case .live: Copy.SettingsHub.live
        }
    }

    var detail: String {
        switch self {
        case .account: Copy.SettingsHub.accountDetail
        case .downloads: Copy.SettingsHub.downloadsDetail
        case .media: Copy.SettingsHub.mediaDetail
        case .live: Copy.SettingsHub.liveDetail
        }
    }

    var symbol: String {
        switch self {
        case .account: "person.crop.circle"
        case .downloads: "arrow.down.circle"
        case .media: "photo.on.rectangle"
        case .live: "dot.radiowaves.left.and.right"
        }
    }
}

/// One group's page: the same grouped `Form` the flat list was, holding only that group's sections.
struct SettingsGroupPage: View {
    let model: AppModel
    let group: SettingsGroup
    /// Owned by `SettingsScreen` so the account section's confirm, new-key sheet and rename survive leaving the page.
    let account: AccountSettingsState

    private var hasKey: Bool { model.settings.hasAPIKey }

    var body: some View {
        Form {
            switch group {
            case .account:
                SettingsServerSection(model: model)
                // accounts (APP-API-CONTRACT 42.6): replaces the api key row on a server with `features.accounts`
                AccountSettingsSection(model: model, state: account)
            case .downloads:
                SharingSettingsSection(model: model)
                SettingsShareSheetSection(model: model)
                StorageSettingsSection(model: model)
                PhotosSettingsSection(model: model)
                // the on-device library and its glow: off until switched on here
                LibrarySyncSettingsSection(model: model)
            case .media:
                SettingsMakingSection(model: model)
                // audio loudness leveling (v10.1): EBU R128 mode, target LUFS, default link, rule probe & backfill
                AudioLevelingSettingsSection(model: model).id(hasKey)
                // "post frame" on save, per site (APP-API-CONTRACT 52.6)
                PostFrameSettingsSection(model: model)
                // private links (APP-API-CONTRACT 36.6): what new gallery links start as, and rotating every key
                PrivateLinksSettingsSection(model: model).id(hasKey)
                // hidden posts and auto-hide rules (APP-API-CONTRACT 37.7)
                HiddenSettingsSection(model: model).id(hasKey)
            case .live:
                SettingsLiveActivitySection(model: model)
                // made again when a key is pasted or reset, so it asks the server with the new key
                McpSettingsSection(model: model).id(hasKey)
                SettingsMenuBarSection(model: model)
                #if os(macOS)
                // the "paste from anywhere" keys and the right-click service
                QuickSaveSettingsSection(model: model)
                #endif
                TelemetrySettingsSection(model: model)
                SettingsFeelSection(model: model)
            }
        }
        .formStyle(.grouped)
        .labelStyle(SettingsRowLabelStyle())
        .font(CobaltType.body)
        .navigationTitle(group.title)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .modifier(AccountPresentations(model: model, account: account, on: group == .account))
    }
}

/// The account section's confirm, new key sheet and rename hang on its page's form (a section's rows come and go).
private struct AccountPresentations: ViewModifier {
    let model: AppModel
    let account: AccountSettingsState
    let on: Bool

    func body(content: Content) -> some View {
        if on {
            content.accountSettingsPresentations(model: model, state: account)
        } else {
            content
        }
    }
}
