import ActivityKit
import CobaltKit
import SwiftUI
import WidgetKit

/// A chat reply on the Lock Screen and in the Dynamic Island (CONTRACT-PARALLEL.md 15.10, APP-API-CONTRACT 27.9): what was
/// asked, what the AI is doing now (thinking, the tool it is using, writing), how many tools it used and files it showed,
/// and the start of the reply once it is done. Written by the app for a message it sent, and by the server's pushes for one
/// sent from another device. A tap opens the chat.
struct ChatLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: CobaltChatActivityAttributes.self) { context in
            ChatLockScreenView(facts: ChatFacts(context.state, prompt: context.attributes.prompt, isStale: context.isStale))
                .activityBackgroundTint(.black)
                .activitySystemActionForegroundColor(Color(hex: 0xe1e1e1))
                .widgetURL(context.attributes.openURL)
        } dynamicIsland: { context in
            let facts = ChatFacts(context.state, prompt: context.attributes.prompt, isStale: context.isStale)
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    HStack(spacing: 6) {
                        ChatGlyph(facts: facts, size: 13)
                        LiveCaption(text: facts.prompt)
                    }
                    .dynamicIsland(verticalPlacement: .belowIfTooWide)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    if facts.isTerminal {
                        ChatMark(facts: facts)
                    } else {
                        LiveTimer(since: facts.since, size: 12)
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    ChatBody(facts: facts)
                        .padding(.top, 2)
                }
            } compactLeading: {
                ChatGlyph(facts: facts, size: 13)
            } compactTrailing: {
                ChatCompactTrailing(facts: facts)
            } minimal: {
                ChatGlyph(facts: facts, size: 11)
            }
            .keylineTint(Color(hex: 0xe1e1e1).opacity(0.35))
            .widgetURL(context.attributes.openURL)
        }
    }
}

// MARK: - what the views read

struct ChatFacts {
    let state: ChatLiveContentState
    let prompt: String
    let isStale: Bool

    init(_ state: ChatLiveContentState, prompt: String, isStale: Bool = false) {
        self.state = state
        self.prompt = prompt.isEmpty ? "chat" : prompt
        self.isStale = isStale
    }

    var since: Date { Date(timeIntervalSince1970: state.since) }
    var isTerminal: Bool { state.isTerminal }
    var isDone: Bool { state.status == .done }
    var isFailed: Bool { state.status == .failed }
    var headline: String { ChatLiveCopy.headline(state, isStale: isStale) }
    var detail: String? { ChatLiveCopy.detail(state) }
    /// The reply so far (or its start, once done); nil before any text.
    var reply: String? { state.reply }

    /// The symbol for what the AI is doing now.
    var symbol: String {
        switch state.status {
        case .thinking: return "sparkles"
        case .working: return "hammer"
        case .writing: return "text.bubble"
        case .done: return Symbol.liveDone
        case .failed: return Symbol.liveFailed
        }
    }
}

// MARK: - pieces

struct ChatGlyph: View {
    let facts: ChatFacts
    var size: CGFloat = 13
    @Environment(\.isLuminanceReduced) private var reduced

    var body: some View {
        Image(systemName: facts.symbol)
            .font(.system(size: size, weight: .semibold))
            .foregroundStyle(LiveInk(reduced: reduced).primary)
            .symbolEffect(.pulse, isActive: !facts.isTerminal && !reduced)
            .contentTransition(.symbolEffect(.replace))
            .accessibilityHidden(true)
    }
}

struct ChatMark: View {
    let facts: ChatFacts
    @Environment(\.isLuminanceReduced) private var reduced

    var body: some View {
        Image(systemName: facts.isDone ? Symbol.liveDone : Symbol.liveFailed)
            .font(.system(size: 12, weight: .bold))
            .foregroundStyle(LiveInk(reduced: reduced).primary)
    }
}

/// The compact island's right side: how many tools so far while it works, the mark once it ended.
struct ChatCompactTrailing: View {
    let facts: ChatFacts
    @Environment(\.isLuminanceReduced) private var reduced

    var body: some View {
        if facts.isTerminal {
            ChatMark(facts: facts)
        } else if facts.state.steps > 0 {
            Text("\(facts.state.steps)")
                .font(liveFont(12, .medium))
                .monospacedDigit()
                .foregroundStyle(LiveInk(reduced: reduced).primary)
                .accessibilityLabel(ChatLiveCopy.detail(facts.state) ?? "")
        } else {
            LiveTimer(since: facts.since, size: 12, width: 36)
        }
    }
}

/// Headline, the counts and the reply: the expanded island's bottom and the Lock Screen card's body.
struct ChatBody: View {
    let facts: ChatFacts
    @Environment(\.isLuminanceReduced) private var reduced

    var body: some View {
        let ink = LiveInk(reduced: reduced)
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline) {
                Text(facts.headline)
                    .font(liveFont(15, .semibold))
                    .foregroundStyle(ink.primary)
                    .lineLimit(1)
                Spacer(minLength: 8)
                if let detail = facts.detail {
                    Text(detail)
                        .font(liveFont(12, .medium))
                        .foregroundStyle(ink.secondary)
                        .lineLimit(1)
                }
            }
            if let reply = facts.reply {
                Text(reply)
                    .font(liveFont(12))
                    .foregroundStyle(ink.secondary)
                    .lineLimit(facts.isTerminal ? 3 : 2)
                    .truncationMode(facts.isTerminal ? .tail : .head)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

struct ChatLockScreenView: View {
    let facts: ChatFacts

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                ChatGlyph(facts: facts, size: 14)
                LiveCaption(text: facts.prompt, size: 13)
                Spacer(minLength: 8)
                if facts.isTerminal {
                    ChatMark(facts: facts)
                } else {
                    LiveTimer(since: facts.since, size: 13)
                }
            }
            ChatBody(facts: facts)
        }
        .padding(16)
    }
}

#if DEBUG
// MARK: - previews

private enum ChatPreview {
    static let order = ["thinking", "working", "writing", "done", "failed"]
    static func states() -> [ChatLiveContentState] {
        let now = Date().timeIntervalSince1970
        return order.compactMap { name in
            guard var s = ChatLiveContentState.samples[name] else { return nil }
            s.since = now - 9
            return s
        }
    }
    static let attributes = CobaltChatActivityAttributes(
        ChatLiveAttributes(thread: "AbCdEfGh12345678", prompt: "find the clips from the beach trip", source: .shortcut))
}

#Preview("chat · island expanded", as: .dynamicIsland(.expanded), using: ChatPreview.attributes) {
    ChatLiveActivity()
} contentStates: {
    for state in ChatPreview.states() { state }
}

#Preview("chat · island compact", as: .dynamicIsland(.compact), using: ChatPreview.attributes) {
    ChatLiveActivity()
} contentStates: {
    for state in ChatPreview.states() { state }
}

#Preview("chat · island minimal", as: .dynamicIsland(.minimal), using: ChatPreview.attributes) {
    ChatLiveActivity()
} contentStates: {
    for state in ChatPreview.states() { state }
}

#Preview("chat · lock screen", as: .content, using: ChatPreview.attributes) {
    ChatLiveActivity()
} contentStates: {
    for state in ChatPreview.states() { state }
}
#endif
