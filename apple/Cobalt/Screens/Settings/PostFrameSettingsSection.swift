import CobaltKit
import SwiftUI

/// "post frame on save" (APP-API-CONTRACT 52.6; the mockup's section 1 with the contract's change: a plain switch and a look,
/// remembered per site, never "framed only"): one row per site, its switch and light or dark. When a site is on, each video
/// saved from it gets a framed copy (`fit`) as soon as the save finishes; the plain video is always kept. Shown only on a
/// server with post frames. App-group defaults, so the share sheet's saves read the same choices when the app picks them up.
struct PostFrameSettingsSection: View {
    let model: AppModel

    var body: some View {
        if model.canMakePostFrames {
            Section {
                ForEach(PostFrameStyle.allCases, id: \.self) { style in
                    PostFrameSaveRow(settings: model.settings, style: style)
                }
            } header: {
                Text(Copy.PostFrame.saveSection).font(CobaltType.caption).textCase(nil)
            } footer: {
                Text(Copy.PostFrame.saveFooter).font(CobaltType.captionSmall).lineSpacing(2)
            }
        }
    }
}

/// One site: the switch, and (while on) light or dark.
private struct PostFrameSaveRow: View {
    let settings: CobaltKit.Settings
    let style: PostFrameStyle

    private var choice: PostFrameSaveChoice { settings.postFrameSaveChoice(for: style) }

    private var on: Binding<Bool> {
        Binding(get: { choice.on }, set: { value in
            var next = choice
            next.on = value
            settings.setPostFrameSaveChoice(next, for: style)
        })
    }

    private var theme: Binding<PostFrameTheme> {
        Binding(get: { choice.theme }, set: { value in
            var next = choice
            next.theme = value
            settings.setPostFrameSaveChoice(next, for: style)
        })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle(isOn: on) {
                Label(Copy.PostFrame.siteRow(style), systemImage: Symbol.PostFrame.frame)
            }
            if choice.on {
                Picker(Copy.PostFrame.look, selection: theme) {
                    ForEach(PostFrameTheme.allCases, id: \.self) { t in
                        Text(Copy.PostFrame.themeName(t)).tag(t)
                    }
                }
                .pickerStyle(.segmented)
                .accessibilityLabel("\(Copy.PostFrame.siteRow(style)), \(Copy.PostFrame.look)")
            }
        }
        .haptic(.selection, trigger: choice)
        .motion(Motion.rows, value: choice.on)
    }
}

#if DEBUG
#Preview("settings · post frame on save") {
    PreviewHost(.happy, tab: .settings) { model in
        Form { PostFrameSettingsSection(model: model) }.formStyle(.grouped)
    }
}
#endif
