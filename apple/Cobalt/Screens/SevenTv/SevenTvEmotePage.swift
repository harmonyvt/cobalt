import CobaltKit
import SwiftUI

// An emote of 7TV in the screen pane (`PaneItem.emote(id)`; APP-API-CONTRACT 57.7, 20.2, apple/CONTRACT-PANE.md section 5).
// It replaces the emote sheet (a tap on an emote of a set) and the variants sheet (a long press): the emote is the hero, and
// spanned it has the whole screen beside its details; the details are the name in the set (save name, or reset to its 7TV name
// when renamed), "add to a set…" (the pane's next page), open on 7tv, remove (asks first) and "copy to set…" (a name that set
// already has opens the clash sheet); and every emote on 7TV with the same name, most used first, as a shelf card (a tap swaps
// it in for this one under this one's name, without the right to edit the set it opens it on 7tv.app).
//
// The pane's item is an id, so the page finds the rest: the set the tab has open (the set screen gives it to the pane with
// `pane.provide(emoteSet)` before opening the emote), an emote the account owns, or one a screen remembered with
// `SevenTvEmoteHits.remember`. A channel that does not let the account manage sets shows the emote read-only.

struct SevenTvEmotePage: View {
    let model: AppModel
    let id: String

    @Environment(Pane.self) private var pane: Pane?
    @State private var looked = false

    private var store: SevenTvStore { model.sevenTv }
    private var emoteSet: SevenTvSetModel? { pane?.provided(SevenTvSetModel.self) }
    private var item: SevenTvSetItem? { emoteSet?.all.first { $0.emoteID == id } }

    private var hit: EmoteHit? {
        if let item { return item.asHit }
        if let owned = store.ownedEmote(id) { return owned.asHit }
        return SevenTvEmoteHits.hit(id)
    }

    var body: some View {
        Group {
            if let hit {
                SevenTvEmoteView(model: model, hit: hit, item: item, emoteSet: item == nil ? nil : emoteSet)
                    .id(item?.id ?? hit.id)
            } else if looked {
                PaneGonePage()
            } else {
                PaneLoadingPage()
            }
        }
        .task(id: id) {
            looked = false
            if store.status == nil { await store.load() }
            if hit == nil, store.isLinked, store.ownedState != .loaded { await store.loadOwned() }
            looked = true
        }
    }
}

private struct SevenTvEmoteView: View {
    let model: AppModel
    let hit: EmoteHit
    /// The emote as the open set has it (its name there); nil when no set is open on it.
    let item: SevenTvSetItem?
    let emoteSet: SevenTvSetModel?

    @Environment(Pane.self) private var pane: Pane?
    @Environment(\.paneShape) private var shape
    @Environment(\.shell) private var shell
    @Environment(\.openURL) private var openURL
    @State private var alias: String
    @State private var problem: String?
    @State private var confirmingRemove = false
    @State private var clash: SevenTvNameClash?
    @State private var variants: SevenTvVariantsModel?
    @State private var swapping: String?
    @State private var doneTick = 0
    @State private var failTick = 0

    init(model: AppModel, hit: EmoteHit, item: SevenTvSetItem?, emoteSet: SevenTvSetModel?) {
        self.model = model
        self.hit = hit
        self.item = item
        self.emoteSet = emoteSet
        _alias = State(initialValue: item?.alias ?? hit.name)
    }

    private var store: SevenTvStore { model.sevenTv }
    private var shownName: String { item?.alias ?? hit.name }
    private var pageURL: URL { SevenTvEmoteRule.pageURL(hit.id) }
    /// Rename, remove and copy: an emote of a set the account may change.
    private var editable: Bool { item != nil && emoteSet?.can.manageSets == true }
    private var working: Bool { item.map { emoteSet?.busy.contains($0.emoteID) == true } ?? false }
    private var canAddToSet: Bool { store.channels.contains { $0.can.manageSets } }
    private var canRename: Bool {
        guard let item, editable, !working, let clean = SevenTvRule.cleanAlias(alias) else { return false }
        return clean != item.alias
    }

