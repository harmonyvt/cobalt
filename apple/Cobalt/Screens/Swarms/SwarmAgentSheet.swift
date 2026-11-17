import CobaltKit
import SwiftUI

// The agent sheet (CONTRACT-SWARMS 3.3): "agent 4", one line on how it went, what it did, its changes and its conversation as
// bubbles (the agent on the left, the owner and you on the right, "→ all agents" marked). While the swarm runs a reply box sends
// to that agent. Arrows step to the next agent. A half sheet on iPhone; on a wide window (Mac, iPad) a column beside the screen.

extension View {
    /// Presents the agent `agent` names: a half sheet when narrow, a 340 pt column when the window is 720 pt or wider.
    func agentPresenter(model: AppModel, agent: Binding<Int?>) -> some View {
        modifier(AgentPresenter(model: model, agent: agent))
    }
}

private struct AgentPresenter: ViewModifier {
    let model: AppModel
    @Binding var agent: Int?
    @State private var width: CGFloat = 0

    private var wide: Bool { width >= 720 }

    private var sheetShown: Binding<Bool> {
        Binding(
            get: { !wide && agent != nil },
            set: { if !$0 { close() } })
    }

    private func close() {
        agent = nil
        model.swarms.closeAgent()
    }

    func body(content: Content) -> some View {
        HStack(spacing: 0) {
            content.frame(maxWidth: .infinity)
            if wide, agent != nil {
                Divider()
                SwarmAgentSheet(model: model, agent: $agent, wide: true, close: close)
                    .frame(width: 340)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .motion(Motion.card, value: agent != nil && wide)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .sheet(isPresented: sheetShown, onDismiss: { model.swarms.closeAgent() }) {
            SwarmAgentSheet(model: model, agent: $agent, wide: false, close: close)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
                .presentationBackground(CobaltColor.bg)
                .cobaltRoot(model: model)
        }
    }
}

struct SwarmAgentSheet: View {
    let model: AppModel
    @Binding var agent: Int?
    let wide: Bool
    let close: () -> Void

    @State private var controller = SwarmController()
    @State private var draft = ""
    @FocusState private var typing: Bool

    private var store: SwarmStore { model.swarms }
    private var swarm: Swarm? { store.shown }
    private var number: Int { agent ?? 1 }
    private var total: Int { swarm?.tasks.cells.count ?? 0 }
    /// The agent the store holds, once it is the one on screen.
    private var detail: SwarmAgent? { store.agent?.agent == number ? store.agent : nil }
    /// Replies go to an agent that can still read them.
    private var canReply: Bool {
        guard let swarm, swarm.status == .running else { return false }
        guard let status = detail?.status ?? swarm.tasks.cells.first(where: { $0.agent == number })?.status else { return true }
        return status == .running || status == .waiting || status == .queued
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: 18) { body(for: detail) }
                    .padding(.horizontal, Metrics.gutter)
                    .padding(.bottom, 16)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if canReply { replyBox }
        }
        .background(CobaltColor.bg)
        .task(id: number) { await store.loadAgent(number) }
    }

    // MARK: the header

