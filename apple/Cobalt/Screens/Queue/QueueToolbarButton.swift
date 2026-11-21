import CobaltKit
import SwiftUI

#if os(iOS)
// The queue's way in on iPhone and iPad (apple/CONTRACT.md section 12): a toolbar button on the save, library and
// links screens that opens the queue sheet (`AppModel.showQueue()`). It carries the work in motion on this device
// (`UnifiedQueue.badgeCount`) as a count after the icon. The Mac has no button: the queue is a row of its sidebar.

/// The queue button as a toolbar item, trailing. Add it to a screen's `.toolbar`.
struct QueueToolbarItem: ToolbarContent {
    let model: AppModel

    var body: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) { QueueToolbarButton(model: model) }
    }
}

struct QueueToolbarButton: View {
    let model: AppModel

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let count = model.unifiedQueue.badgeCount
        // The count sits inside the button, after the icon: a toolbar item clips to its bounds, so a corner badge
        // drawn outside the icon was cut off. The glass capsule simply grows by the count's width.
        Button { model.showQueue() } label: {
            HStack(spacing: 4) {
                Image(systemName: Symbol.queue)
                if count > 0 {
                    Text(count > 99 ? "99+" : "\(count)")
                        .font(Font.cobalt(13, .semibold, relativeTo: .footnote))
                        .monospacedDigit()
                        .contentTransition(reduceMotion ? .identity : .numericText())
                        .transition(.opacity)
                }
            }
            .animation(reduceMotion ? Motion.fade : Motion.rows, value: count)
        }
        .help(Copy.Queue.title)
        .accessibilityLabel(Copy.Queue.openQueueA11y)
        .accessibilityValue(count > 0 ? Copy.Queue.inProgressA11y(count) : "")
    }
}
#endif
