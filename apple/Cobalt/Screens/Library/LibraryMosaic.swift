import CobaltKit
import SwiftUI

/// What the footer under the tiles and rows says.
enum LibraryFooter: Equatable {
    case none, loading, failed
}

/// The footer: a spinner while pages load, or `couldn't load more.` with `try again`.
struct LibraryFooterView: View {
    let state: LibraryFooter
    let retry: () -> Void

    var body: some View {
        switch state {
        case .none:
            EmptyView()
        case .loading:
            ProgressView()
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .accessibilityHidden(true)
        case .failed:
            VStack(spacing: 8) {
                Text(Copy.Library2.loadMoreFailed)
                    .font(CobaltType.captionSmall)
                    .foregroundStyle(.secondary)
                Button(Copy.tryAgain, systemImage: Symbol.retry, action: retry)
                    .buttonStyle(.cobaltSecondary(fullWidth: false))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
        }
    }
}

/// The mosaic (CONTRACT-LIBRARY2 decision 12): a dense masonry of faces at their real aspect. `MasonryPlan` puts
/// each tile, newest first, into the currently shortest column; a new page only appends, so tiles never jump
/// while loading. One `LazyVStack` per column draws what is on screen, so hundreds of tiles cost what a screenful
/// does. The pictures decode off the main thread (`LibraryPictureLoader`), and the moving ones are the
/// animation budget's.
struct LibraryMosaic: View {
    let rows: [LibraryRow]
    let controller: LibraryController
    let tier: Tier
    let footer: LibraryFooter
    let skeleton: Bool
    var zoom: Namespace.ID?
    /// Which posts are already in links and collections (the tiles' badges).
    var shareIndex: ShareSetIndex = .empty
    /// The links and collections shelves over the tiles (the iPhone, not selecting or searching).
    var shelves: LibraryShelves?

    @State private var width: CGFloat = 0
    /// The shelves' height: the tiles start under it (the reveal and the animation budget add it).
    @State private var headerHeight: Double = 0
    @State private var viewport = ViewportBox()
    @State private var position = ScrollPosition()
    @State private var budget: AnimationBudget
    @State private var layoutCache = MosaicLayoutCache()
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.lifecycle) private var lifecycle
    @Environment(\.displayScale) private var displayScale
    @Environment(\.horizontalSizeClass) private var sizeClass

    private var gap: Double { tier == .compact ? 5 : 7 }
    private var margin: Double { tier == .compact ? 8 : 12 }
    private static let topInset: Double = 6

    /// Scroll viewport height and prefetch watermark, read without triggering SwiftUI invalidation.
    final class ViewportBox {
        var height: Double = 0
        var prefetchedHeadID: String?
        var prefetchedCount: Int = 0
        var prefetchedThrough: Int = -1
    }

    init(
        rows: [LibraryRow], controller: LibraryController, tier: Tier, footer: LibraryFooter, skeleton: Bool,
        zoom: Namespace.ID? = nil, shareIndex: ShareSetIndex = .empty, shelves: LibraryShelves? = nil
    ) {
        self.rows = rows
        self.controller = controller
        self.tier = tier
        self.footer = footer
        self.skeleton = skeleton
        self.zoom = zoom
        self.shareIndex = shareIndex
        self.shelves = shelves
        _budget = State(initialValue: AnimationBudget(limit: tier == .compact ? 4 : 8))
    }

    private var minTile: Double {
        if tier == .compact { return 108 }
        return Platform.isMac ? 160 : 150
    }

    /// Nine grey tiles at mixed aspects while the first page loads.
    private static let skeletonAspects: [Double] = [16 / 9, 9 / 16, 1, 9 / 16, 4 / 3, 9 / 16, 1, 16 / 9, 9 / 16]

    /// The plan and each column's tiles, made again only when the posts, their aspects, the width, gap, or column
    /// count changed. Fast-paths in O(1) when the `rows` array storage is identical (zero per-render `rows.map` work).
    private func layout(width: Double) -> MosaicLayout {
        let gap = self.gap
        let margin = self.margin
        let columns = MasonryPlan.duoColumns(
            width: width, minTile: minTile, gap: gap, margin: margin,
            accessibility: typeSize.isAccessibilitySize,
            isRegular: sizeClass == .regular || Platform.isMac)
        if let fast = layoutCache.fastHit(skeleton: skeleton, rows: rows, width: width, columns: columns, gap: gap) {
            return fast
        }
        let ids = skeleton ? [] : rows.map(\.id)
        let aspects = skeleton ? Self.skeletonAspects : rows.map(\.faceAspect)
        let key = MosaicLayout.Key(
            skeleton: skeleton, ids: ids, aspects: aspects, width: width, columns: columns, gap: gap)
        if let cached = layoutCache.layout, cached.key == key {
            layoutCache.record(rows: rows, layout: cached)
            return cached
        }
        let plan = MasonryPlan.make(aspects: key.aspects, width: width, columns: columns, gap: gap, margin: margin)
        // slots come in index order, so each column's tiles stay top to bottom
        var byColumn = [[MosaicTile]](repeating: [], count: plan.columns)
        for slot in plan.slots where byColumn.indices.contains(slot.column) {
            if skeleton {
                byColumn[slot.column].append(MosaicTile(id: "ghost-\(slot.index)", slot: slot))
            } else if key.ids.indices.contains(slot.index) {
                byColumn[slot.column].append(MosaicTile(id: key.ids[slot.index], slot: slot))
            }
        }
        let layout = MosaicLayout(key: key, plan: plan, columns: byColumn)
        layoutCache.record(rows: rows, layout: layout)
        return layout
    }

