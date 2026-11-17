import CobaltKit
import SwiftUI

// The name clash sheet (APP-API-CONTRACT 57.4 `error.seventv.name_taken`, mockup `7tv-tab/` "name clash when adding"): adding
// (or copying) an emote whose name the set already has never fails silently. Both emotes side by side ("in the set now" and
// "adding"), then one of three: add it under another name (a free one suggested, editable), rename the one in the set (then
// the new one goes in under the name; offered when its id is known), or replace it (`override_conflicts`, the old one
// leaves). A choice that clashes again shows the new clash in place; a refusal says 7TV's words under the choices.

struct SevenTvClashSheet: View {
    let emoteSet: SevenTvSetModel

    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.shell) private var shell
    @State private var clash: SevenTvNameClash
    @State private var choice: Choice = .another
    @State private var newName: String
    @State private var oldName: String
    @State private var problem: String?
    @State private var working = false
    @State private var doneTick = 0

    enum Choice: Hashable {
        case another, renameOld, replace
    }

    init(emoteSet: SevenTvSetModel, clash: SevenTvNameClash) {
        self.emoteSet = emoteSet
        _clash = State(initialValue: clash)
        _newName = State(initialValue: clash.suggestion)
        _oldName = State(initialValue: clash.renameSuggestion)
    }

    private var canConfirm: Bool {
        guard !working else { return false }
        switch choice {
        case .another: return SevenTvRule.cleanAlias(newName).map { $0 != clash.alias } ?? false
        case .renameOld: return clash.canRenameExisting && (SevenTvRule.cleanAlias(oldName).map { $0 != clash.alias } ?? false)
        case .replace: return true
        }
    }

    private var confirmTitle: String {
        switch choice {
        case .another: return Copy.SevenTv.addAs(SevenTvRule.cleanAlias(newName) ?? newName)
        case .renameOld: return Copy.SevenTv.renameAndAdd
        case .replace: return Copy.SevenTv.replace
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header
                SevenTvClashPair(clash: clash, now: Date())
                Text(Copy.SevenTv.pickOne)
                    .font(CobaltType.captionSmall)
                    .foregroundStyle(CobaltColor.caption)
                    .accessibilityAddTraits(.isHeader)
                VStack(spacing: 8) {
                    SevenTvClashChoiceRow(
                        title: Copy.SevenTv.addUnderOther, note: nil, selected: choice == .another, select: { choice = .another }
                    ) {
                        SevenTvClashNameField(text: $newName, submit: confirm)
                    }
                    if clash.canRenameExisting {
                        SevenTvClashChoiceRow(
                            title: Copy.SevenTv.renameExisting, note: Copy.SevenTv.renameExistingNote(clash.alias),
                            selected: choice == .renameOld, select: { choice = .renameOld }
                        ) {
                            SevenTvClashNameField(text: $oldName, submit: confirm)
                        }
                    }
                    SevenTvClashChoiceRow(
                        title: Copy.SevenTv.replaceIt, note: Copy.SevenTv.replaceNote, selected: choice == .replace,
                        select: { choice = .replace }
                    ) {
                        EmptyView()
                    }
                }
                if let problem {
                    Text(problem)
                        .font(CobaltType.caption)
                        .foregroundStyle(CobaltColor.errorText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                ButtonRow {
                    Button(Copy.SevenTv.cancel) { dismiss() }
                        .buttonStyle(.cobaltSecondary(fullWidth: false, compact: true))
                    Button(confirmTitle) { confirm() }
                        .buttonStyle(CobaltButtonStyle(kind: choice == .replace ? .destructive : .primary, fullWidth: false, compact: true))
                        .disabled(!canConfirm)
                }
                .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .padding(.horizontal, 16)
            .padding(.top, 20)
            .padding(.bottom, 16)
        }
        #if os(macOS)
        .frame(width: 460, height: 560)
        #else
        .presentationDetents(typeSize.isAccessibilitySize ? [.large] : [.medium, .large])
        .presentationDragIndicator(.visible)
        #endif
        .background(CobaltColor.bg)
        .interactiveDismissDisabled(working)
        .animation(Motion.rows, value: choice)
        .haptic(.selection, trigger: choice)
        .haptic(.success, trigger: doneTick)
        .haptic(.error, trigger: problem) { $0 != nil }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 10) {
            Text(Copy.SevenTv.clashTitle(clash.alias, set: clash.setName))
                .font(Font.cobalt(17, .semibold, relativeTo: .title3))
                .foregroundStyle(CobaltColor.text)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 0)
            CloseButton(cancels: true) { dismiss() }
                .disabled(working)
        }
    }

    private func confirm() {
        guard canConfirm else { return }
        let picked: SevenTvClashChoice
        let finalName: String
        switch choice {
        case .another:
            picked = .addAs(newName)
            finalName = SevenTvRule.cleanAlias(newName) ?? newName
        case .renameOld:
            picked = .renameExisting(to: oldName)
            finalName = clash.alias
        case .replace:
            picked = .replace
            finalName = clash.alias
        }
        let current = clash
        problem = nil
        working = true
        Task {
            defer { working = false }
            do {
                if let next = try await emoteSet.resolve(current, picked) {
                    // the other name is taken too: the new clash, with fresh suggestions
                    clash = next
                    newName = next.suggestion
                    oldName = next.renameSuggestion
                    problem = Copy.SevenTv.message(for: SevenTvError.nameTaken(conflictEmoteID: next.existingEmoteID, alias: next.alias))
                } else {
                    shell.showStatus(
                        current.setID == emoteSet.setID
                            ? Copy.SevenTv.added(finalName) : Copy.SevenTv.copied(finalName, to: current.setName))
                    doneTick += 1
                    dismiss()
                }
            } catch {
                problem = Copy.SevenTv.message(for: error)
            }
        }
    }
}

