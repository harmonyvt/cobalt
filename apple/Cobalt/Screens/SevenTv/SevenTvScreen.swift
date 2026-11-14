import CobaltKit
import Observation
import SwiftUI

// The 7tv tab (APP-API-CONTRACT 57.7, 57.9; mockup `7tv-tab/`), right after the studio and shown on the same rule. Everything
// 7TV in one place instead of a card inside the studio:
//
// - iPhone and iPad: the account (avatar, name, "linked · signs out in N days", ⋯ for link again and unlink), channel chips,
//   then three segments: **sets** (the live set with a peek at its emotes, the other sets with "make live", "new set"; a set
//   opens the set screen), **search** (7TV's search adding to the open set, picked under "adding to") and **upload** (the
//   library's webps and gifs with an "on 7tv" mark, then "your uploads" with their processing state).
// - The Mac (and a wide iPad window): the app's sidebar, then a middle column (the account, chips, the sets, "search 7tv" and
//   "upload from library"), then the open set's grid (`SevenTvSetScreen` embedded), the search or the upload grid.
// - Not linked: "link 7tv", and the plain 7tv search still browses and saves emotes into the library as before.
// - 7TV signed the token out, or the server has no routes: the card's own lines.
//
// State: `model.sevenTv`; the link sheet, unlink, new set and make live go through the card's `SevenTvController`, whose set
// models the tab shares, so an edit anywhere shows everywhere.

/// The tab's own state: the segment, the Mac's right column, the set adding goes into, the upload sheet.
@MainActor @Observable
final class SevenTvTabController {
    enum Segment: Hashable, CaseIterable {
        case sets, search, upload
    }

    /// What the Mac's right column shows.
    enum Pane: Hashable {
        case set(String)
        case search
        case upload
    }

    /// A library picture on its way to the upload sheet.
    struct UploadItem: Identifiable {
        let upload: SevenTvUploadModel
        let file: LibraryFile
        var id: String { file.id }
    }

    let card: SevenTvController
    var segment: Segment = .sets
    var pane: Pane?
    /// The set "search" adds to; nil: the channel's live set (else its first).
    var targetSetID: String?
    var uploading: UploadItem?

    init(model: AppModel) {
        card = SevenTvController(model: model)
    }

    var model: AppModel { card.model }
    var store: SevenTvStore { card.store }
    var channel: SevenTvChannelInfo? { store.selectedChannel }

    /// The picked channel's sets, live first.
    var sets: [SevenTvSetRow] { channel.map { store.sets(of: $0.id) } ?? [] }
    var liveSet: SevenTvSetRow? { sets.first { $0.live } }

    /// The set "search" adds to.
    var targetSet: SevenTvSetRow? {
        if let id = targetSetID, let row = sets.first(where: { $0.id == id }) { return row }
        return liveSet ?? sets.first
    }

    /// The Mac's open set: the picked one, else the live one.
    var paneSetID: String? {
        switch pane {
        case .search?, .upload?:
            return nil
        case .set(let id)?:
            if sets.contains(where: { $0.id == id }) { return id }
            return (liveSet ?? sets.first)?.id
        case nil:
            return (liveSet ?? sets.first)?.id
        }
    }

    func setModel(_ row: SevenTvSetRow) -> SevenTvSetModel? {
        guard let channel else { return nil }
        return card.setModel(row.id, channelID: channel.id)
    }

    /// Pushes the set screen (iPhone and iPad).
    func open(_ row: SevenTvSetRow) {
        guard let channel else { return }
        card.openSet = SevenTvSetRoute(setID: row.id, channelID: channel.id)
    }

    /// "add emotes" of a set: search, adding to it.
    func addEmotes(to setID: String) {
        targetSetID = setID
        segment = .search
        pane = .search
    }

    func startUpload(_ file: LibraryFile, title: String?) {
        uploading = UploadItem(upload: store.uploader(file: file, title: title), file: file)
    }
}

struct SevenTvScreen: View {
    let model: AppModel
    let tier: Tier

    @State private var tab: SevenTvTabController
    @Environment(\.shell) private var shell

    /// `segment`: the part it opens on (previews).
    init(model: AppModel, tier: Tier, segment: SevenTvTabController.Segment = .sets) {
        self.model = model
        self.tier = tier
        let controller = SevenTvTabController(model: model)
        controller.segment = segment
        _tab = State(initialValue: controller)
    }

    private var store: SevenTvStore { model.sevenTv }

