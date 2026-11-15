import CobaltKit
import SwiftUI

// The one swarm screen (CONTRACT-SWARMS 3.2): it fills in as the swarm moves. Waiting: who asks, the name as a sentence, three
// facts, "see exactly what it's told", decline and approve. Running: the bar, the agent grid, the agents that failed or ask,
// stop. Ready: "check first" and "apply n". Done or failed: a line and "see results". The store polls while it is shown (the
// list screen calls `show` and `hide`); every answer goes through a `SwarmController`, and approve and apply run the Face ID
// check inside the store.

struct SwarmScreen: View {
    let model: AppModel
    let dest: SwarmDestination

    @State private var controller = SwarmController()
    @State private var step: SwarmStep?
    @State private var agent: Int?
    @State private var started = false
    @State private var width: CGFloat = 0

    private var store: SwarmStore { model.swarms }

    /// The swarm on screen: the store's shown one, or what the list knew while it loads.
    private var swarm: Swarm? {
        if let shown = store.shown, shown.id == dest.id { return shown }
        return store.list.first { $0.id == dest.id }
    }

    private var columns: Int { width >= 720 ? 20 : 10 }

    var body: some View {
        Group {
            if let swarm {
                content(swarm)
            } else if let problem = store.shownProblem {
                VStack(spacing: 12) {
                    InlineStatus(message: problem == .notFound ? Copy.Swarms.gone : Copy.Swarms.problem(problem))
                    Button(Copy.Swarms.tryAgain) { Task { await store.show(id: dest.id) } }
                        .buttonStyle(.cobaltSecondary(fullWidth: false))
                }
                .padding(Metrics.gutter)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(spacing: 10) {
                    ProgressView()
                    Text(Copy.Swarms.loadingOne).font(CobaltType.caption).foregroundStyle(CobaltColor.caption)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(CobaltColor.bg)
        .navigationTitle(Copy.Swarms.title)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .navigationDestination(item: $step) { step in
            switch step {
            case .told: if let swarm { SwarmToldScreen(swarm: swarm) }
            case .check: SwarmCheckScreen(model: model)
            case .board: SwarmBoardScreen(model: model)
            }
        }
        .agentPresenter(model: model, agent: $agent)
        .task {
            // a link or a launch argument opens on a step or an agent, once
            guard !started else { return }
            started = true
            if let s = dest.step { step = s }
            if let a = dest.agent { agent = a }
        }
    }

    // MARK: what it says

    private enum Phase { case awaiting, working, applying, review, applied, ended }

    private func phase(_ swarm: Swarm) -> Phase {
        switch swarm.status {
        case .awaitingApproval: return .awaiting
        case .running, .stopping: return .working
        case .done:
            switch swarm.apply.status {
            case .applying: return .applying
            case .ready: return .review
            case .none, .applied, .failed: return .applied
            }
        case .failed, .stopped, .declined, .expired: return .ended
        }
    }

    @ViewBuilder
    private func content(_ swarm: Swarm) -> some View {
        let phase = phase(swarm)
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                TimelineView(.periodic(from: .now, by: 15)) { context in
                    SwarmWho(text: SwarmWords.statusLine(swarm, now: context.date), tint: phase == .awaiting || phase == .review ? SwarmColor.amber : CobaltColor.caption)
                }
                SwarmSentence(text: swarm.name)
                switch phase {
                case .awaiting: awaiting(swarm)
                case .working: working(swarm)
                case .applying: applying(swarm)
                case .review: review(swarm)
                case .applied: applied(swarm)
                case .ended: ended(swarm)
                }
                if let problem = store.shownProblem, phase != .awaiting {
                    InlineStatus(message: Copy.Swarms.problem(problem))
                }
            }
            .padding(.horizontal, Metrics.gutter)
            .padding(.top, 8)
            .padding(.bottom, 24)
            .frame(maxWidth: 640, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .refreshable { await store.show(id: dest.id) }
        .safeAreaInset(edge: .bottom, spacing: 0) { actionBar(swarm, phase) }
    }

    // MARK: waiting for you

    private func awaiting(_ swarm: Swarm) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            SwarmCard {
                SwarmFactRow(symbol: factSymbol(swarm), text: SwarmWords.whatHappens(swarm))
                SwarmFactRow(symbol: Symbol.Swarms.factSize, text: SwarmWords.size(swarm))
                SwarmFactRow(symbol: Symbol.Swarms.factCost, text: SwarmWords.cost(swarm), last: true)
            }
            navRow(symbol: Symbol.Swarms.told, text: Copy.Swarms.seeTold, step: .told)
        }
    }

    private func factSymbol(_ swarm: Swarm) -> String {
        switch swarm.mode {
        case .propose: return Symbol.Swarms.factSafe
        case .read: return Symbol.Swarms.factLooks
        case .act: return Symbol.Swarms.factChanges
        }
    }

    private func navRow(symbol: String, text: String, step target: SwarmStep) -> some View {
        Button { step = target } label: {
            HStack(spacing: 12) {
                Image(systemName: symbol).font(.system(size: 14, weight: .medium)).frame(width: 20).accessibilityHidden(true)
                Text(text).font(CobaltType.body)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: Symbol.Swarms.more).font(.system(size: 12, weight: .semibold))
            }
            .foregroundStyle(CobaltColor.caption)
            .padding(.horizontal, 14)
            .frame(minHeight: Metrics.hit + 4)
            .background(CobaltColor.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay { RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(CobaltColor.border.opacity(0.5), lineWidth: 1) }
            .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    // MARK: running

    private func working(_ swarm: Swarm) -> some View {
        let tasks = swarm.tasks
        let finished = tasks.done + tasks.failed
        return VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                SwarmBar(fraction: tasks.total > 0 ? Double(finished) / Double(tasks.total) : 0)
                HStack {
                    Text(Copy.Swarms.agentsDone(tasks.done, of: tasks.total))
                    Spacer()
                    Text(SwarmWords.money(swarm.spentUSD))
                }
                .font(CobaltType.caption)
                .foregroundStyle(CobaltColor.caption)
                .accessibilityElement(children: .combine)
            }
            grid(swarm)
            rows(swarm, canRetry: false)
            if tasks.done + tasks.failed > 0 { navRow(symbol: Symbol.Swarms.results, text: Copy.Swarms.seeResults, step: .board) }
        }
    }

    private func grid(_ swarm: Swarm) -> some View {
        SwarmAgentGrid(cells: swarm.tasks.cells, selected: agent, columns: columns) { agent = $0 }
    }

    private func rows(_ swarm: Swarm, canRetry: Bool) -> some View {
        SwarmAgentRows(swarm: swarm, canRetry: canRetry, busy: controller.busy, open: { agent = $0 }) {
            Task { await controller.run { try await store.retry() } }
        }
    }

    // MARK: applying, ready, done

    private func applying(_ swarm: Swarm) -> some View {
        let a = swarm.apply
        return VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                SwarmBar(fraction: a.total > 0 ? Double(a.done + a.failed) / Double(a.total) : 0)
                HStack {
                    Text(Copy.Swarms.changesApplied(a.done, of: a.total))
                    Spacer()
                    Text(SwarmWords.money(swarm.spentUSD))
                }
                .font(CobaltType.caption)
                .foregroundStyle(CobaltColor.caption)
                .accessibilityElement(children: .combine)
            }
            grid(swarm)
        }
    }

    private func review(_ swarm: Swarm) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            SwarmCard {
                if swarm.clashCount > 0 {
                    SwarmFactRow(symbol: Symbol.Swarms.factDuplicates, text: Copy.Swarms.duplicatesLeftOut(swarm.clashCount))
                }
                SwarmFactRow(symbol: Symbol.Swarms.factSpent, text: Copy.Swarms.spent(SwarmWords.money(swarm.spentUSD)), last: true)
            }
            grid(swarm)
            rows(swarm, canRetry: true)
            navRow(symbol: Symbol.Swarms.results, text: Copy.Swarms.seeResults, step: .board)
        }
    }

    private func applied(_ swarm: Swarm) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            if swarm.mode == .propose, swarm.apply.status != .none {
                SwarmCard {
                    SwarmFactRow(symbol: Symbol.Swarms.applied, text: Copy.Swarms.applied(swarm.apply.done), last: swarm.apply.failed == 0)
                    if swarm.apply.failed > 0 {
                        SwarmFactRow(symbol: Symbol.Swarms.failed, text: Copy.Swarms.applyFailed(swarm.apply.failed), last: true)
                    }
                }
            }
            grid(swarm)
            rows(swarm, canRetry: true)
            if swarm.mode == .propose, swarm.apply.status != .none {
                navRow(symbol: Symbol.Swarms.changes, text: Copy.Swarms.seeChanges, step: .check)
            }
            navRow(symbol: Symbol.Swarms.results, text: Copy.Swarms.seeResults, step: .board)
        }
    }

    @ViewBuilder
    private func ended(_ swarm: Swarm) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            if swarm.status == .failed {
                Text(swarm.error ?? Copy.Swarms.noError)
                    .font(CobaltType.body)
                    .foregroundStyle(CobaltColor.errorText)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if !swarm.tasks.cells.isEmpty, swarm.tasks.done + swarm.tasks.failed > 0 {
                grid(swarm)
                rows(swarm, canRetry: swarm.status != .declined && swarm.status != .expired)
                navRow(symbol: Symbol.Swarms.results, text: Copy.Swarms.seeResults, step: .board)
            }
        }
    }

    // MARK: the buttons

    @ViewBuilder
    private func actionBar(_ swarm: Swarm, _ phase: Phase) -> some View {
        let showsBar = phase == .awaiting || phase == .review || swarm.status == .running || swarm.status == .stopping
        if showsBar || controller.problem != nil {
            VStack(spacing: 8) {
                if let problem = controller.problem {
                    SwarmProblemLine(error: problem) { controller.clear() }
                }
                switch phase {
                case .awaiting:
                    ButtonRow {
                        Button(Copy.Swarms.decline) { Task { await controller.run { try await store.decline() } } }
                            .buttonStyle(.cobaltSecondary())
                        Button(Copy.Swarms.approve) { Task { await controller.run { try await store.approve() } } }
                            .buttonStyle(.cobaltPrimary())
                    }
                    .disabled(controller.busy)
                    Text(Copy.Swarms.confirmHint).font(CobaltType.captionSmall).foregroundStyle(CobaltColor.caption)
                case .review:
                    ButtonRow {
                        Button(Copy.Swarms.checkFirst) { step = .check }
                            .buttonStyle(.cobaltSecondary())
                        Button(Copy.Swarms.apply(applyCount(swarm))) {
                            Task { await controller.run { try await store.apply(skipClashes: true) } }
                        }
                        .buttonStyle(.cobaltPrimary())
                        .disabled(applyCount(swarm) == 0)
                    }
                    .disabled(controller.busy)
                    Text(Copy.Swarms.confirmHint).font(CobaltType.captionSmall).foregroundStyle(CobaltColor.caption)
                case .working:
                    Button(swarm.status == .stopping ? Copy.Swarms.stopping : Copy.Swarms.stop) {
                        Task { await controller.run { try await store.stop() } }
                    }
                    .buttonStyle(.cobaltSecondary())
                    .disabled(controller.busy || swarm.status == .stopping)
                default:
                    EmptyView()
                }
            }
            .padding(.horizontal, Metrics.gutter)
            .padding(.top, 10)
            .padding(.bottom, 8)
            .frame(maxWidth: 640)
            .frame(maxWidth: .infinity)
            .background(CobaltColor.bg)
        }
    }

    /// What "apply" will do: the kept changes with no clash once they are read, else what the server counted.
    private func applyCount(_ swarm: Swarm) -> Int {
        guard !store.changes.isEmpty else { return swarm.applyCount }
        return store.changes.filter { $0.keep && $0.clash == nil && $0.status == .proposed }.count
    }
}
