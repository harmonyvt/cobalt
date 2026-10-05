import SwiftUI

/// A failure the way the system says it: a warning symbol, one line of red text, and the action
/// beside it (a secondary "ok" / "try again"). It replaces the old full-width red-outlined pill;
/// a blocking failure (a revoked or missing key) is an `.alert` instead.
struct InlineStatus<Actions: View>: View {
    let message: String
    @ViewBuilder var actions: () -> Actions

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(CobaltColor.errorText)
                .accessibilityHidden(true)
            Text(message)
                .font(Font.cobalt(13, .regular, relativeTo: .footnote))
                .foregroundStyle(CobaltColor.errorText)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            actions().fixedSize()
        }
        .accessibilityElement(children: .contain)
    }
}

extension InlineStatus where Actions == EmptyView {
    init(message: String) {
        self.init(message: message) { EmptyView() }
    }
}
