import CobaltKit
import SwiftUI

// The swarms tab (CONTRACT-SWARMS 2, 3.1): a list in three groups, "waiting for you", "running" and "finished"; a row is the
// name and one plain line, plus the score once the swarm has one. A tap opens the swarm in the screen pane (`SwarmPage`:
// the agent grid, the answer to give, the agents' messages, the results), which keeps polling in the bar while it runs.
// This screen reads the list and takes `model.swarms.route`: a link may set it before this screen exists, so it is read
// on appear and on every change; it opens the pane (and leaves the step or agent the link named for the page).

struct SwarmsScreen: View {
    let model: AppModel
    let tier: Tier

    @Environment(\.lifecycle) private var lifecycle
    @Environment(Pane.self) private var pane

    private var store: SwarmStore { model.swarms }

    /// The swarm the pane is showing (its row is marked).
    private var openID: String? {
        if case .swarm(let id)? = pane.item, pane.isVisible { return id }
        return nil
    }

    var body: some View {
        list
        .background(CobaltColor.bg)
        .navigationTitle(Copy.Swarms.title)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            #if os(macOS)
            ToolbarItem(placement: .primaryAction) {
                Button(Copy.Swarms.refresh, systemImage: Symbol.retry) { Task { await store.loadList() } }
                    .disabled(store.state == .loading)
                    .keyboardShortcut("r", modifiers: .command)
                    .help(Copy.Swarms.refresh)
            }
            #endif
        }
        .task {
            await store.loadList()
            takeRoute()
            #if DEBUG
            if openID == nil, let launch = SwarmsLaunch.destination() { open(launch) }
            #endif
        }
        .onChange(of: store.route, initial: true) { _, _ in takeRoute() }
        .onChange(of: inFront) { _, inFront in
            // nothing is read while the app is away; coming back reads the list again
            if inFront { Task { await store.loadList() } }
        }
    }

    /// Whether the app counts as in front for this screen. iPhone and iPad: active (a pulled-down Control Center is
    /// away, as it was with scenePhase). The Mac: not hidden, because scenePhase never left `.active` for Cmd-Tab.
    private var inFront: Bool {
        #if os(macOS)
        return lifecycle.isForeground
        #else
        return lifecycle.isActive
        #endif
    }

    /// A link (or a launch argument) asked for a swarm, its check screen or its board: open it and clear the request.
    private func takeRoute() {
        guard let route = store.route else { return }
        store.route = nil
        open(SwarmDestination(route: route))
    }

    private func open(_ destination: SwarmDestination) {
        SwarmPaneIntent.leave(destination)
        pane.open(.swarm(destination.id))
    }

    // MARK: the list

    private var list: some View {
        let groups = store.groups
        return Group {
            if store.list.isEmpty {
                emptyState
            } else {
                List {
                    if case .failed(let error) = store.state {
                        InlineStatus(message: Copy.Swarms.problem(error)) {
                            Button(Copy.Swarms.tryAgain) { Task { await store.loadList() } }
                                .buttonStyle(.cobaltSecondary(fullWidth: false, compact: true))
                        }
                        .listRowBackground(Color.clear)
                    }
                    group(Copy.Swarms.waiting, groups.waiting, waiting: true)
                    group(Copy.Swarms.running, groups.running)
                    group(Copy.Swarms.finished, groups.finished)
                }
                .scrollContentBackground(.hidden)
                .refreshable { await store.loadList() }
            }
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        switch store.state {
        case .idle, .loading:
            VStack(spacing: 10) {
                ProgressView()
                Text(Copy.Swarms.loading).font(CobaltType.caption).foregroundStyle(CobaltColor.caption)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let error):
            ContentUnavailableView {
                Label(Copy.Swarms.problem(error), systemImage: Symbol.error).font(CobaltType.body)
            } actions: {
                Button(Copy.Swarms.tryAgain, systemImage: Symbol.retry) { Task { await store.loadList() } }
                    .buttonStyle(.cobaltSecondary(fullWidth: false))
            }
        case .loaded:
            ContentUnavailableView {
                Label(Copy.Swarms.emptyTitle, systemImage: Symbol.Swarms.tab).font(CobaltType.body)
            } description: {
                Text(Copy.Swarms.emptyBody).font(CobaltType.caption)
            }
        }
    }

    @ViewBuilder
    private func group(_ title: String, _ swarms: [Swarm], waiting: Bool = false) -> some View {
        if !swarms.isEmpty {
            Section {
                ForEach(swarms) { swarm in
                    SwarmRow(swarm: swarm, line: store.rowLine(swarm), waiting: waiting, selected: openID == swarm.id) {
                        open(SwarmDestination(id: swarm.id))
                    }
                    .listRowBackground(openID == swarm.id ? CobaltColor.elevated : CobaltColor.row)
                }
            } header: {
                Text(title).font(CobaltType.caption).foregroundStyle(CobaltColor.caption)
            }
        }
    }
}

// MARK: - a row

struct SwarmRow: View {
    let swarm: Swarm
    let line: String
    var waiting = false
    var selected = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .center, spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(swarm.name)
                        .font(CobaltType.bodyMedium)
                        .foregroundStyle(CobaltColor.text)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    Text(line)
                        .font(CobaltType.caption)
                        .foregroundStyle(waiting ? SwarmColor.amber : CobaltColor.caption)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if let score = swarm.score {
                    Text(SwarmWords.score(score))
                        .font(CobaltType.caption)
                        .foregroundStyle(CobaltColor.caption)
                        .accessibilityLabel(Copy.Swarms.score(score))
                }
                #if os(iOS)
                Image(systemName: Symbol.Swarms.more).font(.system(size: 12, weight: .semibold)).foregroundStyle(CobaltColor.caption)
                    .accessibilityHidden(true)
                #endif
            }
            .padding(.vertical, 4)
            .frame(minHeight: Metrics.hit)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

#if DEBUG
/// Simulator evidence: `-previewSwarm <state>` (CobaltKit) picks the swarm, and these open it further. Debug builds only.
///
///   -previewSwarmView check|results|told   open that step of the swarm
///   -previewSwarmAgent N                   open agent N's sheet
@MainActor
enum SwarmsLaunch {
    private static var done = false

    /// Where the launch arguments say to open, once.
    static func destination() -> SwarmDestination? {
        guard !done, let id = PreviewSwarmStart.launch?.swarmID else { return nil }
        done = true
        let defaults = UserDefaults.standard
        let step: SwarmStep? = switch defaults.string(forKey: "previewSwarmView") {
        case "check": .check
        case "results": .board
        case "told": .told
        default: nil
        }
        let agent = defaults.object(forKey: "previewSwarmAgent") == nil ? nil : defaults.integer(forKey: "previewSwarmAgent")
        return SwarmDestination(id: id, step: step, agent: agent)
    }
}
#endif
