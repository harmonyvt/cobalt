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

/// A row of chips under the kind chips: `not shared` and `shared` with how many posts each holds, then one violet chip
/// per set and one amber chip per collection. A tap filters the library (with the kind, the search and `show`); a tap on the chip that is on
/// turns it off. Only on a server that makes share links, once there is at least one.
struct LibraryShareChips: View {
    let model: AppModel
    /// The posts before this filter (the kind chip, the search and `show` already applied), for the counts.
    let rows: [LibraryRow]
    let index: ShareSetIndex
    @Binding var filter: LibraryShareFilter

    private var store: ShareSetStore { model.shareSets }

    var body: some View {
        let counts = counts
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                chip(.notShared, title: Copy.Library2.notShared, count: counts.notShared, symbol: nil, tint: nil)
                chip(.shared, title: Copy.Library2.sharedChip, count: counts.shared, symbol: Symbol.link, tint: CobaltColor.sharedInk)
                if model.capabilities.shareGroups {
                    ForEach(store.groups) { set in
                        chip(
                            .set(set.id), title: set.name, count: count(of: set, counts),
                            symbol: Symbol.collectionSet, tint: CobaltColor.collectionSet)
                    }
                }
                if model.capabilities.shareCollections {
                    ForEach(store.collections) { collection in
                        chip(
                            .collection(collection.id), title: collection.name, count: counts.byCollection[collection.id] ?? 0,
                            symbol: Symbol.collection, tint: CobaltColor.collection)
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 6)
        }
        .background(.bar)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Copy.Library2.shareFilter)
        .haptic(.selection, trigger: filter)
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

    private func chip(_ value: LibraryShareFilter, title: String, count: Int, symbol: String?, tint: Color?) -> some View {
        let selected = filter == value
        return Button {
            filter = selected ? .all : value
        } label: {
            HStack(spacing: 5) {
                if let symbol {
                    Image(systemName: symbol)
                        .symbolVariant(value == .shared || symbol == Symbol.collectionSet ? .none : .fill)
                        .font(.system(size: 10, weight: .bold))
                }
                Text(Copy.Library2.shareChip(title, count: count))
                    .font(Font.cobalt(11.5, selected ? .semibold : .regular, relativeTo: .caption))
                    .monospacedDigit()
                    .lineLimit(1)
                    .fixedSize()
            }
            .foregroundStyle(selected ? CobaltColor.onText : (tint ?? Color.primary))
            .padding(.horizontal, 12)
            .frame(minHeight: 30)
            .background(Capsule().fill(selected ? CobaltColor.text : CobaltColor.elevated))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityValue("\(count)")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
