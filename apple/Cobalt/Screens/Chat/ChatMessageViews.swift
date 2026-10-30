import CobaltKit
import SwiftUI

// What a thread's messages are drawn with (APP-API-CONTRACT section 27.4): the owner's words in a right-aligned bubble
// (the files they attached small above it), Claude's reply full width as Markdown with its code steps collapsed above and
// the files it showed as a strip of thumbnails below, and the one row a failed reply gets.

// MARK: - Markdown

/// A reply's Markdown: blocks found by `ChatMarkdown` (paragraphs, lists, headings, quotes, code), each block's text
/// drawn as inline Markdown (bold, italic, `code`, links).
struct ChatMarkdownText: View {
    let markdown: String
    var font: Font = CobaltType.body

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(ChatMarkdown.blocks(markdown).enumerated()), id: \.offset) { _, block in
                blockView(block)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func blockView(_ block: ChatBlock) -> some View {
        switch block {
        case .paragraph(let text):
            Text(Self.inline(text)).font(font).foregroundStyle(CobaltColor.text)
        case .heading(let level, let text):
            Text(Self.inline(text))
                .font(Font.cobalt(level <= 1 ? 17 : 15, .semibold, relativeTo: .headline))
                .foregroundStyle(CobaltColor.text)
                .padding(.top, 4)
                .accessibilityAddTraits(.isHeader)
        case .list(let items):
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(item.marker)
                            .font(font)
                            .foregroundStyle(CobaltColor.caption)
                            .frame(minWidth: 18, alignment: .trailing)
                            .accessibilityHidden(true)
                        Text(Self.inline(item.text)).font(font).foregroundStyle(CobaltColor.text)
                    }
                    .padding(.leading, CGFloat(item.level) * 18)
                }
            }
        case .quote(let text):
            HStack(spacing: 10) {
                Rectangle().fill(CobaltColor.border).frame(width: 2)
                Text(Self.inline(text)).font(font).foregroundStyle(CobaltColor.caption)
            }
            .fixedSize(horizontal: false, vertical: true)
        case .code(_, let text):
            ScrollView(.horizontal, showsIndicators: false) {
                Text(text)
                    .font(CobaltType.captionSmall)
                    .foregroundStyle(CobaltColor.text)
                    .fixedSize(horizontal: true, vertical: true)
                    .textSelection(.enabled)
                    .padding(10)
            }
            .background(CobaltColor.surface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        case .rule:
            Divider()
        }
    }

    /// Inline Markdown with line breaks kept; text that is not valid Markdown stays as typed.
    static func inline(_ text: String) -> AttributedString {
        var options = AttributedString.MarkdownParsingOptions()
        options.interpretedSyntax = .inlineOnlyPreservingWhitespace
        options.failurePolicy = .returnPartiallyParsedIfPossible
        guard var parsed = try? AttributedString(markdown: text, options: options) else { return AttributedString(text) }
        for run in parsed.runs where run.inlinePresentationIntent?.contains(.code) == true {
            parsed[run.range].backgroundColor = CobaltColor.elevated
        }
        return parsed
    }
}

// MARK: - one message

/// A message of the thread with everything that hangs off it.
struct ChatMessageView: View {
    let model: AppModel
    let message: ChatMessage
    let content: ChatThreadContent
    var tier: Tier = .compact
    /// A shown post was tapped.
    let open: (LibraryPost) -> Void
    /// "try again" on a failed reply, with the text it answered.
    let retry: (String) -> Void
    let canRetry: Bool
    /// A confirm card's button: the card and the owner's answer.
    var answer: (ChatConfirm, Bool) -> Void = { _, _ in }
    /// The card's answer is on its way.
    var answering = false

    @Environment(\.shell) private var shell

    var body: some View {
        switch message.role {
        case .user: userBubble
        case .assistant: reply
        }
    }

    // MARK: the owner

