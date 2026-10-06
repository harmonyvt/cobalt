import CobaltKit
import SwiftUI

/// The sheet for a post with more than one item. It is a system sheet (Liquid Glass on iOS 26, so no
/// custom background) with detents, because the content is small. Dragging it away resets the
/// pipeline (the binding in `HomeScreen`).
struct PickerSheet: View {
    let pipeline: Pipeline
    let items: [PickerItem]
    let webpAvailable: Bool
    #if os(macOS)
    @Environment(\.dismiss) private var dismiss
    #endif

    var body: some View {
        PickerContent(pipeline: pipeline, items: items, webpAvailable: webpAvailable)
            .padding(.horizontal, 20)
            .padding(.top, 24)
            .padding(.bottom, 12)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            #if os(iOS)
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
            #else
            .frame(minWidth: 420, minHeight: 560)
            .overlay(alignment: .topTrailing) {
                // a Mac sheet has no swipe down: closing is the same as leaving the picker (the binding resets the run)
                CloseButton(cancels: true) { dismiss() }
                    .padding(12)
            }
            #endif
    }
}

#if DEBUG
#Preview("picker sheet") {
    PreviewHost(.picker, script: .input) { model in
        HomeScreen(model: model, tier: .compact)
    }
}
#endif
