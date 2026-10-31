import CobaltKit
import SwiftUI

// Helpers (APP-API-CONTRACT section 43.6): the sub-agents a chat started. While a thread has any, a strip under its header
// shows one chip each (name, status dot, the call it is on while it works); a tap opens the helper's own thread in a sheet,
// read-only: its mail with the chat on top, its task as the first bubble, its replies, and a footer with its status
// instead of the composer. The agents card (ChatToolCards.swift) draws its rows with the same chip.

// MARK: - opening a helper from a card

private struct OpenChatHelperKey: EnvironmentKey {
    static var defaultValue: (@MainActor (String) -> Void)? { nil }
}

extension EnvironmentValues {
    /// Opens a helper's thread by its id (the thread screen's sheet); nil where none can be opened (inside that sheet).
    var openChatHelper: (@MainActor (String) -> Void)? {
        get { self[OpenChatHelperKey.self] }
        set { self[OpenChatHelperKey.self] = newValue }
    }
}

// MARK: - the chip

/// A helper's status as a dot: blue and pulsing while it works, green when done, red when it didn't finish.
struct ChatHelperDot: View {
    let status: ChatAgent.Status

    private var color: Color {
        switch status {
        case .running: CobaltColor.linkBlue
        case .queued: CobaltColor.collection
        case .done: CobaltColor.success
        case .error: CobaltColor.errorText
        case .stopped, .unknown: CobaltColor.caption
        }
    }

    var body: some View {
        Image(systemName: Symbol.chatHelperDot)
            .font(.system(size: 7))
            .foregroundStyle(color)
            .symbolEffect(.pulse, isActive: status.isLive)
            .accessibilityHidden(true)
    }
}

/// One helper: its dot, its name, and what it is doing (the call while it works, else its status); "asked" when it sent
/// the chat a message not read yet.
struct ChatHelperChip: View {
    let name: String
    let status: ChatAgent.Status
    var activity: String? = nil
    var asked = false

    private var shownName: String { name.isEmpty ? Copy.Chat.helper : name }

    var body: some View {
        HStack(spacing: 5) {
            ChatHelperDot(status: status)
            Text(shownName)
                .foregroundStyle(CobaltColor.text)
            Text(Copy.Chat.helperState(status, activity: activity))
                .foregroundStyle(status == .error ? CobaltColor.errorText : CobaltColor.caption)
            if asked {
                Text(Copy.Chat.helperAsked)
                    .foregroundStyle(CobaltColor.collection)
            }
        }
        .font(CobaltType.badge)
        .lineLimit(1)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(CobaltColor.elevated, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Copy.Chat.helperA11y(name: shownName, status: status, activity: activity, asked: asked))
    }
}

/// One message between agents: an arrow, "to lia share 11:" / "from the chat:", the text.
struct ChatMailLine: View {
    let outgoing: Bool
    let label: String
    let text: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: outgoing ? Symbol.chatHelperSent : Symbol.chatHelperReceived)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(CobaltColor.caption)
                .accessibilityHidden(true)
            Text("\(Text("\(label):").font(Font.cobalt(12, .semibold))) \(text)")
                .font(Font.cobalt(12))
                .foregroundStyle(CobaltColor.text)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - the strip

/// Under a thread's header while it has helpers: a chip each, tap to open.
struct ChatHelperStrip: View {
    let list: ChatAgentList
    let open: (String) -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: Symbol.chatHelpers)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(CobaltColor.caption)
                .accessibilityHidden(true)
            Text(Copy.Chat.helpers)
                .font(CobaltType.badge)
                .foregroundStyle(CobaltColor.caption)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(list.agents) { agent in
                        Button { open(agent.id) } label: {
                            ChatHelperChip(
                                name: agent.name, status: agent.status, activity: agent.activity, asked: list.hasAsked(agent.id))
                        }
                        .buttonStyle(.plain)
                        .accessibilityHint(Copy.Chat.helperOpenHint)
                    }
                }
                .padding(.vertical, 7)
            }
            .scrollClipDisabled()
        }
        .padding(.horizontal, 16)
        .frame(maxWidth: 760)
        .frame(maxWidth: .infinity)
        .background(.bar)
        .motion(Motion.card, value: list)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Copy.Chat.helpers)
    }
}

