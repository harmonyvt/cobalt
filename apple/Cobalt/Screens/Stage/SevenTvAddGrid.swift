import CobaltKit
import SwiftUI

// "add from 7tv" on the set screen (APP-API-CONTRACT 57.7, mockup screen 3): section 20's emote search with its sorts (the
// same `GET /emotes?q=&sort=&page=` the 7tv circle uses). A tile's + adds the emote under its own name; a long press (a right
// click on the Mac) offers "add with another name…"; an emote already in the set shows ✓. A name already in the set asks
// before it swaps. The whole set is paged in first so every ✓ is right.

struct SevenTvAddGrid: View {
    let model: AppModel
    let emoteSet: SevenTvSetModel

    /// An add waiting for the owner: a name that is taken (swap?).
    private struct PendingAdd: Identifiable {
        let hit: EmoteHit
        let alias: String?
        var id: String { hit.id + "/" + (alias ?? hit.name) }
    }

    @State private var query = ""
    @State private var sort: EmoteSort = .top
    @State private var hits: [EmoteHit] = []
    @State private var page = 1
    @State private var hasMore = false
    @State private var loadingMore = false
    @State private var searching = false
    @State private var missed = false
    @State private var failed = false
    @State private var token = 0
    @State private var naming: EmoteHit?
    @State private var aliasDraft = ""
    @State private var swapping: PendingAdd?
    @State private var addedTick = 0
    @State private var failTick = 0
    @Environment(\.shell) private var shell

    private struct Ask: Equatable {
        var query: String
        var sort: EmoteSort
    }

    var body: some View {
        let members = emoteSet.memberIDs
        let editable = emoteSet.can.manageSets
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                SevenTvSearchField(placeholder: Copy.SevenTv.searchField, text: $query)
                if searching { ProgressView().controlSize(.small) }
            }
            sortChips
            caption(editable: editable)
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 72), spacing: 12)], spacing: 12) {
                    ForEach(hits) { hit in
                        SevenTvHitTile(
                            hit: hit, inSet: members.contains(hit.id), busy: emoteSet.busy.contains(hit.id), editable: editable
                        ) {
                            tap(hit, inSet: members.contains(hit.id))
                        }
                        .contextMenu {
                            if editable {
                                Button(Copy.SevenTv.addWithName, systemImage: Symbol.SevenTv.rename) {
                                    aliasDraft = hit.name
                                    naming = hit
                                }
                            }
                        }
                        .onAppear {
                            if hit.id == hits.last?.id { Task { await more() } }
                        }
                    }
                }
                if loadingMore {
                    ProgressView().controlSize(.small).padding(.vertical, 8)
                }
            }
            .scrollDismissesKeyboard(.immediately)
        }
        .task { await emoteSet.loadEverything() }
        .task(id: Ask(query: query, sort: sort)) { await search() }
        .modifier(prompts)
        .haptic(.selection, trigger: sort)
        .haptic(.success, trigger: addedTick)
        .haptic(.error, trigger: failTick)
    }

    private var prompts: SevenTvAddPrompts {
        SevenTvAddPrompts(
            naming: $naming, aliasDraft: $aliasDraft, swapping: swappingShown, swapTitle: swapTitle,
            addNamed: { addNamed() }, confirmSwap: { confirmSwap() })
    }

    private var swapTitle: String {
        guard let pending = swapping else { return "" }
        return Copy.SevenTv.swapTitle(pending.alias ?? pending.hit.name)
    }

    private var swappingShown: Binding<Bool> {
        Binding(get: { swapping != nil }, set: { if !$0 { swapping = nil } })
    }

    @ViewBuilder
    private func caption(editable: Bool) -> some View {
        if !editable {
            Text(Copy.SevenTv.readOnly).font(CobaltType.captionSmall).foregroundStyle(CobaltColor.caption)
        } else if failed {
            Text(Copy.SevenTv.searchDown).font(CobaltType.captionSmall).foregroundStyle(CobaltColor.errorText)
        } else if missed && !searching {
            Text(Copy.SevenTv.searchMiss).font(CobaltType.captionSmall).foregroundStyle(CobaltColor.caption)
        } else {
            Text(Copy.SevenTv.addHintShort)
                .font(CobaltType.captionSmall)
                .foregroundStyle(CobaltColor.caption)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var sortChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(EmoteSort.allCases) { option in
                    SevenTvChip(title: Copy.emoteSort(option), selected: sort == option) { sort = option }
                }
            }
        }
        .scrollBounceBehavior(.basedOnSize)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Copy.emoteSortsA11y)
    }

    // MARK: adding

    private func tap(_ hit: EmoteHit, inSet: Bool) {
        guard !inSet else {
            shell.showStatus(Copy.SevenTv.alreadyIn)
            return
        }
        add(hit, alias: nil)
    }

    /// "add with another name…" answered.
    private func addNamed() {
        guard let hit = naming else { return }
        naming = nil
        guard let alias = SevenTvRule.cleanAlias(aliasDraft) else {
            shell.showStatus(Copy.SevenTv.aliasRule)
            failTick += 1
            return
        }
        add(hit, alias: alias == hit.name ? nil : alias)
    }

    /// A name already in the set asks first; otherwise the add goes straight to 7TV.
    private func add(_ hit: EmoteHit, alias: String?) {
        if emoteSet.emote(aliased: alias ?? hit.name) != nil {
            swapping = PendingAdd(hit: hit, alias: alias)
            return
        }
        send(hit, alias: alias, swap: false)
    }

    private func confirmSwap() {
        guard let pending = swapping else { return }
        swapping = nil
        send(pending.hit, alias: pending.alias, swap: true)
    }

    private func send(_ hit: EmoteHit, alias: String?, swap: Bool) {
        let name = alias ?? hit.name
        Task {
            do {
                try await emoteSet.add(hit, alias: alias, overrideConflicts: swap)
                shell.showStatus(Copy.SevenTv.added(name))
                addedTick += 1
            } catch {
                shell.showStatus(Copy.SevenTv.message(for: error))
                failTick += 1
            }
        }
    }

    // MARK: searching (as the 7tv circle's card does)

    private func search() async {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        token += 1
        let mine = token
        failed = false
        missed = false
        loadingMore = false
        page = 1
        hasMore = false
        // a chip tap loads at once; typing waits for a pause
        if !q.isEmpty { try? await Task.sleep(for: .milliseconds(300)) }
        guard mine == token, !Task.isCancelled else { return }
        searching = true
        defer { if mine == token { searching = false } }
        do {
            let first = try await model.library.browseEmotes(query: q, sort: sort, page: 1)
            guard mine == token else { return }
            hits = first.items
            hasMore = first.hasMore
            missed = first.items.isEmpty
        } catch {
            guard mine == token else { return }
            hits = []
            failed = true
        }
    }

    private func more() async {
        guard hasMore, !loadingMore, !searching else { return }
        let mine = token
        let next = page + 1
        loadingMore = true
        defer { if mine == token { loadingMore = false } }
        do {
            let found = try await model.library.browseEmotes(
                query: query.trimmingCharacters(in: .whitespacesAndNewlines), sort: sort, page: next)
            guard mine == token else { return }
            let seen = Set(hits.map(\.id))
            hits += found.items.filter { !seen.contains($0.id) }
            page = next
            hasMore = found.hasMore
        } catch {
            guard mine == token else { return }
            hasMore = false
        }
    }
}

