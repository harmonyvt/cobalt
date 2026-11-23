import CobaltKit
import SwiftUI

// One swarm in the screen pane (apple/CONTRACT-PANE.md section 5; CONTRACT-SWARMS 3.2). It fills in as the swarm moves:
// the hero is the agent grid (one square per agent), the controls are the answer to give (approve or decline, stop, apply
// or check first, see the results), the body says in plain words where it is, and the shelf holds the agent you picked
// (what it did, its conversation, a reply box) and the swarm's other screens (what it is told, the changes, the results
// board). Spanned, the grid is one screen and the words, the agent's messages and the results are the other.
//
// `keepsRunning` while agents or changes are being worked on: the page reports it in every shape, so closing leaves the
// bar (a small grid, "3 of 10 agents done", stop). The store polls while the swarm is shown: this page shows it when it
// appears and lets it go once the pane has moved on (`paneKeeps`). Every answer goes through a `SwarmController`, and
// approve and apply run the Face ID check inside the store.

struct SwarmPage: View {
    let id: String
    let model: AppModel

    @Environment(Pane.self) private var pane
    @Environment(\.paneShape) private var shape
    @Environment(\.paneHeaderHeight) private var headerHeight
    @Environment(\.lifecycle) private var lifecycle
    @State private var controller = SwarmController()
    @State private var step: SwarmStep?
    @State private var agent: Int?
    @State private var started = false

    private var store: SwarmStore { model.swarms }
    private var item: PaneItem { .swarm(id) }

    /// The swarm on screen: the store's shown one, or what the list knew while it loads.
    private var swarm: Swarm? {
        if let shown = store.shown, shown.id == id { return shown }
        return store.list.first { $0.id == id }
    }

    /// The server says this swarm does not exist (deleted, or a restored route for one that was never there).
    private var isGone: Bool {
        store.shownProblem == .notFound && (store.shown == nil || store.shown?.id == id)
    }

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

    // MARK: the page

    var body: some View {
        Group {
            if let swarm {
                page(swarm)
            } else if let problem = store.shownProblem {
                problemPage(problem)
            } else {
                PaneLoadingPage()
            }
        }
        .task {
            // already on screen (a page for another shape took it first): nothing to read again
            if store.shown?.id != id || !store.isPolling { await store.show(id: id) }
        }
        .task {
            // a link or a launch argument opens on a step or an agent, once
            guard !started else { return }
            started = true
            if let intent = SwarmPaneIntent.take(id) {
                if let s = intent.step { step = s }
                if let a = intent.agent { agent = a }
            }
        }
        .onChange(of: swarm?.isWorking, initial: true) { _, working in
            // nothing is claimed until the swarm is known: a bar restored at launch keeps its place until then
            if let working { pane.setRunning(working, for: item) }
        }
        .onChange(of: isGone, initial: true) { _, gone in
            // a swarm the server does not know is never running: the pane lets go of it (no stuck bar, no restored route)
            if gone { pane.itemGone(item) }
        }
        .onChange(of: inFront) { _, inFront in
            // nothing is read while the app is away; coming back reads the list and the swarm again
            guard inFront else { return }
            Task {
                await store.loadList()
                await store.show(id: id)
            }
        }
        .paneKeeps(item) {
            if store.shown?.id == id { store.hide() }
        }
        .navigationDestination(item: $step) { step in
            switch step {
            case .told: if let swarm { SwarmToldScreen(swarm: swarm) }
            case .check: SwarmCheckScreen(model: model)
            case .board: SwarmBoardScreen(model: model)
            }
        }
        .onChange(of: agent) { _, agent in
            if agent == nil { store.closeAgent() } else { pane.setShelf(0) }
        }
    }

    /// Whether the app counts as in front. iPhone and iPad: active. The Mac: not hidden, because scenePhase never left
    /// `.active` for Cmd-Tab, and hiding the swarm there would drop the open board's search and sort every time another
    /// app came to the front.
    private var inFront: Bool {
        #if os(macOS)
        return lifecycle.isForeground
        #else
        return lifecycle.isActive
        #endif
    }

