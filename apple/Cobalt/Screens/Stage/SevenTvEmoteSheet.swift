import CobaltKit
import SwiftUI

// The sheet a tap on an emote of the set opens (APP-API-CONTRACT 57.7, mockup `7tv-tab/` "tap an emote"): its picture, its
// name here and its own 7TV name; the name in this set (save name, or reset to its 7TV name when renamed), copy to another
// set of the same channel (a name that set already has opens the clash sheet), open on 7tv, remove (asks first). A channel
// that does not let the account manage sets shows it read-only, with "open on 7tv".

struct SevenTvEmoteSheet: View {
    let emoteSet: SevenTvSetModel
    let emote: SevenTvSetItem

    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.shell) private var shell
    @Environment(\.openURL) private var openURL
    @State private var alias: String
    @State private var problem: String?
    @State private var confirmingRemove = false
    @State private var clash: SevenTvNameClash?
    @State private var doneTick = 0

    init(emoteSet: SevenTvSetModel, emote: SevenTvSetItem) {
        self.emoteSet = emoteSet
        self.emote = emote
        _alias = State(initialValue: emote.alias)
    }

    private var editable: Bool { emoteSet.can.manageSets }
    private var working: Bool { emoteSet.busy.contains(emote.emoteID) }
    private var canRename: Bool {
        guard editable, !working, let clean = SevenTvRule.cleanAlias(alias) else { return false }
        return clean != emote.alias
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if editable {
                aliasField
                if let problem {
                    Text(problem)
                        .font(CobaltType.caption)
                        .foregroundStyle(CobaltColor.errorText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                SevenTvEmoteActions(
                    canRename: canRename, canReset: emote.renamed && !working, resetName: emote.name, working: working,
                    otherSets: emoteSet.otherSets, rename: { rename(to: alias) }, reset: { rename(to: emote.name) }, copy: copy,
                    open: openOnSevenTv, remove: { confirmingRemove = true })
            } else {
                Text(Copy.SevenTv.readOnly)
                    .font(CobaltType.captionSmall)
                    .foregroundStyle(CobaltColor.caption)
                Button(Copy.SevenTv.openOn7tv, systemImage: Symbol.SevenTv.website) { openOnSevenTv() }
                    .buttonStyle(.cobaltSecondary(fullWidth: false, compact: true))
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 20)
        .padding(.bottom, 12)
        #if os(macOS)
        .frame(width: 440)
        #else
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .presentationDetents(typeSize.isAccessibilitySize ? [.large] : [.height(400), .large])
        .presentationDragIndicator(.visible)
        #endif
        .background(CobaltColor.bg)
        .interactiveDismissDisabled(working)
        .confirmationDialog(Copy.SevenTv.removeTitle(emote.alias), isPresented: $confirmingRemove, titleVisibility: .visible) {
            Button(Copy.SevenTv.remove, role: .destructive) { remove() }
            Button(Copy.SevenTv.keep, role: .cancel) {}
        } message: {
            Text(Copy.SevenTv.removeMessage)
        }
        .sheet(item: $clash) { found in
            SevenTvClashSheet(emoteSet: emoteSet, clash: found)
        }
        .haptic(.success, trigger: doneTick)
        .haptic(.error, trigger: problem) { $0 != nil }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            EmotePicture(url: emote.previewURL, animated: emote.animated, side: 52)
                .padding(4)
                .background(CobaltColor.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(emote.alias)
                    .font(Font.cobalt(16, .semibold, relativeTo: .headline))
                    .foregroundStyle(CobaltColor.text)
                    .lineLimit(1)
                Text(Copy.SevenTv.sevenTvNameLine(emote.name, animated: emote.animated))
                    .font(CobaltType.captionSmall)
                    .foregroundStyle(CobaltColor.caption)
                    .lineLimit(1)
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 0)
            CloseButton(cancels: true) { dismiss() }
        }
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
        problem = nil
        if let clean = SevenTvRule.cleanAlias(raw), let holder = emoteSet.emote(aliased: clean), holder.id != emote.id {
            problem = Copy.SevenTv.message(for: SevenTvError.nameTaken(conflictEmoteID: holder.emoteID, alias: clean))
            return
        }
        Task {
            do {
                try await emoteSet.rename(emote, to: raw)
                shell.showStatus(Copy.SevenTv.renamed(SevenTvRule.cleanAlias(raw) ?? raw))
                doneTick += 1
                dismiss()
            } catch {
                problem = Copy.SevenTv.message(for: error)
            }
        }
    }

    private func copy(_ target: SevenTvSetRow) {
        problem = nil
        Task {
            do {
                if let found = try await emoteSet.copy(emote, to: target.id) {
                    clash = found
                } else {
                    shell.showStatus(Copy.SevenTv.copied(emote.alias, to: target.name))
                    doneTick += 1
                }
            } catch {
                problem = Copy.SevenTv.message(for: error)
            }
        }
    }

    private func openOnSevenTv() {
        openURL(SevenTvEmoteRule.pageURL(emote.emoteID))
    }

    private func remove() {
        problem = nil
        Task {
            do {
                try await emoteSet.remove(emote)
                shell.showStatus(Copy.SevenTv.removed(emote.alias))
                doneTick += 1
                dismiss()
            } catch {
                problem = Copy.SevenTv.message(for: error)
            }
        }
    }
}

/// save name · reset to <7tv name> · copy to set… · open on 7tv · remove.
private struct SevenTvEmoteActions: View {
    let canRename: Bool
    let canReset: Bool
    let resetName: String
    let working: Bool
    let otherSets: [SevenTvSetRow]
    let rename: () -> Void
    let reset: () -> Void
    let copy: (SevenTvSetRow) -> Void
    let open: () -> Void
    let remove: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ButtonRow {
                Button(Copy.SevenTv.saveName, systemImage: Symbol.SevenTv.rename) { rename() }
                    .buttonStyle(.cobaltPrimary(fullWidth: false, compact: true))
                    .disabled(!canRename)
                if canReset {
                    Button(Copy.SevenTv.resetTo(resetName), systemImage: Symbol.SevenTv.reset) { reset() }
                        .buttonStyle(.cobaltSecondary(fullWidth: false, compact: true))
                }
            }
            ButtonRow {
                copyMenu
                Button(Copy.SevenTv.openOn7tv, systemImage: Symbol.SevenTv.website) { open() }
                    .buttonStyle(.cobaltSecondary(fullWidth: false, compact: true))
                Button(Copy.SevenTv.remove, systemImage: Symbol.SevenTv.remove, role: .destructive) { remove() }
                    .buttonStyle(.cobaltSecondary(fullWidth: false, compact: true))
                    .disabled(working)
            }
        }
    }

    private var copyMenu: some View {
        Menu {
            if otherSets.isEmpty {
                Text(Copy.SevenTv.noOtherSets)
            }
            ForEach(otherSets) { target in
                Button(target.name) { copy(target) }
            }
        } label: {
            Label(Copy.SevenTv.copyToSet, systemImage: Symbol.SevenTv.copyToSet)
                .font(CobaltType.buttonSmall)
                .foregroundStyle(CobaltColor.text)
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, 14)
                .frame(minHeight: Metrics.hit)
                .background(CobaltColor.elevated, in: Capsule())
                .contentShape(Capsule())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .disabled(working || otherSets.isEmpty)
    }
}