/// The thread screen's helper parts, one modifier so its chain stays small: the strip on top (when `shows`), the sheet a
/// chip or a card opens, and the environment action the cards use.
struct ChatHelperChrome: ViewModifier {
    let model: AppModel
    let threadID: String
    let shows: Bool

    @State private var opened: ChatRoute?

    private var store: ChatStore { model.chat }

    private var openHelper: (@MainActor (String) -> Void)? {
        guard shows else { return nil }
        let target = $opened
        return { id in target.wrappedValue = ChatRoute(id: id) }
    }

    func body(content: Content) -> some View {
        content
            .safeAreaInset(edge: .top, spacing: 0) {
                if shows, !store.agents(of: threadID).isEmpty {
                    ChatHelperStrip(list: store.agents(of: threadID)) { opened = ChatRoute(id: $0) }
                }
            }
            .environment(\.openChatHelper, openHelper)
            .sheet(item: $opened) { route in
                ChatHelperSheet(model: model, agentID: route.id, parentID: threadID)
            }
    }
}

// MARK: - a helper's thread

/// A helper's own thread in a sheet: the thread screen, read-only, with a close button.
struct ChatHelperSheet: View {
    let model: AppModel
    let agentID: String
    let parentID: String

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            // compact: a shown post opens inside the sheet, not in the library tab behind it
            ChatThreadScreen(model: model, threadID: agentID, tier: .compact, helperOf: parentID)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button { dismiss() } label: {
                            Label(Copy.Chat.helperClose, systemImage: Symbol.close)
                                .labelStyle(.iconOnly)
                        }
                        .iconName(Copy.Chat.helperClose)
                    }
                }
        }
        .cobaltRoot(model: model)
        #if os(macOS)
        .frame(minWidth: 520, minHeight: 620)
        #endif
        .onAppear { model.chat.openAgentID = agentID }
        .onDisappear { if model.chat.openAgentID == agentID { model.chat.openAgentID = nil } }
    }
}

/// On top of a helper's thread: the messages between it and the chat, oldest first.
struct ChatHelperMail: View {
    let mail: [ChatAgentMail]

    var body: some View {
        if !mail.isEmpty {
            VStack(alignment: .leading, spacing: 7) {
                Text(Copy.Chat.helperMail)
                    .font(Font.cobalt(12, .semibold))
                    .foregroundStyle(CobaltColor.caption)
                ForEach(mail) { m in
                    // seen from the helper: the chat's messages came in, its own went out
                    ChatMailLine(
                        outgoing: !m.isFromParent,
                        label: m.isFromParent ? Copy.Chat.helperFrom(m.fromName) : Copy.Chat.helperTo(m.toName),
                        text: m.text)
                }
            }
            .padding(11)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(CobaltColor.row, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(CobaltColor.hairline, lineWidth: 1))
            .accessibilityElement(children: .contain)
        }
    }
}

/// In place of the composer on a helper's thread: its status and why nobody can write here.
struct ChatHelperFooter: View {
    let model: AppModel
    let content: ChatThreadContent
    let parentID: String?

    private var agent: ChatAgent? { parentID.flatMap { model.chat.agents(of: $0).agent(content.thread.id) } }
    private var status: ChatAgent.Status { agent?.status ?? content.agent?.status ?? .unknown }

    var body: some View {
        HStack(spacing: 10) {
            ChatHelperDot(status: status)
            VStack(alignment: .leading, spacing: 2) {
                Text(Copy.Chat.helperFooter(status, activity: agent?.activity, error: agent?.error))
                    .font(CobaltType.bodySemibold)
                    .foregroundStyle(status == .error ? CobaltColor.errorText : CobaltColor.text)
                    .lineLimit(1)
                Text(Copy.Chat.helperReadOnly)
                    .font(CobaltType.caption)
                    .foregroundStyle(CobaltColor.caption)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .accessibilityElement(children: .combine)
    }
}
