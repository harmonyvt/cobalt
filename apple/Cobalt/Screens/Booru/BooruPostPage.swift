import CobaltKit
import SwiftUI

// One booru post in the pane (APP-API-CONTRACT 72, apple/CONTRACT-PANE.md section 5): the picture as the hero (spanned, a
// whole screen to itself), save (the file's link goes to the queue like any paste), open on Danbooru, share, and its tags by
// kind. A tag searches; its menu adds it to the search or hides it (the blacklist). Picking a tag runs the search and hides
// the pane, so the grid under it shows the result.

struct BooruPostPage: View {
    let model: AppModel
    let id: Int

    @Environment(Pane.self) private var pane: Pane?
    @Environment(\.openURL) private var openURL
    @State private var saved = false
    @State private var hiddenTags: Set<String> = []
    /// The post as last seen: a search that replaces the grid (a tag picked, a filter changed) must not empty the page.
    @State private var kept: BooruPost?

    private var store: BooruStore { model.booru }
    /// A post above general (72.9) is never shown, not even the copy kept for a search that replaced the grid.
    private var post: BooruPost? {
        guard let found = store.posts.first(where: { $0.id == id }) ?? kept else { return nil }
        return store.allows(found) ? found : nil
    }
    private var filteredOut: Bool {
        guard let found = store.posts.first(where: { $0.id == id }) ?? kept else { return false }
        return !store.allows(found)
    }

    var body: some View {
        Group {
            if let post {
                page(post)
            } else if filteredOut {
                PaneGonePage()
            } else if store.phase == .loaded || store.phase.isFailed {
                PaneGonePage()
            } else {
                PaneLoadingPage()
            }
        }
        .task { await store.load() }
        .onChange(of: store.posts, initial: true) { _, posts in
            if let found = posts.first(where: { $0.id == id }), store.allows(found) { kept = found }
        }
        .task(id: filteredOut) {
            guard filteredOut else { return }
            kept = nil
            pane?.close(ifShowing: .booruPost(id))
        }
    }

    private func page(_ post: BooruPost) -> some View {
        PanePage(
            title: post.tags.character.first?.replacingOccurrences(of: "_", with: " ") ?? Copy.Booru.title,
            subtitle: Copy.Booru.size(post.width, post.height, post.ext),
            actions: [
                PaneAction(Copy.Booru.openDanbooru, systemImage: Symbol.Booru.open) { openURL(post.pageUrl) },
            ]
        ) {
            picture(post)
        } controls: {
            PaneActionGrid([
                PaneAction(saved ? Copy.Booru.savedToLibrary : Copy.Booru.save, systemImage: Symbol.Booru.save,
                           disabled: saved) {
                    _ = model.queue.add([.link(post.fileUrl)], via: .paste, options: JobOptions(booru: BooruCredit(post: post)))
                    saved = true
                },
                PaneAction(Copy.Booru.openDanbooru, systemImage: Symbol.Booru.open) { openURL(post.pageUrl) },
            ])
        } body: {
            VStack(alignment: .leading, spacing: 14) {
                info(post)
                tagGroup(Copy.Booru.artist, post.tags.artist, .artist)
                tagGroup(Copy.Booru.character, post.tags.character, .character)
                tagGroup(Copy.Booru.copyright, post.tags.copyright, .copyright)
                tagGroup(Copy.Booru.general, post.tags.general, .general)
                tagGroup(Copy.Booru.meta, post.tags.meta, .meta)
            }
            .padding(.horizontal, 16)
        }
    }

    private func picture(_ post: BooruPost) -> some View {
        ZStack {
            LinearGradient(colors: [CobaltColor.frameTop, CobaltColor.frameBottom], startPoint: .top, endPoint: .bottom)
            AsyncImage(url: post.sampleUrl) { phase in
                if let image = phase.image {
                    image.resizable().scaledToFit()
                } else {
                    ProgressView()
                }
            }
            .mediaMask()
        }
        .aspectRatio(max(0.4, min(post.aspect, 2.5)), contentMode: .fit)
    }

    private func info(_ post: BooruPost) -> some View {
        HStack(spacing: 14) {
            Label(Copy.Booru.score(post.score), systemImage: Symbol.Booru.score)
            Label(Copy.Booru.favs(post.favs), systemImage: Symbol.Booru.favs)
            Spacer(minLength: 0)
            ShareLink(item: post.pageUrl) {
                Label(Copy.Booru.share, systemImage: Symbol.Booru.share).labelStyle(.iconOnly)
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
        }
        .font(CobaltType.caption)
        .foregroundStyle(CobaltColor.caption)
    }

    /// A tag was picked: search it (or add it to the search), then show the grid.
    private func pick(_ tag: String, replace: Bool) {
        let next = replace ? tag : (store.query.tagList + [tag]).suffix(BooruQuery.maxTags).joined(separator: " ")
        var q = store.query
        q.tags = next
        pane?.close()
        Task { await store.search(q) }
    }

    @ViewBuilder
    private func tagGroup(_ title: String, _ tags: [String], _ kind: BooruSuggestion.Kind) -> some View {
        let shown = tags.filter { !hiddenTags.contains($0) }
        if !shown.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(CobaltType.caption).foregroundStyle(CobaltColor.caption)
                BooruFlow(spacing: 6, lineSpacing: 6) {
                    ForEach(shown, id: \.self) { tag in
                        Menu {
                            Button(Copy.Booru.searchTag, systemImage: Symbol.Booru.search) { pick(tag, replace: true) }
                            Button(Copy.Booru.addTag, systemImage: Symbol.Booru.add) { pick(tag, replace: false) }
                            Button(Copy.Booru.hideTag, systemImage: Symbol.Booru.hide, role: .destructive) {
                                hiddenTags.insert(tag)
                                Task { await store.blacklist(tag: tag) }
                            }
                        } label: {
                            Text(tag.replacingOccurrences(of: "_", with: " "))
                                .font(CobaltType.caption)
                                .foregroundStyle(BooruTagColor.of(kind))
                                .padding(.horizontal, 9)
                                .padding(.vertical, 5)
                                .background(CobaltColor.elevated, in: RoundedRectangle(cornerRadius: 8))
                        } primaryAction: {
                            pick(tag, replace: true)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }
}

private extension BooruStore.Phase {
    var isFailed: Bool { if case .failed = self { true } else { false } }
}

/// Tags that wrap onto as many lines as they need.
struct BooruFlow: Layout {
    var spacing: CGFloat
    var lineSpacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, line: CGFloat = 0, widest: CGFloat = 0
        for s in subviews {
            let size = s.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                y += line + lineSpacing
                x = 0
                line = 0
            }
            x += size.width + spacing
            line = max(line, size.height)
            widest = max(widest, x - spacing)
        }
        return CGSize(width: proposal.width ?? widest, height: y + line)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, line: CGFloat = 0
        for s in subviews {
            let size = s.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                y += line + lineSpacing
                x = bounds.minX
                line = 0
            }
            s.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            line = max(line, size.height)
        }
    }
}