    private var userBubble: some View {
        VStack(alignment: .trailing, spacing: 6) {
            if !message.postIDs.isEmpty {
                ChatPostStrip(model: model, ids: message.postIDs, posts: content.posts, side: 44, showsTitles: false, open: open)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            Text(message.text)
                .font(CobaltType.body)
                .foregroundStyle(CobaltColor.text)
                .textSelection(.enabled)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(CobaltColor.elevated, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .contextMenu { copyButton }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .padding(.leading, 56)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Copy.Chat.messageA11y(role: .user, text: message.text))
    }

    // MARK: Claude

    private var reply: some View {
        VStack(alignment: .leading, spacing: 10) {
            // a confirm step is drawn as the card below, not as a code row
            ForEach(message.steps.filter { $0.kind != "confirm" }) { step in
                ChatStepRow(step: step)
            }
            if !message.text.isEmpty {
                ChatMarkdownText(markdown: message.text)
                    .textSelection(.enabled)
                    .contextMenu { copyButton }
            } else if message.status == .running, !message.steps.contains(where: { $0.status == .running }) {
                ChatWorkingDots()
            }
            if !message.postIDs.isEmpty {
                ChatPostStrip(model: model, ids: message.postIDs, posts: content.posts, side: 104, showsTitles: true, open: open)
            }
            if let collage = message.collage {
                ChatCollageView(
                    model: model, threadID: content.thread.id, messageID: message.id, collage: collage, tier: tier, open: open)
            }
            if let ranked = message.ranked, !ranked.hits.isEmpty {
                ChatRankedView(model: model, ranked: ranked, posts: content.posts, open: open)
            }
            if let card = message.confirm {
                ChatConfirmCard(card: card, answering: answering) { answer(card, $0) }
            }
            if message.status == .error { failure }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Copy.Chat.messageA11y(role: .assistant, text: message.text))
    }

    private var failure: some View {
        let interrupted = message.error == ChatError.interrupted.code
        let prompt = content.prompt(before: message)
        return HStack(spacing: 8) {
            Image(systemName: Symbol.error).accessibilityHidden(true)
            Text(interrupted ? Copy.Chat.replyInterrupted : Copy.Chat.replyFailed)
            Spacer(minLength: 4)
            if let prompt {
                Button(Copy.Chat.tryAgain, systemImage: Symbol.retry) { retry(prompt.text) }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .disabled(!canRetry)
            }
        }
        .font(CobaltType.caption)
        .foregroundStyle(CobaltColor.errorText)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(CobaltColor.errorText.opacity(0.1), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .contentShape(Rectangle())
        .onTapGesture { if canRetry, let prompt { retry(prompt.text) } }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityHint(Copy.Chat.tryAgain)
    }

    @ViewBuilder
    private var copyButton: some View {
        Button(Copy.Chat.copyText, systemImage: Symbol.copy) {
            Pasteboard.copy(message.text)
            shell.showStatus(Copy.Media.copied)
        }
    }
}

// MARK: - a confirm card

/// A call the chat makes only after the owner's yes (APP-API-CONTRACT 33.7): the summary, what it touches (posts, files,
/// size, links that stop working), and a red "delete 3" / "make private" beside "cancel". Answered or timed out, the
/// buttons give way to a quiet status line. The card ticks over to "timed out" on its own when its 15 minutes run out.
struct ChatConfirmCard: View {
    let card: ChatConfirm
    let answering: Bool
    let answer: (Bool) -> Void

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            content(open: card.isOpen(at: context.date))
        }
    }

    private func content(open: Bool) -> some View {
        let effect = Copy.Chat.confirmEffect(card.effect)
        let titles = card.effect.titles.count > 1 ? Copy.Chat.confirmTitles(card.effect.titles) : ""
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: Symbol.chatConfirm)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(open ? Color.red : CobaltColor.caption)
                    .accessibilityHidden(true)
                Text(card.summary)
                    .font(CobaltType.bodySemibold)
                    .foregroundStyle(CobaltColor.text)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !effect.isEmpty {
                Text(effect)
                    .font(CobaltType.caption)
                    .foregroundStyle(CobaltColor.caption)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !titles.isEmpty {
                Text(titles)
                    .font(CobaltType.caption)
                    .foregroundStyle(CobaltColor.caption)
                    .lineLimit(2)
            }
            if open {
                buttons
            } else {
                status
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(CobaltColor.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(open ? Color.red.opacity(0.35) : CobaltColor.border, lineWidth: 1)
        }
        .animation(Motion.card, value: open)
        .animation(Motion.card, value: answering)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Copy.Chat.confirmA11y(summary: card.summary, effect: effect))
    }

    private var buttons: some View {
        ButtonRow {
            Button(role: .destructive) { answer(true) } label: {
                if answering {
                    Label(Copy.Chat.confirmAnswering, systemImage: Symbol.chatConfirm)
                } else {
                    Text(Copy.Chat.confirmButton(card.action))
                }
            }
            .buttonStyle(.cobaltDestructive(fullWidth: false, compact: true))
            Button(Copy.Chat.confirmCancel, role: .cancel) { answer(false) }
                .buttonStyle(.cobaltSecondary(fullWidth: false, compact: true))
        }
        .disabled(answering)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var status: some View {
        let (symbol, text): (String, String) = switch card.status {
        case .yes: (Symbol.chatConfirmDone, Copy.Chat.confirmDone)
        case .no: (Symbol.chatConfirmKept, Copy.Chat.confirmKept)
        case .waiting, .expired: (Symbol.chatConfirmKept, Copy.Chat.confirmExpired)
        }
        return Label(text, systemImage: symbol)
            .font(CobaltType.caption)
            .foregroundStyle(CobaltColor.caption)
            .contentTransition(.opacity)
    }
}

/// Three dots that pulse while a reply has nothing to show yet.
struct ChatWorkingDots: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 8) {
            if reduceMotion {
                Image(systemName: "ellipsis").foregroundStyle(CobaltColor.caption)
            } else {
                ProgressView().controlSize(.small)
            }
            Text(Copy.Chat.working)
                .font(CobaltType.caption)
                .foregroundStyle(CobaltColor.caption)
        }
        .frame(minHeight: 24)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.updatesFrequently)
    }
}

