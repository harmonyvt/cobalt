import SwiftUI

/// A short line at the bottom of the window: what happened to a screen that has just popped ("deleted.",
/// "the private copy and the video's public link are still on the server..."). A glass capsule that fades after a
/// moment; VoiceOver hears it announced, since the screen it described is gone.
struct StatusToast: View {
    let text: String
    /// A second, smaller line under the text (APP-API-CONTRACT 41.4: "messages already posted in discord keep…").
    var detail: String? = nil
    /// The one action beside the text ("undo", "open"); nil draws none.
    var actionTitle: String? = nil
    var action: @MainActor () -> Void = {}

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            VStack(alignment: actionTitle == nil ? .center : .leading, spacing: 3) {
                Text(text)
                    .font(Font.cobalt(13, .medium, relativeTo: .footnote))
                    .foregroundStyle(CobaltColor.text)
                if let detail {
                    Text(detail)
                        .font(CobaltType.badge)
                        .foregroundStyle(CobaltColor.caption)
                }
            }
            .multilineTextAlignment(actionTitle == nil ? .center : .leading)
            if let actionTitle {
                Button(actionTitle, action: action)
                    .font(Font.cobalt(13, .semibold, relativeTo: .footnote))
                    .foregroundStyle(CobaltColor.linkBlue)
                    .buttonStyle(.borderless)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .glassEffect(.regular, in: .rect(cornerRadius: 22))
        .frame(maxWidth: 420)
        .padding(.horizontal, Metrics.gutter)
        #if os(iOS)
        .padding(.bottom, 96)          // above the tab bar
        #else
        .padding(.bottom, 24)
        #endif
        .accessibilityElement(children: actionTitle == nil ? .combine : .contain)
        .accessibilityAddTraits(actionTitle == nil ? .isStaticText : [])
    }
}