    var body: some View {
        PanePage(
            title: shownName, subtitle: Copy.SevenTv.sevenTvNameLine(hit.name, animated: hit.animated)
        ) {
            emoteHero
        } controls: {
            VStack(alignment: .leading, spacing: 12) {
                if editable {
                    aliasField
                    if let problem {
                        Text(problem)
                            .font(CobaltType.caption)
                            .foregroundStyle(CobaltColor.errorText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    ButtonRow {
                        Button(Copy.SevenTv.saveName, systemImage: Symbol.SevenTv.rename) { rename(to: alias) }
                            .buttonStyle(.cobaltPrimary(fullWidth: false, compact: true))
                            .disabled(!canRename)
                        if let item, item.renamed, !working {
                            Button(Copy.SevenTv.resetTo(item.name), systemImage: Symbol.SevenTv.reset) { rename(to: item.name) }
                                .buttonStyle(.cobaltSecondary(fullWidth: false, compact: true))
                        }
                    }
                } else if item != nil {
                    Text(Copy.SevenTv.readOnly)
                        .font(CobaltType.captionSmall)
                        .foregroundStyle(CobaltColor.caption)
                }
                PaneActionGrid(actions)
            }
        } shelf: {
            PaneCard(Copy.SevenTv.variants) { variantsCard }
        }
        .task { makeVariants() }
        .sheet(item: $clash) { found in
            if let emoteSet { SevenTvClashSheet(emoteSet: emoteSet, clash: found) }
        }
        .confirmationDialog(Copy.SevenTv.removeTitle(shownName), isPresented: $confirmingRemove, titleVisibility: .visible) {
            Button(Copy.SevenTv.remove, role: .destructive) { remove() }
            Button(Copy.SevenTv.keep, role: .cancel) {}
        } message: {
            Text(Copy.SevenTv.removeMessage)
        }
        .haptic(.success, trigger: doneTick)
        .haptic(.error, trigger: failTick)
    }

    @ViewBuilder
    private var emoteHero: some View {
        let stage = ZStack {
            CobaltColor.surface
            EmotePicture(url: hit.previewURL, animated: hit.animated, side: 180)
                .padding(20)
        }
        .frame(minHeight: 200)
        .accessibilityHidden(true)

        if shape == .tall {
            stage
                .clipShape(RoundedRectangle(cornerRadius: Metrics.thumbRadius, style: .continuous))
                .padding(.horizontal, 16)
                .padding(.top, 12)
        } else {
            stage
        }
    }

    // MARK: actions

    private var actions: [PaneAction] {
        var list = [
            PaneAction(Copy.SevenTv.addToSetTitle, systemImage: Symbol.SevenTv.addToSet, disabled: !canAddToSet) {
                SevenTvEmoteHits.remember(hit)
                pane?.open(.emoteAddToSet(hit.id))
            },
            PaneAction(Copy.SevenTv.openOn7tv, systemImage: Symbol.SevenTv.website) { openURL(pageURL) },
        ]
        if editable, let emoteSet, !emoteSet.otherSets.isEmpty {
            let choices = emoteSet.otherSets.map { target in
                PaneAction(target.name, systemImage: Symbol.SevenTv.copyToSet, id: "copy-\(target.id)") {
                    copy(to: target)
                }
            }
            list.append(
                PaneAction(Copy.SevenTv.copyToSet, systemImage: Symbol.SevenTv.copyToSet, disabled: working, choices: choices) {})
        }
        if editable {
            list.append(
                PaneAction(Copy.SevenTv.remove, systemImage: Symbol.SevenTv.remove, role: .destructive, disabled: working) {
                    confirmingRemove = true
                })
        }
        return list
    }

    private var aliasField: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(Copy.SevenTv.alias)
                .font(CobaltType.captionSmall)
                .foregroundStyle(CobaltColor.caption)
            TextField(Copy.SevenTv.alias, text: $alias)
                .font(CobaltType.body)
                .foregroundStyle(CobaltColor.text)
                .autocorrectionDisabled()
                #if os(iOS)
                .textInputAutocapitalization(.never)
                #endif
                .onSubmit { if canRename { rename(to: alias) } }
                .padding(.horizontal, 12)
                .frame(minHeight: Metrics.hit)
                .background(CobaltColor.elevated, in: RoundedRectangle(cornerRadius: Metrics.radius, style: .continuous))
                .accessibilityLabel(Copy.SevenTv.alias)
            Text(Copy.SevenTv.aliasRuleLong)
                .font(CobaltType.badge)
                .foregroundStyle(CobaltColor.caption)
        }
    }