    /// Three columns on the Mac and in a wide iPad window.
    private var twoPane: Bool {
        #if os(macOS)
        return true
        #else
        return tier == .wide
        #endif
    }

    private var uploadShown: Binding<SevenTvTabController.UploadItem?> {
        Binding(get: { tab.uploading }, set: { tab.uploading = $0 })
    }

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(CobaltColor.bg)
            .navigationTitle(Copy.SevenTv.title)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .task { await store.load() }
            .task(id: store.linkOutcome?.id) { tab.card.sayOutcome(shell: shell) }
            .sevenTvPresentations(tab.card)
            .sheet(item: uploadShown) { item in
                SevenTvUploadSheet(upload: item.upload, picture: SevenTvUploadIcon.picture(model: model, file: item.file))
            }
    }

    @ViewBuilder
    private var content: some View {
        if let status = store.status, status.linked, !status.needsRelink {
            if twoPane {
                SevenTvWideLayout(tab: tab)
            } else {
                SevenTvPhoneLayout(tab: tab)
            }
        } else if let status = store.status, !status.linked {
            SevenTvNotLinkedPage(tab: tab)
        } else {
            // loading, refused, no routes on this server, or signed out by 7TV: the card's own lines
            ScrollView {
                StageCard(title: Copy.SevenTv.title) {
                    if store.status == nil && store.state == .failed(.off) {
                        Text(Copy.SevenTv.message(for: SevenTvError.off))
                            .font(CobaltType.caption)
                            .foregroundStyle(CobaltColor.caption)
                    } else {
                        SevenTvCardContent(controller: tab.card)
                    }
                }
                .padding(Metrics.gutter)
                .frame(maxWidth: Metrics.columnMax)
                .frame(maxWidth: .infinity)
            }
        }
    }
}

// MARK: - the account

/// The avatar, the name, "linked · signs out in N days", and ⋯ (link again, unlink).
struct SevenTvTabAccountRow: View {
    let tab: SevenTvTabController

    private var store: SevenTvStore { tab.store }

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            SevenTvAvatar(url: store.account?.avatarURL, size: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text(store.account?.name ?? Copy.SevenTv.title)
                    .font(CobaltType.bodyMedium)
                    .foregroundStyle(CobaltColor.text)
                    .lineLimit(1)
                Text(Copy.SevenTv.signsOutIn(days: store.account?.daysLeft(now: store.now())))
                    .font(CobaltType.captionSmall)
                    .foregroundStyle(store.account?.expiresSoon(now: store.now()) == true ? CobaltColor.collection : CobaltColor.caption)
                    .lineLimit(1)
            }
            .accessibilityElement(children: .combine)
            Spacer(minLength: 8)
            Menu {
                Button(Copy.SevenTv.linkAgain, systemImage: Symbol.SevenTv.link) { tab.card.linkShown = true }
                Button(Copy.SevenTv.unlink, systemImage: Symbol.SevenTv.unlink, role: .destructive) {
                    tab.card.confirmingUnlink = true
                }
            } label: {
                Label(Copy.SevenTv.accountMenuA11y, systemImage: Symbol.SevenTv.more)
                    .labelStyle(.iconOnly)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(CobaltColor.text)
                    .frame(width: Metrics.hit, height: Metrics.hit)
                    .contentShape(Rectangle())
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .disabled(tab.card.isBusy("unlink"))
        }
    }
}

// MARK: - iPhone and iPad

