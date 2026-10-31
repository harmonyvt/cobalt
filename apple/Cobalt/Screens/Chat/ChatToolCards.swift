import CobaltKit
import SwiftUI

// The chat's tool cards (APP-API-CONTRACT section 38): under a code step, a chip for every `cobalt.*` call it made, then a
// card for each call with something to see: the posts it searched or looked at, 7TV emotes, an edit as a small timeline,
// a job and what it made, a box command, a share link, a collection or set, a save. Cards only show; a tap opens the post,
// the editor project or the link.

// MARK: - the chips

/// The calls of a step as small chips that wrap: the op, how long it took; red when it failed, amber when it asks first.
/// Calls in a row to the same op that all ran fine share one chip ("library.search ×3 5.0s", the longest of them), so a
/// step that searched three times reads as one line instead of three chips wrapping into a grid.
struct ChatCallTrail: View {
    let calls: [ChatToolCall]

    var body: some View {
        AboutFlow(spacing: 5) {
            ForEach(Array(ChatCallGroup.of(calls).enumerated()), id: \.offset) { _, group in
                ChatCallChip(group: group)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Copy.ChatCards.calls(calls.count))
    }
}

/// One chip's worth of calls: a single call, or a run of the same op that all ran.
struct ChatCallGroup: Equatable {
    var call: ChatToolCall
    var count: Int

    static func of(_ calls: [ChatToolCall]) -> [ChatCallGroup] {
        var groups: [ChatCallGroup] = []
        for call in calls {
            if call.status == .done, let last = groups.last, last.call.status == .done, last.call.op == call.op {
                groups[groups.count - 1].count += 1
                groups[groups.count - 1].call.ms = max(last.call.ms, call.ms)
            } else {
                groups.append(ChatCallGroup(call: call, count: 1))
            }
        }
        return groups
    }
}

private struct ChatCallChip: View {
    let group: ChatCallGroup
    private var call: ChatToolCall { group.call }

    private var ink: Color {
        switch call.status {
        case .done: CobaltColor.text
        case .error: CobaltColor.errorText
        case .asked: CobaltColor.collection
        }
    }

    var body: some View {
        let tone = ChatCardTone.of(call)
        HStack(spacing: 5) {
            // what ran, as its icon (search, look, link, edit, job, box, emotes…), in the kind's colour
            Image(systemName: tone.symbol)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(tone.color)
                .accessibilityHidden(true)
            Text(Copy.ChatCards.chip(call.op))
                .foregroundStyle(ink)
            if group.count > 1 {
                Text(Copy.ChatCards.times(group.count))
                    .foregroundStyle(ink)
            }
            Text(call.status == .asked ? Copy.ChatCards.asked : Copy.ChatCards.ms(call.ms))
                .foregroundStyle(CobaltColor.caption)
        }
        .font(CobaltType.badge)
        .lineLimit(1)
        .fixedSize()
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(CobaltColor.elevated, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .help(call.error ?? "")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Copy.ChatCards.chipA11y(call, count: group.count))
    }
}

/// A colour per kind of card, shared by the chip's square and the card's badge.
enum ChatCardTone {
    case search, look, emotes, edit, job, box, link, folder, saved, agents, other

    static func of(_ call: ChatToolCall) -> ChatCardTone {
        if let card = call.card { return of(card) }
        let op = call.op
        if op.hasPrefix("library.search") || op.hasPrefix("library.list") { return .search }
        if op.hasPrefix("emotes.") { return .emotes }
        if op.hasPrefix("edits.") { return .edit }
        if op.hasPrefix("make.") || op.hasPrefix("jobs.") { return .job }
        if op.hasPrefix("box.") { return .box }
        if op.hasPrefix("links.") { return .link }
        if op.hasPrefix("collections.") || op.hasPrefix("sets.") { return .folder }
        if op.hasPrefix("agents.") { return .agents }
        return .other
    }

    static func of(_ card: ChatToolCard) -> ChatCardTone {
        switch card {
        case .search: .search
        case .look: .look
        case .emotes: .emotes
        case .edit: .edit
        case .job: .job
        case .box, .files: .box
        case .link: .link
        case .collection: .folder
        case .saved, .facts: .saved
        case .agents: .agents
        }
    }

