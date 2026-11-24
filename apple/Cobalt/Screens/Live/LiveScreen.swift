#if os(iOS)
import CobaltKit
import SwiftUI

/// The live tab (apple 04-PHASE4 4.1): the three things that talk to a stream, under one segmented picker. The OBS stage
/// opens first; twitch (watch and chat) and 7tv (the emote sets) are the other two. The picker remembers which was last open
/// (`PhoneNavState.live`). A segment's screen is the same screen the iPad has as a tab, with its own title and toolbar.
///
/// The bar is the hub's (`PhoneRootToolbar`: pill, gear) for every segment; the studio's own pill is silenced
/// (`phoneHeaderOwnsActivity`). Switching segments (or tabs) takes the old screen out, which is
/// what stops the studio's polling; `PhoneTabs` writes the new `selectedTab` for the same reason.
struct LiveScreen<Segment: View>: View {
    let model: AppModel
    @Environment(PhoneNavState.self) private var nav: PhoneNavState?
    /// The screen of a segment (`AppShell.tabScreen`).
    @ViewBuilder let segment: (LiveSegment) -> Segment

    var body: some View {
        let current = nav?.live ?? .stage
        VStack(spacing: 0) {
            PhoneSegmentBar(
                label: Copy.PhoneNav.liveSegments,
                selection: Binding(get: { nav?.live ?? .stage }, set: { nav?.live = $0 }),
                options: LiveSegment.allCases.map { .init(value: $0, title: $0.title) },
                identifier: "live.segments")
            segment(current)
                .id(current)
        }
        .background(CobaltColor.bg)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { PhoneRootToolbar(model: model) }
        .environment(\.phoneHeaderOwnsActivity, true)
    }
}
#endif
