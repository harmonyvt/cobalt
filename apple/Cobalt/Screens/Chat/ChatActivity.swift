import CobaltKit
import SwiftUI

// A reply's activity row (chat-ui mockup, 2026-10-31): every code step, call chip and tool card of a reply folds into one
// line, "3 searches, 1 edit" over "3 posts looked at · 14 s", with the first posts it found stacked at the end. While the
// reply works, the line says what it is doing now ("library.about…"). A tap opens the trail: each step as a flat row (its
// code behind its own disclosure, its chips under it) with that step's cards, drawn flat on a rail instead of as boxes.

/// What the folded line says, worked out from the steps.
struct ChatActivitySummary: Equatable {
    var title: String
    var sub: String
    var running: Bool
    var failed: Bool
    var postIDs: [String]

    init(steps: [ChatStep]) {
        let calls = steps.flatMap(\.calls)
        var counts: [ChatCardTone: Int] = [:]
        var looked = 0
        var helpers = 0
        var posts: [String] = []
        func add(_ ids: [String]) {
            for id in ids where !posts.contains(id) && posts.count < 3 { posts.append(id) }
        }
        for call in calls where call.status != .error {
            let tone = ChatCardTone.of(call)
            counts[tone, default: 0] += 1
            switch call.card {
            case .search(let s): add(Array(s.hits.prefix(1).map(\.postID)))
            case .look(let ids):
                looked += ids.count
                add(ids)
            case .saved(let s): add(s.postIDs)
            case .agents(let a) where a.change == .started: helpers += a.agents.count
            default: break
            }
        }
        var parts: [String] = []
        if let n = counts[.search] { parts.append(Copy.ChatActivity.searches(n)) }
        if let n = counts[.edit] { parts.append(Copy.ChatActivity.edits(n)) }
        if let n = counts[.job] { parts.append(Copy.ChatActivity.jobs(n)) }
        if counts[.look] != nil { parts.append(Copy.ChatActivity.looked(max(looked, counts[.look] ?? 0))) }
        if let n = counts[.link] { parts.append(Copy.ChatActivity.links(n)) }
        if let n = counts[.saved] { parts.append(Copy.ChatActivity.saved(n)) }
        if let n = counts[.folder] { parts.append(Copy.ChatActivity.folders(n)) }
        if counts[.agents] != nil, helpers > 0 { parts.append(Copy.ChatActivity.helpers(helpers)) }
        if let n = counts[.emotes] { parts.append(Copy.ChatActivity.emotes(n)) }
        if let n = counts[.box] { parts.append(Copy.ChatActivity.box(n)) }

        let errors = calls.filter { $0.status == .error }.count + steps.filter { $0.status == .error }.count
        let ms = steps.compactMap(\.durationMS).reduce(0, +)
        running = steps.contains { $0.status == .running }
        failed = errors > 0
        postIDs = posts

        var subParts = Array(parts.dropFirst(2))
        if parts.isEmpty, !calls.isEmpty { subParts.append(Copy.ChatActivity.calls(calls.count)) }
        if errors > 0 { subParts.append(Copy.ChatActivity.failed(errors)) }
        if ms > 0 { subParts.append(Copy.ChatActivity.seconds(ms)) }

        if running {
            // what it is on now: the running step's newest call, else the step's own words
            let live = steps.last { $0.status == .running }
            if let op = live?.calls.last?.op {
                title = Copy.ChatActivity.doing(Copy.ChatCards.chip(op))
            } else if live?.kind == "job" {
                title = Copy.Chat.jobWaiting
            } else {
                title = Copy.Chat.running
            }
            // the sub line says what is done so far
            sub = (Array(parts.prefix(2)) + subParts).joined(separator: " · ")
        } else {
            title = parts.isEmpty ? (failed ? Copy.Chat.failedStep : Copy.ChatActivity.ranCode) : parts.prefix(2).joined(separator: ", ")
            sub = subParts.joined(separator: " · ")
        }
    }
}

struct ChatActivityView: View {
    let model: AppModel
    let steps: [ChatStep]
    let posts: [String: LibraryPost]
    let open: (LibraryPost) -> Void

    @State private var expanded = false

    var body: some View {
        let summary = ChatActivitySummary(steps: steps)
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(Motion.card) { expanded.toggle() }
            } label: {
                header(summary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Copy.ChatActivity.a11y(summary.title, summary.sub, open: expanded))
            .accessibilityHint(expanded ? Copy.ChatActivity.close : Copy.ChatActivity.open)

            if expanded {
                trail
                    .padding(.horizontal, 12)
                    .padding(.bottom, 12)
                    .transition(.opacity)
            }
        }
        .background(CobaltColor.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .animation(Motion.card, value: summary)
        .accessibilityElement(children: .contain)
    }

    // MARK: the folded line

    private func header(_ s: ChatActivitySummary) -> some View {
        HStack(spacing: 10) {
            badge(s)
            VStack(alignment: .leading, spacing: 1) {
                Text(s.title)
                    .font(Font.cobalt(13, .medium))
                    .foregroundStyle(s.failed && !s.running ? CobaltColor.errorText : CobaltColor.text)
                    .lineLimit(1)
                    .contentTransition(.opacity)
                if !s.sub.isEmpty {
                    Text(s.sub)
                        .font(CobaltType.badge)
                        .foregroundStyle(CobaltColor.caption)
                        .lineLimit(1)
                        .contentTransition(.opacity)
                }
            }
            Spacer(minLength: 4)
            if !s.postIDs.isEmpty { stack(s.postIDs) }
            Image(systemName: Symbol.chatDisclosure)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(CobaltColor.caption)
                .rotationEffect(.degrees(expanded ? 90 : 0))
                .accessibilityHidden(true)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private func badge(_ s: ChatActivitySummary) -> some View {
        let tint = s.running ? CobaltColor.collection : s.failed ? CobaltColor.errorText : CobaltColor.linkBlue
        Group {
            if s.running {
                ProgressView().controlSize(.mini)
            } else {
                Image(systemName: s.failed ? Symbol.chatActivityFailed : Symbol.chatActivityDone)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(tint)
            }
        }
        .frame(width: 26, height: 26)
        .background(tint.opacity(0.16), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .accessibilityHidden(true)
    }

    /// The first posts it found, overlapping.
    private func stack(_ ids: [String]) -> some View {
        HStack(spacing: -9) {
            ForEach(ids, id: \.self) { id in
                Group {
                    if let post = posts[id] {
                        FacePicture(item: model.mediaItem(for: post), maxPixel: 90, gradient: 0)
                    } else {
                        CobaltColor.elevated
                    }
                }
                .frame(width: 26, height: 26)
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(CobaltColor.surface, lineWidth: 2))
            }
        }
        .accessibilityHidden(true)
    }

    // MARK: the open trail

    private var trail: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(steps) { step in
                VStack(alignment: .leading, spacing: 10) {
                    ChatStepRow(step: step, flat: true)
                    ForEach(step.cards) { entry in
                        ChatToolCardView(model: model, card: entry.card, posts: posts, flat: true, open: open)
                    }
                }
            }
        }
    }
}
