import CobaltKit
import SwiftUI

// One booru post (APP-API-CONTRACT 72): the picture, save (the file's link goes to the queue like any paste), open on
// Danbooru, share, and its tags by kind. A tag searches; its menu adds it to the search or hides it (the blacklist).

struct BooruPostSheet: View {
    let model: AppModel
    let post: BooruPost
    /// A tag was picked: (tag, replace the search) or add it to the search.
    let pick: (String, Bool) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var saved = false
    @State private var hiddenTags: Set<String> = []

    private var store: BooruStore { model.booru }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    picture
                    actions
                    info
                    tagGroup(Copy.Booru.artist, post.tags.artist, .artist)
                    tagGroup(Copy.Booru.character, post.tags.character, .character)
                    tagGroup(Copy.Booru.copyright, post.tags.copyright, .copyright)
                    tagGroup(Copy.Booru.general, post.tags.general, .general)
                    tagGroup(Copy.Booru.meta, post.tags.meta, .meta)
                }
                .padding(16)
                .frame(maxWidth: 760)
                .frame(maxWidth: .infinity)
            }
            .background(CobaltColor.bg)
            .navigationTitle(post.tags.character.first ?? Copy.Booru.title)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(Copy.Booru.close, systemImage: Symbol.Booru.close) { dismiss() }
                }
            }
        }
    }

    private var picture: some View {
        Color.clear
            .aspectRatio(max(0.4, min(post.aspect, 2.5)), contentMode: .fit)
            .overlay {
                AsyncImage(url: post.sampleUrl) { phase in
                    if let image = phase.image {
                        image.resizable().scaledToFit()
                    } else {
                        ZStack {
                            LinearGradient(colors: [CobaltColor.frameTop, CobaltColor.frameBottom], startPoint: .top, endPoint: .bottom)
                            ProgressView()
                        }
                    }
                }
                .mediaMask()
            }
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .overlay(alignment: .topLeading) {
                Text(Copy.Booru.level(post.rating))
                    .font(CobaltType.pill)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .foregroundStyle(.white)
                    .background(BooruLevelColor.of(post.rating).opacity(0.85), in: Capsule())
                    .padding(10)
            }
    }

    private var actions: some View {
        HStack(spacing: 8) {
            Button(saved ? Copy.Booru.savedToLibrary : Copy.Booru.save, systemImage: Symbol.Booru.save) {
                _ = model.queue.add([.link(post.fileUrl)], via: .paste)
                saved = true
            }
            .buttonStyle(.cobaltPrimary(fullWidth: true, compact: true))
            .disabled(saved)
            ShareLink(item: post.pageUrl) {
                Label(Copy.Booru.share, systemImage: Symbol.Booru.share).labelStyle(.iconOnly)
            }
            .buttonStyle(.cobaltSecondary(fullWidth: false, compact: true))
            Link(destination: post.pageUrl) {
                Label(Copy.Booru.openDanbooru, systemImage: Symbol.Booru.open).labelStyle(.iconOnly)
            }
            .buttonStyle(.cobaltSecondary(fullWidth: false, compact: true))
        }
    }

    private var info: some View {
        HStack(spacing: 14) {
            Label(Copy.Booru.score(post.score), systemImage: Symbol.Booru.score)
            Label(Copy.Booru.favs(post.favs), systemImage: Symbol.Booru.favs)
            Text(Copy.Booru.size(post.width, post.height, post.ext))
        }
        .font(CobaltType.caption)
        .foregroundStyle(CobaltColor.caption)
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
                            Button(Copy.Booru.searchTag, systemImage: Symbol.Booru.search) { pick(tag, true) }
                            Button(Copy.Booru.addTag, systemImage: Symbol.Booru.add) { pick(tag, false) }
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
                            pick(tag, true)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }
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