    var body: some View {
        let layout = self.layout(width: Double(max(width, 1)))
        let plan = layout.plan
        // the picks' numbers, the same as the select pill's thumbnails
        let numbers = LibraryPickNumbers.of(rows, controller: controller)
        ScrollView {
            VStack(spacing: 0) {
                if let shelves {
                    shelves
                        .onGeometryChange(for: Double.self) { Double($0.size.height) } action: { headerHeight = $0 }
                }
                // The columns are an overlay of a spacer that only has the plan's height. A row of fixed-width
                // columns as the content itself reports its own width as the content's minimum, and that width is
                // measured from the very column it sizes: on the Mac the split view's detail column read it as its
                // minimum width, changed it every layout pass and AppKit threw "more Update Constraints passes than
                // there are views". The spacer's width is flexible, so the minimum no longer depends on the plan.
                //
                // No tiles until the scroll view has told its width (8.17). Its first pass has none: a plan for a width of
                // 1 gave every tile a height of 0, so each lazy column found hundreds of them "on screen" and built and
                // measured every one, then threw them all away when the real width came in a moment later (the 914 ms
                // frame on the switch to the library: AttributeGraph and LayoutProxy.dimensions). The width arrives in the
                // same transaction (`onGeometryChange` below), so the first frame drawn already has the real tiles.
                Color.clear
                    .frame(height: hasWidth ? plan.height + Self.topInset : 0)
                    .overlay(alignment: .topLeading) {
                        // one band of light over all the grey tiles at once (one clock, not one per tile)
                        if hasWidth { columns(layout, numbers: numbers).skeletonShimmer(skeleton) }
                    }
                if !skeleton { LibraryFooterView(state: footer) { controller.loadMoreAgain() } }
                Color.clear.frame(height: 24)
            }
        }
        .scrollPosition($position)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { viewport.height = Double($0) }
        // Quantized to 48 pt buckets so fast flings don't wake the animation budget on every single scroll pixel.
        .onScrollGeometryChange(for: Int.self) {
            Int((Double($0.contentOffset.y + $0.containerSize.height / 2) / 48).rounded())
        } action: { _, bucket in
            budget.setCenter(Double(bucket) * 48)
        }
        .onScrollPhaseChange { _, phase in budget.setScrolling(phase != .idle) }
        .onChange(of: reduceMotion, initial: true) { budget.setEnvironment(reduceMotion: reduceMotion, sceneActive: lifecycle.isForeground) }
        .onChange(of: lifecycle.phase) { budget.setEnvironment(reduceMotion: reduceMotion, sceneActive: lifecycle.isForeground) }
        .onChange(of: controller.reveal, initial: true) { _, request in
            // a moment for the first layout (a tab just opened by "open in library" has no width yet)
            guard let request else { return }
            Task {
                try? await Task.sleep(for: .milliseconds(150))
                scrollTo(request.id)
            }
        }
        .task { budget.start() }
        .onDisappear { budget.stop() }
        .refreshable { controller.pullToRefresh() }
        .accessibilityLabel(Copy.postsA11y)
    }

    /// Whether the scroll view's width is known (and leaves room for a column): before it, the plan has no real sizes.
    private var hasWidth: Bool { width > 0 && Double(width) > 2 * margin }

    /// The columns: one `LazyVStack` each, so only the tiles on screen are built and measured.
    private func columns(_ layout: MosaicLayout, numbers: [String: Int]) -> some View {
        let plan = layout.plan
        let gap = self.gap
        return HStack(alignment: .top, spacing: gap) {
            ForEach(0..<plan.columns, id: \.self) { column in
                LazyVStack(spacing: gap) {
                    ForEach(layout.columns.indices.contains(column) ? layout.columns[column] : []) { tile in
                        tileView(tile.slot, plan: plan, numbers: numbers)
                    }
                }
                .frame(width: plan.columnWidth)
            }
        }
        .padding(.horizontal, margin)
        .padding(.top, Self.topInset)
        .frame(maxHeight: .infinity, alignment: .top)
    }

