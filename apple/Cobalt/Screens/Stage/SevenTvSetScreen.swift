import CobaltKit
import SwiftUI

// A 7TV set (APP-API-CONTRACT 57.7, mockup `7tv-tab/` "managing a set"), pushed from the 7tv tab (and the studio's old card),
// or embedded as the Mac's right column (`embedded`: a header with rename, make live and "+ add emotes" instead of the chips).
// Two chips: "in this set" (a 4-column grid with a name filter and paging; a tap opens the emote sheet; a long press, or
// "select", picks several for "copy to…" and "remove N") and "add from 7tv" (section 20's search and sorts; + adds under the
// emote's own name, a long press or right click adds with another name, ✓ marks what is already in the set; a name already
// in the set opens the clash sheet). Rename the set and make it live from the title menu. Every edit changes the grid once
// 7TV took it; a refusal says 7TV's words on the status line.

struct SevenTvSetScreen: View {
    let model: AppModel
    let route: SevenTvSetRoute
    /// The Mac's right column: no navigation title, a header row instead of the chips.
    var embedded = false
    /// The header's "+ add emotes" (embedded); nil switches to the "add from 7tv" chip.
    var addEmotes: (() -> Void)?

    @State private var emoteSet: SevenTvSetModel
    @State private var tab: Tab = .inSet
    @State private var picked: SevenTvSetItem?
    @State private var renaming = false
    @State private var draftName = ""
    @State private var selecting = false
    @State private var selection: Set<String> = []
    @State private var confirmingRemove = false
    @State private var clash: SevenTvNameClash?
    @State private var working = false
    @State private var doneTick = 0
    @State private var failTick = 0
    @Environment(\.shell) private var shell

    enum Tab: Hashable {
        case inSet, add
    }

    init(
        model: AppModel, route: SevenTvSetRoute, emoteSet: SevenTvSetModel? = nil, embedded: Bool = false,
        addEmotes: (() -> Void)? = nil
    ) {
        self.model = model
        self.route = route
        self.embedded = embedded
        self.addEmotes = addEmotes
        _emoteSet = State(initialValue: emoteSet ?? model.sevenTv.openSet(route.setID, channelID: route.channelID))
    }

    private var pickedEmotes: [SevenTvSetItem] { emoteSet.all.filter { selection.contains($0.id) } }

    var body: some View {
        page
            .modifier(SevenTvSetScreenChrome(embedded: embedded, title: emoteSet.info?.name ?? Copy.SevenTv.setFallbackTitle) {
                titleMenu
            })
            .task { await emoteSet.load() }
            .sheet(item: $picked) { emote in
                SevenTvEmoteSheet(emoteSet: emoteSet, emote: emote)
            }
            .sheet(item: $clash) { found in
                SevenTvClashSheet(emoteSet: emoteSet, clash: found)
            }
            .modifier(SevenTvRenameSetAlert(emoteSet: emoteSet, isPresented: $renaming, draft: $draftName, done: { doneTick += 1 }, failed: { failTick += 1 }))
            .confirmationDialog(
                Copy.SevenTv.removeManyTitle(selection.count), isPresented: $confirmingRemove, titleVisibility: .visible
            ) {
                Button(Copy.SevenTv.removeN(selection.count), role: .destructive) { removePicked() }
                Button(Copy.SevenTv.keep, role: .cancel) {}
            } message: {
                Text(Copy.SevenTv.removeMessage)
            }
            .onChange(of: tab) { _, _ in endSelecting() }
            .haptic(.success, trigger: doneTick)
            .haptic(.error, trigger: failTick)
            .haptic(.selection, trigger: tab)
            .haptic(.selection, trigger: selection.count)
    }

    private var page: some View {
        VStack(alignment: .leading, spacing: 12) {
            if embedded {
                embeddedHeader
            }
            if selecting {
                selectBar
            } else if !embedded {
                header
            }
            content
        }
        .padding(.horizontal, Metrics.gutter)
        .padding(.top, 8)
        .frame(maxWidth: embedded ? .infinity : Metrics.columnMax)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(CobaltColor.bg)
    }

