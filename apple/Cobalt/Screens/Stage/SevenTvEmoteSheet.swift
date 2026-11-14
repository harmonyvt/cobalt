import CobaltKit
import SwiftUI

// The small sheet a tap on an emote of the set opens (APP-API-CONTRACT 57.7, mockup screen 2): its picture, its name here and
// its own 7TV name; rename (its alias in this set), copy to another set of the same channel, remove (asks first). A channel
// that does not let the account manage sets shows it read-only.

struct SevenTvEmoteSheet: View {
    let emoteSet: SevenTvSetModel
    let emote: SevenTvSetItem

    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.shell) private var shell
    @State private var alias: String
    @State private var problem: String?
    @State private var confirmingRemove = false
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
                    canRename: canRename, working: working, otherSets: emoteSet.otherSets,
                    rename: rename, copy: copy, remove: { confirmingRemove = true })
            } else {
                Text(Copy.SevenTv.readOnly)
                    .font(CobaltType.captionSmall)
                    .foregroundStyle(CobaltColor.caption)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 20)
        .padding(.bottom, 12)
        #if os(macOS)
        .frame(width: 420)
        #else
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .presentationDetents(typeSize.isAccessibilitySize ? [.large] : [.height(330), .large])
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
                Text(Copy.SevenTv.ownName(emote.name))
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
            TextField(Copy.SevenTv.alias, text: $alias)
                .font(CobaltType.body)
                .foregroundStyle(CobaltColor.text)
                .autocorrectionDisabled()
                #if os(iOS)
                .textInputAutocapitalization(.never)
                #endif
                .onSubmit { if canRename { rename() } }
                .padding(.horizontal, 12)
                .frame(minHeight: Metrics.hit)
                .background(CobaltColor.elevated, in: RoundedRectangle(cornerRadius: Metrics.radius, style: .continuous))
            Text(Copy.SevenTv.aliasRule)
                .font(CobaltType.badge)
                .foregroundStyle(CobaltColor.caption)
        }
    }

    // MARK: edits

    private func rename() {
        let next = alias
        problem = nil
        Task {
            do {
                try await emoteSet.rename(emote, to: next)
                shell.showStatus(Copy.SevenTv.renamed(SevenTvRule.cleanAlias(next) ?? next))
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
                try await emoteSet.copy(emote, to: target.id)
                shell.showStatus(Copy.SevenTv.copied(emote.alias, to: target.name))
                doneTick += 1
            } catch {
                problem = Copy.SevenTv.message(for: error)
            }
        }
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

/// rename · copy to set… · remove.
private struct SevenTvEmoteActions: View {
    let canRename: Bool
    let working: Bool
    let otherSets: [SevenTvSetRow]
    let rename: () -> Void
    let copy: (SevenTvSetRow) -> Void
    let remove: () -> Void

    var body: some View {
        ButtonRow {
            Button(Copy.SevenTv.rename, systemImage: Symbol.SevenTv.rename) { rename() }
                .buttonStyle(.cobaltPrimary(fullWidth: false, compact: true))
                .disabled(!canRename)
            copyMenu
            Button(Copy.SevenTv.remove, systemImage: Symbol.SevenTv.remove, role: .destructive) { remove() }
                .buttonStyle(.cobaltSecondary(fullWidth: false, compact: true))
                .disabled(working)
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
