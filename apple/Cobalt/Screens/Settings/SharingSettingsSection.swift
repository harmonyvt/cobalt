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
        if model.capabilities.publicDefault {
            Section {
                Toggle(isOn: Binding(get: { settings.newSavesPublic }, set: { settings.newSavesPublic = $0 })) {
                    Label(Copy.Media.newSavesPublic, systemImage: settings.newSavesPublic ? Symbol.Media.isPublic : Symbol.Media.isPrivate)
                        .contentTransition(.symbolEffect(.replace))
                }
            } header: {
                Text(Copy.Media.saveGroup).font(CobaltType.caption).textCase(nil)
            } footer: {
                Text(Copy.Media.newSavesPublicFooter).font(CobaltType.captionSmall).lineSpacing(2)
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