    @ViewBuilder
    private var titleMenu: some View {
        if emoteSet.can.manageSets {
            Button(Copy.SevenTv.renameSet, systemImage: Symbol.SevenTv.rename) { askRename() }
            Button(Copy.SevenTv.select, systemImage: Symbol.SevenTv.select) { startSelecting() }
        }
        if emoteSet.can.makeLive, emoteSet.info?.live == false {
            Button(Copy.SevenTv.makeLive, systemImage: Symbol.SevenTv.makeLive) { makeLive() }
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            SevenTvChip(title: Copy.SevenTv.inThisSet, selected: tab == .inSet) { tab = .inSet }
            SevenTvChip(title: Copy.SevenTv.addFrom7tv, selected: tab == .add) { tab = .add }
            Spacer(minLength: 8)
            if emoteSet.info?.live == true { SevenTvLivePill() }
            if let info = emoteSet.info {
                Text(Copy.SevenTv.count(info.count, capacity: info.capacity))
                    .font(CobaltType.pill)
                    .foregroundStyle(CobaltColor.caption)
                    .monospacedDigit()
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(CobaltColor.elevated, in: Capsule())
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Copy.SevenTv.tabsA11y)
    }

    /// The Mac's header: the name (and live), the count and channel, rename, make live, "+ add emotes".
    private var embeddedHeader: some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(emoteSet.info?.name ?? Copy.SevenTv.setFallbackTitle)
                        .font(Font.cobalt(20, .semibold, relativeTo: .title2))
                        .foregroundStyle(CobaltColor.text)
                        .lineLimit(1)
                        .accessibilityAddTraits(.isHeader)
                    if emoteSet.info?.live == true { SevenTvLivePill() }
                }
                if let info = emoteSet.info {
                    Text(Copy.SevenTv.emotesLine(info.count, capacity: info.capacity, channel: emoteSet.channel?.name ?? ""))
                        .font(CobaltType.captionSmall)
                        .foregroundStyle(CobaltColor.caption)
                        .monospacedDigit()
                }
            }
            Spacer(minLength: 8)
            if emoteSet.can.makeLive, emoteSet.info?.live == false {
                Button(Copy.SevenTv.makeLive, systemImage: Symbol.SevenTv.makeLive) { makeLive() }
                    .buttonStyle(.cobaltSecondary(fullWidth: false, compact: true))
            }
            if emoteSet.can.manageSets {
                Button(Copy.SevenTv.renameSet, systemImage: Symbol.SevenTv.rename) { askRename() }
                    .buttonStyle(.cobaltSecondary(fullWidth: false, compact: true))
                Button(Copy.SevenTv.addEmotes, systemImage: Symbol.SevenTv.add) {
                    if let addEmotes { addEmotes() } else { tab = .add }
                }
                .buttonStyle(.cobaltPrimary(fullWidth: false, compact: true))
            }
        }
    }

    /// Picking several: how many, "copy to…", "remove N", "done".
    private var selectBar: some View {
        HStack(spacing: 8) {
            Text(Copy.SevenTv.selected(selection.count))
                .font(CobaltType.bodySemibold)
                .foregroundStyle(CobaltColor.text)
                .monospacedDigit()
                .contentTransition(.numericText())
            Spacer(minLength: 6)
            if working { ProgressView().controlSize(.small) }
            Menu {
                if emoteSet.otherSets.isEmpty {
                    Text(Copy.SevenTv.noOtherSets)
                }
                ForEach(emoteSet.otherSets) { target in
                    Button(target.name) { copyPicked(to: target) }
                }
            } label: {
                Label(Copy.SevenTv.copyTo, systemImage: Symbol.SevenTv.copyToSet)
                    .font(CobaltType.buttonSmall)
                    .foregroundStyle(CobaltColor.text)
                    .lineLimit(1)
                    .fixedSize()
                    .padding(.horizontal, 12)
                    .frame(minHeight: 36)
                    .background(CobaltColor.elevated, in: Capsule())
                    .contentShape(Capsule())
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .disabled(selection.isEmpty || working)
            Button(Copy.SevenTv.removeN(selection.count), role: .destructive) { confirmingRemove = true }
                .buttonStyle(.cobaltSecondary(fullWidth: false, compact: true))
                .disabled(selection.isEmpty || working)
            Button(Copy.SevenTv.doneSelecting) { endSelecting() }
                .buttonStyle(.cobaltPrimary(fullWidth: false, compact: true))
        }
        .animation(Motion.copy, value: selection.count)
    }

    @ViewBuilder
    private var content: some View {
        switch emoteSet.state {
        case .idle, .loading:
            VStack(spacing: 10) {
                ProgressView()
                Text(Copy.SevenTv.loadingSet).font(CobaltType.caption).foregroundStyle(CobaltColor.caption)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let error):
            ContentUnavailableView {
                Label(Copy.SevenTv.failedSet, systemImage: Symbol.SevenTv.warn).font(CobaltType.body)
            } description: {
                Text(Copy.SevenTv.message(for: error)).font(CobaltType.caption)
            } actions: {
                Button(Copy.SevenTv.retry, systemImage: Symbol.SevenTv.retry) { Task { await emoteSet.load() } }
                    .buttonStyle(.cobaltSecondary(fullWidth: false))
            }
        case .loaded:
            switch tab {
            case .inSet:
                SevenTvInSetGrid(
                    emoteSet: emoteSet, selecting: selecting, selection: selection,
                    pick: { emote in tap(emote) }, hold: { emote in hold(emote) }, select: { startSelecting() })
            case .add:
                SevenTvAddGrid(model: model, emoteSet: emoteSet)
            }
        }
    }

    // MARK: picking

    private func tap(_ emote: SevenTvSetItem) {
        guard selecting else {
            picked = emote
            return
        }
        if selection.contains(emote.id) { selection.remove(emote.id) } else { selection.insert(emote.id) }
    }

    private func hold(_ emote: SevenTvSetItem) {
        guard emoteSet.can.manageSets else {
            picked = emote
            return
        }
        selecting = true
        selection.insert(emote.id)
    }

    private func startSelecting() {
        guard emoteSet.can.manageSets else { return }
        tab = .inSet
        selecting = true
    }

    private func endSelecting() {
        selecting = false
        selection = []
    }

    private func copyPicked(to target: SevenTvSetRow) {
        let emotes = pickedEmotes
        guard !emotes.isEmpty else { return }
        working = true
        Task {
            let result = await emoteSet.copyMany(emotes, to: target.id)
            working = false
            var line = Copy.SevenTv.copiedMany(result.done, to: target.name)
            if !result.clashes.isEmpty { line += " · " + Copy.SevenTv.alreadyThere(result.clashes.count) }
            if let error = result.lastError, result.done == 0, result.clashes.isEmpty { line = Copy.SevenTv.message(for: error) }
            shell.showStatus(line)
            if result.failed > 0 { failTick += 1 } else { doneTick += 1 }
            endSelecting()
            // one clash at a time: the first opens its sheet, the others are counted on the status line
            if let first = result.clashes.first { clash = first }
        }
    }

    private func removePicked() {
        let emotes = pickedEmotes
        guard !emotes.isEmpty else { return }
        working = true
        Task {
            let result = await emoteSet.removeMany(emotes)
            working = false
            if let error = result.lastError, result.done == 0 {
                shell.showStatus(Copy.SevenTv.message(for: error))
                failTick += 1
            } else {
                shell.showStatus(Copy.SevenTv.removedMany(result.done))
                doneTick += 1
            }
            endSelecting()
        }
    }

    // MARK: the set

    private func askRename() {
        draftName = emoteSet.info?.name ?? ""
        renaming = true
    }

    private func makeLive() {
        let name = emoteSet.info?.name ?? ""
        Task {
            do {
                try await emoteSet.makeLive()
                shell.showStatus(Copy.SevenTv.madeLive(name))
                doneTick += 1
            } catch {
                shell.showStatus(Copy.SevenTv.message(for: error))
                failTick += 1
            }
        }
    }
}

