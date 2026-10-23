import ActivityKit
import CobaltKit
import SwiftUI
import WidgetKit

/// An editor render on the Lock Screen and in the Dynamic Island (apple/CONTRACT-EDITOR.md section 11): the project's name,
/// what the server is doing, a progress bar, and the finished video's length, size and weight. A tap opens the queue, where
/// the finished render's row opens the video. Written by the app while it is open and by the server's pushes after.
struct EditLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: CobaltEditActivityAttributes.self) { context in
            EditLockScreenView(facts: EditFacts(context.state, isStale: context.isStale))
                .activityBackgroundTint(.black)
                .activitySystemActionForegroundColor(Color(hex: 0xe1e1e1))
        } dynamicIsland: { context in
            let facts = EditFacts(context.state, isStale: context.isStale)
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    HStack(spacing: 6) {
                        EditGlyph(facts: facts, size: 13)
                        LiveCaption(text: facts.title)
                    }
                    .dynamicIsland(verticalPlacement: .belowIfTooWide)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    if facts.isTerminal {
                        EditMark(facts: facts)
                    } else {
                        LiveTimer(since: facts.since, size: 12)
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    EditBody(facts: facts)
                        .padding(.top, 2)
                }
            } compactLeading: {
                EditGlyph(facts: facts, size: 13)
            } compactTrailing: {
                EditCompactTrailing(facts: facts)
            } minimal: {
                EditRing(facts: facts)
            }
            .keylineTint(Color(hex: 0xe1e1e1).opacity(0.35))
            .widgetURL(EditFacts.openURL)
        }
    }
}

// MARK: - what the views read

struct EditFacts {
    let state: EditLiveContentState
    let isStale: Bool

    init(_ state: EditLiveContentState, isStale: Bool = false) {
        self.state = state
        self.isStale = isStale
    }

    static let openURL = URL(string: "cobalt-apple://jobs")!

    var title: String { state.title }
    var since: Date { Date(timeIntervalSince1970: state.since) }
    var isTerminal: Bool { state.isTerminal }
    var isDone: Bool { state.status == .done }
    var isFailed: Bool { state.status == .failed }
    /// 0...1 while the server works on it; nil while it waits in line or once it ended.
    var fraction: Double? { isTerminal || state.status == .queued ? nil : min(1, max(0, state.progress ?? 0)) }

    var headline: String {
        if isStale && !isTerminal { return "waiting for capystore…" }
        switch state.status {
        case .queued:
            if let n = state.queueAhead, n > 0 { return n == 1 ? "1 render ahead" : "\(n) renders ahead" }
            return "waiting to render"
        case .preparing: return "sending the clips"
        case .rendering: return "rendering"
        case .finishing: return "saving the video"
        case .done: return "video ready"
        case .failed: return "couldn't render"
        case .cancelled: return "cancelled"
        }
    }

    /// The line under the headline: the result, the reason, or nothing.
    var detail: String? {
        switch state.status {
        case .done:
            var parts: [String] = []
            if let s = state.resultSeconds { parts.append(Format.timecode(s)) }
            if let w = state.resultWidth, let h = state.resultHeight { parts.append(Format.size(w, h)) }
            if let b = state.resultBytes { parts.append(Format.bytes(b)) }
            return parts.isEmpty ? nil : parts.joined(separator: " · ")
        case .failed: return EditLiveCopy.reason(state.code)
        default: return nil
        }
    }

    var percent: String? { fraction.map { "\(Int(($0 * 100).rounded(.down)))%" } }
}

// MARK: - pieces

/// The editor's mark (a film frame), or the result's mark once it ended.
struct EditGlyph: View {
    let facts: EditFacts
    var size: CGFloat = 13
    @Environment(\.isLuminanceReduced) private var reduced

    var body: some View {
        Image(systemName: facts.isDone ? Symbol.liveDone : facts.isFailed ? Symbol.liveFailed : "film")
            .font(.system(size: size, weight: .semibold))
            .foregroundStyle(LiveInk(reduced: reduced).primary)
            .accessibilityHidden(true)
    }
}

struct EditMark: View {
    let facts: EditFacts
    @Environment(\.isLuminanceReduced) private var reduced

    var body: some View {
        Image(systemName: facts.isDone ? Symbol.liveDone : facts.isFailed ? Symbol.liveFailed : "xmark")
            .font(.system(size: 12, weight: .bold))
            .foregroundStyle(LiveInk(reduced: reduced).primary)
    }
}

struct EditCompactTrailing: View {
    let facts: EditFacts
    @Environment(\.isLuminanceReduced) private var reduced

