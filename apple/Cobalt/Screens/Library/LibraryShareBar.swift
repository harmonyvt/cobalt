import CobaltKit
import SwiftUI

/// The bottom bar of select mode when the server makes gallery share links (APP-API-CONTRACT 24): one primary button,
/// `make share link`, and a short line under it that says how many files make the link or why the button is off.
/// It sits in the library's bottom safe area, so on the iPhone it is above the floating tab bar. The verdict is
/// `ShareSetRule.verdict`: 2 up to `limits.share_set_max` picked files, all public.
struct LibraryShareBar: View {
    let verdict: ShareSetVerdict
    let count: Int
    let making: Bool
    let make: () -> Void

    private var ready: Bool { verdict == .ready }

    var body: some View {
        VStack(spacing: 8) {
            Button(action: make) {
                if making {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(Copy.Links.making)
                    }
                } else {
                    Label(Copy.Links.make, systemImage: Symbol.link)
                }
            }
            .buttonStyle(.cobaltPrimary())
            .disabled(!ready || making)
            .accessibilityHint(Copy.Links.makeA11yHint)
            // The line stays, with the same words for a screen reader: tooFew / tooMany / notPublic are the reason.
            Text(Copy.Links.line(for: verdict, count: count))
                .font(CobaltType.captionSmall)
                .foregroundStyle(ready ? CobaltColor.caption : CobaltColor.text)
                .contentTransition(.opacity)
                .accessibilityLabel(Copy.Links.line(for: verdict, count: count))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(maxWidth: 420)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .continuous))
        .padding(.horizontal, 16)
        .padding(.bottom, 6)
        .frame(maxWidth: .infinity)
        .motion(Motion.rows, value: verdict)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }
}