    @ViewBuilder
    private func tileView(_ slot: MasonryPlan.Slot, plan: MasonryPlan, numbers: [String: Int]) -> some View {
        let size = CGSize(width: plan.columnWidth, height: slot.height)
        if skeleton {
            LibraryGhostTile(size: size, index: slot.index)
        } else if rows.indices.contains(slot.index) {
            let row = rows[slot.index]
            let maxPixel = Self.bucket(max(size.width, size.height) * Double(displayScale))
            LibraryTile(
                row: row, index: slot.index, size: size, centerY: top + slot.y + slot.height / 2,
                maxPixel: maxPixel, showsCaption: true, lit: controller.lit == row.id,
                selected: !controller.compact && controller.selection == row.id,
                selecting: controller.selecting, holdOpens: controller.holdOpens, ticked: controller.picked.contains(row.id),
                pickNumber: numbers[row.id],
                reload: controller.reload,
                share: shareIndex.status(for: row.item), controller: controller, budget: budget, zoom: zoom,
                nearEnd: slot.index >= rows.count - 6)
            .equatable()
            .onAppear { prefetchAhead(from: slot.index, plan: plan) }
        }
    }

    /// Warms thumbnails for the next few tiles below the viewport at `.utility` priority so fast scrolling hits RAM.
    private func prefetchAhead(from index: Int, plan: MasonryPlan) {
        guard !skeleton, !rows.isEmpty else { return }
        let headID = rows.first?.id
        if viewport.prefetchedHeadID != headID || viewport.prefetchedCount != rows.count {
            viewport.prefetchedHeadID = headID
            viewport.prefetchedCount = rows.count
            viewport.prefetchedThrough = -1
        }
        let targetEnd = min(rows.count - 1, index + plan.columns * 2)
        guard targetEnd > viewport.prefetchedThrough else { return }
        let start = max(index + 1, viewport.prefetchedThrough + 1)
        guard start <= targetEnd else { return }
        viewport.prefetchedThrough = targetEnd
        let scale = Double(displayScale)
        var requests: [(source: LibraryPictureSource, maxPixel: Int)] = []
        requests.reserveCapacity(targetEnd - start + 1)
        for i in start...targetEnd where rows.indices.contains(i) && plan.slots.indices.contains(i) {
            guard let source = FaceChain.sources(for: rows[i].item).first else { continue }
            let slot = plan.slots[i]
            let px = Self.bucket(max(plan.columnWidth, slot.height) * scale)
            requests.append((source, px))
        }
        guard !requests.isEmpty else { return }
        Task(priority: .utility) {
            await LibraryPictureLoader.shared.prefetch(requests)
        }
    }

    /// Scrolls the tile to the centre of the viewport and lights it (decision 17).
    private func scrollTo(_ id: String) {
        let plan = layout(width: Double(max(width, 1))).plan
        guard let index = rows.firstIndex(where: { $0.id == id }), let slot = plan.slots.first(where: { $0.index == index }) else { return }
        let centre = top + slot.y + slot.height / 2
        let target = max(0, centre - viewport.height / 2)
        withAnimation(reduceMotion ? nil : Motion.card) { position.scrollTo(y: target) }
        controller.light(id)
        controller.reveal = nil
    }

    /// Where the first tile starts in the scroll content: under the shelves, when they show.
    private var top: Double { Self.topInset + (shelves == nil ? 0 : headerHeight) }

    /// A long side a thumbnail is decoded at: 64 pt steps, 128 at least, 768 at most.
    private static func bucket(_ pixels: Double) -> Int {
        let stepped = (pixels / 64).rounded(.up) * 64
        return Int(min(768, max(128, stepped)))
    }
}

/// A slot keyed by its post, not its position: a new save at the top or another sort shifts every index, and a tile
/// keyed by index handed its picture, its failed state and its delete confirm to another post.
private struct MosaicTile: Identifiable {
    let id: String
    let slot: MasonryPlan.Slot
}

/// The mosaic's plan and its columns' tiles, with what they were made from.
private struct MosaicLayout {
    struct Key: Equatable {
        var skeleton: Bool
        var ids: [String]
        var aspects: [Double]
        var width: Double
        var columns: Int
        var gap: Double
    }
    let key: Key
    let plan: MasonryPlan
    let columns: [[MosaicTile]]
}

/// Holds the last layout across body passes (not observed: reading it never redraws).
/// Keeps a reference to the last `rows` array so unchanged CoW buffers hit in O(1) without allocating `ids`/`aspects`.
private final class MosaicLayoutCache {
    var layout: MosaicLayout?
    private var lastRows: [LibraryRow] = []
    private var hasRows = false

    func fastHit(skeleton: Bool, rows: [LibraryRow], width: Double, columns: Int, gap: Double) -> MosaicLayout? {
        guard let layout else { return nil }
        guard layout.key.skeleton == skeleton,
              layout.key.width == width,
              layout.key.columns == columns,
              layout.key.gap == gap
        else { return nil }
        if skeleton { return layout }
        guard hasRows, rows.count == lastRows.count else { return nil }
        let sameStorage = rows.withUnsafeBufferPointer { a in
            lastRows.withUnsafeBufferPointer { b in a.baseAddress == b.baseAddress }
        }
        return sameStorage ? layout : nil
    }

    func record(rows: [LibraryRow], layout: MosaicLayout) {
        self.layout = layout
        self.lastRows = layout.key.skeleton ? [] : rows
        self.hasRows = !layout.key.skeleton
    }
}
