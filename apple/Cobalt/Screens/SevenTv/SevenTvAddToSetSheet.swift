import CobaltKit
import SwiftUI

// "add to a set…" (APP-API-CONTRACT 57.14): an emote the account owns, put into any set of any channel it may edit. Opened from
// a row of "your emotes on 7tv" (the row's button, its context menu and its swipe) and from the upload sheet once the emote is
// uploaded (7TV can take it into a set while it is still processing). The channels the account can edit are chips (a channel
// without the right to change sets is not there; a private emote is offered the account's own channel alone), then that
// channel's sets: name, live pill, count / capacity, a thin fill bar. A tap adds it under its own name, the same call as
// the search's add (`SevenTvAddToSetModel.add(to:)` → `SevenTvSetModel.addChecking`). A full set is dimmed with "full", a
// set that has it says "in this set". A name another emote already holds opens the name clash sheet (another name, rename
// the one there, or replace it). It stays open after an add, so it can go into more sets: a line under the sets says
// what came of the last one ("added to main on capybaraharmony").
//
// Two homes, one set of parts:
// - `SevenTvAddToSetPage`: the screen pane's page for `PaneItem.emoteAddToSet(id)` (the id of the emote). It finds the emote
//   (one the account owns, one the tab or the chat remembered with `SevenTvEmoteHits.remember`, or one of the open set) and
//   builds the picker itself, with the tab's shared set models when the tab gave the pane its `SevenTvController`.
// - `SevenTvAddToSetSheet`: the same thing as a plain sheet, for a picker that is already made (the upload sheet's result,
//   and the Twitch tab until it opens the pane's page too).

// MARK: - the flow

/// What the picker's parts share: the name clash sheet, the line that says what the last add came to, the haptics.
@MainActor @Observable
final class SevenTvAddToSetFlow {
    /// What the last add came to, said under the sets.
    struct Line: Equatable {
        var text: String
        var good: Bool
    }

    let picker: SevenTvAddToSetModel
    var clash: SevenTvNameClash?
    /// The set the open clash sheet is about.
    private(set) var clashRow: SevenTvSetRow?
    var line: Line?
    private(set) var addedTick = 0
    private(set) var failTick = 0

    init(picker: SevenTvAddToSetModel) {
        self.picker = picker
    }

    func add(to row: SevenTvSetRow, shell: ShellActions) {
        Task {
            let outcome = await picker.add(to: row)
            switch outcome {
            case .added(_, let setName, let channelName):
                say(Copy.SevenTv.addedToSetOn(set: setName, channel: channelName), good: true, shell: shell)
            case .alreadyIn(let setName):
                say(Copy.SevenTv.alreadyInSet(setName), good: true, shell: shell)
            case .clash(let found):
                line = nil
                clashRow = row
                clash = found
            case .failed(let error):
                say(Copy.SevenTv.message(for: error), good: false, shell: shell)
            }
        }
    }

    private func say(_ text: String, good: Bool, shell: ShellActions) {
        line = Line(text: text, good: good)
        shell.showStatus(text)
        if good { addedTick += 1 } else { failTick += 1 }
    }

    /// The clash sheet closed: when the emote went in meanwhile (another name, or replacing), say so.
    func clashClosed() {
        defer { clashRow = nil }
        guard let row = clashRow, let channel = picker.channel, picker.contains(row) else { return }
        line = Line(text: Copy.SevenTv.addedToSetOn(set: row.name, channel: channel.name), good: true)
        addedTick += 1
    }
}

/// Reads the sets once, shows the clash sheet, animates the line and plays the haptics.
private struct SevenTvAddToSetPresentations: ViewModifier {
    @Bindable var flow: SevenTvAddToSetFlow

    func body(content: Content) -> some View {
        content
            .animation(Motion.rows, value: flow.line)
            .haptic(.success, trigger: flow.addedTick)
            .haptic(.error, trigger: flow.failTick)
            .task { await flow.picker.prepare() }
            .sheet(item: $flow.clash, onDismiss: { flow.clashClosed() }) { found in
                if let row = flow.picker.sets.first(where: { $0.id == found.setID }), let target = flow.picker.setModel(for: row) {
                    SevenTvClashSheet(emoteSet: target, clash: found)
                }
            }
    }
}