private struct SevenTvPhoneLayout: View {
    @Bindable var tab: SevenTvTabController

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 12) {
                SevenTvTabAccountRow(tab: tab)
                if tab.store.channels.count > 1 {
                    SevenTvChannelChips(store: tab.store)
                }
                Picker(Copy.SevenTv.segmentsA11y, selection: $tab.segment) {
                    Text(Copy.SevenTv.segmentSets).tag(SevenTvTabController.Segment.sets)
                    Text(Copy.SevenTv.segmentSearch).tag(SevenTvTabController.Segment.search)
                    Text(Copy.SevenTv.segmentUpload).tag(SevenTvTabController.Segment.upload)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            .padding(.horizontal, Metrics.gutter)
            .padding(.top, 8)
            Group {
                switch tab.segment {
                case .sets:
                    SevenTvSetsPage(tab: tab)
                case .search:
                    SevenTvSearchPage(tab: tab)
                        .padding(.horizontal, Metrics.gutter)
                case .upload:
                    SevenTvUploadPage(tab: tab)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .frame(maxWidth: Metrics.columnMax)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .haptic(.selection, trigger: tab.segment)
    }
}

/// "sets": the live set with a peek at its emotes, the other sets, "new set".
private struct SevenTvSetsPage: View {
    let tab: SevenTvTabController

    @Environment(\.shell) private var shell

    private var store: SevenTvStore { tab.store }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if let channel = tab.channel {
                    let sets = store.sets(of: channel.id)
                    switch store.setsState(of: channel.id) {
                    case .failed(let error) where sets.isEmpty:
                        Text(Copy.SevenTv.message(for: error))
                            .font(CobaltType.captionSmall)
                            .foregroundStyle(CobaltColor.errorText)
                    case .loading where sets.isEmpty, .idle where sets.isEmpty:
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text(Copy.SevenTv.loadingSets).font(CobaltType.captionSmall).foregroundStyle(CobaltColor.caption)
                        }
                    default:
                        if let live = tab.liveSet, let emoteSet = tab.setModel(live) {
                            SevenTvLiveSetCard(row: live, emoteSet: emoteSet) { tab.open(live) }
                        } else {
                            Text(sets.isEmpty ? Copy.SevenTv.noSets : Copy.SevenTv.noLiveSet)
                                .font(CobaltType.captionSmall)
                                .foregroundStyle(CobaltColor.caption)
                        }
                        let others = sets.filter { !$0.live }
                        if !others.isEmpty {
                            Text(Copy.SevenTv.otherSets)
                                .font(CobaltType.captionSmall)
                                .foregroundStyle(CobaltColor.caption)
                                .accessibilityAddTraits(.isHeader)
                            VStack(alignment: .leading, spacing: 6) {
                                ForEach(others) { row in
                                    SevenTvSetLine(controller: tab.card, channel: channel, row: row)
                                }
                            }
                            .padding(12)
                            .background(CobaltColor.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                        }
                    }
                    if channel.can.createSets {
                        Button(Copy.SevenTv.newSet, systemImage: Symbol.SevenTv.newSet) { tab.card.askNewSet(channelID: channel.id) }
                            .buttonStyle(.cobaltSecondary(compact: true))
                            .disabled(tab.card.isBusy("new"))
                    }
                }
            }
            .padding(.horizontal, Metrics.gutter)
            .padding(.bottom, 16)
            .motion(Motion.rows, value: tab.sets.map(\.id))
        }
        .refreshable { await store.load() }
    }
}

/// "live now": the live set's name, how full it is, and its first eight emotes; a tap opens the set.
private struct SevenTvLiveSetCard: View {
    let row: SevenTvSetRow
    let emoteSet: SevenTvSetModel
    let open: () -> Void

    private var columns: [GridItem] { Array(repeating: GridItem(.flexible(), spacing: 8), count: 4) }

    var body: some View {
        Button(action: open) {
            VStack(alignment: .leading, spacing: 10) {
                Text(Copy.SevenTv.liveNow)
                    .font(CobaltType.captionSmall)
                    .foregroundStyle(CobaltColor.caption)
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(row.name)
                        .font(Font.cobalt(18, .semibold, relativeTo: .title3))
                        .foregroundStyle(CobaltColor.text)
                        .lineLimit(1)
                    SevenTvLivePill()
                    Spacer(minLength: 6)
                    Image(systemName: Symbol.SevenTv.open)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(CobaltColor.caption)
                }
                Text(Copy.SevenTv.emotesOf(row.count, capacity: row.capacity))
                    .font(CobaltType.captionSmall)
                    .foregroundStyle(CobaltColor.caption)
                    .monospacedDigit()
                SevenTvFillBar(fill: row.fill, live: true, width: 160)
                LazyVGrid(columns: columns, spacing: 8) {
                    ForEach(emoteSet.all.prefix(8)) { emote in
                        VStack(spacing: 3) {
                            EmotePicture(url: emote.previewURL, animated: emote.animated, side: 40)
                                .padding(4)
                                .frame(maxWidth: .infinity)
                                .background(CobaltColor.elevated, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                            Text(emote.alias)
                                .font(CobaltType.badge)
                                .foregroundStyle(CobaltColor.caption)
                                .lineLimit(1)
                        }
                    }
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(CobaltColor.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Copy.SevenTv.setA11y(row.name, count: row.count, capacity: row.capacity, live: true))
        .accessibilityHint(Copy.SevenTv.seeSetA11y(row.name))
        .accessibilityAddTraits(.isButton)
        .task(id: row.id) { if emoteSet.state != .loaded { await emoteSet.load() } }
    }
}

/// "search": "adding to <set>" (a menu of the channel's sets), then 7TV's search adding to it.
private struct SevenTvSearchPage: View {
    let tab: SevenTvTabController

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SevenTvTargetPicker(tab: tab)
            if let target = tab.targetSet, let emoteSet = tab.setModel(target) {
                SevenTvAddGrid(model: tab.model, emoteSet: emoteSet)
                    .id(target.id)
            } else {
                Text(Copy.SevenTv.noEditableSet)
                    .font(CobaltType.captionSmall)
                    .foregroundStyle(CobaltColor.caption)
                Spacer(minLength: 0)
            }
        }
    }
}

/// "adding to main ▾".
private struct SevenTvTargetPicker: View {
    let tab: SevenTvTabController

