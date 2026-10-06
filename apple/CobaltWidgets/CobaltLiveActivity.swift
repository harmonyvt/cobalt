import ActivityKit
import CobaltKit
import SwiftUI
import WidgetKit

/// The pipeline run on the Lock Screen and in the Dynamic Island. `CobaltActivityAttributes` lives
/// in CobaltKit so the app, the share sheet's relay and the server's push-to-start all name the
/// same type. The views are in `LiveViews.swift`; this file only places them.
struct CobaltLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: CobaltActivityAttributes.self) { context in
            LiveLockScreenView(facts: LiveFacts(context))
                .activityBackgroundTint(.black)
                .activitySystemActionForegroundColor(Color(hex: 0xe1e1e1))
        } dynamicIsland: { context in
            let facts = LiveFacts(context)
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    HStack(spacing: 6) {
                        LiveStar()
                        Text(facts.shortSource)
                            .font(Font.cobalt(12, .regular, relativeTo: .caption))
                            .foregroundStyle(Color(hex: 0xe1e1e1))
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .dynamicIsland(verticalPlacement: .belowIfTooWide)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    if facts.isTerminal {
                        LiveMetricView(metric: .symbol(facts.isFailed ? Symbol.liveFailed : Symbol.liveDone), size: 12)
                    } else {
                        LiveTimer(since: facts.since, size: 12)
                    }
                }
                DynamicIslandExpandedRegion(.center) {
                    LiveExpandedCenter(facts: facts)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    LiveExpandedBottom(facts: facts)
                }
            } compactLeading: {
                LiveStepGlyph(facts: facts)
            } compactTrailing: {
                LiveCompactTrailing(facts: facts)
            } minimal: {
                LiveRing(facts: facts)
            }
            .keylineTint(Color(hex: 0xe1e1e1).opacity(0.35))
            .widgetURL(facts.openURL)
        }
    }
}

#if DEBUG
// MARK: - previews: every presentation x every fixture state

/// The fixture states of CONTRACT-LIVE.md 2.4 in run order, with their clocks moved to "just now" so
/// the timers read seconds, not the weeks since the fixture's fixed epoch.
private enum LivePreview {
    static let order = [
        "fetching_waking", "uploading", "saving_storing", "reading", "ready", "decoding", "packing", "done",
        "failed_render_lost", "failed_fetch",
    ]

    static func states(_ names: [String] = order, running: Double = 7) -> [LiveContentState] {
        let now = Date().timeIntervalSince1970
        return names.compactMap { name in
            guard var s = LiveContentState.samples[name] else { return nil }
            s.since = now - running
            return s
        }
    }

    /// The same states carrying the owner's title (CONTRACT-LIBRARY2 decision 9): the caption above the headline.
    static func titled(_ names: [String] = order, title: String, running: Double = 7) -> [LiveContentState] {
        states(names, running: running).map { state in
            var state = state
            state.title = title
            return state
        }
    }

    static let link = CobaltActivityAttributes(LiveRunAttributes(
        run: UUID(), input: "link", service: "instagram", ref: "Dd7P496wolG", origin: "app"))
    static let file = CobaltActivityAttributes(LiveRunAttributes(
        run: UUID(), input: "file", service: "file", ref: "IMG_0412.mov", origin: "app"))
    static let share = CobaltActivityAttributes(LiveRunAttributes(
        run: UUID(), input: "link", service: "x", ref: "2105435404002562056", origin: "share"))
}

#Preview("island · expanded", as: .dynamicIsland(.expanded), using: LivePreview.link) {
    CobaltLiveActivity()
} contentStates: {
    for state in LivePreview.states() { state }
}

#Preview("island · compact", as: .dynamicIsland(.compact), using: LivePreview.link) {
    CobaltLiveActivity()
} contentStates: {
    for state in LivePreview.states() { state }
}

#Preview("island · minimal", as: .dynamicIsland(.minimal), using: LivePreview.link) {
    CobaltLiveActivity()
} contentStates: {
    for state in LivePreview.states() { state }
}

#Preview("lock screen", as: .content, using: LivePreview.link) {
    CobaltLiveActivity()
} contentStates: {
    for state in LivePreview.states() { state }
}

#Preview("file upload · expanded", as: .dynamicIsland(.expanded), using: LivePreview.file) {
    CobaltLiveActivity()
} contentStates: {
    for state in LivePreview.states(["uploading"]) { state }
}

#Preview("file upload · lock screen", as: .content, using: LivePreview.file) {
    CobaltLiveActivity()
} contentStates: {
    for state in LivePreview.states(["uploading", "ready"]) { state }
}

#Preview("lock screen · title caption", as: .content, using: LivePreview.file) {
    CobaltLiveActivity()
} contentStates: {
    for state in LivePreview.titled(["uploading", "saving_storing", "reading", "done", "failed_fetch"], title: "beach day, 4 oct") { state }
}

#Preview("lock screen · long title", as: .content, using: LivePreview.link) {
    CobaltLiveActivity()
} contentStates: {
    for state in LivePreview.titled(
        ["decoding", "done"], title: "the whole afternoon at the harbour, before the wind came up and everyone left") { state }
}

#Preview("island · expanded · title", as: .dynamicIsland(.expanded), using: LivePreview.file) {
    CobaltLiveActivity()
} contentStates: {
    for state in LivePreview.titled(["uploading", "done"], title: "beach day, 4 oct") { state }
}

#Preview("share run · lock screen", as: .content, using: LivePreview.share) {
    CobaltLiveActivity()
} contentStates: {
    for state in LivePreview.states(["fetching_waking", "decoding"]) { state }
}

// The stale card (the activity has not heard from cobalt for 120 s) is not a preview content state,
// so it is drawn directly.
#Preview("lock screen · stale", traits: .sizeThatFitsLayout) {
    VStack(spacing: 12) {
        ForEach(["saving_storing", "decoding", "reading"], id: \.self) { name in
            LiveLockScreenView(facts: LiveFacts(
                attributes: LivePreview.link, state: LivePreview.states([name])[0], isStale: true))
                .background(Color.black)
        }
    }
    .padding()
    .background(Color.black)
}

#Preview("lock screen · always on", traits: .sizeThatFitsLayout) {
    VStack(spacing: 12) {
        ForEach(["decoding", "done"], id: \.self) { name in
            LiveLockScreenView(facts: LiveFacts(attributes: LivePreview.link, state: LivePreview.states([name])[0]))
                .environment(\.isLuminanceReduced, true)
                .background(Color.black)
        }
    }
    .padding()
    .background(Color.black)
}
#endif
