import SwiftUI

/// A short line at the bottom of the window: what happened to a screen that has just popped ("deleted.",
/// "the private copy and the video's public link are still on the server..."). A glass capsule that fades after a
/// moment; VoiceOver hears it announced, since the screen it described is gone.
struct StatusToast: View {
    let text: String

    var body: some View {
        Text(text)
            .font(Font.cobalt(13, .medium, relativeTo: .footnote))
            .foregroundStyle(CobaltColor.text)
            .multilineTextAlignment(.center)
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
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isStaticText)
    }
}
