import CobaltKit
import SwiftUI

// The pool picker (APP-API-CONTRACT 29.11): what the canvas and the store draw from. A segmented control (collection · set ·
// search · whole library), then what the chosen kind needs: a menu of the links tab's collections or sets, the search words in
// a field, or nothing for the whole library. Choosing is a write; the row under the control always says what the stage draws
// from now and how many files that is. Private items never show, whatever the pool.

struct StagePoolPicker: View {
    let model: AppModel
    let stage: StageSettings
    let controller: StageController
    /// The compact layout's shorter note.
    let compact: Bool

    @Environment(\.shell) private var shell
    /// The segment the owner tapped before choosing anything in it; nil follows the stage.
    @State private var shown: StagePool.Kind?
    @State private var words = ""

    private var kind: StagePool.Kind { shown ?? stage.pool.kind }
    private var busy: Bool { controller.isBusy("pool") }
    private var shareSets: ShareSetStore { model.shareSets }

    /// The kinds this server can pool by, in the board's order.
    private var kinds: [StagePool.Kind] {
        var out: [StagePool.Kind] = []
        if model.capabilities.shareCollections { out.append(.collection) }
        if model.capabilities.shareGroups { out.append(.group) }
        out.append(.search)
        out.append(.library)
        if !out.contains(stage.pool.kind) { out.insert(stage.pool.kind, at: 0) }      // what the stage has stays on the control
        return out
    }

    var body: some View {
        StageCard {
            VStack(alignment: .leading, spacing: 2) {
                Text(Copy.Stage.pool)
                    .font(CobaltType.bodySemibold)
                    .foregroundStyle(CobaltColor.text)
                    .accessibilityAddTraits(.isHeader)
                Text(compact ? Copy.Stage.poolPhoneNote : Copy.Stage.poolNote)
                    .font(CobaltType.captionSmall)
                    .foregroundStyle(CobaltColor.caption)
            }
            kindPicker
            detail
            current
        }
        .onAppear { if stage.pool.kind == .search { words = stage.pool.ref ?? "" } }
        .onChange(of: stage.pool) { _, pool in
            shown = nil
            if pool.kind == .search { words = pool.ref ?? "" }
        }
    }

    // MARK: the control

