import CobaltKit
import SwiftUI

/// What the share card says when the copying pass ended and some posts did not come (apple 02-PHASE2 2.2.4): "3 of 4 ready ·
/// 1 failed", each failed post with why, and the two choices (share what is ready, or retry the failed ones). It goes under the
/// share card's rows while `controller.sharePrepSummary` is set; the share sheet has not opened yet. It draws no media, so it
/// wears no mask.
struct SharePrepSummaryBar: View {
    let controller: LibraryController

    /// Failed posts listed before `and n more`.
    private static let listed = 3

    var body: some View {
        if let summary = controller.sharePrepSummary {
            let failed = controller.sharePrep.filter { $0.failure != nil }
            VStack(alignment: .leading, spacing: 8) {
                Text(summary.text)
                    .font(Font.cobalt(13, .semibold, relativeTo: .subheadline))
                    .foregroundStyle(CobaltColor.errorText)
                    .accessibilityAddTraits(.isHeader)
                ForEach(failed.prefix(Self.listed)) { row in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(row.title)
                            .font(Font.cobalt(12, relativeTo: .caption))
                            .foregroundStyle(CobaltColor.text)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: 4)
                        Text(Copy.Save.sharePrepRowFailure(row.failure ?? ""))
                            .font(Font.cobalt(11.5, relativeTo: .caption))
                            .foregroundStyle(CobaltColor.caption)
                            .lineLimit(1)
                    }
                    .accessibilityElement(children: .combine)
                }
                if failed.count > Self.listed {
                    Text(Copy.Library2.sharePrepMore(failed.count - Self.listed))
                        .font(Font.cobalt(12, relativeTo: .caption))
                        .foregroundStyle(CobaltColor.caption)
                }
                HStack(spacing: 10) {
                    Button(Copy.Save.sharePrepRetry, systemImage: Symbol.retry) { controller.retryFailedShares() }
                        .buttonStyle(.cobaltSecondary(fullWidth: true, compact: true))
                    if summary.ready > 0 {
                        Button(Copy.Save.sharePrepShareReady(summary.ready)) { controller.shareReadyOnes() }
                            .buttonStyle(.cobaltPrimary(fullWidth: true, compact: true))
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .contain)
        }
    }
}
