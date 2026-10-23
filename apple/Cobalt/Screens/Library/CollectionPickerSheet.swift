import CobaltKit
import SwiftUI

/// The select panel's `collection` button opens this: the picks become one link, filed in the collection chosen here.
/// On top, a field to name a new collection; under it every collection as a row with its cover (one file from each of
/// its newest four links), its name in the collection amber, how many links and files it already holds, and how many
/// of the picks are already in it. A tap files the picks there and closes the sheet. iPhone and iPad: a sheet; Mac:
/// the same view, 420 pt wide.
struct CollectionPickerSheet: View {
    let store: ShareSetStore
    let picks: [LibraryRow]
    let file: (LibraryController.CollectionTarget) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var newName = ""
    @FocusState private var naming: Bool

    private var cleaned: String? { ShareCollectionRule.cleanName(newName) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            newRow
            if store.collections.isEmpty {
                Text(Copy.Library2.noCollectionsYet)
                    .font(CobaltType.caption)
                    .foregroundStyle(CobaltColor.caption)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 8)
                Spacer(minLength: 0)
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(store.collections) { collection in
                            row(collection)
                        }
                    }
                    .padding(.bottom, 8)
                }
                .scrollBounceBehavior(.basedOnSize)
                #if os(macOS)
                .frame(maxHeight: 360)
                #endif
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 20)
        .padding(.bottom, 12)
        #if os(macOS)
        .frame(width: 420)
        #else
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .presentationDetents(typeSize.isAccessibilitySize ? [.large] : [.medium, .large])
        .presentationDragIndicator(.visible)
        #endif
        .background(CobaltColor.bg)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Copy.Library2.pickCollectionTitle)
    }

    // MARK: the top

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 3) {
                Text(Copy.Library2.pickCollectionTitle)
                    .font(Font.cobalt(16, .semibold, relativeTo: .headline))
                    .foregroundStyle(CobaltColor.text)
                    .accessibilityAddTraits(.isHeader)
                Text(Copy.Library2.pickCollectionLine(picks.count))
                    .font(CobaltType.captionSmall)
                    .foregroundStyle(CobaltColor.caption)
            }
            Spacer(minLength: 8)
            Button(Copy.cancel) { dismiss() }
                .font(CobaltType.captionSmall)
                .buttonStyle(.cobaltSecondary(fullWidth: false, compact: true))
                .keyboardShortcut(.cancelAction)
        }
    }

    /// Name a new collection and file the picks in it, in one go.
    private var newRow: some View {
        HStack(spacing: 8) {
            Image(systemName: Symbol.collection)
                .symbolVariant(.fill)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(CobaltColor.collection)
                .frame(width: 40, height: 40)
                .background(CobaltColor.collectionBack, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .accessibilityHidden(true)
            TextField(Copy.Library2.newCollectionPlaceholder, text: $newName)
                .font(CobaltType.bodyMedium)
                .textFieldStyle(.plain)
                .focused($naming)
                .submitLabel(.done)
                .onSubmit(createNew)
                .accessibilityLabel(Copy.Library2.newCollectionTitle)
            Button(action: createNew) {
                Label(Copy.Library2.create, systemImage: Symbol.Library.collectionFile).labelStyle(.iconOnly)
            }
            .buttonStyle(.selectAction(.collection))
            .frame(width: 56)
            .disabled(cleaned == nil)
            .accessibilityLabel(Copy.Library2.create)
        }
        .padding(8)
        .background(CobaltColor.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(naming ? CobaltColor.collection.opacity(0.6) : CobaltColor.border.opacity(0.5),
                              style: StrokeStyle(lineWidth: 1, dash: naming ? [] : [5, 4])))
        .motion(Motion.rows, value: naming)
    }

    private func createNew() {
        guard let cleaned else { return }
        dismiss()
        file(.new(name: cleaned))
    }

    // MARK: a collection

    private func row(_ collection: ShareCollection) -> some View {
        let links = store.sets(in: collection)
        let files = links.reduce(0) { $0 + $1.items.count }
        let already = Self.alreadyIn(links, picks)
        let cover = links.prefix(4).compactMap { $0.items.first(where: \.isPublic) ?? $0.items.first }
        return Button {
            dismiss()
            file(.existing(id: collection.id, name: collection.name))
        } label: {
            HStack(spacing: 12) {
                LinkCover(items: cover, side: 56)
                VStack(alignment: .leading, spacing: 3) {
                    Label(collection.name, systemImage: Symbol.collection)
                        .labelStyle(CollectionLineLabel())
                        .font(CobaltType.bodySemibold)
                        .foregroundStyle(CobaltColor.collection)
                        .lineLimit(1)
                    Text(Copy.Library2.collectionHolds(links: collection.setIDs.count, files: files))
                        .font(CobaltType.captionSmall)
                        .foregroundStyle(CobaltColor.caption)
                        .lineLimit(1)
                    if already > 0 {
                        Text(Copy.Library2.alreadyHere(already, of: picks.count))
                            .font(CobaltType.badge)
                            .foregroundStyle(CobaltColor.collection)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(CobaltColor.collectionBack, in: Capsule())
                    }
                }
                Spacer(minLength: 8)
                Image(systemName: Symbol.Library.collectionFileHere)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(CobaltColor.collection)
                    .frame(width: 34, height: 34)
                    .background(CobaltColor.collectionBack, in: Circle())
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(CobaltColor.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.borderless)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            Copy.Library2.collectionRowA11y(
                name: collection.name, links: collection.setIDs.count, files: files, already: already,
                of: picks.count))
        .accessibilityHint(Copy.Library2.fileHereHint)
        .accessibilityAddTraits(.isButton)
    }

    /// How many of the picks are already in one of the collection's links.
    static func alreadyIn(_ links: [ShareSet], _ picks: [LibraryRow]) -> Int {
        let held = Set(links.flatMap { $0.items.map(\.id) })
        guard !held.isEmpty else { return 0 }
        return picks.filter { !ShareSetIndex.fileIDs(of: $0.item).isDisjoint(with: held) }.count
    }
}