    private var kindPicker: some View {
        Picker(Copy.Stage.poolPicker, selection: Binding(get: { kind }, set: { choose(kind: $0) })) {
            ForEach(kinds, id: \.self) { kind in
                Text(Self.title(kind)).tag(kind)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .disabled(busy)
        .accessibilityLabel(Copy.Stage.poolPicker)
    }

    private static func title(_ kind: StagePool.Kind) -> String {
        switch kind {
        case .collection: return Copy.Stage.poolCollection
        case .group: return Copy.Stage.poolSet
        case .search: return Copy.Stage.poolSearch
        case .library: return Copy.Stage.poolLibrary
        }
    }

    private func choose(kind next: StagePool.Kind) {
        shown = next == stage.pool.kind ? nil : next
        if next == .library && stage.pool.kind != .library { controller.choosePool(.library, shell: shell) }
    }

    // MARK: what the kind needs

    @ViewBuilder
    private var detail: some View {
        switch kind {
        case .collection:
            chooser(
                prompt: Copy.Stage.chooseCollection, empty: Copy.Stage.noCollections,
                entries: shareSets.collections.map { PoolEntry(id: $0.id, name: $0.name) },
                chosen: stage.pool.kind == .collection ? stage.pool.ref : nil,
                choice: { StagePoolChoice.collection(id: $0) })
        case .group:
            chooser(
                prompt: Copy.Stage.chooseSet, empty: Copy.Stage.noSets,
                entries: shareSets.groups.map { PoolEntry(id: $0.id, name: $0.name) },
                chosen: stage.pool.kind == .group ? stage.pool.ref : nil,
                choice: { StagePoolChoice.group(id: $0) })
        case .search:
            searchField
        case .library:
            EmptyView()
        }
    }

    private func chooser(
        prompt: String, empty: String, entries: [PoolEntry], chosen: String?, choice: @escaping (String) -> StagePoolChoice
    ) -> some View {
        Group {
            if entries.isEmpty {
                Text(empty)
                    .font(CobaltType.caption)
                    .foregroundStyle(CobaltColor.caption)
            } else {
                Menu {
                    ForEach(entries) { entry in
                        Button {
                            controller.choosePool(choice(entry.id), shell: shell)
                        } label: {
                            if entry.id == chosen {
                                Label(entry.name, systemImage: Symbol.stageChosen)
                            } else {
                                Text(entry.name)
                            }
                        }
                    }
                } label: {
                    HStack {
                        Text(entries.first { $0.id == chosen }?.name ?? prompt)
                            .font(CobaltType.body)
                            .foregroundStyle(CobaltColor.text)
                            .lineLimit(1)
                        Spacer(minLength: 8)
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(CobaltColor.caption)
                    }
                    .padding(.horizontal, 12)
                    .frame(maxWidth: .infinity, minHeight: Metrics.hit)
                    .background(CobaltColor.elevated, in: RoundedRectangle(cornerRadius: Metrics.radius, style: .continuous))
                    .contentShape(Rectangle())
                }
                .menuIndicator(.hidden)
                .buttonStyle(.plain)
                .disabled(busy)
            }
        }
    }

    private var cleanWords: String? { StageRule.cleanSearch(words) }

    private var searchField: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                TextField(Copy.Stage.searchPlaceholder, text: $words)
                    .submitLabel(.search)
                    .onSubmit { useWords() }
                    .onChange(of: words) { _, text in cut(text) }
                    .font(CobaltType.body)
                    .foregroundStyle(CobaltColor.text)
                    .textFieldStyle(.plain)
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    #endif
                    .autocorrectionDisabled()
                    .padding(.horizontal, 12)
                    .frame(maxWidth: .infinity, minHeight: Metrics.hit)
                    .background(CobaltColor.elevated, in: RoundedRectangle(cornerRadius: Metrics.radius, style: .continuous))
                    .accessibilityLabel(Copy.Stage.searchPlaceholder)
                Button(Copy.Stage.searchUse) { useWords() }
                    .buttonStyle(.cobaltSecondary(fullWidth: false, compact: true))
                    .disabled(cleanWords == nil || busy)
            }
            Text(Copy.Stage.searchNote)
                .font(CobaltType.badge)
                .foregroundStyle(CobaltColor.caption)
        }
    }

    private func useWords() {
        guard let clean = cleanWords, !busy else { return }
        controller.choosePool(.search(words: clean), shell: shell)
    }

    /// The field takes at most `StageRule.searchLimit` characters.
    private func cut(_ text: String) {
        guard text.unicodeScalars.count > StageRule.searchLimit else { return }
        var scalars = String.UnicodeScalarView()
        scalars.append(contentsOf: text.unicodeScalars.prefix(StageRule.searchLimit))
        words = String(scalars)
    }

    // MARK: what the stage draws from now

    private var current: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: Self.symbol(stage.pool.kind))
                .font(.system(size: 13))
                .foregroundStyle(CobaltColor.caption)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(currentName)
                    .font(CobaltType.bodyMedium)
                    .foregroundStyle(CobaltColor.text)
                    .lineLimit(2)
                if stage.pool.missing {
                    Text(Copy.Stage.poolMissing)
                        .font(CobaltType.captionSmall)
                        .foregroundStyle(CobaltColor.errorText)
                } else if stage.pool.kind == .library {
                    Text(Copy.Stage.poolLibraryNote)
                        .font(CobaltType.captionSmall)
                        .foregroundStyle(CobaltColor.caption)
                }
            }
            Spacer(minLength: 8)
            Text(Copy.Stage.poolCount(stage.pool.count))
                .font(CobaltType.captionSmall)
                .foregroundStyle(CobaltColor.caption)
                .monospacedDigit()
        }
        .accessibilityElement(children: .combine)
    }

    private var currentName: String {
        let pool = stage.pool
        switch pool.kind {
        case .library: return pool.name ?? Copy.Stage.poolLibrary
        case .search: return Copy.Stage.poolWords(pool.ref ?? pool.name ?? "")
        case .collection, .group: return pool.name ?? ""
        }
    }

    private static func symbol(_ kind: StagePool.Kind) -> String {
        switch kind {
        case .collection: return Symbol.stagePoolCollection
        case .group: return Symbol.stagePoolSet
        case .search: return Symbol.stagePoolSearch
        case .library: return Symbol.stagePoolLibrary
        }
    }
}

/// One collection or set in the chooser.
private struct PoolEntry: Identifiable {
    let id: String
    let name: String
}
