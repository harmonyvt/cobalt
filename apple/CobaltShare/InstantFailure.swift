import CobaltKit
import SwiftUI
import UIKit

/// The instant share's only visible moment (CONTRACT-SHARE-QUICK.md section 9): when the save could not
/// even be queued (no key this process can read, no link in what was shared, the server refused the
/// request) the sheet says so in one line, with "open cobalt" and close. Everything else leaves the
/// extension without ever showing a view.
struct InstantFailureView: View {
    let failure: InstantShare.Failure
    let openCobalt: () -> Void
    let close: () -> Void
    /// The content's own height, so the controller can size the sheet to it.
    var onFit: ((CGFloat) -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: ShareSymbol.failed)
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(CobaltColor.errorText)
                    .frame(width: 22, height: 22)
                    .accessibilityHidden(true)
                Text(ShareCopy.instantFailure(failure))
                    .font(CobaltType.bodySemibold)
                    .foregroundStyle(CobaltColor.text)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                CloseButton(action: close)
            }
            Button(ShareCopy.quickOpenCobalt, systemImage: Symbol.openApp, action: openCobalt)
                .buttonStyle(.cobaltPrimary(compact: true))
        }
        .padding(.horizontal, 20)
        .padding(.top, 18)
        .padding(.bottom, 20)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(CobaltColor.bg.ignoresSafeArea())
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { onFit?($0) }
        .dynamicTypeSize(...DynamicTypeSize.accessibility2)
        .accessibilityElement(children: .contain)
        .sensoryFeedback(.error, trigger: failure)
    }
}

#if DEBUG
#Preview("instant · no key") { InstantFailureView(failure: .noKey, openCobalt: {}, close: {}) }
#Preview("instant · no link") { InstantFailureView(failure: .noLink, openCobalt: {}, close: {}) }
#Preview("instant · key refused") { InstantFailureView(failure: .rejected(status: 401), openCobalt: {}, close: {}) }
#Preview("instant · server down") { InstantFailureView(failure: .rejected(status: 503), openCobalt: {}, close: {}) }
#Preview("instant · unreachable") { InstantFailureView(failure: .unreachable, openCobalt: {}, close: {}) }
#endif