// MARK: - the parts

/// The emote, with what it is about to be added to.
private struct SevenTvAddToSetEmoteCard: View {
    let picker: SevenTvAddToSetModel

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            EmotePicture(url: picker.pending ? nil : picker.emote.previewURL, animated: false, side: 48)
                .padding(4)
                .background(CobaltColor.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                Text(picker.emote.name)
                    .font(Font.cobalt(16, .semibold, relativeTo: .headline))
                    .foregroundStyle(CobaltColor.text)
                    .lineLimit(1)
                SevenTvAddToSetNotes(picker: picker)
            }
            .accessibilityElement(children: .combine)
            Spacer(minLength: 0)
        }
    }
}

/// "for <name>", and the pending / private notes.
private struct SevenTvAddToSetNotes: View {
    let picker: SevenTvAddToSetModel

    var body: some View {
        Text(Copy.SevenTv.addToSetFor(picker.emote.name))
            .font(CobaltType.captionSmall)
            .foregroundStyle(CobaltColor.caption)
            .fixedSize(horizontal: false, vertical: true)
        if picker.pending {
            Text(Copy.SevenTv.addToSetPending)
                .font(CobaltType.captionSmall)
                .foregroundStyle(CobaltColor.collection)
                .fixedSize(horizontal: false, vertical: true)
        } else if picker.isPrivate {
            Text(Copy.SevenTv.addToSetPrivate)
                .font(CobaltType.captionSmall)
                .foregroundStyle(CobaltColor.caption)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct SevenTvAddToSetChannels: View {
    let picker: SevenTvAddToSetModel

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(picker.channels) { channel in
                    SevenTvChip(title: channel.name, selected: channel.id == picker.channelID) {
                        Task { await picker.pickChannel(channel.id) }
                    }
                }
            }
        }
        .scrollBounceBehavior(.basedOnSize)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(Copy.SevenTv.channelsA11y))
    }
}

private struct SevenTvAddToSetLineView: View {
    let line: SevenTvAddToSetFlow.Line?

    var body: some View {
        if let line {
            Text(line.text)
                .font(CobaltType.caption)
                .foregroundStyle(line.good ? CobaltColor.success : CobaltColor.errorText)
                .fixedSize(horizontal: false, vertical: true)
                .transition(.opacity)
                .accessibilityAddTraits(.updatesFrequently)
        }
    }
}

/// The picked channel's sets: loading, failed, empty, or the rows.
private struct SevenTvAddToSetSets: View {
    let flow: SevenTvAddToSetFlow

    @Environment(\.shell) private var shell

    private var picker: SevenTvAddToSetModel { flow.picker }

    var body: some View {
        let sets = picker.sets
        switch picker.setsState {
        case .failed(let error) where sets.isEmpty:
            VStack(alignment: .leading, spacing: 8) {
                Text(Copy.SevenTv.message(for: error))
                    .font(CobaltType.captionSmall)
                    .foregroundStyle(CobaltColor.errorText)
                Button(Copy.SevenTv.retry, systemImage: Symbol.SevenTv.retry) { Task { await picker.reloadSets() } }
                    .buttonStyle(.cobaltSecondary(fullWidth: false, compact: true))
            }
        case .loading where sets.isEmpty, .idle where sets.isEmpty:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(Copy.SevenTv.loadingSets).font(CobaltType.captionSmall).foregroundStyle(CobaltColor.caption)
            }
        default:
            if sets.isEmpty {
                Text(Copy.SevenTv.addToSetNoSets)
                    .font(CobaltType.captionSmall)
                    .foregroundStyle(CobaltColor.caption)
            } else {
                VStack(spacing: 6) {
                    ForEach(sets) { row in
                        SevenTvAddToSetRow(
                            row: row, inSet: picker.contains(row), full: picker.isFull(row), busy: picker.isBusy(row)
                        ) {
                            flow.add(to: row, shell: shell)
                        }
                    }
                }
                Text(Copy.SevenTv.addToSetStays)
                    .font(CobaltType.badge)
                    .foregroundStyle(CobaltColor.caption)
            }
        }
    }
}

