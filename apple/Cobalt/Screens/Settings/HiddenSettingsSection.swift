import CobaltKit
import SwiftUI

/// "hidden" in settings (APP-API-CONTRACT 37.7): one row that opens the hidden screen (rules, the lock, open hidden).
/// iPhone and iPad push it on the settings stack; the Mac's Settings window has no stack, so it opens as a sheet.
/// Shown only on a server with `features.hidden` and a key, like `PrivateLinksSettingsSection`.
struct HiddenSettingsSection: View {
    let model: AppModel

    #if os(macOS)
    @State private var showing = false
    #endif

    var body: some View {
        if model.capabilities.hidden && model.settings.hasAPIKey {
            Section {
                #if os(macOS)
                Button { showing = true } label: { row(chevron: true) }
                    .buttonStyle(.plain)
                #else
                NavigationLink { HiddenRulesScreen(model: model) } label: { row(chevron: false) }
                #endif
            } header: {
                Text(Copy.Hidden.settingsGroup).font(CobaltType.caption).textCase(nil)
            } footer: {
                Text(Copy.Hidden.settingsFooter).font(CobaltType.captionSmall).lineSpacing(2)
            }
            #if os(macOS)
            .sheet(isPresented: $showing) {
                NavigationStack { HiddenRulesScreen(model: model, closes: true) }
                    .frame(width: 500, height: 660)
                    .cobaltRoot(model: model)
            }
            #endif
        }
    }

    private func row(chevron: Bool) -> some View {
        LabeledContent {
            HStack(spacing: 6) {
                Text(Copy.Hidden.posts(model.library.hiddenCount))
                    .font(Font.cobalt(12.5)).foregroundStyle(.secondary).monospacedDigit()
                if chevron {
                    Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(.tertiary)
                }
            }
        } label: {
            Label(Copy.Hidden.settingsRow, systemImage: Symbol.HiddenRules.hidden)
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

#if DEBUG
#Preview("settings · hidden") {
    PreviewHost(.hidden, tab: .settings) { model in
        Form { HiddenSettingsSection(model: model) }.formStyle(.grouped)
    }
}
#endif