    private func problemPage(_ problem: SwarmError) -> some View {
        VStack(spacing: 12) {
            InlineStatus(message: problem == .notFound ? Copy.Swarms.gone : Copy.Swarms.problem(problem))
            if problem != .notFound {
                Button(Copy.Swarms.tryAgain) { Task { await store.show(id: id) } }
                    .buttonStyle(.cobaltSecondary(fullWidth: false))
            }
        }
        .padding(Metrics.gutter)
        .padding(.top, shape == .bar ? 0 : headerHeight)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func page(_ swarm: Swarm) -> some View {
        let phase = phase(swarm)
        return PanePage(
            title: swarm.name, subtitle: subtitle(swarm), progress: progress(swarm, phase)
        ) {
            hero(swarm)
        } controls: {
            controls(swarm, phase)
        } body: {
            words(swarm, phase)
        } shelf: {
            if let number = agent {
                PaneCard(Copy.Swarms.agent(number)) {
                    SwarmAgentSheet(model: model, agent: $agent, wide: false, close: { agent = nil })
                        .frame(height: shape.isSplit ? 560 : 480)
                        .clipShape(.rect(cornerRadius: 14))
                }
            }
            PaneCard(Copy.Swarms.boardTitle) {
                results(swarm, phase)
            }
        }
    }

    private func subtitle(_ swarm: Swarm) -> String {
        SwarmWords.statusLine(swarm, now: Date())
    }

    /// The hairline: agents done while it runs, changes applied while it applies.
    private func progress(_ swarm: Swarm, _ phase: Phase) -> Double? {
        switch phase {
        case .working:
            let tasks = swarm.tasks
            return tasks.total > 0 ? Double(tasks.done + tasks.failed) / Double(tasks.total) : 0
        case .applying:
            let a = swarm.apply
            return a.total > 0 ? Double(a.done + a.failed) / Double(a.total) : 0
        default:
            return nil
        }
    }

    // MARK: the hero: one square per agent

    @ViewBuilder
    private func hero(_ swarm: Swarm) -> some View {
        let cells = swarm.tasks.cells
        switch shape {
        case .bar:
            ZStack {
                CobaltColor.surface
                Image(systemName: Symbol.Swarms.tab)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(swarm.isWorking ? CobaltColor.text : CobaltColor.caption)
            }
        default:
            ZStack {
                CobaltColor.surface
                if cells.isEmpty {
                    Image(systemName: Symbol.Swarms.tab)
                        .font(.system(size: 36, weight: .light))
                        .foregroundStyle(CobaltColor.caption)
                        .accessibilityHidden(true)
                } else {
                    SwarmAgentGrid(cells: cells, selected: agent, columns: columns(cells.count)) { agent = $0 }
                        .padding(16)
                }
            }
            .padding(.top, shape == .tall ? headerHeight : 0)
            .background(CobaltColor.surface)
        }
    }

    private func columns(_ count: Int) -> Int {
        let base = count > 100 ? 20 : count > 40 ? 14 : 10
        return shape == .tall ? base : base + 6
    }

    // MARK: the words

    @ViewBuilder
    private func words(_ swarm: Swarm, _ phase: Phase) -> some View {
        VStack(alignment: .leading, spacing: 16) {
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
        .padding(.horizontal, 16)
    }

    private func awaiting(_ swarm: Swarm) -> some View {
        SwarmCard {
            SwarmFactRow(symbol: factSymbol(swarm), text: SwarmWords.whatHappens(swarm))
            SwarmFactRow(symbol: Symbol.Swarms.factSize, text: SwarmWords.size(swarm))
            SwarmFactRow(symbol: Symbol.Swarms.factCost, text: SwarmWords.cost(swarm), last: true)
        }
    }

    private func factSymbol(_ swarm: Swarm) -> String {
        switch swarm.mode {
        case .propose: return Symbol.Swarms.factSafe
        case .read: return Symbol.Swarms.factLooks
        case .act: return Symbol.Swarms.factChanges
        }
    }

    private func working(_ swarm: Swarm) -> some View {
        let tasks = swarm.tasks
        return VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(Copy.Swarms.agentsDone(tasks.done, of: tasks.total))
                Spacer()
                Text(SwarmWords.money(swarm.spentUSD))
            }
            .font(CobaltType.caption)
            .foregroundStyle(CobaltColor.caption)
            .accessibilityElement(children: .combine)
            rows(swarm, canRetry: false)
        }
    }

