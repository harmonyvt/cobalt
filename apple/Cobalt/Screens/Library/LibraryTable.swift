import CobaltKit
import SwiftUI

// The table (CONTRACT-LIBRARY2 decision 13): on the iPad and Mac a real `Table` with sortable columns, on the
// iPhone a dense two-line list.

extension LibraryRow {
    /// The table's `kind` column sorts by this (galleries, photos, videos, webps).
    var kindRank: Int { kind.sortRank }
}

// MARK: - iPad and Mac: Table

/// Nine sortable columns (title, service, length, resolution, files, size, public, offline, date); the default sort is
/// date, newest first, and a header click sorts, again reverses. Below 860 pt of table width `service` and
/// `resolution` drop out (the title of a link save already names its service, and the detail shows the
/// resolution). The model sorts and filters (the server pages by date only, so a sort loads the whole library
/// first); the table only reports what the owner asked.
struct LibraryTable: View {
    let rows: [LibraryRow]
    @Bindable var controller: LibraryController
    let footer: LibraryFooter
    /// What is already shared, for the badges after the title.
    var shareIndex: ShareSetIndex = .empty

    @State private var width: CGFloat = 1000
    @State private var removing: MediaItem?

    private var library: LibraryModel { controller.library }

    /// Under this the two least useful columns go.
    static let fullWidth: CGFloat = 860

    private var wide: Bool { width >= Self.fullWidth }

    private var lastIDs: Set<String> { Set(rows.suffix(6).map(\.id)) }

    // MARK: sort mapping

    static func comparator(for sort: LibrarySort) -> KeyPathComparator<LibraryRow> {
        let order: SortOrder = sort.ascending ? .forward : .reverse
        switch sort.key {
        case .date: return KeyPathComparator(\.date, order: order)
        case .title: return KeyPathComparator(\.title, order: order)
        case .length: return KeyPathComparator(\.length, order: order)
        case .size: return KeyPathComparator(\.bytes, order: order)
        case .resolution: return KeyPathComparator(\.pixels, order: order)
        case .files: return KeyPathComparator(\.fileCount, order: order)
        case .visibility: return KeyPathComparator(\.visibilityRank, order: order)
        case .offline: return KeyPathComparator(\.offline, order: order)
        case .kind: return KeyPathComparator(\.kindRank, order: order)
        }
    }

    static func sort(from comparator: KeyPathComparator<LibraryRow>) -> LibrarySort? {
        let path: PartialKeyPath<LibraryRow> = comparator.keyPath
        let key: LibrarySortKey
        if path == \LibraryRow.date { key = .date }
        else if path == \LibraryRow.title { key = .title }
        else if path == \LibraryRow.length { key = .length }
        else if path == \LibraryRow.bytes { key = .size }
        else if path == \LibraryRow.pixels { key = .resolution }
        else if path == \LibraryRow.fileCount { key = .files }
        else if path == \LibraryRow.visibilityRank { key = .visibility }
        else if path == \LibraryRow.offline { key = .offline }
        else if path == \LibraryRow.kindRank { key = .kind }
        else { return nil }
        return LibrarySort(key: key, ascending: comparator.order == .forward)
    }

    private var sortOrder: Binding<[KeyPathComparator<LibraryRow>]> {
        Binding(
            get: { [Self.comparator(for: library.sort)] },
            set: { new in
                if let first = new.first, let sort = Self.sort(from: first), sort != library.sort { library.sort = sort }
            })
    }

    // MARK: table

