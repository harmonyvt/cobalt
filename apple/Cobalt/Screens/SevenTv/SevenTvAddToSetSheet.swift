import CobaltKit
import SwiftUI

// "add to a set…" (APP-API-CONTRACT 57.14): an emote the account owns, put into any set of any channel it may edit. Opened from
// a row of "your emotes on 7tv" (the row's button, its context menu and its swipe) and from the upload sheet once the emote is
// uploaded (7TV can take it into a set while it is still processing). The channels the account can edit are chips (a channel
// without the right to change sets is not there; a private emote is offered the account's own channel alone), then that
// channel's sets: name, live pill, count / capacity, a thin fill bar. A tap adds it under its own name, the same call as
// the search's add (`SevenTvAddToSetModel.add(to:)` → `SevenTvSetModel.addChecking`). A full set is dimmed with "full", a
// set that has it says "in this set". A name another emote already holds opens the name clash sheet (another name, rename
// the one there, or replace it). The sheet stays open after an add, so it can go into more sets: a line under the sets says
// what came of the last one ("added to main on capybaraharmony").

struct SevenTvAddToSetSheet: View {
    let picker: SevenTvAddToSetModel

    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.shell) private var shell
    @State private var clash: SevenTvNameClash?
    /// The set the open clash sheet is about.
    @State private var clashRow: SevenTvSetRow?
    @State private var line: Line?
    @State private var addedTick = 0
    @State private var failTick = 0

    /// What the last add came to, said under the sets.
    private struct Line: Equatable {
        var text: String
        var good: Bool
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header
                emoteCard
                if picker.channels.isEmpty {
                    Text(Copy.SevenTv.noEditableChannels)
                        .font(CobaltType.caption)
                        .foregroundStyle(CobaltColor.caption)
                } else {
                    channelChips
                    setList
                }
                if let line {
                    Text(line.text)
                        .font(CobaltType.caption)
                        .foregroundStyle(line.good ? CobaltColor.success : CobaltColor.errorText)
                        .fixedSize(horizontal: false, vertical: true)
                        .transition(.opacity)
                        .accessibilityAddTraits(.updatesFrequently)
                }
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
        .animation(Motion.rows, value: line)
        .haptic(.success, trigger: addedTick)
        .haptic(.error, trigger: failTick)
        .task { await picker.prepare() }
        .sheet(item: $clash, onDismiss: clashClosed) { found in
            if let row = picker.sets.first(where: { $0.id == found.setID }), let target = picker.setModel(for: row) {
                SevenTvClashSheet(emoteSet: target, clash: found)
            }
        }
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

    // MARK: the emote

    private var emoteCard: some View {
        HStack(alignment: .center, spacing: 12) {
            EmotePicture(url: picker.pending ? nil : picker.emote.previewURL, animated: false, side: 48)
                .padding(4)
                .background(CobaltColor.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                Text(picker.emote.name)
                    .font(Font.cobalt(16, .semibold, relativeTo: .headline))
                    .foregroundStyle(CobaltColor.text)
                    .lineLimit(1)
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
            .accessibilityElement(children: .combine)
            Spacer(minLength: 0)
        }
    }

    // MARK: channels and sets

    private var channelChips: some View {
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

    @ViewBuilder
    private var setList: some View {
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
                            add(to: row)
                        }
                    }
                }
                Text(Copy.SevenTv.addToSetStays)
                    .font(CobaltType.badge)
                    .foregroundStyle(CobaltColor.caption)
            }
        }
    }

    // MARK: adding

    private func add(to row: SevenTvSetRow) {
        Task {
            let outcome = await picker.add(to: row)
            switch outcome {
            case .added(_, let setName, let channelName):
                say(Copy.SevenTv.addedToSetOn(set: setName, channel: channelName), good: true)
            case .alreadyIn(let setName):
                say(Copy.SevenTv.alreadyInSet(setName), good: true)
            case .clash(let found):
                line = nil
                clashRow = row
                clash = found
            case .failed(let error):
                say(Copy.SevenTv.message(for: error), good: false)
            }
        }
    }

    private func say(_ text: String, good: Bool) {
        line = Line(text: text, good: good)
        shell.showStatus(text)
        if good { addedTick += 1 } else { failTick += 1 }
    }

    /// The clash sheet closed: when the emote went in meanwhile (another name, or replacing), say so.
    private func clashClosed() {
        defer { clashRow = nil }
        guard let row = clashRow, let channel = picker.channel, picker.contains(row) else { return }
        line = Line(text: Copy.SevenTv.addedToSetOn(set: row.name, channel: channel.name), good: true)
        addedTick += 1
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