// MARK: - a code step

/// "ran code · 0.8 s", collapsed; "running code…" with a spinner while it runs; "code failed" when it errored. Open, it
/// shows the code, what it logged, what it returned and its error, in monospace.
struct ChatStepRow: View {
    let step: ChatStep

    @State private var expanded = false

    private var title: String {
        // a job handed to the server (33.14): no code, just how it is going
        if step.kind == "job" {
            switch step.status {
            case .running: return Copy.Chat.jobWaiting
            case .error: return Copy.Chat.jobFailed(step.job?.status)
            case .done: return Copy.Chat.jobDone
            }
        }
        switch step.status {
        case .running: return Copy.Chat.running
        case .error: return Copy.Chat.failedStep
        case .done: return Copy.Chat.ran(seconds: step.durationMS.map { Double($0) / 1000 })
        }
    }

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 10) {
                if !step.code.isEmpty { section(Copy.Chat.code, step.code) }
                if !step.logs.isEmpty { section(Copy.Chat.logs, step.logs.joined(separator: "\n")) }
                if let result = step.result, !result.isEmpty { section(Copy.Chat.result, result) }
                if let error = step.error, !error.isEmpty { section(Copy.Chat.error, error, isError: true) }
            }
            .padding(.top, 8)
        } label: {
            HStack(spacing: 8) {
                if step.status == .running {
                    ProgressView().controlSize(.mini)
                } else {
                    Image(systemName: step.status == .error ? Symbol.chatCodeFailed : Symbol.chatCode)
                        .font(.system(size: 12))
                        .foregroundStyle(step.status == .error ? CobaltColor.errorText : CobaltColor.caption)
                        .accessibilityHidden(true)
                }
                Text(title)
                    .font(CobaltType.caption)
                    .foregroundStyle(step.status == .error ? CobaltColor.errorText : CobaltColor.caption)
                    .contentTransition(.opacity)
            }
            .frame(minHeight: 28, alignment: .leading)
            .contentShape(Rectangle())
        }
        // the system chevron ignored `.tint` (the app's monochrome accent won), so the style draws its own
        .disclosureGroupStyle(ChatStepDisclosureStyle())
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .background(CobaltColor.surface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .animation(Motion.card, value: expanded)
        .accessibilityValue(Copy.Chat.stepA11y(title, expanded: expanded))
    }

    private func section(_ name: String, _ text: String, isError: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(name).font(CobaltType.badge).foregroundStyle(CobaltColor.caption)
            ScrollView(.horizontal, showsIndicators: false) {
                Text(text)
                    .font(CobaltType.captionSmall)
                    .foregroundStyle(isError ? CobaltColor.errorText : CobaltColor.text)
                    .fixedSize(horizontal: true, vertical: true)
                    .textSelection(.enabled)
                    .padding(8)
            }
            .background(CobaltColor.bg.opacity(0.6), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
    }
}

