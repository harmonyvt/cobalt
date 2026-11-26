import CobaltKit
import SwiftUI

// The results board (CONTRACT-SWARMS 6; APP-API-CONTRACT 62): one board for any swarm. A search field, group chips, a sort menu,
// the agent strip (one square per agent, coloured by score; tap opens that agent), then a grid of cards: the first picture, the
// title, a small score bar and up to three fields. Tap a card for all its fields, media and links. An agent that failed is a red
// card with its items. 100 cards at a time: reaching the last one reads the next hundred.

struct SwarmBoardScreen: View {
    let model: AppModel
    @Bindable private var store: SwarmStore

    @State private var agent: Int?
    @State private var picked: BoardRow?
    @State private var width: CGFloat = 0

    init(model: AppModel) {
        self.model = model
        _store = Bindable(model.swarms)
    }

    private struct Key: Hashable {
        var query: String
        var group: String?
        var sort: BoardSort
    }

    private var key: Key { Key(query: store.boardQuery, group: store.boardGroup, sort: store.boardSort) }
    private var board: SwarmBoard? { store.board }

    private var cardMinimum: CGFloat { width >= 720 ? 200 : 150 }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if let board {
                    summary(board)
                    if !board.groups.isEmpty { chips(board) }
                    if !board.agents.isEmpty { strip(board) }
                    if board.rows.isEmpty { empty } else { cards(board) }
                } else if let problem = store.boardProblem {
                    InlineStatus(message: Copy.Swarms.problem(problem)) {
                        Button(Copy.Swarms.tryAgain) { Task { await store.loadBoard() } }
                            .buttonStyle(.cobaltSecondary(fullWidth: false, compact: true))
                    }
                } else {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text(Copy.Swarms.loadingBoard).font(CobaltType.caption).foregroundStyle(CobaltColor.caption)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 40)
                }
            }
            .padding(.horizontal, Metrics.gutter)
            .padding(.top, 8)
            .padding(.bottom, 24)
        }
        .background(CobaltColor.bg)
        .navigationTitle(Copy.Swarms.boardTitle)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .searchable(text: $store.boardQuery, prompt: Copy.Swarms.searchPrompt)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Picker(Copy.Swarms.sort, selection: $store.boardSort) {
                        ForEach(BoardSort.allCases, id: \.self) { Text(Copy.Swarms.sortName($0)).tag($0) }
                    }
                } label: {
                    Label(Copy.Swarms.sort, systemImage: Symbol.Swarms.sort)
                }
            }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .task(id: key) {
            // typing waits a moment so a word is one read; the first read does not
            if store.board != nil { try? await Task.sleep(for: .milliseconds(300)) }
            guard !Task.isCancelled else { return }
            await store.loadBoard()
        }
        .agentPresenter(model: model, agent: $agent)
        .sheet(item: $picked) { row in
            SwarmBoardDetail(row: row)
                .presentationDetents([.medium, .large])
                .presentationBackground(CobaltColor.bg)
                .cobaltRoot(model: model)
        }
    }

    // MARK: the head

    private func summary(_ board: SwarmBoard) -> some View {
        Text(Copy.Swarms.resultCount(board.total))
            .font(CobaltType.caption)
            .foregroundStyle(CobaltColor.caption)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func chips(_ board: SwarmBoard) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                chip(Copy.Swarms.all, on: store.boardGroup == nil) { store.boardGroup = nil }
                ForEach(board.groups, id: \.value) { group in
                    chip(Copy.Swarms.groupChip(group.value, group.count), on: store.boardGroup == group.value) {
                        store.boardGroup = group.value
                    }
                }
            }
            .padding(.vertical, 2)
        }
        .scrollClipDisabled()
    }

    private func chip(_ title: String, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(CobaltType.caption)
                .foregroundStyle(on ? CobaltColor.onText : CobaltColor.text)
                .padding(.horizontal, 12)
                .frame(minHeight: 32)
                .background(on ? CobaltColor.text : CobaltColor.elevated, in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    private func strip(_ board: SwarmBoard) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 20, maximum: 28), spacing: 4)], spacing: 4) {
            ForEach(board.agents) { item in
                Button { agent = item.agent } label: {
                    SwarmSquare(status: item.status, selected: agent == item.agent, fillOpacity: Self.opacity(item))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Self.label(item))
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Copy.Swarms.agentsStrip)
    }

    /// A finished agent is green, stronger the higher its score; the others keep their status colour.
    static func opacity(_ item: BoardAgent) -> Double {
        guard item.status == .done, let score = item.score else { return 1 }
        return 0.25 + 0.75 * min(1, max(0, score))
    }

    private static func label(_ item: BoardAgent) -> String {
        let base = Copy.Swarms.cell(item.agent, item.status)
        guard let score = item.score else { return base }
        return "\(base), \(Copy.Swarms.score(score))"
    }

    // MARK: the cards

    private var empty: some View {
        Text(store.boardQuery.isEmpty && store.boardGroup == nil ? Copy.Swarms.boardNone : Copy.Swarms.boardEmpty)
            .font(CobaltType.body)
            .foregroundStyle(CobaltColor.caption)
            .frame(maxWidth: .infinity)
            .padding(.top, 40)
    }

    private func cards(_ board: SwarmBoard) -> some View {
        DuoAdaptiveGrid(minItemWidth: cardMinimum, spacing: 12, alignment: .leading) {
            ForEach(board.rows) { row in
                Button { picked = row } label: {
                    SwarmBoardCard(row: row)
                }
                .buttonStyle(.plain)
                .onAppear {
                    if row.id == board.rows.last?.id { Task { await store.loadMoreBoard() } }
                }
            }
        }
        .motion(Motion.rows, value: board.rows.count)
    }
}

