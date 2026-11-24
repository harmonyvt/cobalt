import CobaltKit
import SwiftUI

#if os(iOS)
// The way into the queue on iPhone and iPad (apple/CONTRACT.md section 12), now the activity pill (apple 03-PHASE3 3.4.1): a
// toolbar item on the save, library, links, chat and studio screens that opens the activity and health sheet. It says what the
// table of `ActivityPillState` says (work in motion, a failure, offline, syncing, waking, or a quiet check) from the one count
// `model.activity` holds. The Mac has no button: the queue is a row of its sidebar, with the same count as its badge.
//
// The name and the init stay: the six screens that mount `QueueToolbarItem(model:)` change nothing.

/// The activity pill as a toolbar item, trailing. Add it to a screen's `.toolbar`.
struct QueueToolbarItem: ToolbarContent {
    let model: AppModel
    /// The iPhone's root screens get their pill (and the gear after it) from `PhoneRootToolbar`, set around the root by the
    /// shell: a screen's own `QueueToolbarItem` then draws nothing, so the bar has one pill and the gear stays last.
    @Environment(\.phoneHeaderOwnsActivity) private var headerOwnsActivity

    @ToolbarContentBuilder
    var body: some ToolbarContent {
        if !headerOwnsActivity {
            ToolbarItem(placement: .topBarTrailing) { ActivityPill(model: model) }
        }
    }
}
#endif