    var color: Color {
        switch self {
        case .search, .link: CobaltColor.linkBlue
        case .look: Color(light: 0x1f8a74, dark: 0x9effe4)
        case .emotes, .edit: CobaltColor.collectionSet
        case .job, .folder: CobaltColor.collection
        case .box: CobaltColor.caption
        case .saved: CobaltColor.success
        case .agents: Color(light: 0xc2410c, dark: 0xffb38a)
        case .other: CobaltColor.caption
        }
    }

    var symbol: String {
        switch self {
        case .search: "magnifyingglass"
        case .look: "eye"
        case .emotes: "face.smiling"
        case .edit: "film.stack"
        case .job: "sparkles"
        case .box: "terminal"
        case .link: "link"
        case .folder: "folder"
        case .saved: "checkmark"
        case .agents: Symbol.chatHelpers
        case .other: "function"
        }
    }
}

// MARK: - a card

/// One card. `posts` is the thread's map (the server ships every post a card names); a post it lacks is a blank tile.
struct ChatToolCardView: View {
    let model: AppModel
    let card: ChatToolCard
    let posts: [String: LibraryPost]
    /// Inside a reply's open activity trail: no box, a dot in the kind's colour instead of the badge, strips cut at the
    /// trail's edge.
    var flat = false
    let open: (LibraryPost) -> Void

    private var bleed: CGFloat { flat ? 0 : Self.pad }

    var body: some View {
        Group {
            switch card {
            case .search(let s):
                cardFrame(.search, Copy.ChatCards.searched, Copy.ChatCards.searchSub(query: s.query, within: s.within, total: s.total)) {
                    ChatCardPosts(model: model, ids: s.hits.map(\.postID), posts: posts, side: 64, scores: s.hits.map(\.score), top: s.topScore, bleed: bleed, open: open)
                }
            case .look(let ids):
                cardFrame(.look, Copy.ChatCards.lookedAt, Copy.ChatCards.pictures(ids.count)) {
                    ChatCardPosts(model: model, ids: ids, posts: posts, side: 48, bleed: bleed, open: open)
                }
            case .emotes(let e):
                cardFrame(.emotes, e.saved ? Copy.ChatCards.emoteSaved : Copy.ChatCards.emotes, Copy.ChatCards.emotesSub(e)) {
                    ChatEmoteGrid(emotes: e, saved: e.saved, posts: posts, open: open)
                }
            case .edit(let e):
                cardFrame(.edit, Copy.ChatCards.editChange(e.change), e.title ?? "") {
                    ChatEditTimeline(model: model, edit: e, posts: posts, open: open)
                }
                .accessibilityLabel(Copy.ChatCards.editA11y(e))
            case .job(let j):
                cardFrame(.job, Copy.ChatCards.jobTitle(j.op), nil) {
                    ChatJobBody(model: model, job: j, posts: posts, open: open)
                }
            case .box(let b):
                cardFrame(.box, Copy.ChatCards.box, Copy.ChatCards.exit(b.code, timedOut: b.timedOut)) {
                    ChatBoxBody(box: b)
                }
            case .files(let f):
                cardFrame(.box, f.isIn ? Copy.ChatCards.pulled(f.files.count) : Copy.ChatCards.savedFromBox, nil) {
                    ChatFilesBody(model: model, files: f, posts: posts, open: open)
                }
            case .link(let l):
                cardFrame(.link, Copy.ChatCards.link, Copy.ChatCards.linkSub(l)) { ChatLinkBody(link: l) }
            case .collection(let c):
                cardFrame(.folder, "\(Copy.ChatCards.folderChange(c)) \(Copy.ChatCards.folder(c))", nil) { ChatFolderBody(folder: c) }
            case .saved(let s):
                cardFrame(.saved, Copy.ChatCards.saved, Copy.ChatCards.saveStatus(s.status) ?? s.title) {
                    ChatCardPosts(model: model, ids: s.postIDs, posts: posts, side: 64, bleed: bleed, open: open)
                }
            case .facts(let f):
                cardFrame(.saved, f.title, f.rows.map { "\($0.name): \($0.value)" }.joined(separator: " · ")) {
                    if !f.postIDs.isEmpty {
                        ChatCardPosts(model: model, ids: f.postIDs, posts: posts, side: 44, bleed: bleed, open: open)
                    }
                }
            case .agents(let a):
                cardFrame(.agents, Copy.ChatCards.agentsTitle(a), Copy.ChatCards.agentsSub(a)) {
                    ChatAgentsBody(model: model, card: a, posts: posts, open: open)
                }
            }
        }
    }