    private var header: some View {
        HStack(spacing: 8) {
            Button { step(-1) } label: { Image(systemName: Symbol.Swarms.previous).font(.system(size: 14, weight: .semibold)) }
                .buttonStyle(.glass).buttonBorderShape(.circle)
                .disabled(number <= 1)
                .accessibilityLabel(Copy.Swarms.previousAgent)
            VStack(spacing: 2) {
                Text(Copy.Swarms.agent(number))
                    .font(CobaltType.sheetTitle)
                    .accessibilityAddTraits(.isHeader)
                if let swarm {
                    Text(summary(swarm))
                        .font(CobaltType.caption).foregroundStyle(CobaltColor.caption)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity)
            Button { step(1) } label: { Image(systemName: Symbol.Swarms.next).font(.system(size: 14, weight: .semibold)) }
                .buttonStyle(.glass).buttonBorderShape(.circle)
                .disabled(number >= total)
                .accessibilityLabel(Copy.Swarms.nextAgent)
            if wide {
                CloseButton(action: close)
            }
        }
        .padding(.horizontal, Metrics.gutter)
        .padding(.top, wide ? 12 : 18)
        .padding(.bottom, 12)
    }

    /// "done in 41 s · 1¢ · items 151–200", with how it went when the board knows ("20 items · 18 answered · … · score 0.75").
    private func summary(_ swarm: Swarm) -> String {
        if let detail { return SwarmWords.agentLine(detail, batchSize: swarm.batchSize) }
        return SwarmWords.agentLine(
            SwarmAgent(swarm: swarm.id, agent: number, status: swarm.tasks.cells.first { $0.agent == number }?.status ?? .queued),
            batchSize: swarm.batchSize)
    }

    private func step(_ delta: Int) {
        let next = number + delta
        guard next >= 1, next <= max(total, 1) else { return }
        agent = next
    }

    // MARK: what it did

    @ViewBuilder
    private func body(for detail: SwarmAgent?) -> some View {
        if let outcome = store.board?.agents.first(where: { $0.agent == number })?.outcome {
            Text(SwarmWords.outcome(outcome))
                .font(CobaltType.caption).foregroundStyle(CobaltColor.caption)
        }
        if let detail {
            if let error = detail.error {
                Text(error).font(CobaltType.body).foregroundStyle(CobaltColor.errorText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            block(Copy.Swarms.did) {
                if detail.steps.isEmpty {
                    placeholder(Copy.Swarms.nothingYet)
                } else {
                    SwarmCard {
                        ForEach(Array(detail.steps.enumerated()), id: \.offset) { index, item in
                            line(item.text, last: index == detail.steps.count - 1)
                        }
                    }
                }
            }
            if !detail.changes.isEmpty {
                block(Copy.Swarms.itsChanges) {
                    SwarmCard {
                        let shown = Array(detail.changes.prefix(20))
                        ForEach(Array(shown.enumerated()), id: \.offset) { index, change in
                            line(Self.changeLine(change), last: index == shown.count - 1 && detail.changes.count <= shown.count)
                        }
                        if detail.changes.count > shown.count {
                            Text(Copy.Swarms.andMore(detail.changes.count - shown.count))
                                .font(CobaltType.caption).foregroundStyle(CobaltColor.caption)
                                .padding(.horizontal, 14).padding(.vertical, 10)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
            }
            block(Copy.Swarms.conversation) {
                if detail.messages.isEmpty {
                    placeholder(Copy.Swarms.nothingYet)
                } else {
                    VStack(spacing: 8) {
                        ForEach(detail.messages) { SwarmBubble(message: $0, planner: swarm?.planner) }
                    }
                }
            }
        } else if let problem = store.agentProblem {
            InlineStatus(message: Copy.Swarms.problem(problem)) {
                Button(Copy.Swarms.tryAgain) { Task { await store.loadAgent(number) } }
                    .buttonStyle(.cobaltSecondary(fullWidth: false, compact: true))
            }
        } else {
            HStack(spacing: 10) {
                ProgressView()
                Text(Copy.Swarms.thinking).font(CobaltType.caption).foregroundStyle(CobaltColor.caption)
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 24)
        }
    }

    static func changeLine(_ change: SwarmChange) -> String {
        switch (change.before, change.after) {
        case (let before?, let after?): return "\(before) → \(after)"
        case (nil, let after?): return after
        case (let before?, nil): return before
        default: return [SwarmWords.writeWords(change.op), change.target].compactMap { $0 }.joined(separator: " · ")
        }
    }

    private func block<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(CobaltType.caption).foregroundStyle(CobaltColor.caption)
                .accessibilityAddTraits(.isHeader)
            content()
        }
    }

    private func placeholder(_ text: String) -> some View {
        Text(text).font(CobaltType.body).foregroundStyle(CobaltColor.caption)
    }

    private func line(_ text: String, last: Bool) -> some View {
        VStack(spacing: 0) {
            Text(text)
                .font(CobaltType.body)
                .foregroundStyle(CobaltColor.text)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14).padding(.vertical, 10)
            if !last { Divider().overlay(CobaltColor.hairline).padding(.leading, 14) }
        }
    }

    // MARK: the reply box

    private var replyBox: some View {
        VStack(spacing: 6) {
            if let problem = controller.problem {
                SwarmProblemLine(error: problem) { controller.clear() }
            }
            HStack(spacing: 8) {
                TextField(Copy.Swarms.reply(to: number), text: $draft, axis: .vertical)
                    .font(CobaltType.body)
                    .lineLimit(1...4)
                    .textFieldStyle(.plain)
                    .focused($typing)
                    .submitLabel(.send)
                    .onSubmit(send)
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .background(CobaltColor.surface, in: Capsule())
                Button(action: send) {
                    Image(systemName: Symbol.Swarms.send).font(.system(size: 30))
                        .foregroundStyle(trimmed.isEmpty ? CobaltColor.border : CobaltColor.text)
                }
                .buttonStyle(.plain)
                .disabled(trimmed.isEmpty || controller.busy)
                .accessibilityLabel(Copy.Swarms.sendA11y)
            }
        }
        .padding(.horizontal, Metrics.gutter)
        .padding(.vertical, 10)
        .background(CobaltColor.bg)
    }

    private var trimmed: String { draft.trimmingCharacters(in: .whitespacesAndNewlines) }

    private func send() {
        let text = trimmed
        guard !text.isEmpty else { return }
        let to = number
        Task {
            await controller.run { try await store.send(to: .agent(to), text: text) }
            if controller.problem == nil { draft = "" }
        }
    }
}

// MARK: - one message

struct SwarmBubble: View {
    let message: SwarmMessage
    let planner: String?

    private var fromAgent: Bool { message.sender == .agent }

    var body: some View {
        VStack(alignment: fromAgent ? .leading : .trailing, spacing: 3) {
            Text(label)
                .font(CobaltType.badge)
                .foregroundStyle(CobaltColor.caption)
            Text(message.text)
                .font(Font.cobalt(12.5, .regular, relativeTo: .footnote))
                .foregroundStyle(CobaltColor.text)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(fromAgent ? CobaltColor.elevated : SwarmColor.ownerBubble, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            if message.isOpenAsk {
                Text(Copy.Swarms.waitingForAnswer).font(CobaltType.badge).foregroundStyle(SwarmColor.amber)
            }
        }
        .frame(maxWidth: .infinity, alignment: fromAgent ? .leading : .trailing)
        .accessibilityElement(children: .combine)
    }

    /// "agent 7 → claude code", "claude code → agent 7", "claude code → all agents", "you → agent 7".
    private var label: String {
        let agent = message.agent.map(Copy.Swarms.agent) ?? Copy.Swarms.allAgents
        let owner = planner ?? "the one that asked"
        switch message.sender {
        case .agent: return Copy.Swarms.conversationLabel(from: agent, to: owner)
        case .owner: return Copy.Swarms.conversationLabel(from: owner, to: agent == Copy.Swarms.allAgents ? Copy.Swarms.allAgents : agent)
        case .you: return Copy.Swarms.conversationLabel(from: Copy.Swarms.you, to: agent)
        }
    }
}
