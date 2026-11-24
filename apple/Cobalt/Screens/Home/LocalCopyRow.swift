import CobaltKit
import SwiftUI

/// The copy of the run's file on this device, when it is not simply there (apple 02-PHASE2 2.2.4): "copying to this
/// iphone…" with its bytes while it comes, and "in your library · device copy failed" with the reason and a retry when it
/// did not. The library copy is what counts, so a failure here never reads as a failed save. Nothing is drawn once the file
/// is on the device or when keeping a copy was not asked.
struct LocalCopyRow: View {
    let pipeline: Pipeline

    var body: some View {
        switch pipeline.localCopyState {
        case .notRequested, .savedOnDevice:
            EmptyView()
        case .downloading(let progress):
            line(symbol: Symbol.retry, tint: CobaltColor.caption, title: Copy.Save.localCopying, detail: bytes(progress), retry: false)
        case .failed(let code):
            line(
                symbol: Symbol.error, tint: CobaltColor.errorText, title: Copy.Save.localCopyFailed,
                detail: Copy.Save.localCopyReason(code), retry: pipeline.canRetryLocalCopy)
        }
    }

    private func bytes(_ p: TransferProgress) -> String? {
        guard p.bytes > 0 || p.total != nil else { return nil }
        if let total = p.total, total > 0 { return Copy.bytesOf(p.bytes, total) }
        return Format.bytes(p.bytes)
    }

    private func line(symbol: String, tint: Color, title: String, detail: String?, retry: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(tint)
                .frame(width: 22)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(CobaltType.captionSmall)
                    .foregroundStyle(CobaltColor.text)
                    .lineLimit(2)
                if let detail {
                    Text(detail)
                        .font(CobaltType.captionSmall)
                        .foregroundStyle(CobaltColor.caption)
                        .monospacedDigit()
                        .lineLimit(2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
            if retry {
                Button(Copy.Save.localCopyRetry, systemImage: Symbol.retry) { pipeline.retryLocalCopy() }
                    .buttonStyle(.cobaltSecondary(fullWidth: false, compact: true))
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .accessibilityElement(children: .contain)
    }
}

extension LocalCopyState {
    /// The row has something to say: the copy is coming, or it failed.
    var isDisplayed: Bool {
        switch self {
        case .downloading, .failed: return true
        case .notRequested, .savedOnDevice: return false
        }
    }
}