    /// The card's inner padding; a post strip reaches back across it to the card's edges.
    static let pad: CGFloat = 11

    private func cardFrame<Content: View>(_ tone: ChatCardTone, _ title: String, _ sub: String?, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                if flat {
                    Circle()
                        .fill(tone.color)
                        .frame(width: 7, height: 7)
                        .frame(width: 14)
                        .accessibilityHidden(true)
                } else {
                    Image(systemName: tone.symbol)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(tone.color)
                        .frame(width: 22, height: 22)
                        .background(tone.color.opacity(0.16), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                        .accessibilityHidden(true)
                }
                Text(title).font(Font.cobalt(12, .semibold)).foregroundStyle(CobaltColor.text)
                if let sub, !sub.isEmpty {
                    Text(sub).font(Font.cobalt(12)).foregroundStyle(CobaltColor.caption).lineLimit(1).truncationMode(.tail)
                }
                Spacer(minLength: 0)
            }
            .accessibilityElement(children: .combine)
            content()
                .padding(.leading, flat ? 22 : 0)
        }
        .padding(flat ? 0 : Self.pad)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            if !flat { RoundedRectangle(cornerRadius: 14, style: .continuous).fill(CobaltColor.row) }
        }
        .overlay {
            if !flat { RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(CobaltColor.hairline, lineWidth: 1) }
        }
        .accessibilityElement(children: .contain)
    }
}

// MARK: - helpers

/// Sub-agents (43.5): their rows as the strip's chips (a tap opens the helper's thread), each with its task and, once
/// done, its report and the posts it showed; `sent` as an arrow line "to <name>: <text>"; `inbox` the messages read.
private struct ChatAgentsBody: View {
    let model: AppModel
    let card: ChatToolCard.Agents
    let posts: [String: LibraryPost]
    let open: (LibraryPost) -> Void

    @Environment(\.openChatHelper) private var openHelper

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            if card.change == .sent, let message = card.message {
                ChatMailLine(outgoing: true, label: Copy.Chat.helperTo(message.to), text: message.text)
            }
            if card.change == .inbox {
                ForEach(Array(card.mail.enumerated()), id: \.offset) { _, mail in
                    ChatMailLine(outgoing: false, label: Copy.Chat.helperFrom(mail.from), text: mail.text)
                }
            }
            ForEach(Array(card.agents.enumerated()), id: \.offset) { _, row in
                ChatAgentRowView(model: model, row: row, posts: posts, open: open, openHelper: openHelper)
            }
        }
    }
}

private struct ChatAgentRowView: View {
    let model: AppModel
    let row: ChatToolCard.Agents.Row
    let posts: [String: LibraryPost]
    let open: (LibraryPost) -> Void
    let openHelper: (@MainActor (String) -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            chip
            if !row.task.isEmpty {
                Text(row.task)
                    .font(CobaltType.badge)
                    .foregroundStyle(CobaltColor.caption)
                    .lineLimit(2)
            }
            if let result = row.result, !result.isEmpty {
                Text(result)
                    .font(Font.cobalt(12))
                    .foregroundStyle(CobaltColor.text)
                    .lineLimit(4)
                    .textSelection(.enabled)
            }
            if !row.postIDs.isEmpty {
                ChatCardPosts(model: model, ids: row.postIDs, posts: posts, side: 44, open: open)
            }
        }
    }

    @ViewBuilder
    private var chip: some View {
        let face = ChatHelperChip(name: row.name, status: row.status, activity: row.activity)
        if let openHelper, !row.id.isEmpty {
            Button { openHelper(row.id) } label: { face }
                .buttonStyle(.plain)
                .accessibilityHint(Copy.Chat.helperOpenHint)
        } else {
            face
        }
    }
}

// MARK: - files and folders

private struct ChatFilesBody: View {
    let model: AppModel
    let files: ChatToolCard.Files
    let posts: [String: LibraryPost]
    let open: (LibraryPost) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            AboutFlow(spacing: 6) {
                ForEach(Array(files.files.enumerated()), id: \.offset) { _, file in
                    Text(Copy.ChatCards.file(file))
                        .font(CobaltType.badge)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 4)
                        .background(CobaltColor.surface, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                }
            }
            if !files.isIn, let id = files.postID {
                ChatCardPosts(model: model, ids: [id], posts: posts, side: 56, open: open)
            }
        }
    }
}

