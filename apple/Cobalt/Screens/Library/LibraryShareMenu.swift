import CobaltKit
import SwiftUI

/// What the share chips let through: every post, the ones in no link yet, the ones in at least one link, the ones in
/// one collection (through any of its links), or the ones in any collection of one set.
enum LibraryShareFilter: Hashable {
    case all
    case notShared
    case shared
    case collection(String)
    /// A set (APP-API-CONTRACT 28): the posts in any of its collections.
    case set(String)

    /// Whether the post passes. `index` is built from the share store's links and collections; `setCollections` is the
    /// set's collection ids (only read for `.set`).
    func admits(_ row: LibraryRow, index: ShareSetIndex, setCollections: Set<String> = []) -> Bool {
        switch self {
        case .all: return true
        case .notShared: return row.shareable && index.setIDs(for: row.item).isEmpty
        case .shared: return !index.setIDs(for: row.item).isEmpty
        case .collection(let id): return index.collectionIDs(for: row.item).contains(id)
        case .set: return !index.collectionIDs(for: row.item).isDisjoint(with: setCollections)
        }
    }
}

/// The library's one "links" filter (2026-11-15, replacing the second chip row): a chip pinned at the trailing end of the
/// kind chips that opens a menu of `everything`, `not shared` and `shared` with how many posts each holds, then every set
/// and every collection. Off it is the link icon and a small chevron; on it turns black and names the pick with its count,
/// so the owner always sees what is narrowing the tiles. `everything` turns it off. Only on a server that makes share links, once there is at least one.
struct LibraryShareMenu: View {
    let model: AppModel
    /// The posts before this filter (the kind chip, the search and `show` already applied), for the counts.
    let rows: [LibraryRow]
    let index: ShareSetIndex
    @Binding var filter: LibraryShareFilter

    private var store: ShareSetStore { model.shareSets }

    var body: some View {
        let counts = counts
        Menu {
            Picker(Copy.Library2.shareFilter, selection: $filter) {
                Text(Copy.Library2.shareEverything).tag(LibraryShareFilter.all)
                Label(Copy.Library2.menuRow(Copy.Library2.notShared, counts.notShared), systemImage: Symbol.Library.notShared)
                    .tag(LibraryShareFilter.notShared)
                Label(Copy.Library2.menuRow(Copy.Library2.sharedChip, counts.shared), systemImage: Symbol.link)
                    .tag(LibraryShareFilter.shared)
            }
            .pickerStyle(.inline)
            if model.capabilities.shareGroups, !store.groups.isEmpty {
                Picker(Copy.Library2.setsSection, selection: $filter) {
                    ForEach(store.groups) { set in
                        Label(Copy.Library2.menuRow(set.name, count(of: set, counts)), systemImage: Symbol.collectionSet)
                            .tag(LibraryShareFilter.set(set.id))
                    }
                }
                .pickerStyle(.inline)
            }
            if model.capabilities.shareCollections, !store.collections.isEmpty {
                Picker(Copy.Library2.collectionsShelf, selection: $filter) {
                    ForEach(store.collections) { collection in
                        Label(
                            Copy.Library2.menuRow(collection.name, counts.byCollection[collection.id] ?? 0),
                            systemImage: Symbol.collection
                        )
                        .tag(LibraryShareFilter.collection(collection.id))
                    }
                }
                .pickerStyle(.inline)
            }
        } label: {
            label(counts)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(Copy.Library2.shareMenuName)
        .accessibilityLabel(Copy.Library2.shareMenuName)
        .accessibilityValue(filter == .all ? Copy.Library2.shareEverything : title(filter))
        .haptic(.selection, trigger: filter)
    }

    @ViewBuilder
    private func label(_ counts: Counts) -> some View {
        let on = filter != .all
        HStack(spacing: 5) {
            Image(systemName: symbol(filter))
                .symbolVariant(symbolFills(filter) ? .fill : .none)
                .font(.system(size: 11, weight: .bold))
            if on {
                Text(Copy.Library2.shareChip(title(filter), count: count(filter, counts)))
                    .font(Font.cobalt(11.5, .semibold, relativeTo: .caption))
                    .monospacedDigit()
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 150, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Image(systemName: Symbol.Library.descending)
                    .font(.system(size: 8, weight: .bold))
                    .opacity(0.6)
            }
        }
        .foregroundStyle(on ? CobaltColor.onText : tint(filter))
        .padding(.horizontal, 12)
        .frame(minWidth: 40, minHeight: 30)
        .background(Capsule().fill(on ? CobaltColor.text : CobaltColor.elevated))
        .contentShape(Capsule())
        .motion(Motion.chip, value: filter)
    }

    // MARK: words, icons and counts of a pick

    private func title(_ value: LibraryShareFilter) -> String {
        switch value {
        case .all: return Copy.Library2.shareEverything
        case .notShared: return Copy.Library2.notShared
        case .shared: return Copy.Library2.sharedChip
        case .set(let id): return store.group(id)?.name ?? Copy.Library2.setsSection
        case .collection(let id): return store.collection(id)?.name ?? Copy.Library2.collectionsShelf
        }
    }

    private func symbol(_ value: LibraryShareFilter) -> String {
        switch value {
        case .all, .shared: return Symbol.link
        case .notShared: return Symbol.Library.notShared
        case .set: return Symbol.collectionSet
        case .collection: return Symbol.collection
        }
    }

    private func symbolFills(_ value: LibraryShareFilter) -> Bool {
        if case .collection = value { return true }
        return false
    }

    private func tint(_ value: LibraryShareFilter) -> Color {
        switch value {
        case .all, .shared: return CobaltColor.sharedInk
        case .notShared: return Color.primary
        case .set: return CobaltColor.collectionSet
        case .collection: return CobaltColor.collection
        }
    }

    private func count(_ value: LibraryShareFilter, _ counts: Counts) -> Int {
        switch value {
        case .all: return rows.count
        case .notShared: return counts.notShared
        case .shared: return counts.shared
        case .set(let id): return store.group(id).map { count(of: $0, counts) } ?? 0
        case .collection(let id): return counts.byCollection[id] ?? 0
        }
    }

    private struct Counts {
        var notShared = 0
        var shared = 0
        var byCollection: [String: Int] = [:]
        /// Each shared post's collections, for the sets' counts (a post in two of a set's collections counts once).
        var postCollections: [Set<String>] = []
    }

    private func count(of set: CollectionGroup, _ counts: Counts) -> Int {
        let ids = Set(set.collectionIDs)
        return counts.postCollections.reduce(0) { $0 + ($1.isDisjoint(with: ids) ? 0 : 1) }
    }

    private var counts: Counts {
        var out = Counts()
        for row in rows {
            let sets = index.setIDs(for: row.item)
            if sets.isEmpty {
                if row.shareable { out.notShared += 1 }
                continue
            }
            out.shared += 1
            let collections = index.collectionIDs(for: row.item)
            for id in collections { out.byCollection[id, default: 0] += 1 }
            if !collections.isEmpty { out.postCollections.append(collections) }
        }
        return out
    }
}