    var body: some View {
        HStack(spacing: 8) {
            Text(Copy.SevenTv.addingTo)
                .font(CobaltType.captionSmall)
                .foregroundStyle(CobaltColor.caption)
            Menu {
                ForEach(tab.sets) { row in
                    Button { tab.targetSetID = row.id } label: {
                        if row.id == tab.targetSet?.id {
                            Label(Copy.SevenTv.setChoice(row.name, live: row.live), systemImage: Symbol.checkmark)
                        } else {
                            Text(Copy.SevenTv.setChoice(row.name, live: row.live))
                        }
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Text(tab.targetSet?.name ?? Copy.SevenTv.pickSet)
                        .font(CobaltType.bodySemibold)
                        .foregroundStyle(CobaltColor.text)
                        .lineLimit(1)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(CobaltColor.caption)
                }
                .padding(.horizontal, 10)
                .frame(minHeight: 32)
                .background(CobaltColor.elevated, in: Capsule())
                .contentShape(Capsule())
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .disabled(tab.sets.isEmpty)
            if tab.targetSet?.live == true { SevenTvLivePill() }
            Spacer(minLength: 0)
        }
    }
}

// MARK: - not linked

/// "link 7tv", then the plain 7tv search (browse and save into the library, as the 7tv circle does).
private struct SevenTvNotLinkedPage: View {
    let tab: SevenTvTabController

    private var store: SevenTvStore { tab.store }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            StageCard(title: Copy.SevenTv.title) {
                Text(Copy.SevenTv.tabNotLinkedBody)
                    .font(CobaltType.caption)
                    .foregroundStyle(CobaltColor.caption)
                    .fixedSize(horizontal: false, vertical: true)
                Button(store.linking ? Copy.SevenTv.linking : Copy.SevenTv.link, systemImage: Symbol.SevenTv.link) {
                    tab.card.linkShown = true
                }
                .buttonStyle(.cobaltPrimary(compact: true))
                .disabled(store.linking)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(Copy.SevenTv.withoutLinking)
                    .font(CobaltType.captionSmall)
                    .foregroundStyle(CobaltColor.caption)
                    .accessibilityAddTraits(.isHeader)
                Text(Copy.SevenTv.browseBody)
                    .font(CobaltType.caption)
                    .foregroundStyle(CobaltColor.text)
            }
            EmoteSearchCard(model: tab.model, maxGridHeight: .infinity)
                .padding(14)
                .frame(maxHeight: .infinity, alignment: .top)
                .background(CobaltColor.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .padding(.horizontal, Metrics.gutter)
        .padding(.top, 8)
        .padding(.bottom, 12)
        .frame(maxWidth: Metrics.columnMax)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

// MARK: - the Mac and a wide iPad window

/// The middle column (the account, chips, the sets, search and upload) and the right one.
private struct SevenTvWideLayout: View {
    let tab: SevenTvTabController

    var body: some View {
        HStack(spacing: 0) {
            SevenTvMiddleColumn(tab: tab)
                .frame(width: 280)
                .background(CobaltColor.surface.opacity(0.5))
            Divider()
            SevenTvRightColumn(tab: tab)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

private struct SevenTvMiddleColumn: View {
    let tab: SevenTvTabController

    private var store: SevenTvStore { tab.store }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                SevenTvTabAccountRow(tab: tab)
                if store.channels.count > 1 {
                    SevenTvChannelChips(store: store)
                }
                sectionTitle(Copy.SevenTv.allSets)
                VStack(alignment: .leading, spacing: 2) {
                    if let channel = tab.channel, case .loading = store.setsState(of: channel.id), tab.sets.isEmpty {
                        ProgressView().controlSize(.small).padding(8)
                    }
                    ForEach(tab.sets) { row in
                        setRow(row)
                    }
                    if let channel = tab.channel, channel.can.createSets {
                        Button { tab.card.askNewSet(channelID: channel.id) } label: {
                            Label(Copy.SevenTv.newSet, systemImage: Symbol.SevenTv.newSet)
                                .font(CobaltType.caption)
                                .foregroundStyle(CobaltColor.caption)
                                .padding(.horizontal, 10)
                                .frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(tab.card.isBusy("new"))
                    }
                }
                sectionTitle(Copy.SevenTv.more)
                VStack(alignment: .leading, spacing: 2) {
                    paneButton(Copy.SevenTv.searchSevenTv, symbol: Symbol.SevenTv.search, pane: .search)
                    paneButton(Copy.SevenTv.uploadFromLibrary, symbol: Symbol.SevenTv.library, pane: .upload)
                }
            }
            .padding(14)
        }
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text)
            .font(CobaltType.captionSmall)
            .foregroundStyle(CobaltColor.caption)
            .padding(.top, 4)
            .accessibilityAddTraits(.isHeader)
    }

    private func setRow(_ row: SevenTvSetRow) -> some View {
        let picked = tab.paneSetID == row.id
        return Button { tab.pane = .set(row.id) } label: {
            HStack(spacing: 8) {
                Text(row.name)
                    .font(Font.cobalt(13, picked ? .semibold : .regular, relativeTo: .body))
                    .foregroundStyle(CobaltColor.text)
                    .lineLimit(1)
                if row.live { SevenTvLivePill() }
                Spacer(minLength: 4)
                Text("\(row.count)")
                    .font(CobaltType.badge)
                    .foregroundStyle(CobaltColor.caption)
                    .monospacedDigit()
            }
            .padding(.horizontal, 10)
            .frame(minHeight: 32)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(picked ? CobaltColor.elevated : Color.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Copy.SevenTv.setA11y(row.name, count: row.count, capacity: row.capacity, live: row.live))
        .accessibilityAddTraits(picked ? [.isButton, .isSelected] : .isButton)
        .contextMenu {
            if let channel = tab.channel, channel.can.makeLive, !row.live {
                Button(Copy.SevenTv.makeLive, systemImage: Symbol.SevenTv.makeLive) {
                    tab.card.makeLive(row, channelID: channel.id, shell: shellActions)
                }
            }
            if tab.channel?.can.manageSets == true {
                Button(Copy.SevenTv.addEmotes, systemImage: Symbol.SevenTv.add) { tab.addEmotes(to: row.id) }
            }
        }
    }

    @Environment(\.shell) private var shellActions

    private func paneButton(_ title: String, symbol: String, pane: SevenTvTabController.Pane) -> some View {
        let picked = tab.pane == pane
        return Button { tab.pane = pane } label: {
            Label(title, systemImage: symbol)
                .font(Font.cobalt(13, picked ? .semibold : .regular, relativeTo: .body))
                .foregroundStyle(CobaltColor.text)
                .padding(.horizontal, 10)
                .frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(picked ? CobaltColor.elevated : Color.clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(picked ? [.isButton, .isSelected] : .isButton)
    }
}

/// The open set's grid (the set screen, embedded), the search, or the upload grid.
private struct SevenTvRightColumn: View {
    let tab: SevenTvTabController

    var body: some View {
        switch tab.pane {
        case .search?:
            SevenTvSearchPage(tab: tab)
                .padding(.horizontal, Metrics.gutter)
                .padding(.top, 12)
        case .upload?:
            SevenTvUploadPage(tab: tab)
                .padding(.top, 12)
        default:
            if let channel = tab.channel, let id = tab.paneSetID {
                SevenTvSetScreen(
                    model: tab.model, route: SevenTvSetRoute(setID: id, channelID: channel.id),
                    emoteSet: tab.card.setModel(id, channelID: channel.id), embedded: true,
                    addEmotes: { tab.addEmotes(to: id) })
                    .id(id)
                    .padding(.top, 12)
            } else {
                ContentUnavailableView {
                    Label(Copy.SevenTv.pickASet, systemImage: Symbol.SevenTv.tab).font(CobaltType.body)
                }
            }
        }
    }
}