private struct ChatFolderBody: View {
    let folder: ChatToolCard.Folder

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: folder.isSet ? "folder.badge.gearshape" : "folder")
                .font(.system(size: 18))
                .foregroundStyle(CobaltColor.collection)
                .frame(width: 40, height: 34)
                .background(CobaltColor.collectionBack, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(folder.name).font(CobaltType.bodySemibold).foregroundStyle(CobaltColor.text).lineLimit(1)
                if let n = Copy.ChatCards.folderCount(folder) {
                    Text(n).font(CobaltType.badge).foregroundStyle(CobaltColor.caption)
                }
            }
        }
    }
}

// MARK: - posts

/// A row of post thumbnails, optionally with a score bar on top of each.
private struct ChatCardPosts: View {
    let model: AppModel
    let ids: [String]
    let posts: [String: LibraryPost]
    let side: CGFloat
    var scores: [Double?] = []
    var top: Double? = nil
    /// How far the strip reaches past its own frame on each side: a card's own padding, so the row runs to the card's
    /// edges and is cut there (it used to draw past the card's right edge). Its first tile still lines up with the title.
    var bleed: CGFloat = 0
    let open: (LibraryPost) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(Array(ids.enumerated()), id: \.offset) { i, id in
                    tile(id: id, score: i < scores.count ? scores[i] : nil)
                }
            }
        }
        .contentMargins(.horizontal, bleed, for: .scrollContent)
        .padding(.horizontal, -bleed)
    }

    @ViewBuilder
    private func tile(id: String, score: Double?) -> some View {
        if let post = posts[id] {
            ChatPostTile(model: model, post: post, side: side, showsTitle: false) { open(post) }
                .overlay(alignment: .top) { bar(score) }
                .overlay(alignment: .bottomTrailing) { label(score) }
        } else {
            ChatRemovedTile(side: side, showsTitle: false)
        }
    }

    @ViewBuilder
    private func bar(_ score: Double?) -> some View {
        if let score, let top, top > 0 {
            GeometryReader { g in
                Rectangle().fill(CobaltColor.linkBlue).frame(width: g.size.width * max(0, min(1, score / top)), height: 3)
            }
            .frame(height: 3)
            .clipShape(UnevenRoundedRectangle(topLeadingRadius: 10, topTrailingRadius: 10))
            .allowsHitTesting(false)
        }
    }

    @ViewBuilder
    private func label(_ score: Double?) -> some View {
        if let score {
            Text(String(format: "%.2f", score))
                .font(Font.cobalt(9.5))
                .foregroundStyle(CobaltColor.badgeInk)
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .background(CobaltColor.badgeBack, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                .padding(4)
                .allowsHitTesting(false)
        }
    }
}

// MARK: - emotes

/// The 7TV emotes, playing. A tap picks one and names it; an emote in the library opens its post.
private struct ChatEmoteGrid: View {
    let emotes: ChatToolCard.Emotes
    let saved: Bool
    let posts: [String: LibraryPost]
    let open: (LibraryPost) -> Void

    @State private var picked: String?

    var body: some View {
        let one = emotes.emotes.count == 1
        let side: CGFloat = one ? 72 : 44
        VStack(alignment: .leading, spacing: 6) {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: side + 8), spacing: 6)], alignment: .leading, spacing: 6) {
                ForEach(emotes.emotes) { e in
                    Button {
                        if picked == e.id, let lib = e.libraryID, let post = posts[lib] { open(post) }
                        picked = e.id
                    } label: {
                        EmotePicture(url: e.url, animated: e.animated, side: side)
                            .padding(4)
                            .background(CobaltColor.surface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                            .overlay(alignment: .topTrailing) {
                                if e.libraryID != nil || saved {
                                    Circle().fill(CobaltColor.success).frame(width: 9, height: 9).padding(4)
                                }
                            }
                            .overlay {
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .strokeBorder(picked == e.id ? CobaltColor.collectionSet : .clear, lineWidth: 2)
                            }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(e.name)
                }
            }
            if let e = emotes.emotes.first(where: { $0.id == (picked ?? (one ? $0.id : "")) }) {
                Text(Copy.ChatCards.emoteLine(e.name, saved: saved || e.libraryID != nil))
                    .font(CobaltType.badge)
                    .foregroundStyle(CobaltColor.caption)
            }
        }
    }
}