/// The pushed screen's title and title menu; nothing when embedded (the Mac's right column has its own header).
private struct SevenTvSetScreenChrome<TitleMenu: View>: ViewModifier {
    let embedded: Bool
    let title: String
    @ViewBuilder let menu: () -> TitleMenu

    @ViewBuilder
    func body(content: Content) -> some View {
        if embedded {
            content
        } else {
            content
                .navigationTitle(title)
                #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
                #endif
                .toolbarTitleMenu { menu() }
        }
    }
}

/// The title menu's "rename set": an alert with the name.
private struct SevenTvRenameSetAlert: ViewModifier {
    let emoteSet: SevenTvSetModel
    @Binding var isPresented: Bool
    @Binding var draft: String
    let done: () -> Void
    let failed: () -> Void

    @Environment(\.shell) private var shell

    func body(content: Content) -> some View {
        content
            .alert(Copy.SevenTv.renameSet, isPresented: $isPresented) {
                TextField(Copy.SevenTv.setName, text: $draft)
                    .accessibilityLabel(Copy.SevenTv.setName)
                Button(Copy.SevenTv.save) { commit() }
                    .disabled(SevenTvRule.cleanSetName(draft) == nil)
                Button(Copy.SevenTv.cancel, role: .cancel) {}
            } message: {
                Text(Copy.SevenTv.renameSetMessage)
            }
    }

    private func commit() {
        let name = draft
        Task {
            do {
                try await emoteSet.renameSet(name)
                shell.showStatus(Copy.SevenTv.setRenamed(emoteSet.info?.name ?? name))
                done()
            } catch {
                shell.showStatus(Copy.SevenTv.message(for: error))
                failed()
            }
        }
    }
}

// MARK: - in this set

