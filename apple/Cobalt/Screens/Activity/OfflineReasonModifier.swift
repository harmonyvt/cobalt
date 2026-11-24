import SwiftUI

// The one way a control says "this needs the server" while it can't be reached (apple 03-PHASE3 3.4.3): a caption under it, never
// only a dimmed control. The words are `Copy.Activity.needsNetwork`; the pane's action grid says the same through `Copy.Pane`
// (lane (e) uses that string and not this view), so the two stay one sentence.
//
// `offlineReason(_:)` leaves the content alone online. Offline it adds the caption under the content and, with `disables`, turns the
// control off (the default: a control that can't work offline must not look as if it can).

private struct OfflineReasonModifier: ViewModifier {
    let offline: Bool
    let disables: Bool
    let reason: String

    func body(content: Content) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            content
                .disabled(offline && disables)
            if offline {
                Text(reason)
                    .font(CobaltType.captionSmall)
                    .foregroundStyle(CobaltColor.caption)
                    .accessibilityHidden(true)
                    .transition(.opacity)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityHint(offline ? reason : "")
    }
}

extension View {
    /// While `offline`, says why this control waits ("needs network") under it and, with `disables`, turns it off.
    func offlineReason(_ offline: Bool, disables: Bool = true, reason: String = Copy.Activity.needsNetwork) -> some View {
        modifier(OfflineReasonModifier(offline: offline, disables: disables, reason: reason))
    }
}