// MARK: - an edit

/// The project as a small timeline: a ruler, the main track's clips back to back, one row per overlay layer. A clip shows
/// its picture (pictures, cutouts and emotes have a dashed edge), its speed when it is not 1×, and a violet ring when this
/// call added it. A tap on a clip says where it sits; the red playhead can be dragged to see what plays when.
private struct ChatEditTimeline: View {
    let model: AppModel
    let edit: ChatToolCard.Edit
    let posts: [String: LibraryPost]
    let open: (LibraryPost) -> Void

    @State private var selected: String?
    @State private var playhead: Double = 0

    private let labelWidth: CGFloat = 40

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            GeometryReader { g in
                let width = max(1, g.size.width - labelWidth)
                ZStack(alignment: .topLeading) {
                    ruler(width: width)
                    VStack(alignment: .leading, spacing: 5) {
                        ForEach(edit.tracks) { track in
                            row(track, width: width)
                        }
                    }
                    .padding(.top, 16)
                    playheadView(width: width, height: g.size.height)
                }
                .coordinateSpace(.named("chatEditTimeline"))
            }
            .frame(height: height)
            .padding(8)
            .background(CobaltColor.bg, in: RoundedRectangle(cornerRadius: 10, style: .continuous))

            AboutFlow(spacing: 6) {
                if let r = edit.revision { pill(Copy.ChatCards.revision(r)) }
                pill(Copy.ChatCards.seconds(edit.duration))
                if let w = edit.width, let h = edit.height { pill(Copy.ChatCards.size(w, h)) }
                if !edit.added.isEmpty { pill(Copy.ChatCards.added(edit.added), tint: CobaltColor.collectionSet) }
                if let r = edit.render { pill(Copy.ChatCards.rendered(r.status)) }
            }
            if let clip = edit.tracks.flatMap(\.clips).first(where: { $0.id == selected }) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(clip.title ?? Copy.ChatCards.kind(clip.kind)) · \(Copy.ChatCards.kind(clip.kind))\(clip.isNew ? " · \(Copy.ChatCards.addedHere)" : "")")
                        .font(Font.cobalt(11, .medium))
                    Text(Copy.ChatCards.clipDetail(clip)).font(CobaltType.badge).foregroundStyle(CobaltColor.caption)
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(CobaltColor.surface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .transition(.opacity)
            }
            HStack(spacing: 8) {
                if let id = edit.render?.postID, let post = posts[id] {
                    ChatPostTile(model: model, post: post, side: 40, showsTitle: false) { open(post) }
                }
                Spacer(minLength: 0)
                Button {
                    Task { await EditorLauncher.shared.open(edit.projectID, model: model) }
                } label: {
                    Label(Copy.ChatCards.openEditor, systemImage: Symbol.Editor.edit)
                }
                .buttonStyle(.cobaltIcon(.small, tint: CobaltColor.collectionSet))
            }
        }
        .animation(Motion.card, value: selected)
    }

    private var height: CGFloat {
        16 + edit.tracks.reduce(0) { $0 + ($1.isMain ? 30 : 24) + 5 }
    }

    private func x(_ seconds: Double, _ width: CGFloat) -> CGFloat {
        edit.duration > 0 ? CGFloat(seconds / edit.duration) * width : 0
    }

    private func ruler(width: CGFloat) -> some View {
        let step = Self.tick(edit.duration)
        let marks = stride(from: 0.0, through: edit.duration, by: step).map { $0 }
        return ZStack(alignment: .topLeading) {
            ForEach(marks, id: \.self) { t in
                Text("\(Int(t))s")
                    .font(Font.cobalt(9))
                    .foregroundStyle(CobaltColor.caption)
                    .fixedSize()
                    .offset(x: labelWidth + x(t, width) - (t == 0 ? 0 : 8))
            }
        }
        .frame(height: 12)
        .accessibilityHidden(true)
    }

    /// 1, 2, 5, 10, 15, 30, 60... seconds: about four marks.
    static func tick(_ duration: Double) -> Double {
        for s in [1.0, 2, 5, 10, 15, 30, 60, 120, 300] where duration / s <= 5 { return s }
        return 600
    }

    private func row(_ track: ChatToolCard.Edit.Track, width: CGFloat) -> some View {
        let h: CGFloat = track.isMain ? 30 : 24
        return HStack(spacing: 0) {
            Text(track.isMain ? Copy.ChatCards.main : Copy.ChatCards.layer(track.index))
                .font(Font.cobalt(9.5))
                .foregroundStyle(CobaltColor.caption)
                .frame(width: labelWidth, alignment: .leading)
            ZStack(alignment: .leading) {
                Color.clear
                ForEach(track.clips) { clip in
                    clipView(clip, height: h)
                        .frame(width: max(6, x(clip.length, width)), height: h)
                        .offset(x: x(clip.at, width))
                }
            }
            .frame(width: width, height: h, alignment: .leading)
        }
    }

    private func clipView(_ clip: ChatToolCard.Edit.Clip, height: CGFloat) -> some View {
        Button { selected = selected == clip.id ? nil : clip.id } label: {
            ZStack(alignment: .leading) {
                picture(clip)
                LinearGradient(colors: [.black.opacity(0.55), .clear], startPoint: .leading, endPoint: .trailing)
                Text(clip.title ?? Copy.ChatCards.kind(clip.kind))
                    .font(Font.cobalt(9, .medium))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .padding(.horizontal, 5)
                if abs(clip.speed - 1) > 0.001 {
                    Text(String(format: "%g×", clip.speed))
                        .font(Font.cobalt(8.5))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 3)
                        .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 4))
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                        .padding(2)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(.white.opacity(0.18), style: StrokeStyle(lineWidth: 1, dash: clip.isPicture ? [3, 2] : []))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(selected == clip.id ? CobaltColor.linkBlue : clip.isNew ? CobaltColor.collectionSet : .clear, lineWidth: 2)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(clip.title ?? Copy.ChatCards.kind(clip.kind)), \(Copy.ChatCards.clipDetail(clip))")
    }

    @ViewBuilder
    private func picture(_ clip: ChatToolCard.Edit.Clip) -> some View {
        if clip.kind == .emote, let url = clip.picture {
            HStack {
                EmotePicture(url: url, animated: true, side: 20).padding(.leading, 2)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(CobaltColor.collectionSetBack)
        } else if let id = clip.postID, let post = posts[id] {
            FacePicture(item: model.mediaItem(for: post), maxPixel: 160, gradient: 0)
        } else if let url = clip.picture {
            RemoteStill(poster: RemotePoster(url: url, isVideo: false), maxPixel: 160)
        } else {
            LinearGradient(colors: [CobaltColor.frameTop, CobaltColor.frameBottom], startPoint: .top, endPoint: .bottom)
        }
    }

    private func playheadView(width: CGFloat, height: CGFloat) -> some View {
        let px = labelWidth + x(playhead, width)
        return ZStack(alignment: .top) {
            Rectangle().fill(Color.red).frame(width: 2, height: height - 12)
            Circle().fill(Color.red).frame(width: 9, height: 9).offset(y: -4)
        }
        .offset(x: px - 1, y: 12)
        .contentShape(Rectangle().inset(by: -10))
        .gesture(
            DragGesture(minimumDistance: 0, coordinateSpace: .named("chatEditTimeline"))
                .onChanged { v in
                    let f = (v.location.x - labelWidth) / width
                    playhead = max(0, min(edit.duration, Double(f) * edit.duration))
                    selected = edit.clips(at: playhead).first?.id
                }
        )
        .accessibilityHidden(true)
    }

    private func pill(_ text: String, tint: Color = CobaltColor.text) -> some View {
        Text(text)
            .font(CobaltType.badge)
            .foregroundStyle(tint)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(CobaltColor.surface, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}

// MARK: - a job

private struct ChatJobBody: View {
    let model: AppModel
    let job: ChatToolCard.Job
    let posts: [String: LibraryPost]
    let open: (LibraryPost) -> Void

    var body: some View {
        HStack(spacing: 10) {
            if let id = job.postID, let post = posts[id] {
                ChatPostTile(model: model, post: post, side: 56, showsTitle: false) { open(post) }
            }
            VStack(alignment: .leading, spacing: 5) {
                Text(Copy.ChatCards.jobStatus(job))
                    .font(CobaltType.badge)
                    .foregroundStyle(job.isFailed ? CobaltColor.errorText : CobaltColor.caption)
                ProgressView(value: job.isDone ? 1 : max(0, min(1, job.progress ?? 0)))
                    .tint(job.isDone ? CobaltColor.success : job.isFailed ? CobaltColor.errorText : CobaltColor.linkBlue)
                let result = Copy.ChatCards.jobResult(job)
                if job.isDone, !result.isEmpty {
                    Text(result).font(CobaltType.badge).foregroundStyle(CobaltColor.caption)
                }
            }
            if let project = job.projectID, !EditRender.isChatProjectID(project) {      // a chat video has no project (45.3)
                Button {
                    Task { await EditorLauncher.shared.open(project, model: model) }
                } label: {
                    Label(Copy.ChatCards.openEditor, systemImage: Symbol.Editor.edit)
                }
                .buttonStyle(.cobaltIcon(.small, tint: CobaltColor.collectionSet))
            }
        }
    }
}

// MARK: - the box

/// The command and the end of what it printed, dark like a terminal, three lines high until opened.
private struct ChatBoxBody: View {
    let box: ChatToolCard.Box
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(Text("$ ").foregroundStyle(Color(hex: 0x5fd35a)))\(box.cmd)").foregroundStyle(Color(hex: 0xd4d4d4))
                if !box.stdout.isEmpty { Text(box.stdout).foregroundStyle(Color(hex: 0xd4d4d4)) }
                if !box.stderr.isEmpty { Text(box.stderr).foregroundStyle(Color(hex: 0xff8a8a)) }
            }
            .font(Font.cobalt(10.5))
            .textSelection(.enabled)
            .lineLimit(expanded ? nil : 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
            .background(Color(hex: 0x0c0c0c), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            HStack(spacing: 8) {
                Text(Copy.ChatCards.exit(box.code, timedOut: box.timedOut))
                    .font(CobaltType.badge)
                    .foregroundStyle(box.succeeded ? CobaltColor.success : CobaltColor.errorText)
                Spacer(minLength: 0)
                if !box.stdout.isEmpty || !box.stderr.isEmpty || box.cmd.count > 120 {
                    Button { expanded.toggle() } label: {
                        Label(
                            expanded ? Copy.ChatCards.showLess : Copy.ChatCards.showAll,
                            systemImage: expanded ? Symbol.chatShowLess : Symbol.chatShowAll)
                    }
                    .buttonStyle(.cobaltIcon(.small))
                }
            }
        }
        .animation(Motion.card, value: expanded)
    }
}

// MARK: - a link

private struct ChatLinkBody: View {
    let link: ChatToolCard.Link
    @Environment(\.shell) private var shell
    @Environment(\.openURL) private var openURL
    /// The copy icon shows its green tick for a moment after a copy.
    @State private var copied = false
    @State private var copiedReset: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let title = link.title {
                Text(title).font(CobaltType.bodySemibold).foregroundStyle(CobaltColor.text).lineLimit(1)
            }
            HStack(spacing: 6) {
                if link.isPrivate {
                    Image(systemName: "lock.fill").font(.system(size: 10)).foregroundStyle(CobaltColor.caption).accessibilityHidden(true)
                }
                Text(link.url.absoluteString)
                    .font(CobaltType.captionSmall)
                    .foregroundStyle(CobaltColor.linkBlue)
                    .lineLimit(2)
                    .textSelection(.enabled)
            }
            IconRow(spacing: 8, alignment: .leading) {
                Button {
                    Pasteboard.copy(link.url.absoluteString)
                    shell.showStatus(Copy.ChatCards.copied)
                    copied = true
                    copiedReset?.cancel()
                    copiedReset = Task { @MainActor in
                        try? await Task.sleep(for: .seconds(1.6))
                        guard !Task.isCancelled else { return }
                        copied = false
                    }
                } label: {
                    Label(Copy.ChatCards.copyLink, systemImage: copied ? Symbol.Library.copied : Symbol.copyLink)
                }
                .buttonStyle(.cobaltIcon(.small, state: copied ? .done : .idle))
                Button { openURL(link.url) } label: {
                    Label(Copy.ChatCards.openLink, systemImage: Symbol.web)
                }
                .buttonStyle(.cobaltIcon(.small))
            }
        }
        .onDisappear { copiedReset?.cancel() }
    }
}