// MARK: - the sheet

struct SevenTvAddToSetSheet: View {
    @State private var flow: SevenTvAddToSetFlow

    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var typeSize

    init(picker: SevenTvAddToSetModel) {
        _flow = State(initialValue: SevenTvAddToSetFlow(picker: picker))
    }

    private var picker: SevenTvAddToSetModel { flow.picker }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header
                SevenTvAddToSetEmoteCard(picker: picker)
                if picker.channels.isEmpty {
                    Text(Copy.SevenTv.noEditableChannels)
                        .font(CobaltType.caption)
                        .foregroundStyle(CobaltColor.caption)
                } else {
                    SevenTvAddToSetChannels(picker: picker)
                    SevenTvAddToSetSets(flow: flow)
                }
                SevenTvAddToSetLineView(line: flow.line)
                #if os(macOS)
                // the Mac sheet has no drag to dismiss; on iPhone the close button and the drag do it, and a done row
                // under the medium detent only showed half-cut
                HStack {
                    Spacer(minLength: 0)
                    Button(Copy.SevenTv.done, systemImage: Symbol.checkmark) { dismiss() }
                        .buttonStyle(.cobaltPrimary(fullWidth: false, compact: true))
                }
                #endif
            }
            .padding(.horizontal, 16)
            .padding(.top, 20)
            .padding(.bottom, 16)
        }
        #if os(macOS)
        .frame(width: 460, height: 600)
        #else
        .presentationDetents(typeSize.isAccessibilitySize ? [.large] : [.medium, .large])
        .presentationDragIndicator(.visible)
        #endif
        .background(CobaltColor.bg)
        .modifier(SevenTvAddToSetPresentations(flow: flow))
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 10) {
            Text(Copy.SevenTv.addToSetTitle)
                .font(Font.cobalt(18, .semibold, relativeTo: .title3))
                .foregroundStyle(CobaltColor.text)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 0)
            CloseButton(cancels: true) { dismiss() }
        }
    }
}

// MARK: - the pane's page

/// `PaneItem.emoteAddToSet(id)`: finds the emote, makes the picker, then shows `SevenTvAddToSetPicked`.
struct SevenTvAddToSetPage: View {
    let model: AppModel
    let id: String

    @Environment(Pane.self) private var pane: Pane?
    @State private var picker: SevenTvAddToSetModel?
    @State private var missing = false

    var body: some View {
        Group {
            if let picker {
                SevenTvAddToSetPicked(picker: picker)
                    .id(picker.id)
            } else if missing {
                PaneGonePage()
            } else {
                PaneLoadingPage()
            }
        }
        .task(id: id) { await find() }
    }

    /// An emote the account owns first (it knows what the upload put where), then one remembered by the tab or the chat, then
    /// one of the set the tab has open.
    private func find() async {
        let store = model.sevenTv
        picker = nil
        missing = false
        if store.status == nil { await store.load() }
        if store.isLinked, store.ownedEmote(id) == nil, store.ownedState != .loaded { await store.loadOwned() }
        var shared: (@MainActor (String, String) -> SevenTvSetModel)?
        if let card = pane?.provided(SevenTvController.self) {
            shared = { setID, channelID in card.setModel(setID, channelID: channelID) }
        }
        if let owned = store.ownedEmote(id) {
            picker = store.addToSetPicker(for: owned, setModel: shared)
        } else if let hit = SevenTvEmoteHits.hit(id) {
            picker = store.addToSetPicker(emote: hit, setModel: shared)
        } else if let item = pane?.provided(SevenTvSetModel.self)?.all.first(where: { $0.emoteID == id }) {
            picker = store.addToSetPicker(emote: item.asHit, setModel: shared)
        } else {
            missing = true
        }
    }
}