/// The two questions of an add: the other name, and "swap?" when the name is taken.
private struct SevenTvAddPrompts: ViewModifier {
    @Binding var naming: EmoteHit?
    @Binding var aliasDraft: String
    @Binding var swapping: Bool
    let swapTitle: String
    let addNamed: () -> Void
    let confirmSwap: () -> Void

    private var namingShown: Binding<Bool> {
        Binding(get: { naming != nil }, set: { if !$0 { naming = nil } })
    }

    func body(content: Content) -> some View {
        content
            .alert(Copy.SevenTv.addAsTitle, isPresented: namingShown) {
                TextField(Copy.SevenTv.alias, text: $aliasDraft)
                    .accessibilityLabel(Copy.SevenTv.alias)
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    #endif
                Button(Copy.SevenTv.add) { addNamed() }
                Button(Copy.SevenTv.cancel, role: .cancel) {}
            } message: {
                Text(Copy.SevenTv.addAsMessage(naming?.name ?? ""))
            }
            .confirmationDialog(swapTitle, isPresented: $swapping, titleVisibility: .visible) {
                Button(Copy.SevenTv.swap, role: .destructive) { confirmSwap() }
                Button(Copy.SevenTv.cancel, role: .cancel) {}
            } message: {
                Text(Copy.SevenTv.swapMessage)
            }
    }
}

/// One search result: the picture, its name, and + (or ✓ once it is in the set) in the corner.
private struct SevenTvHitTile: View {
    let hit: EmoteHit
    let inSet: Bool
    let busy: Bool
    let editable: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                ZStack(alignment: .topTrailing) {
                    EmotePicture(url: hit.previewURL, animated: hit.animated)
                        .padding(4)
                        .background(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .fill(inSet ? CobaltColor.elevated : Color.clear))
                        .scaleEffect(busy ? 0.92 : 1)
                        .opacity(busy ? 0.6 : 1)
                    if busy {
                        ProgressView().controlSize(.small)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else if editable || inSet {
                        badge
                            .offset(x: 6, y: -6)
                            .transition(.scale.combined(with: .opacity))
                    }
                }
                .animation(Motion.chip, value: inSet)
                .animation(Motion.press, value: busy)
                Text(hit.name)
                    .font(Font.cobalt(11.5, .regular, relativeTo: .caption))
                    .foregroundStyle(CobaltColor.caption)
                    .lineLimit(1)
            }
        }
        .buttonStyle(.plain)
        .disabled(busy || (!editable && !inSet))
        .accessibilityLabel(Copy.SevenTv.hitA11y(hit.name, inSet: inSet))
        .accessibilityHint(inSet ? "" : Copy.SevenTv.addHintA11y)
    }

    private var badge: some View {
        Image(systemName: inSet ? Symbol.SevenTv.inSet : Symbol.SevenTv.add)
            .font(.system(size: 11, weight: .bold))
            .foregroundStyle(inSet ? Color.black : CobaltColor.onText)
            .frame(width: 22, height: 22)
            .background(Circle().fill(inSet ? CobaltColor.success : CobaltColor.text))
            .accessibilityHidden(true)
    }
}