    // MARK: edits

    /// "save name" and "reset to <7tv name>". A name another emote of the set already has is refused here.
    private func rename(to raw: String) {
        guard let item, let emoteSet else { return }
        problem = nil
        if let clean = SevenTvRule.cleanAlias(raw), let holder = emoteSet.emote(aliased: clean), holder.id != item.id {
            problem = Copy.SevenTv.message(for: SevenTvError.nameTaken(conflictEmoteID: holder.emoteID, alias: clean))
            return
        }
        Task {
            do {
                try await emoteSet.rename(item, to: raw)
                shell.showStatus(Copy.SevenTv.renamed(SevenTvRule.cleanAlias(raw) ?? raw))
                doneTick += 1
            } catch {
                problem = Copy.SevenTv.message(for: error)
                failTick += 1
            }
        }
    }

    private func copy(to target: SevenTvSetRow) {
        guard let item, let emoteSet else { return }
        problem = nil
        Task {
            do {
                if let found = try await emoteSet.copy(item, to: target.id) {
                    clash = found
                } else {
                    shell.showStatus(Copy.SevenTv.copied(item.alias, to: target.name))
                    doneTick += 1
                }
            } catch {
                problem = Copy.SevenTv.message(for: error)
                failTick += 1
            }
        }
    }

    private func remove() {
        guard let item, let emoteSet else { return }
        problem = nil
        Task {
            do {
                try await emoteSet.remove(item)
                shell.showStatus(Copy.SevenTv.removed(item.alias))
                doneTick += 1
                pane?.close()
            } catch {
                problem = Copy.SevenTv.message(for: error)
                failTick += 1
            }
        }
    }

    // MARK: variants

    private func makeVariants() {
        guard variants == nil else { return }
        let library = model.library
        let held = item ?? SevenTvSetItem(
            emoteID: hit.id, alias: hit.name, name: hit.name, animated: hit.animated, previewURL: hit.previewURL,
            fileURL: hit.fileURL)
        variants = SevenTvVariantsModel(emote: held) { name, page in
            try await library.emoteVariants(name: name, page: page)
        }
    }

    @ViewBuilder
    private var variantsCard: some View {
        if let variants {
            SevenTvVariantsList(
                variants: variants, emoteSet: emoteSet, held: item, swapping: swapping,
                pick: { pick($0, in: variants) }, open: { openURL(SevenTvEmoteRule.pageURL($0.id)) })
        }
    }

    /// A tap on a variant: swapped in under this one's name when the set can be changed, else opened on 7tv.app.
    private func pick(_ other: EmoteHit, in variants: SevenTvVariantsModel) {
        guard let item, let emoteSet, emoteSet.can.manageSets else { return openURL(SevenTvEmoteRule.pageURL(other.id)) }
        guard other.id != item.emoteID, swapping == nil else { return }
        swapping = other.id
        Task {
            do {
                try await emoteSet.swap(item, for: other)
                swapping = nil
                shell.showStatus(Copy.SevenTv.swapped(other.name, as: item.alias))
                doneTick += 1
                pane?.open(.emote(other.id))
            } catch {
                swapping = nil
                shell.showStatus(Copy.SevenTv.message(for: error))
                failTick += 1
            }
        }
    }
}

// MARK: - the variants

/// Every 7TV emote with the held one's own name (never the alias it has in the set), most used first. The held one says
/// "this one", another already in the set wears a check, and the next page loads at the last tile.
private struct SevenTvVariantsList: View {
    let variants: SevenTvVariantsModel
    let emoteSet: SevenTvSetModel?
    let held: SevenTvSetItem?
    let swapping: String?
    let pick: (EmoteHit) -> Void
    let open: (EmoteHit) -> Void