    var body: some View {
        if let percent = facts.percent {
            Text(percent)
                .font(liveFont(12, .medium))
                .monospacedDigit()
                .foregroundStyle(LiveInk(reduced: reduced).primary)
        } else if facts.state.status == .queued {
            Text(facts.state.queueAhead.map { $0 > 0 ? "+\($0)" : "next" } ?? "next")
                .font(liveFont(12, .medium))
                .foregroundStyle(LiveInk(reduced: reduced).secondary)
        } else {
            EditMark(facts: facts)
        }
    }
}

/// The minimal island: the progress as a ring.
struct EditRing: View {
    let facts: EditFacts
    @Environment(\.isLuminanceReduced) private var reduced

    var body: some View {
        let ink = LiveInk(reduced: reduced)
        ZStack {
            if facts.isDone {
                Circle().fill(ink.primary)
                Image(systemName: Symbol.liveDone).font(.system(size: 9, weight: .bold)).foregroundStyle(ink.onPrimary)
            } else if facts.isTerminal {
                Circle().strokeBorder(ink.primary, lineWidth: 2)
                Image(systemName: facts.isFailed ? Symbol.liveFailed : "xmark").font(.system(size: 9, weight: .bold)).foregroundStyle(ink.primary)
            } else {
                Circle().strokeBorder(ink.ring, lineWidth: 2)
                if let f = facts.fraction {
                    Circle()
                        .trim(from: 0, to: max(0.04, f))
                        .stroke(ink.primary, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .padding(1)
                }
                Image(systemName: "film").font(.system(size: 8, weight: .semibold)).foregroundStyle(ink.primary)
            }
        }
        .frame(width: 22, height: 22)
    }
}

/// Headline, detail and the bar: the expanded island's bottom and the Lock Screen card's body.
struct EditBody: View {
    let facts: EditFacts
    @Environment(\.isLuminanceReduced) private var reduced

    var body: some View {
        let ink = LiveInk(reduced: reduced)
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(facts.headline)
                    .font(liveFont(15, .semibold))
                    .foregroundStyle(ink.primary)
                    .lineLimit(1)
                Spacer(minLength: 8)
                if let percent = facts.percent {
                    Text(percent)
                        .font(liveFont(13, .medium))
                        .monospacedDigit()
                        .foregroundStyle(ink.secondary)
                }
            }
            if let detail = facts.detail {
                Text(detail)
                    .font(liveFont(12))
                    .foregroundStyle(ink.secondary)
                    .lineLimit(1)
            }
            if !facts.isTerminal {
                EditBar(fraction: facts.fraction)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// The progress bar; indeterminate (a short segment) while the render waits in line.
struct EditBar: View {
    let fraction: Double?
    @Environment(\.isLuminanceReduced) private var reduced

    var body: some View {
        let ink = LiveInk(reduced: reduced)
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(ink.track)
                Capsule()
                    .fill(ink.primary.opacity(fraction == nil ? 0.35 : 1))
                    .frame(width: max(6, geo.size.width * (fraction ?? 0.08)))
            }
        }
        .frame(height: 5)
    }
}

struct EditLockScreenView: View {
    let facts: EditFacts
    @Environment(\.isLuminanceReduced) private var reduced

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                EditGlyph(facts: facts, size: 14)
                LiveCaption(text: facts.title, size: 13)
                Spacer(minLength: 8)
                if facts.isTerminal {
                    EditMark(facts: facts)
                } else {
                    LiveTimer(since: facts.since, size: 13)
                }
            }
            EditBody(facts: facts)
        }
        .padding(16)
    }
}

#if DEBUG
// MARK: - previews

private enum EditPreview {
    static let order = ["queued", "preparing", "rendering", "finishing", "done", "failed", "cancelled"]
    static func states() -> [EditLiveContentState] {
        let now = Date().timeIntervalSince1970
        return order.compactMap { name in
            guard var s = EditLiveContentState.samples[name] else { return nil }
            s.since = now - 12
            return s
        }
    }
    static let attributes = CobaltEditActivityAttributes(EditLiveAttributes(render: "Rq7sTu0vWx3yZa6bCd9e", project: "ProjectAAAAAAAAA"))
}

#Preview("edit · island expanded", as: .dynamicIsland(.expanded), using: EditPreview.attributes) {
    EditLiveActivity()
} contentStates: {
    for state in EditPreview.states() { state }
}

#Preview("edit · island compact", as: .dynamicIsland(.compact), using: EditPreview.attributes) {
    EditLiveActivity()
} contentStates: {
    for state in EditPreview.states() { state }
}

#Preview("edit · island minimal", as: .dynamicIsland(.minimal), using: EditPreview.attributes) {
    EditLiveActivity()
} contentStates: {
    for state in EditPreview.states() { state }
}

#Preview("edit · lock screen", as: .content, using: EditPreview.attributes) {
    EditLiveActivity()
} contentStates: {
    for state in EditPreview.states() { state }
}
#endif
