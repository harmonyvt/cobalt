import CobaltKit
import SwiftUI

// The new / rename sheet (APP-API-CONTRACT section 26). A name field (save is enabled only when
// `ShareCollectionRule.cleanName` accepts it) and, for a new collection, a checklist of the existing links to include
// (thumbnail and title), with the link the owner came from already ticked. iPhone and iPad: a sheet; Mac: the same view,
// 420 pt wide. A refusal is shown inside the sheet (the shell's status line would sit behind it) and the sheet stays
// open; a link the server says is gone is unticked.

struct CollectionSheet: View {
    let model: AppModel
    let request: CollectionSheetRequest

    @Environment(\.dismiss) private var dismiss
    @Environment(\.shell) private var shell
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var name: String
    @State private var picked: Set<String>
    @State private var saving = false
    @State private var problem: String?
    @FocusState private var focused: Bool

    init(model: AppModel, request: CollectionSheetRequest) {
        self.model = model
        self.request = request
        switch request {
        case .create(let preselected):
            _name = State(initialValue: "")
            _picked = State(initialValue: Set(preselected))
        case .rename(let collection):
            _name = State(initialValue: collection.name)
            _picked = State(initialValue: [])
        }
    }

    private var store: ShareSetStore { model.shareSets }
    private var isCreate: Bool {
        if case .create = request { return true }
        return false
    }
    private var cleaned: String? { ShareCollectionRule.cleanName(name) }
    private var canSave: Bool { cleaned != nil && !saving }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(isCreate ? Copy.Collections.newTitle : Copy.Collections.renameTitle)
                .font(Font.cobalt(16, .semibold, relativeTo: .headline))
                .foregroundStyle(CobaltColor.text)
                .accessibilityAddTraits(.isHeader)
            field
            if isCreate { checklist }
            if let problem {
                Text(problem)
                    .font(CobaltType.caption)
                    .foregroundStyle(CobaltColor.errorText)
                    .accessibilityAddTraits(.updatesFrequently)
            }
            buttons
        }
        .haptic(.selection, trigger: picked.count)
        .haptic(.error, trigger: problem) { $0 != nil }
        .padding(.horizontal, 16)
        .padding(.top, 20)
        .padding(.bottom, 12)
        #if os(macOS)
        .frame(width: 420)
        #else
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .presentationDetents(detents)
        .presentationDragIndicator(.visible)
        #endif
        .background(CobaltColor.bg)
        .interactiveDismissDisabled(saving)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(isCreate ? Copy.Collections.newTitle : Copy.Collections.renameTitle)
        .task {
            // after the sheet's rise has settled: focus asked for sooner is dropped
            try? await Task.sleep(for: .milliseconds(500))
            focused = true
        }
    }

    #if os(iOS)
    private var detents: Set<PresentationDetent> {
        if !isCreate { return typeSize.isAccessibilitySize ? [.height(260), .large] : [.height(200)] }
        return [.medium, .large]
    }
    #endif

    // MARK: the name

    private var field: some View {
        VStack(alignment: .trailing, spacing: 4) {
            HStack(spacing: 6) {
                TextField(Copy.Collections.namePlaceholder, text: $name)
                    .focused($focused)
                    .submitLabel(.done)
                    .onSubmit { if canSave { save() } }
                    .font(CobaltType.body)
                    .foregroundStyle(CobaltColor.text)
                    .accessibilityLabel(Copy.Collections.nameField)
                if !name.isEmpty {
                    Button {
                        name = ""
                        focused = true
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 17))
                            .foregroundStyle(CobaltColor.caption)
                            .frame(width: Metrics.hit, height: Metrics.hit)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Copy.Media.clearTitle)
                }
            }
            .padding(.leading, 12)
            .padding(.trailing, name.isEmpty ? 12 : 0)
            .frame(minHeight: Metrics.hit)
            .background(CobaltColor.elevated, in: RoundedRectangle(cornerRadius: Metrics.radius, style: .continuous))
            .onChange(of: name) { _, now in
                let cut = TitleText.capped(now, limit: ShareCollectionRule.nameLimit)
                if cut != now { name = cut }
                problem = nil
            }
            if name.unicodeScalars.count >= 50 {
                Text(Copy.Collections.nameCount(name.unicodeScalars.count))
                    .font(CobaltType.caption)
                    .foregroundStyle(CobaltColor.caption)
                    .monospacedDigit()
            }
        }
    }

    // MARK: the links to include

    @ViewBuilder
    private var checklist: some View {
        HStack {
            SectionLabel(text: Copy.Collections.includeHeader)
            Spacer()
            if !picked.isEmpty {
                Text(Copy.Collections.picked(picked.count))
                    .font(CobaltType.captionSmall)
                    .foregroundStyle(CobaltColor.caption)
                    .monospacedDigit()
            }
        }
        if store.sets.isEmpty {
            Text(Copy.Collections.noLinksToInclude)
                .font(CobaltType.caption)
                .foregroundStyle(CobaltColor.caption)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 8)
            Spacer(minLength: 0)
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(store.sets) { link in
                        ChecklistRow(link: link, isOn: picked.contains(link.id)) { toggle(link) }
                    }
                }
            }
            #if os(macOS)
            .frame(height: 240)
            #endif
        }
    }

    private func toggle(_ link: ShareSet) {
        if picked.contains(link.id) { picked.remove(link.id) } else { picked.insert(link.id) }
        problem = nil
    }

    // MARK: the buttons

    private var buttons: some View {
        HStack(spacing: 8) {
            Button(Copy.Collections.cancel) { dismiss() }
                .buttonStyle(.cobaltSecondary())
                .keyboardShortcut(.cancelAction)
                .disabled(saving)
            Button(Copy.Collections.save) { save() }
                .buttonStyle(.cobaltPrimary())
                .keyboardShortcut(.defaultAction)
                .disabled(!canSave)
        }
    }

    private func save() {
        guard let cleaned, !saving else { return }
        saving = true
        problem = nil
        // the links in the order they are listed, so the newest ends up where the server puts it
        let ids = store.sets.map(\.id).filter(picked.contains)
        Task {
            defer { saving = false }
            do {
                switch request {
                case .create:
                    try await store.createCollection(name: cleaned, setIDs: ids)
                    shell.showStatus(Copy.Collections.made)
                case .rename(let collection):
                    if cleaned != collection.name {
                        try await store.renameCollection(collection.id, to: cleaned)
                        shell.showStatus(Copy.Collections.renamed)
                    }
                }
                dismiss()
            } catch {
                if case ShareCollectionError.linkNotFound(let gone) = error { picked.subtract(gone) }
                problem = Copy.Collections.message(for: error)
            }
        }
    }
}

/// One link in the checklist: a circle or a check, its first thumbnail, its title and file count.
private struct ChecklistRow: View {
    let link: ShareSet
    let isOn: Bool
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 12) {
                Image(systemName: isOn ? Symbol.linkPicked : Symbol.linkNotPicked)
                    .font(.system(size: 20))
                    .foregroundStyle(isOn ? CobaltColor.focus : CobaltColor.caption)
                    .frame(width: 24)
                    .accessibilityHidden(true)
                if let item = link.items.first(where: \.isPublic) ?? link.items.first {
                    LinkThumb(item: item, side: 44).accessibilityHidden(true)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(link.displayTitle)
                        .font(CobaltType.bodySemibold)
                        .foregroundStyle(CobaltColor.text)
                        .lineLimit(1)
                    Text(Copy.Links.fileCount(link.items.count))
                        .font(CobaltType.captionSmall)
                        .foregroundStyle(CobaltColor.caption)
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 6)
            .frame(minHeight: Metrics.hit)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(link.displayTitle)
        .accessibilityAddTraits(isOn ? [.isButton, .isSelected] : .isButton)
    }
}