    private func applying(_ swarm: Swarm) -> some View {
        let a = swarm.apply
        return HStack {
            Text(Copy.Swarms.changesApplied(a.done, of: a.total))
            Spacer()
            Text(SwarmWords.money(swarm.spentUSD))
        }
        .font(CobaltType.caption)
        .foregroundStyle(CobaltColor.caption)
        .accessibilityElement(children: .combine)
    }

    private func review(_ swarm: Swarm) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            SwarmCard {
                if swarm.clashCount > 0 {
                    SwarmFactRow(symbol: Symbol.Swarms.factDuplicates, text: Copy.Swarms.duplicatesLeftOut(swarm.clashCount))
                }
                SwarmFactRow(symbol: Symbol.Swarms.factSpent, text: Copy.Swarms.spent(SwarmWords.money(swarm.spentUSD)), last: true)
            }
            rows(swarm, canRetry: true)
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
            rows(swarm, canRetry: true)
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
                rows(swarm, canRetry: swarm.status != .declined && swarm.status != .expired)
            }
        }
    }

    private func rows(_ swarm: Swarm, canRetry: Bool) -> some View {
        SwarmAgentRows(swarm: swarm, canRetry: canRetry, busy: controller.busy, open: { agent = $0 }) {
            Task { await controller.run { try await store.retry() } }
        }
    }

    // MARK: the controls

    @ViewBuilder
    private func controls(_ swarm: Swarm, _ phase: Phase) -> some View {
        if shape == .bar {
            barControl(swarm)
        } else {
            VStack(alignment: .leading, spacing: 10) {
                if let problem = controller.problem {
                    SwarmProblemLine(error: problem) { controller.clear() }
                }
                let actions = actions(swarm, phase)
                if !actions.isEmpty { PaneActionGrid(actions) }
                if phase == .awaiting || phase == .review {
                    Text(Copy.Swarms.confirmHint).font(CobaltType.captionSmall).foregroundStyle(CobaltColor.caption)
                }
            }
        }
    }

    /// The bar's one control: stop, while it runs.
    @ViewBuilder
    private func barControl(_ swarm: Swarm) -> some View {
        if swarm.status == .running || swarm.status == .stopping {
            Button { answer { try await store.stop() } } label: {
                Image(systemName: Symbol.Swarms.stop).font(.system(size: 14, weight: .semibold))
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
            #if os(iOS)
            .controlSize(.large)
            #endif
            .disabled(controller.busy || swarm.status == .stopping)
            .accessibilityLabel(swarm.status == .stopping ? Copy.Swarms.stopping : Copy.Swarms.stop)
        }
    }

    private func actions(_ swarm: Swarm, _ phase: Phase) -> [PaneAction] {
        let busy = controller.busy
        switch phase {
        case .awaiting:
            return [
                PaneAction(Copy.Swarms.approve, systemImage: "checkmark", needsServer: true, disabled: busy) {
                    answer { try await store.approve() }
                },
                PaneAction(Copy.Swarms.decline, systemImage: Symbol.Swarms.close, needsServer: true, disabled: busy) {
                    answer { try await store.decline() }
                },
            ]
        case .review:
            return [
                PaneAction(
                    Copy.Swarms.apply(store.applyCount), systemImage: Symbol.Swarms.applied, needsServer: true,
                    disabled: busy || store.applyCount == 0
                ) { answer { try await store.apply(skipClashes: true) } },
                PaneAction(Copy.Swarms.checkFirst, systemImage: Symbol.Swarms.changes, disabled: busy) { step = .check },
            ]
        case .working:
            return [
                PaneAction(
                    swarm.status == .stopping ? Copy.Swarms.stopping : Copy.Swarms.stop, systemImage: Symbol.Swarms.stop,
                    needsServer: true, disabled: busy || swarm.status == .stopping
                ) { answer { try await store.stop() } },
            ]
        case .applying, .applied, .ended:
            return []
        }
    }

    private func answer(_ work: @escaping @MainActor () async throws -> Void) {
        Task { await controller.run(work) }
    }

    // MARK: the shelf's results card

    private func results(_ swarm: Swarm, _ phase: Phase) -> some View {
        let tasks = swarm.tasks
        return VStack(spacing: 8) {
            navRow(symbol: Symbol.Swarms.told, text: Copy.Swarms.seeTold, step: .told)
            if tasks.done + tasks.failed > 0 {
                navRow(symbol: Symbol.Swarms.results, text: Copy.Swarms.seeResults, step: .board)
            }
            if swarm.mode == .propose, swarm.apply.status != .none {
                navRow(symbol: Symbol.Swarms.changes, text: Copy.Swarms.seeChanges, step: .check)
            }
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
            .foregroundStyle(CobaltColor.text)
            .padding(.horizontal, 14)
            .frame(minHeight: Metrics.hit + 4)
            .background(CobaltColor.elevated, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

/// Where a link, a launch argument or a notification asked a swarm to open (its check screen, its board, an agent): the
/// swarms tab leaves it here when it opens the pane, and the page takes it once. (`PaneItem.swarm` carries only the id.)
@MainActor
enum SwarmPaneIntent {
    private static var pending: [String: SwarmDestination] = [:]

    static func leave(_ destination: SwarmDestination) {
        guard destination.step != nil || destination.agent != nil else { return }
        pending[destination.id] = destination
    }

    static func take(_ id: String) -> SwarmDestination? {
        pending.removeValue(forKey: id)
    }
}

#if DEBUG
private struct SwarmPageHost: View {
    let state: PreviewSwarmStart
    var id: String?
    let shape: PaneShape
    var hinge: PaneHinge?
    @State private var model: AppModel

    init(_ state: PreviewSwarmStart, id: String? = nil, shape: PaneShape, hinge: PaneHinge? = nil) {
        UserDefaults.standard.set(state.rawValue, forKey: "previewSwarm")
        let model = AppModel.preview(.happy)
        model.selectedTab = .swarms
        _model = State(initialValue: model)
        self.state = state
        self.id = id ?? state.swarmID
        self.shape = shape
        self.hinge = hinge
    }

    var body: some View {
        let id = id ?? PreviewSwarmIDs.story
        AreaPageHost(item: .swarm(id), shape: shape, hinge: hinge) {
            NavigationStack { SwarmPage(id: id, model: model) }
        }
        .cobaltRoot(model: model)
        .task { await model.swarms.loadList() }
        .onDisappear { model.swarms.hide() }
    }
}

#Preview("swarm · waiting for you", traits: .fixedLayout(width: 440, height: 900)) {
    SwarmPageHost(.awaiting, shape: .tall)
}
#Preview("swarm · running", traits: .fixedLayout(width: 440, height: 900)) {
    SwarmPageHost(.running, shape: .tall)
}
#Preview("swarm · running, AX3", traits: .fixedLayout(width: 440, height: 1100)) {
    SwarmPageHost(.running, shape: .tall).dynamicTypeSize(.accessibility3)
}
#Preview("swarm · ready to apply", traits: .fixedLayout(width: 440, height: 900)) {
    SwarmPageHost(.review, shape: .tall)
}
#Preview("swarm · done", traits: .fixedLayout(width: 440, height: 900)) {
    SwarmPageHost(.done, shape: .tall)
}
#Preview("swarm · failed", traits: .fixedLayout(width: 440, height: 900)) {
    SwarmPageHost(.failed, id: PreviewSwarmIDs.failed, shape: .tall)
}
#Preview("swarm · declined", traits: .fixedLayout(width: 440, height: 900)) {
    SwarmPageHost(.declined, id: PreviewSwarmIDs.declined, shape: .tall)
}
#Preview("swarm · wide", traits: .fixedLayout(width: 1000, height: 600)) {
    SwarmPageHost(.running, shape: .wide)
}
#Preview("swarm · spanned, wide duo", traits: .fixedLayout(width: 1080, height: 800)) {
    SwarmPageHost(.running, shape: .split(.media), hinge: PaneHinge(axis: .vertical, position: 540))
}
#Preview("swarm · bar", traits: .fixedLayout(width: 402, height: 64)) {
    SwarmPageHost(.running, shape: .bar)
}
#endif