/// The page of a made picker: the emote as the hero, the channels and the last result as the controls, the sets as the body.
private struct SevenTvAddToSetPicked: View {
    @State private var flow: SevenTvAddToSetFlow
    @Environment(\.paneShape) private var shape

    init(picker: SevenTvAddToSetModel) {
        _flow = State(initialValue: SevenTvAddToSetFlow(picker: picker))
    }

    private var picker: SevenTvAddToSetModel { flow.picker }

    var body: some View {
        PanePage(title: picker.emote.name, subtitle: Copy.SevenTv.addToSetTitle) {
            emoteHero
        } controls: {
            VStack(alignment: .leading, spacing: 10) {
                if picker.channels.isEmpty {
                    Text(Copy.SevenTv.noEditableChannels)
                        .font(CobaltType.caption)
                        .foregroundStyle(CobaltColor.caption)
                } else {
                    SevenTvAddToSetChannels(picker: picker)
                }
                SevenTvAddToSetLineView(line: flow.line)
            }
        } body: {
            if !picker.channels.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    SevenTvAddToSetNotes(picker: picker)
                    SevenTvAddToSetSets(flow: flow)
                }
                .padding(.horizontal, 16)
            }
        }
        .modifier(SevenTvAddToSetPresentations(flow: flow))
    }

    @ViewBuilder
    private var emoteHero: some View {
        let stage = ZStack {
            CobaltColor.surface
            EmotePicture(url: picker.pending ? nil : picker.emote.previewURL, animated: picker.emote.animated, side: 160)
                .padding(20)
        }
        .frame(minHeight: 180)
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
}

/// One set: its name, "live", how full it is, and what a tap does (add, "in this set", "full", or a spinner).
private struct SevenTvAddToSetRow: View {
    let row: SevenTvSetRow
    let inSet: Bool
    let full: Bool
    let busy: Bool
    let add: () -> Void

    var body: some View {
        Button(action: add) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 6) {
                        Text(row.name)
                            .font(CobaltType.bodySemibold)
                            .foregroundStyle(CobaltColor.text)
                            .lineLimit(1)
                        if row.live { SevenTvLivePill() }
                    }
                    HStack(spacing: 8) {
                        Text(Copy.SevenTv.count(row.count, capacity: row.capacity))
                            .font(CobaltType.captionSmall)
                            .foregroundStyle(CobaltColor.caption)
                            .monospacedDigit()
                        if row.capacity != nil { SevenTvFillBar(fill: row.fill, live: row.live, width: 80) }
                    }
                }
                Spacer(minLength: 6)
                trailing
            }
            .padding(12)
            .frame(maxWidth: .infinity, minHeight: Metrics.hit, alignment: .leading)
            .background(CobaltColor.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .opacity(full && !inSet ? 0.55 : 1)
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(full || inSet || busy)
        .accessibilityLabel(
            Copy.SevenTv.addToSetRowA11y(row.name, count: row.count, capacity: row.capacity, live: row.live, full: full, inSet: inSet))
        .accessibilityHint(full || inSet ? "" : Copy.SevenTv.addButton)
    }

    @ViewBuilder
    private var trailing: some View {
        if busy {
            ProgressView().controlSize(.small)
        } else if inSet {
            Label(Copy.SevenTv.inSetPill, systemImage: Symbol.SevenTv.setHasIt)
                .labelStyle(.titleAndIcon)
                .font(CobaltType.pill)
                .foregroundStyle(CobaltColor.success)
        } else if full {
            Text(Copy.SevenTv.fullPill)
                .font(CobaltType.pill)
                .foregroundStyle(CobaltColor.caption)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(CobaltColor.elevated, in: Capsule())
        } else {
            Image(systemName: Symbol.SevenTv.add)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(CobaltColor.text)
                .frame(width: 30, height: 30)
                .background(CobaltColor.elevated, in: Circle())
                .accessibilityHidden(true)
        }
    }
}
