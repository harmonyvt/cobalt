import CobaltKit
import SwiftUI

// A 7TV set (APP-API-CONTRACT 57.7, mockup screens 2 and 3), pushed from the studio tab's 7TV card. Two chips: "in this set"
// (a 4-column grid with a name filter and paging; a tap opens the emote sheet) and "add from 7tv" (section 20's search and
// sorts; + adds under the emote's own name, a long press or right click adds with another name, ✓ marks what is already in
// the set). Rename the set and make it live from the title menu. Every edit changes the grid once 7TV took it; a refusal says
// 7TV's words on the status line.

struct SevenTvSetScreen: View {
    let model: AppModel
    let route: SevenTvSetRoute

    @State private var emoteSet: SevenTvSetModel
    @State private var tab: Tab = .inSet
    @State private var picked: SevenTvSetItem?
    @State private var renaming = false
    @State private var draftName = ""
    @State private var doneTick = 0
    @State private var failTick = 0
    @Environment(\.shell) private var shell

    enum Tab: Hashable {
        case inSet, add
    }

    init(model: AppModel, route: SevenTvSetRoute) {
        self.model = model
        self.route = route
        _emoteSet = State(initialValue: model.sevenTv.openSet(route.setID, channelID: route.channelID))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            content
        }
        .padding(.horizontal, Metrics.gutter)
        .padding(.top, 8)
        .frame(maxWidth: Metrics.columnMax)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(CobaltColor.bg)
        .navigationTitle(emoteSet.info?.name ?? Copy.SevenTv.setFallbackTitle)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbarTitleMenu { titleMenu }
        .task { await emoteSet.load() }
        .sheet(item: $picked) { emote in
            SevenTvEmoteSheet(emoteSet: emoteSet, emote: emote)
        }
        .modifier(SevenTvRenameSetAlert(emoteSet: emoteSet, isPresented: $renaming, draft: $draftName, done: { doneTick += 1 }, failed: { failTick += 1 }))
        .haptic(.success, trigger: doneTick)
        .haptic(.error, trigger: failTick)
        .haptic(.selection, trigger: tab)
    }

    @ViewBuilder
    private var titleMenu: some View {
        if emoteSet.can.manageSets {
            Button(Copy.SevenTv.renameSet, systemImage: Symbol.SevenTv.rename) {
                draftName = emoteSet.info?.name ?? ""
                renaming = true
            }
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
                SevenTvInSetGrid(emoteSet: emoteSet) { picked = $0 }
            case .add:
                SevenTvAddGrid(model: model, emoteSet: emoteSet)
            }
        }
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
/// last tile shows.
private struct SevenTvInSetGrid: View {
    @Bindable var emoteSet: SevenTvSetModel
    let pick: (SevenTvSetItem) -> Void

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 10), count: 4)

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SevenTvSearchField(placeholder: Copy.SevenTv.filter(emoteSet.info?.count ?? emoteSet.all.count), text: $emoteSet.filter)
            caption
            ScrollView {
                LazyVGrid(columns: columns, spacing: 10) {
                    ForEach(emoteSet.emotes) { emote in
                        SevenTvSetTile(emote: emote, busy: emoteSet.busy.contains(emote.emoteID)) { pick(emote) }
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

/// One emote of the set: its picture, its name here, and "was <7TV name>" when renamed.
private struct SevenTvSetTile: View {
    let emote: SevenTvSetItem
    let busy: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                EmotePicture(url: emote.previewURL, animated: emote.animated, side: 52)
                    .padding(6)
                    .frame(maxWidth: .infinity)
                    .background(CobaltColor.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
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
        }
        .buttonStyle(.plain)
        .disabled(busy)
        .accessibilityLabel(Copy.SevenTv.tileA11y(emote.alias, name: emote.name, renamed: emote.renamed))
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
