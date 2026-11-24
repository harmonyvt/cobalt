import CobaltKit
import SwiftUI

// The small sections that were private to `SettingsScreen`, moved here unchanged so the group pages can hold them.

/// Settings › media & webp: how webps are made.
struct SettingsMakingSection: View {
    let model: AppModel
    private var settings: CobaltKit.Settings { model.settings }

    var body: some View {
        Section {
            Picker(selection: Binding(get: { settings.webpQuality }, set: { settings.webpQuality = $0 })) {
                ForEach(WebpQuality.allCases, id: \.self) { q in
                    Text(Copy.qualityName(q)).tag(q)
                }
            } label: {
                Label(Copy.webpQuality, systemImage: Symbol.quality)
            }
        } header: {
            SettingsRows.header(Copy.groupMaking)
        }
    }
}

/// Settings › downloads & storage: whether sharing a link to cobalt carries on by itself after a short wait.
/// iPhone and iPad only: the Mac has no share sheet.
struct SettingsShareSheetSection: View {
    let model: AppModel
    private var settings: CobaltKit.Settings { model.settings }

    var body: some View {
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
            SettingsRows.header(Copy.Sync.shareGroup)
        } footer: {
            SettingsRows.footer(settings.shareFullSheet ? Copy.Sync.autoContinueFooter : Copy.Sync.quickFooter)
        }
        #endif
    }
}

/// Settings › live & integrations: whether the island follows a run while cobalt is closed. Hidden on the Mac.
struct SettingsLiveActivitySection: View {
    let model: AppModel

    var body: some View {
        if let status = Copy.Live.status(model.liveStatus) {
            Section {
                SettingsRows.row(Copy.Live.row, Symbol.liveActivity) { SettingsRows.value(status) }
            } footer: {
                SettingsRows.footer(Copy.Live.rowFooter)
            }
        }
    }
}

/// Settings › live & integrations: the menu bar icon. Mac only: closing the window leaves capystore running while this is on.
struct SettingsMenuBarSection: View {
    let model: AppModel
    private var settings: CobaltKit.Settings { model.settings }

    var body: some View {
        #if os(macOS)
        Section {
            Toggle(isOn: Binding(
                get: { settings.menuBarExtra },
                set: { on in
                    settings.menuBarExtra = on
                    MenuBarPresence.shared.staysRunning = on
                }
            )) {
                Label(Copy.MenuBar.showIcon, systemImage: Symbol.menuBar)
            }
        } header: {
            SettingsRows.header(Copy.MenuBar.section)
        } footer: {
            SettingsRows.footer(Copy.MenuBar.showIconFooter)
        }
        #else
        EmptyView()
        #endif
    }
}

/// Settings › live & integrations: haptics and motion.
struct SettingsFeelSection: View {
    let model: AppModel
    private var settings: CobaltKit.Settings { model.settings }

    var body: some View {
        Section {
            Toggle(isOn: Binding(get: { settings.haptics }, set: { settings.haptics = $0 })) {
                Label(Copy.haptics, systemImage: Symbol.haptics)
            }
            // turning haptics on answers with one, so the owner feels what they turned on
            .haptic(.impact(weight: .medium), trigger: settings.haptics) { $0 }
            SettingsRows.row(Copy.motion, Symbol.motion) { SettingsRows.value(Copy.motionFollows) }
        } header: {
            SettingsRows.header(Copy.groupFeel)
        } footer: {
            SettingsRows.footer(Copy.settingsFooter)
        }
    }
}