// MARK: - a card

struct SwarmBoardCard: View {
    let row: BoardRow

    private var picture: MediaRef? { row.media.first { $0.error == nil && $0.previewURL != nil } }
    private var failed: Bool { row.isFailedAgent }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let picture, !failed { SwarmThumb(url: picture.previewURL, height: 104) }
            Text(row.title ?? Copy.Swarms.agent(row.agent))
                .font(CobaltType.bodyMedium)
                .foregroundStyle(failed ? CobaltColor.errorText : CobaltColor.text)
                .lineLimit(failed ? 4 : 2)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let score = row.score, !failed { SwarmScoreBar(score: score) }
            ForEach(Array(row.fields.prefix(3).enumerated()), id: \.offset) { _, field in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(field.key).foregroundStyle(CobaltColor.caption)
                    Text(field.value).foregroundStyle(CobaltColor.text)
                }
                    .font(CobaltType.captionSmall)
                    .lineLimit(failed ? 4 : 2)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(failed ? CobaltColor.error.opacity(0.14) : CobaltColor.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(failed ? CobaltColor.error.opacity(0.6) : CobaltColor.border.opacity(0.4), lineWidth: 1)
        }
        .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

struct SwarmScoreBar: View {
    let score: Double

    var body: some View {
        HStack(spacing: 8) {
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(CobaltColor.elevated)
                    Capsule().fill(CobaltColor.text).frame(width: proxy.size.width * min(1, max(0, score)))
                }
            }
            .frame(height: 4)
            Text(SwarmWords.score(score)).font(CobaltType.badge).foregroundStyle(CobaltColor.caption)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Copy.Swarms.score(score))
    }
}

/// A preview picture: the app never plays here, it shows the still the server gives.
struct SwarmThumb: View {
    let url: URL?
    var height: CGFloat = 104

    var body: some View {
        ZStack {
            CobaltColor.railTrack
            if let url {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image): image.resizable().scaledToFit()
                    case .failure: Image(systemName: "photo").foregroundStyle(CobaltColor.caption)
                    default: ProgressView().controlSize(.small)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: height)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .mediaMask()
        .accessibilityHidden(true)
    }
}