/// "in the set now" and "adding", side by side.
private struct SevenTvClashPair: View {
    let clash: SevenTvNameClash
    let now: Date

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            side(
                title: Copy.SevenTv.inTheSetNow, url: clash.existing?.previewURL, animated: clash.existing?.animated ?? false,
                name: clash.alias,
                line: clash.existing?.addedAt.map { Copy.SevenTv.addedAgo(Copy.SevenTv.ago($0, now: now)) }
                    ?? (clash.existing == nil ? Copy.SevenTv.unknownEmote : nil))
            side(
                title: Copy.SevenTv.addingNow, url: clash.incoming.previewURL, animated: clash.incoming.animated,
                name: clash.incoming.name, line: nil)
        }
    }

    private func side(title: String, url: URL?, animated: Bool, name: String, line: String?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(CobaltType.badge)
                .foregroundStyle(CobaltColor.caption)
            HStack(spacing: 8) {
                EmotePicture(url: url, animated: animated, side: 40)
                    .padding(4)
                    .background(CobaltColor.elevated, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text(name)
                        .font(CobaltType.bodySemibold)
                        .foregroundStyle(CobaltColor.text)
                        .lineLimit(1)
                    if let line {
                        Text(line)
                            .font(CobaltType.badge)
                            .foregroundStyle(CobaltColor.caption)
                            .lineLimit(2)
                    }
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(CobaltColor.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

/// One way out: a round mark, its name, a line under it, and (when picked) its name field.
private struct SevenTvClashChoiceRow<Extra: View>: View {
    let title: String
    let note: String?
    let selected: Bool
    let select: () -> Void
    @ViewBuilder let extra: () -> Extra

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button(action: select) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Image(systemName: selected ? Symbol.SevenTv.choiceOn : Symbol.SevenTv.choiceOff)
                        .foregroundStyle(selected ? CobaltColor.text : CobaltColor.caption)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title)
                            .font(CobaltType.bodySemibold)
                            .foregroundStyle(CobaltColor.text)
                        if let note {
                            Text(note)
                                .font(CobaltType.badge)
                                .foregroundStyle(CobaltColor.caption)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
            if selected {
                extra()
                    .padding(.leading, 28)
                    .transition(.opacity)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(selected ? CobaltColor.elevated : CobaltColor.surface))
    }
}

/// A name field for the clash sheet (no spaces, no capitals added, no autocorrect).
private struct SevenTvClashNameField: View {
    @Binding var text: String
    let submit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            TextField(Copy.SevenTv.alias, text: $text)
                .font(CobaltType.body)
                .foregroundStyle(CobaltColor.text)
                .autocorrectionDisabled()
                #if os(iOS)
                .textInputAutocapitalization(.never)
                #endif
                .onSubmit { submit() }
                .padding(.horizontal, 12)
                .frame(minHeight: Metrics.hit)
                .background(CobaltColor.bg, in: RoundedRectangle(cornerRadius: Metrics.radius, style: .continuous))
                .accessibilityLabel(Copy.SevenTv.alias)
            if SevenTvRule.cleanAlias(text) == nil, !text.isEmpty {
                Text(Copy.SevenTv.aliasRule)
                    .font(CobaltType.badge)
                    .foregroundStyle(CobaltColor.errorText)
            }
        }
    }
}
