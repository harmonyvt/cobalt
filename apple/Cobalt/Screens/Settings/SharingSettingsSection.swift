import CobaltKit
import SwiftUI

/// "saving": whether a new save, an upload or a share from the share sheet gets a public link right away
/// (CONTRACT-VISIBILITY decision 3). On by default; off, new saves stay private until the owner switches one on
/// from its detail. It only changes what is saved afterwards, and it is shown only on a server that takes the
/// flag (`features.public_default`). The setting lives in the app group's defaults, so the share sheet reads it too.
struct SharingSettingsSection: View {
    let model: AppModel

    private var settings: CobaltKit.Settings { model.settings }

    var body: some View {
        if model.capabilities.publicDefault || model.capabilities.ytdlp {
            Section {
                if model.capabilities.publicDefault {
                    Toggle(isOn: Binding(get: { settings.newSavesPublic }, set: { settings.newSavesPublic = $0 })) {
                        Label(Copy.Media.newSavesPublic, systemImage: settings.newSavesPublic ? Symbol.Media.isPublic : Symbol.Media.isPrivate)
                            .contentTransition(.symbolEffect(.replace))
                    }
                }
                // "save links with yt-dlp" (APP-API-CONTRACT 49.7): yt-dlp only, no cobalt; galleries still go to cobalt
                if model.capabilities.ytdlp {
                    Toggle(isOn: Binding(get: { settings.saveWithYtdlp }, set: { settings.saveWithYtdlp = $0 })) {
                        Label(Copy.Media.saveWithYtdlp, systemImage: "arrow.down.circle")
                    }
                }
            } header: {
                Text(Copy.Media.saveGroup).font(CobaltType.caption).textCase(nil)
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    if model.capabilities.publicDefault { Text(Copy.Media.newSavesPublicFooter) }
                    if model.capabilities.ytdlp { Text(Copy.Media.saveWithYtdlpFooter) }
                }
                .font(CobaltType.captionSmall).lineSpacing(2)
            }
        }
    }
}

#if DEBUG
#Preview("settings · saving") {
    PreviewHost(.happy, tab: .settings) { model in
        Form { SharingSettingsSection(model: model) }.formStyle(.grouped)
    }
}
#Preview("settings · saving, plain cobalt (hidden)") {
    PreviewHost(.plainCobalt, tab: .settings) { model in
        Form { SharingSettingsSection(model: model) }.formStyle(.grouped)
    }
}
#endif