    var body: some View {
        // the picks' numbers, the same as the select pill's thumbnails
        let numbers = LibraryPickNumbers.of(rows, controller: controller)
        Table(rows, selection: $controller.selection, sortOrder: sortOrder) {
            TableColumn(Copy.Library2.colTitle, value: \.title) { row in
                HStack(spacing: 8) {
                    if controller.selecting, row.shareable {
                        // A click that only moves the inspector selection does not run `primaryAction`, so the tick
                        // itself toggles. It is not its own VoiceOver control; the cell carries `.isSelected`.
                        Button {
                            if controller.takeSwallowedTap() { return }
                            controller.togglePick(row)
                        } label: {
                            LibraryPickMark(ticked: controller.picked.contains(row.id), number: numbers[row.id])
                                .frame(width: 28, height: 28)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.borderless)
                        .accessibilityHidden(true)
                    }
                    LibraryThumb(row: row, side: 24, reload: controller.reload)
                    LibraryTitleText(row: row, size: 11.5, weight: .medium)
                    let share = shareIndex.status(for: row.item)
                    if share.isShared { SharedTileBadges(share: share) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                // hold a row while selecting to see its media, as on a tile
                .peekOnHold(row, controller: controller, enabled: controller.selecting)
                .onAppear { if lastIDs.contains(row.id) { controller.loadMoreIfNeeded() } }
                .accessibilityElement(children: .combine)
                .accessibilityLabel(LibraryRowCopy.a11yLabel(row))
                .accessibilityAddTraits(controller.selecting && controller.picked.contains(row.id) ? .isSelected : [])
            }
            .width(min: 150, ideal: 280)
            if controller.model.capabilities.gallery {
                TableColumn(Copy.Library2.colKind, value: \.kindRank) { row in
                    secondary(LibraryRowCopy.kind(row))
                }
                .width(min: 64, ideal: 88, max: 120)
            }
            if wide {
                TableColumn(Copy.Library2.colService, value: \.service) { row in
                    secondary(LibraryRowCopy.service(row))
                }
                .width(min: 56, ideal: 80, max: 120)
            }
            TableColumn(Copy.Library2.colLength, value: \.length) { row in
                secondary(LibraryRowCopy.length(row))
            }
            .width(min: 54, ideal: 70, max: 100)
            if wide {
                TableColumn(Copy.Library2.colResolution, value: \.pixels) { row in
                    secondary(LibraryRowCopy.resolution(row))
                }
                .width(min: 72, ideal: 92, max: 130)
            }
            TableColumn(Copy.Library2.colFiles, value: \.fileCount) { row in
                secondary(LibraryRowCopy.files(row))
            }
            .width(min: 80, ideal: 120, max: 180)
            TableColumn(Copy.Library2.colSize, value: \.bytes) { row in
                secondary(LibraryRowCopy.size(row))
            }
            .width(min: 56, ideal: 72, max: 100)
            TableColumn(Copy.Library2.colPublic, value: \.visibilityRank) { row in
                Label(LibraryRowCopy.visibility(row), systemImage: row.isPublic ? Symbol.Library.isPublic : Symbol.Library.isPrivate)
                    .font(CobaltType.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .width(min: 70, ideal: 84, max: 110)
            if controller.model.store.canKeep {
                TableColumn(Copy.Offline.column, value: \.offline) { row in
                    OfflineCell(item: row.item, model: controller.model)
                }
                .width(min: 78, ideal: 88, max: 110)
            }
            TableColumn(Copy.Library2.colDate, value: \.date) { row in
                secondary(Format.when(row.date, now: Date()))
            }
            .width(min: 90, ideal: 110, max: 150)
        }
        .contextMenu(forSelectionType: String.self) { ids in
            if !controller.selecting, let id = ids.first, let row = rows.first(where: { $0.id == id }) {
                LibraryMenuItems(row: row, controller: controller, selected: rows.filter { ids.contains($0.id) }) { removing = $0 }
            }
        } primaryAction: { ids in
            guard let id = ids.first else { return }
            if controller.selecting {
                if let row = rows.first(where: { $0.id == id }) { controller.togglePick(row) }
            } else if let row = rows.first(where: { $0.id == id }) {
                controller.open(row)
            }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            LibraryFooterView(state: footer) { controller.loadMoreAgain() }
        }
        .offlineRemoveConfirm($removing, model: controller.model)
        .refreshable { controller.pullToRefresh() }
        .accessibilityLabel(Copy.postsA11y)
    }

    private func secondary(_ text: String) -> some View {
        Text(text)
            .font(CobaltType.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.tail)
    }
}

// MARK: - iPhone: the dense two-line list

/// A 44 pt face at its aspect; line 1 the title with the `webp ×3` capsule and the link dot, line 2 `14.8 s ·
/// 720×1280 · 12.8 MB · today 21:04`. At accessibility sizes the picture goes above and the lines wrap.
struct LibraryListRow: View {
    let row: LibraryRow
    let model: AppModel
    let reload: Int
    var selecting = false
    var ticked = false
    /// The order it was picked in (the select pill's thumbnails carry the same number).
    var number: Int? = nil
    /// How many links (and collections) already hold the post.
    var share = ShareStatus()
    @Environment(\.dynamicTypeSize) private var typeSize

    private var stacked: Bool { typeSize.isAccessibilitySize }

    var body: some View {
        let meta = LibraryRowCopy.meta(row, now: Date(), withKind: model.capabilities.gallery)
        HStack(spacing: 10) {
            Group {
                if stacked {
                    VStack(alignment: .leading, spacing: 8) {
                        LibraryThumb(row: row, side: 64, reload: reload, maxPixel: 256)
                        VStack(alignment: .leading, spacing: 3) {
                            LibraryTitleText(row: row, size: 13).lineLimit(nil)
                            Text(meta).font(CobaltType.captionSmall).foregroundStyle(.secondary)
                            HStack(spacing: 6) {
                                LibraryRowBadges(row: row, model: model)
                                if share.isShared { SharedTileBadges(share: share) }
                            }
                        }
                    }
                } else {
                    HStack(spacing: 10) {
                        LibraryThumb(row: row, side: 44, reload: reload)
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 6) {
                                LibraryTitleText(row: row)
                                Spacer(minLength: 4)
                                if share.isShared { SharedTileBadges(share: share) }
                                LibraryRowBadges(row: row, model: model)
                            }
                            Text(meta)
                                .font(Font.cobalt(10.5, .regular, relativeTo: .caption2))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .minimumScaleFactor(0.8)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if selecting, row.shareable { LibraryPickMark(ticked: ticked, number: number) }
        }
        .opacity(selecting ? (row.shareable ? (ticked ? 1 : 0.7) : 0.35) : 1)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(minHeight: stacked ? nil : 44)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(LibraryRowCopy.a11yLabel(row))
        .accessibilityValue(OfflineMark(item: row.item, model: model).spoken.map { "\(meta), \($0)" } ?? meta)
        .accessibilityAddTraits(ticked ? [.isButton, .isSelected] : .isButton)
    }
}

struct LibraryList: View {
    let rows: [LibraryRow]
    let controller: LibraryController
    let footer: LibraryFooter
    var zoom: Namespace.ID?
    var shareIndex: ShareSetIndex = .empty
    @State private var removing: MediaItem?

    private var lastIDs: Set<String> { Set(rows.suffix(6).map(\.id)) }

    var body: some View {
        let numbers = LibraryPickNumbers.of(rows, controller: controller)
        ScrollViewReader { proxy in
            List {
                Section {
                    ForEach(rows) { row in
                        let selecting = controller.selecting
                        Button {
                            if selecting {
                                // the touch that ended a hold-to-peek is not a tick
                                if controller.takeSwallowedTap() { return }
                                withAnimation(Motion.rows) { controller.togglePick(row) }
                            } else {
                                controller.open(row)
                            }
                        } label: {
                            LibraryListRow(
                                row: row, model: controller.model, reload: controller.reload,
                                selecting: selecting, ticked: controller.picked.contains(row.id),
                                number: numbers[row.id], share: shareIndex.status(for: row.item))
                        }
                        .buttonStyle(.plain)
                        .peekOnHold(row, controller: controller, enabled: selecting)
                        .zoomSource(id: row.id, in: zoom)
                        .modifier(LibraryRowMenu(row: row, controller: controller, enabled: !selecting, removing: $removing))
                        .listRowBackground(controller.lit == row.id ? CobaltColor.focus.opacity(0.14) : nil)
                        .id(row.id)
                        .onAppear { if lastIDs.contains(row.id) { controller.loadMoreIfNeeded() } }
                    }
                } footer: {
                    LibraryFooterView(state: footer) { controller.loadMoreAgain() }
                }
            }
            #if os(iOS)
            .listStyle(.insetGrouped)
            #endif
            .offlineRemoveConfirm($removing, model: controller.model)
            .refreshable { controller.pullToRefresh() }
            .accessibilityLabel(Copy.postsA11y)
            .onChange(of: controller.reveal, initial: true) { _, request in
                guard let request else { return }
                Task {
                    try? await Task.sleep(for: .milliseconds(150))
                    guard rows.contains(where: { $0.id == request.id }) else { return }
                    withAnimation(Motion.card) { proxy.scrollTo(request.id, anchor: .center) }
                    withAnimation(Motion.card) { controller.light(request.id) }
                    controller.reveal = nil
                }
            }
        }
    }
}

/// The picks' numbers in tap order, for the rows on screen (the select pill numbers its thumbnails the same way).
enum LibraryPickNumbers {
    @MainActor
    static func of(_ rows: [LibraryRow], controller: LibraryController) -> [String: Int] {
        guard controller.selecting else { return [:] }
        return Dictionary(uniqueKeysWithValues: controller.pickedRows(rows).enumerated().map { ($1.id, $0 + 1) })
    }
}