    private var canSwap: Bool { held != nil && emoteSet?.can.manageSets == true }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            caption
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 76), spacing: 12)], spacing: 12) {
                ForEach(variants.items) { hit in
                    SevenTvVariantTile(
                        hit: hit, held: hit.id == variants.emote.emoteID, inSet: emoteSet?.memberIDs.contains(hit.id) == true,
                        swaps: canSwap, swapping: swapping == hit.id, dimmed: swapping != nil && swapping != hit.id,
                        pick: { pick(hit) }, open: { open(hit) })
                    .onAppear {
                        if hit.id == variants.items.last?.id { Task { await variants.loadMore() } }
                    }
                }
            }
            if variants.loadingMore {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity)
            }
        }
        .motion(Motion.rows, value: variants.items.map(\.id))
        .task { if variants.state != .loaded { await variants.load() } }
    }

    @ViewBuilder
    private var caption: some View {
        switch variants.state {
        case .loading:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(Copy.SevenTv.variantsHint)
                    .font(CobaltType.captionSmall)
                    .foregroundStyle(CobaltColor.caption)
            }
        case .failed:
            HStack(spacing: 8) {
                Text(Copy.SevenTv.variantsDown)
                    .font(CobaltType.captionSmall)
                    .foregroundStyle(CobaltColor.errorText)
                Button(Copy.SevenTv.retry, systemImage: Symbol.SevenTv.retry) { Task { await variants.load() } }
                    .buttonStyle(.cobaltSecondary(fullWidth: false, compact: true))
            }
        case .loaded:
            VStack(alignment: .leading, spacing: 2) {
                Text(Copy.SevenTv.variantsCount(variants.othersCount, more: variants.hasMore))
                    .font(CobaltType.caption)
                    .foregroundStyle(CobaltColor.text)
                    .contentTransition(.numericText())
                Text(canSwap ? Copy.SevenTv.variantsSwapHint : Copy.SevenTv.variantsHint)
                    .font(CobaltType.captionSmall)
                    .foregroundStyle(CobaltColor.caption)
            }
            .accessibilityElement(children: .combine)
        }
    }
}

/// One variant: its picture and name, "this one" under the held emote, a check on another already in the set.
private struct SevenTvVariantTile: View {
    let hit: EmoteHit
    let held: Bool
    let inSet: Bool
    /// A tap swaps it in (else it opens on 7tv.app).
    let swaps: Bool
    let swapping: Bool
    let dimmed: Bool
    let pick: () -> Void
    let open: () -> Void

    var body: some View {
        Button(action: pick) {
            VStack(spacing: 4) {
                ZStack(alignment: .topTrailing) {
                    EmotePicture(url: hit.previewURL, animated: hit.animated)
                        .padding(6)
                        .background(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .fill(held || inSet ? CobaltColor.elevated : CobaltColor.surface))
                        .overlay {
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .strokeBorder(held ? CobaltColor.focus : Color.clear, lineWidth: 2)
                        }
                    if swapping {
                        ProgressView().controlSize(.small)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                    if inSet && !held {
                        Image(systemName: Symbol.SevenTv.inSet)
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(Color.black)
                            .frame(width: 22, height: 22)
                            .background(Circle().fill(CobaltColor.success))
                            .offset(x: 6, y: -6)
                            .accessibilityHidden(true)
                    }
                }
                Text(held ? Copy.SevenTv.thisOne : hit.name)
                    .font(Font.cobalt(11.5, held ? .semibold : .regular, relativeTo: .caption))
                    .foregroundStyle(held ? CobaltColor.text : CobaltColor.caption)
                    .lineLimit(1)
            }
        }
        .buttonStyle(.plain)
        .opacity(dimmed ? 0.45 : 1)
        .disabled(dimmed)
        .contextMenu {
            Button(Copy.SevenTv.openOn7tv, systemImage: Symbol.SevenTv.website, action: open)
        }
        .accessibilityLabel(Copy.SevenTv.variantA11y(hit.name, held: held, inSet: inSet, animated: hit.animated))
        .accessibilityHint(swaps && !held ? Copy.SevenTv.variantSwapHintA11y : Copy.SevenTv.variantHintA11y)
        .accessibilityAction(named: Copy.SevenTv.openOn7tv, open)
    }
}