/// The set's emotes, 4 across, with a name filter (the server's `q`, 300 ms after the last key) and the next page when the
/// last tile shows. While picking several, a tap marks a tile.
private struct SevenTvInSetGrid: View {
    @Bindable var emoteSet: SevenTvSetModel
    let selecting: Bool
    let selection: Set<String>
    let pick: (SevenTvSetItem) -> Void
    let hold: (SevenTvSetItem) -> Void
    let select: () -> Void

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 10), count: 4)

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                SevenTvSearchField(placeholder: Copy.SevenTv.filter(emoteSet.info?.count ?? emoteSet.all.count), text: $emoteSet.filter)
                if emoteSet.can.manageSets && !selecting {
                    Button(Copy.SevenTv.select, systemImage: Symbol.SevenTv.select) { select() }
                        .buttonStyle(.cobaltIcon(.small))
                }
            }
            caption
            ScrollView {
                LazyVGrid(columns: columns, spacing: 10) {
                    ForEach(emoteSet.emotes) { emote in
                        SevenTvSetTile(
                            emote: emote, busy: emoteSet.busy.contains(emote.emoteID), selecting: selecting,
                            picked: selection.contains(emote.id), tap: { pick(emote) }, hold: { hold(emote) })
                        .onAppear {
                            if emote.id == emoteSet.emotes.last?.id { Task { await emoteSet.loadMore() } }
                        }
                    }
                }
                if emoteSet.loadingMore {
                    ProgressView().controlSize(.small).padding(.vertical, 8)
                }
            }
            .scrollDismissesKeyboard(.immediately)
        }
        .task(id: emoteSet.filter) {
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            await emoteSet.applyFilter()
        }
        .motion(Motion.rows, value: emoteSet.emotes.map(\.id))
    }

    @ViewBuilder
    private var caption: some View {
        if emoteSet.emotes.isEmpty {
            Text(emoteSet.isFiltered ? Copy.SevenTv.filterMiss : Copy.SevenTv.empty)
                .font(CobaltType.captionSmall)
                .foregroundStyle(CobaltColor.caption)
        } else if !emoteSet.can.manageSets {
            Text(Copy.SevenTv.readOnly)
                .font(CobaltType.captionSmall)
                .foregroundStyle(CobaltColor.caption)
        }
    }
}

/// One emote of the set: its picture, its name here, and "was <7TV name>" when renamed. A tap opens it (or marks it while
/// picking several); a long press starts picking several.
private struct SevenTvSetTile: View {
    let emote: SevenTvSetItem
    let busy: Bool
    let selecting: Bool
    let picked: Bool
    let tap: () -> Void
    let hold: () -> Void

    var body: some View {
        VStack(spacing: 4) {
            EmotePicture(url: emote.previewURL, animated: emote.animated, side: 52)
                .padding(6)
                .frame(maxWidth: .infinity)
                .background(CobaltColor.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(picked ? CobaltColor.focus : Color.clear, lineWidth: 2)
                }
                .overlay(alignment: .topTrailing) {
                    if selecting {
                        Image(systemName: picked ? Symbol.SevenTv.picked : Symbol.SevenTv.select)
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(picked ? CobaltColor.focus : CobaltColor.caption)
                            .padding(4)
                            .transition(.scale.combined(with: .opacity))
                            .accessibilityHidden(true)
                    }
                }
                .opacity(busy ? 0.5 : 1)
                .overlay { if busy { ProgressView().controlSize(.small) } }
            Text(emote.alias)
                .font(Font.cobalt(11.5, .regular, relativeTo: .caption))
                .foregroundStyle(CobaltColor.text)
                .lineLimit(1)
            if emote.renamed {
                Text(Copy.SevenTv.was(emote.name))
                    .font(CobaltType.badge)
                    .foregroundStyle(CobaltColor.caption)
                    .lineLimit(1)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { if !busy { tap() } }
        .onLongPressGesture(minimumDuration: 0.4) { if !busy { hold() } }
        .animation(Motion.press, value: picked)
        .animation(Motion.press, value: selecting)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Copy.SevenTv.tileA11y(emote.alias, name: emote.name, renamed: emote.renamed))
        .accessibilityAddTraits(picked ? [.isButton, .isSelected] : .isButton)
        .accessibilityHint(selecting ? "" : Copy.SevenTv.selectHintA11y)
        .accessibilityAction(.default) { if !busy { tap() } }
        .accessibilityAction(named: Copy.SevenTv.select) { if !busy { hold() } }
    }
}

/// A search field on the elevated grey, like the emote search's.
struct SevenTvSearchField: View {
    let placeholder: String
    @Binding var text: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: Symbol.SevenTv.filter)
                .foregroundStyle(CobaltColor.caption)
                .accessibilityHidden(true)
            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .font(Font.cobalt(15))
                #if os(iOS)
                .textInputAutocapitalization(.never)
                .submitLabel(.search)
                #endif
                .autocorrectionDisabled()
        }
        .padding(.horizontal, 12)
        .frame(minHeight: 40)
        .background(CobaltColor.elevated, in: RoundedRectangle(cornerRadius: Metrics.radius, style: .continuous))
    }
}
