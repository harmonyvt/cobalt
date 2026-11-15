import CobaltKit
import SwiftUI

/// "see exactly what it's told" (CONTRACT-SWARMS 3.2): the instructions every agent gets, the first items, and what the agents
/// can look at and change, as plain lists. Nothing here can be edited: this is what you are approving.
struct SwarmToldScreen: View {
    let swarm: Swarm

    private static let shownItems = 10

    private var items: [String] {
        (swarm.preview?.itemsSample ?? []).map(\.display).filter { !$0.isEmpty }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                section(Copy.Swarms.toldPrompt) {
                    Text(swarm.prompt.isEmpty ? Copy.Swarms.nothing : swarm.prompt)
                        .font(CobaltType.body)
                        .foregroundStyle(CobaltColor.text)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(14)
                        .background(CobaltColor.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                }
                section(Copy.Swarms.toldItems) {
                    list(Array(items.prefix(Self.shownItems)), extra: max(0, swarm.items - min(items.count, Self.shownItems)))
                }
                section(Copy.Swarms.toldTools) {
                    list(swarm.tools.map(Self.words))
                }
                section(Copy.Swarms.toldWrites) {
                    list(swarm.writes.map(SwarmWords.writeWords))
                }
            }
            .padding(.horizontal, Metrics.gutter)
            .padding(.vertical, 12)
            .frame(maxWidth: 640, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .background(CobaltColor.bg)
        .navigationTitle(Copy.Swarms.toldTitle)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }

    /// "seventv.set" -> "seventv set": the tool as a person would say it.
    private static func words(_ tool: String) -> String {
        tool.replacingOccurrences(of: ".", with: " ").replacingOccurrences(of: "_", with: " ")
    }

    private func section<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(CobaltType.caption).foregroundStyle(CobaltColor.caption)
                .accessibilityAddTraits(.isHeader)
            content()
        }
    }

    @ViewBuilder
    private func list(_ rows: [String], extra: Int = 0) -> some View {
        if rows.isEmpty {
            Text(Copy.Swarms.nothing).font(CobaltType.body).foregroundStyle(CobaltColor.caption)
        } else {
            SwarmCard {
                ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                    VStack(spacing: 0) {
                        Text(row)
                            .font(CobaltType.body)
                            .foregroundStyle(CobaltColor.text)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 14).padding(.vertical, 11)
                        if index < rows.count - 1 || extra > 0 { Divider().overlay(CobaltColor.hairline).padding(.leading, 14) }
                    }
                }
                if extra > 0 {
                    Text(Copy.Swarms.moreItems(extra))
                        .font(CobaltType.caption).foregroundStyle(CobaltColor.caption)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 14).padding(.vertical, 11)
                }
            }
        }
    }
}
