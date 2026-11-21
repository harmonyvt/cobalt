import CobaltKit
import SwiftUI
#if os(iOS)
import UIKit
#endif

// The booru tab (APP-API-CONTRACT 72): Danbooru search under this device's own content level (general, sensitive or
// questionable; explicit is not part of capystore) and filters, all applied by the server. A grid of posts; a post opens
// in a sheet with its tags and "save". While the screen is mirrored, recorded or on a TV, only general shows (safe mode).

struct BooruScreen: View {
    let model: AppModel
    let tier: Tier

    @State private var text = ""
    @State private var open: BooruPost?
    @State private var filtersShown = false
    @FocusState private var searchFocused: Bool

    private var store: BooruStore { model.booru }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                searchField
                if searchFocused, !store.suggestions.isEmpty { suggestions }
                chips
                if store.safeMode { notice(Copy.Booru.safeMode, symbol: Symbol.Booru.safe) }
                if !store.dropped.isEmpty, store.query.order != .new { notice(Copy.Booru.dropped, symbol: Symbol.Booru.filters) }
                content
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: 1400, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .scrollDismissesKeyboard(.immediately)
        .refreshable { await store.reload() }
        .background(CobaltColor.bg)
        .navigationTitle(Copy.Booru.title)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(Copy.Booru.filters, systemImage: Symbol.Booru.filters) { filtersShown = true }
            }
        }
        .task {
            text = store.query.tags
            await store.load()
        }
        .modifier(BooruSafeModeWatch(store: store))
        .spreadSheet(item: $open) { post in
            BooruPostSheet(model: model, post: post) { tag, replace in
                open = nil
                let next = replace ? tag : (store.query.tagList + [tag]).suffix(BooruQuery.maxTags).joined(separator: " ")
                text = next
                var q = store.query
                q.tags = next
                Task { await store.search(q) }
            }
        }
        .spreadSheet(isPresented: $filtersShown, id: "booru-filters") {
            BooruFilterSheet(model: model)
        }
    }

    // MARK: search

    private var searchField: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Image(systemName: Symbol.Booru.search).foregroundStyle(CobaltColor.caption)
                TextField(Copy.Booru.searchPrompt, text: $text)
                    .textFieldStyle(.plain)
                    .font(CobaltType.body)
                    .autocorrectionDisabled()
                    .focused($searchFocused)
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    .submitLabel(.search)
                    #endif
                    .onSubmit(runSearch)
                    .onChange(of: text) { _, now in Task { await store.suggest(now) } }
                if !text.isEmpty {
                    Button(Copy.Booru.close, systemImage: Symbol.Booru.clear) {
                        text = ""
                        runSearch()
                    }
                    .labelStyle(.iconOnly)
                    .foregroundStyle(CobaltColor.caption)
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
            .frame(minHeight: Metrics.hit)
            .background(CobaltColor.surface, in: Capsule())
            let n = BooruQuery(tags: text).tagList.count
            Text(n > BooruQuery.maxTags ? Copy.Booru.tooManyTags : Copy.Booru.tagsUsed(n))
                .font(CobaltType.captionSmall)
                .foregroundStyle(n > BooruQuery.maxTags ? CobaltColor.errorText : CobaltColor.caption)
                .padding(.leading, 14)
        }
    }

    private var suggestions: some View {
        VStack(spacing: 0) {
            ForEach(store.suggestions) { s in
                Button {
                    var words = text.split(whereSeparator: \.isWhitespace).map(String.init)
                    if !words.isEmpty { words.removeLast() }
                    words.append(s.name)
                    text = words.joined(separator: " ") + " "
                    store.clearSuggestions()
                } label: {
                    HStack {
                        Text(s.name).font(CobaltType.body).foregroundStyle(BooruTagColor.of(s.kind))
                        Spacer()
                        Text(s.count.formatted(.number.notation(.compactName))).font(CobaltType.caption).foregroundStyle(CobaltColor.caption)
                    }
                    .padding(.horizontal, 14)
                    .frame(minHeight: 40)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .background(CobaltColor.surface, in: RoundedRectangle(cornerRadius: Metrics.radius))
    }

    private func runSearch() {
        store.clearSuggestions()
        searchFocused = false
        var q = store.query
        q.tags = text.trimmingCharacters(in: .whitespaces)
        Task { await store.search(q) }
    }

    // MARK: chips

    private var chips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                Button { filtersShown = true } label: {
                    BooruChip(text: Copy.Booru.upTo(store.effectiveLevel), dot: BooruLevelColor.of(store.effectiveLevel), on: true)
                }
                .buttonStyle(.plain)
                Menu {
                    Picker(Copy.Booru.order, selection: orderBinding) {
                        ForEach(BooruOrder.allCases, id: \.self) { Text(Copy.Booru.order($0)).tag($0) }
                    }
                } label: {
                    BooruChip(text: Copy.Booru.order(store.query.order), dot: nil, on: store.query.order != .new)
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                ForEach(BooruMedia.allCases, id: \.self) { m in
                    Button {
                        var q = store.query
                        q.media = q.media == m ? nil : m
                        Task { await store.search(q) }
                    } label: {
                        BooruChip(text: Copy.Booru.media(m), dot: nil, on: store.query.media == m)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var orderBinding: Binding<BooruOrder> {
        Binding(get: { store.query.order }, set: { o in
            var q = store.query
            q.order = o
            Task { await store.search(q) }
        })
    }

    private func notice(_ text: String, symbol: String) -> some View {
        Label(text, systemImage: symbol)
            .font(CobaltType.caption)
            .foregroundStyle(CobaltColor.caption)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(CobaltColor.surface, in: RoundedRectangle(cornerRadius: Metrics.radius))
    }

    // MARK: the grid

    @ViewBuilder private var content: some View {
        switch store.phase {
        case .idle, .loading where store.posts.isEmpty:
            Text(Copy.Booru.loading).font(CobaltType.body).foregroundStyle(CobaltColor.caption).padding(.top, 30)
                .frame(maxWidth: .infinity)
        case .failed(let code):
            VStack(spacing: 10) {
                Text(Copy.Booru.failure(code)).font(CobaltType.body).foregroundStyle(CobaltColor.caption)
                    .multilineTextAlignment(.center)
                if code != "error.booru.too_many_tags" {
                    Button(Copy.Booru.retry, systemImage: Symbol.Booru.retry) { Task { await store.reload() } }
                        .buttonStyle(.cobaltSecondary(fullWidth: false, compact: true))
                }
            }
            .padding(.top, 30)
            .frame(maxWidth: .infinity)
        default:
            if store.posts.isEmpty {
                VStack(spacing: 4) {
                    Text(Copy.Booru.empty).font(CobaltType.bodyMedium)
                    Text(Copy.Booru.emptyHint).font(CobaltType.caption).foregroundStyle(CobaltColor.caption)
                }
                .padding(.top, 30)
                .frame(maxWidth: .infinity)
            } else {
                grid
            }
        }
    }

    private var grid: some View {
        VStack(spacing: 12) {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: tier == .compact ? 108 : 150), spacing: 4)], spacing: 4) {
                ForEach(store.posts) { post in
                    BooruTile(post: post, covered: post.blur && !store.revealed.contains(post.id)) {
                        if post.blur && !store.revealed.contains(post.id) {
                            store.reveal(post.id)
                        } else {
                            open = post
                        }
                    }
                    .onAppear {
                        if post.id == store.posts.last?.id { Task { await store.loadMore() } }
                    }
                }
            }
            if store.hidden.byFilters > 0 {
                Text(Copy.Booru.hidden(store.hidden.byFilters)).font(CobaltType.captionSmall).foregroundStyle(CobaltColor.caption)
            }
            if store.loadingMore {
                ProgressView().padding(8)
            } else if store.nextPage != nil {
                Button(Copy.Booru.more) { Task { await store.loadMore() } }
                    .buttonStyle(.cobaltSecondary(fullWidth: false, compact: true))
            }
        }
    }
}

// MARK: - pieces

struct BooruChip: View {
    let text: String
    let dot: Color?
    let on: Bool

    var body: some View {
        HStack(spacing: 5) {
            if let dot { Circle().fill(dot).frame(width: 8, height: 8) }
            Text(text).font(CobaltType.caption).lineLimit(1)
        }
        .padding(.horizontal, 11)
        .frame(minHeight: 32)
        .foregroundStyle(on ? CobaltColor.onText : CobaltColor.text)
        .background(on ? CobaltColor.text : CobaltColor.surface, in: Capsule())
        .contentShape(Capsule())
    }
}

enum BooruLevelColor {
    static func of(_ l: BooruLevel) -> Color {
        switch l {
        case .general: return CobaltColor.success
        case .sensitive: return CobaltColor.focus
        case .questionable: return CobaltColor.collectionOnTile
        }
    }
}

enum BooruTagColor {
    static func of(_ k: BooruSuggestion.Kind) -> Color {
        switch k {
        case .artist: return Color(hex: 0xff8a8a)
        case .character: return Color(hex: 0x62d36f)
        case .copyright: return CobaltColor.collectionSet
        case .meta: return CobaltColor.collection
        case .general: return CobaltColor.text
        }
    }
}

/// One post in the grid: its thumbnail, or a cover when a theme set to blur matched (tap shows it).
struct BooruTile: View {
    let post: BooruPost
    let covered: Bool
    let tap: () -> Void

    var body: some View {
        Button(action: tap) {
            Color.clear
                .aspectRatio(3 / 4, contentMode: .fit)
                .overlay {
                    AsyncImage(url: post.thumbUrl) { phase in
                        if let image = phase.image {
                            image.resizable().scaledToFill()
                        } else {
                            LinearGradient(colors: [CobaltColor.frameTop, CobaltColor.frameBottom], startPoint: .top, endPoint: .bottom)
                        }
                    }
                    .blur(radius: covered ? 22 : 0)
                    .mediaMask()
                }
                .overlay {
                    if covered {
                        ZStack {
                            CobaltColor.scrim
                            Label(Copy.Booru.tapToShow, systemImage: Symbol.Booru.blur)
                                .font(CobaltType.captionSmall)
                                .foregroundStyle(CobaltColor.badgeInk)
                        }
                    }
                }
                .overlay(alignment: .topLeading) {
                    Text(post.rating.rawValue)
                        .font(CobaltType.pill)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .foregroundStyle(.white)
                        .background(BooruLevelColor.of(post.rating).opacity(0.85), in: RoundedRectangle(cornerRadius: 6))
                        .padding(6)
                }
                .overlay(alignment: .bottomTrailing) {
                    if post.media != .image {
                        Image(systemName: post.media == .video ? Symbol.Booru.video : Symbol.Booru.animated)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(CobaltColor.badgeInk)
                            .padding(5)
                            .background(CobaltColor.badgeBack, in: Circle())
                            .padding(6)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: Metrics.thumbRadius))
                .contentShape(RoundedRectangle(cornerRadius: Metrics.thumbRadius))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(post.tags.character.first ?? post.tags.general.prefix(3).joined(separator: ", "))
    }
}

/// Safe mode: while the screen is mirrored, recorded or shown on another display, the store asks for general only.
private struct BooruSafeModeWatch: ViewModifier {
    let store: BooruStore

    func body(content: Content) -> some View {
        #if os(iOS)
        content
            .onAppear(perform: check)
            .onReceive(NotificationCenter.default.publisher(for: UIScreen.capturedDidChangeNotification)) { _ in check() }
            .onReceive(NotificationCenter.default.publisher(for: UIScene.willConnectNotification)) { _ in check() }
            .onReceive(NotificationCenter.default.publisher(for: UIScene.didDisconnectNotification)) { _ in check() }
        #else
        content
        #endif
    }

    #if os(iOS)
    private func check() {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let captured = scenes.contains { $0.traitCollection.sceneCaptureState == .active }
        let external = UIApplication.shared.connectedScenes.contains { $0.session.role != .windowApplication }
        let safe = captured || external
        if store.safeMode != safe { store.safeMode = safe }
    }
    #endif
}