// MARK: - shown and attached posts

/// A row of thumbnails of library posts, in the order the message lists them. A post the library no longer has (it is not in
/// the thread's map) is a `removed` tile that does nothing. A tap opens the post.
struct ChatPostStrip: View {
    let model: AppModel
    let ids: [String]
    let posts: [String: LibraryPost]
    let side: CGFloat
    let showsTitles: Bool
    let open: (LibraryPost) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: side > 60 ? 8 : 4) {
                ForEach(Array(ids.enumerated()), id: \.offset) { _, id in
                    if let post = posts[id] {
                        ChatPostTile(model: model, post: post, side: side, showsTitle: showsTitles) { open(post) }
                    } else {
                        ChatRemovedTile(side: side, showsTitle: showsTitles)
                    }
                }
            }
        }
        .scrollClipDisabled()
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Copy.Chat.shownA11y)
    }
}

/// One post as a square picture (the library's `FacePicture`) with a play badge on a video and its title under it.
struct ChatPostTile: View {
    let model: AppModel
    let post: LibraryPost
    let side: CGFloat
    let showsTitle: Bool
    let action: () -> Void

    var body: some View {
        let row = LibraryRow(item: model.mediaItem(for: post))
        Button(action: action) {
            VStack(alignment: .leading, spacing: 5) {
                FacePicture(item: row.item, maxPixel: Int(side * 3), gradient: 0)
                    .frame(width: side, height: side)
                    .overlay(alignment: .bottomLeading) { badge(row) }
                    .clipShape(RoundedRectangle(cornerRadius: side > 60 ? 10 : 6, style: .continuous))
                if showsTitle {
                    LibraryTitleText(row: row, size: 10.5, weight: .regular)
                        .frame(width: side, alignment: .leading)
                }
            }
        }
        .buttonStyle(ChatTilePress())
        .accessibilityLabel(row.title)
        .accessibilityHint(Copy.Chat.openPostA11yHint)
        .accessibilityAddTraits(.isButton)
    }

    @ViewBuilder
    private func badge(_ row: LibraryRow) -> some View {
        if side > 60, row.kind == .video || row.kind == .gallery {
            Image(systemName: row.kind == .video ? Symbol.chatPlay : Symbol.Gallery.gallery)
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(CobaltColor.badgeInk)
                .padding(6)
                .background(CobaltColor.badgeBack, in: Circle())
                .padding(6)
                .accessibilityHidden(true)
        }
    }
}

/// The tile of a post the library no longer has.
struct ChatRemovedTile: View {
    let side: CGFloat
    let showsTitle: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            RoundedRectangle(cornerRadius: side > 60 ? 10 : 6, style: .continuous)
                .fill(CobaltColor.surface)
                .overlay {
                    Image(systemName: Symbol.chatRemoved)
                        .font(.system(size: side * 0.28))
                        .foregroundStyle(CobaltColor.caption)
                }
                .frame(width: side, height: side)
            if showsTitle {
                Text(Copy.Chat.removed)
                    .font(Font.cobalt(10.5))
                    .foregroundStyle(CobaltColor.caption)
                    .frame(width: side, alignment: .leading)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Copy.Chat.removedA11y)
    }
}

private struct ChatTilePress: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.opacity(configuration.isPressed ? 0.8 : 1)
    }
}

/// A disclosure row whose chevron is caption grey and turns as it opens; the whole label toggles it.
private struct ChatStepDisclosureStyle: DisclosureGroupStyle {
    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(Motion.card) { configuration.isExpanded.toggle() }
            } label: {
                HStack(spacing: 8) {
                    configuration.label
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(CobaltColor.caption)
                        .rotationEffect(.degrees(configuration.isExpanded ? 90 : 0))
                        .accessibilityHidden(true)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if configuration.isExpanded {
                configuration.content
                    .transition(.opacity)
            }
        }
    }
}
