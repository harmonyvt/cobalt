import CobaltKit
import SwiftUI

/// One square per agent (CONTRACT-SWARMS 3.2): grey waiting its turn, white and pulsing while it works, amber while it asks a
/// question, green done, red failed. Tap one to open that agent. Reduce Motion: no pulse.
struct SwarmAgentGrid: View {
    let cells: [SwarmCell]
    var selected: Int?
    var columns = 10
    let pick: (Int) -> Void

    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 5), count: max(1, columns)), spacing: 5) {
            ForEach(cells, id: \.idx) { cell in
                Button { pick(cell.agent) } label: {
                    SwarmSquare(status: cell.status, selected: selected == cell.agent)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Copy.Swarms.cell(cell.agent, cell.status))
            }
        }
    }
}

struct SwarmSquare: View {
    let status: SwarmCell.Status
    var selected = false
    /// A board square coloured by a score instead of a status.
    var fillOpacity: Double = 1

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var dim = false

    var body: some View {
        RoundedRectangle(cornerRadius: 7, style: .continuous)
            .fill(SwarmColor.cell(status).opacity(fillOpacity))
            .aspectRatio(1, contentMode: .fit)
            .opacity(status == .running && dim ? 0.45 : 1)
            .overlay {
                if selected { RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(CobaltColor.focus, lineWidth: 2).padding(-2) }
            }
            .onAppear { startPulse() }
            .onChange(of: status) { _, _ in startPulse() }
    }

    private func startPulse() {
        guard status == .running, !reduceMotion else { dim = false; return }
        withAnimation(.easeInOut(duration: 1.4).repeatForever(autoreverses: true)) { dim = true }
    }
}

/// The rows under the grid: an agent that failed ("agent 7 failed · retry") and one that asks ("agent 3 is asking claude code").
struct SwarmAgentRows: View {
    let swarm: Swarm
    /// `retry` is only offered once the swarm stopped running: the server retries failed agents of a finished swarm.
    let canRetry: Bool
    let busy: Bool
    let open: (Int) -> Void
    let retry: () -> Void

    private static let shown = 5

    private var asking: [SwarmCell] { swarm.tasks.cells.filter { $0.status == .waiting } }
    private var failed: [SwarmCell] { swarm.tasks.cells.filter { $0.status == .failed } }

    var body: some View {
        if !asking.isEmpty || !failed.isEmpty {
            SwarmCard {
                ForEach(Array(asking.prefix(Self.shown)), id: \.idx) { cell in
                    row(last: false) {
                        Button { open(cell.agent) } label: {
                            HStack(spacing: 10) {
                                Image(systemName: Symbol.Swarms.asking).foregroundStyle(SwarmColor.amber).frame(width: 20)
                                Text(Copy.Swarms.agentAsking(cell.agent, who: swarm.planner))
                                    .font(CobaltType.body).foregroundStyle(CobaltColor.text)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                Image(systemName: Symbol.Swarms.more).font(.system(size: 12)).foregroundStyle(CobaltColor.caption)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                ForEach(Array(failed.prefix(Self.shown)), id: \.idx) { cell in
                    row(last: false) {
                        HStack(spacing: 10) {
                            Button { open(cell.agent) } label: {
                                HStack(spacing: 10) {
                                    Image(systemName: Symbol.Swarms.failed).foregroundStyle(CobaltColor.errorText).frame(width: 20)
                                    Text(Copy.Swarms.agentFailed(cell.agent))
                                        .font(CobaltType.body).foregroundStyle(CobaltColor.text)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            if canRetry {
                                Button(Copy.Swarms.retry, action: retry)
                                    .buttonStyle(.cobaltSecondary(fullWidth: false, compact: true))
                                    .disabled(busy)
                            } else {
                                Image(systemName: Symbol.Swarms.more).font(.system(size: 12)).foregroundStyle(CobaltColor.caption)
                            }
                        }
                    }
                }
                let extra = max(0, asking.count - Self.shown) + max(0, failed.count - Self.shown)
                if extra > 0 {
                    Text(Copy.Swarms.andMore(extra))
                        .font(CobaltType.caption).foregroundStyle(CobaltColor.caption)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 14).padding(.vertical, 10)
                }
            }
        }
    }

    private func row<Content: View>(last: Bool, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(spacing: 0) {
            content().padding(.horizontal, 14).padding(.vertical, 10).frame(minHeight: 44)
            if !last { Divider().overlay(CobaltColor.hairline).padding(.leading, 44) }
        }
    }
}