// MARK: - one card, all of it

struct SwarmBoardDetail: View {
    let row: BoardRow

    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    SwarmSentence(text: row.title ?? Copy.Swarms.agent(row.agent))
                        .foregroundStyle(row.isFailedAgent ? CobaltColor.errorText : CobaltColor.text)
                    if let score = row.score { SwarmScoreBar(score: score) }
                    if !row.media.isEmpty {
                        block(Copy.Swarms.media) {
                            VStack(spacing: 12) { ForEach(Array(row.media.enumerated()), id: \.offset) { item in mediaRow(item.element) } }
                        }
                    }
                    if !row.fields.isEmpty {
                        block(Copy.Swarms.fields) {
                            SwarmCard {
                                ForEach(Array(row.fields.enumerated()), id: \.offset) { index, field in
                                    VStack(spacing: 0) {
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(field.key).font(CobaltType.captionSmall).foregroundStyle(CobaltColor.caption)
                                            Text(field.value).font(CobaltType.body).foregroundStyle(CobaltColor.text)
                                                .textSelection(.enabled)
                                                .fixedSize(horizontal: false, vertical: true)
                                        }
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .padding(.horizontal, 14).padding(.vertical, 10)
                                        if index < row.fields.count - 1 { Divider().overlay(CobaltColor.hairline).padding(.leading, 14) }
                                    }
                                }
                            }
                        }
                    }
                    if !row.links.isEmpty {
                        block(Copy.Swarms.links) {
                            SwarmCard {
                                ForEach(Array(row.links.enumerated()), id: \.offset) { index, link in
                                    VStack(spacing: 0) {
                                        Button { openURL(link) } label: {
                                            HStack(spacing: 10) {
                                                Image(systemName: Symbol.Swarms.link).foregroundStyle(CobaltColor.caption)
                                                Text(link.host(percentEncoded: false) ?? link.absoluteString)
                                                    .font(CobaltType.body).foregroundStyle(CobaltColor.linkBlue).lineLimit(1)
                                                    .frame(maxWidth: .infinity, alignment: .leading)
                                            }
                                            .padding(.horizontal, 14).frame(minHeight: Metrics.hit)
                                            .contentShape(Rectangle())
                                        }
                                        .buttonStyle(.plain)
                                        if index < row.links.count - 1 { Divider().overlay(CobaltColor.hairline).padding(.leading, 14) }
                                    }
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, Metrics.gutter)
                .padding(.vertical, 12)
                .frame(maxWidth: 640, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .background(CobaltColor.bg)
            .navigationTitle(Copy.Swarms.details)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    DuoToolbarButton(title: Copy.Swarms.done, systemImage: "checkmark") { dismiss() }
                }
                .duoVisibilityPriority(.high)
            }
        }
        #if os(macOS)
        .frame(minWidth: 420, minHeight: 480)
        #endif
    }

    private func block<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(CobaltType.caption).foregroundStyle(CobaltColor.caption)
                .accessibilityAddTraits(.isHeader)
            content()
        }
    }

    /// A picture and where it opens. Posts and files have a link of our own (the share page), emotes and urls open in the
    /// browser: all of them through `openURL`.
    @ViewBuilder
    private func mediaRow(_ ref: MediaRef) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let error = ref.error {
                Text("\(ref.ref) · \(error)").font(CobaltType.captionSmall).foregroundStyle(CobaltColor.errorText)
            } else {
                if ref.previewURL != nil { SwarmThumb(url: ref.previewURL, height: 180) }
                HStack {
                    Text(ref.title ?? ref.ref).font(CobaltType.caption).foregroundStyle(CobaltColor.caption).lineLimit(1)
                    Spacer()
                    if let target = ref.openURL ?? ref.previewURL {
                        Button(Copy.Swarms.open, systemImage: Symbol.Swarms.open) { openURL(target) }
                            .buttonStyle(.cobaltSecondary(fullWidth: false, compact: true))
                    }
                }
            }
        }
    }
}
