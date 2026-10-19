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
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.displayScale) private var displayScale

    private static let gap: Double = 6
    private static let margin: Double = 12
    private static let topInset: Double = 6

    /// The scroll viewport's height, read when a reveal scrolls (not observed).
    final class ViewportBox { var height: Double = 0 }

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

    private var aspects: [Double] {
        skeleton ? Self.skeletonAspects : rows.map(\.faceAspect)
    }

    /// Nine grey tiles at mixed aspects while the first page loads.
    private static let skeletonAspects: [Double] = [16 / 9, 9 / 16, 1, 9 / 16, 4 / 3, 9 / 16, 1, 16 / 9, 9 / 16]

    private func plan(width: Double) -> MasonryPlan {
        let columns = MasonryPlan.columns(
            width: width, minTile: minTile, gap: Self.gap, margin: Self.margin, accessibility: typeSize.isAccessibilitySize)
        return MasonryPlan.make(aspects: aspects, width: width, columns: columns, gap: Self.gap, margin: Self.margin)
    }

    var body: some View {
        let plan = plan(width: Double(max(width, 1)))
        let byColumn = Dictionary(grouping: plan.slots, by: \.column)
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
                Color.clear
                    .frame(height: plan.height + Self.topInset)
                    .overlay(alignment: .topLeading) {
                        HStack(alignment: .top, spacing: Self.gap) {
                            ForEach(0..<plan.columns, id: \.self) { column in
                                LazyVStack(spacing: Self.gap) {
                                    ForEach(tiles(byColumn[column] ?? [])) { tile in
                                        tileView(tile.slot, plan: plan, numbers: numbers)
                                    }
                                }
                                .frame(width: plan.columnWidth)
                            }
                        }
                        .padding(.horizontal, Self.margin)
                        .padding(.top, Self.topInset)
                        .frame(maxHeight: .infinity, alignment: .top)
                    }
                if !skeleton { LibraryFooterView(state: footer) { Task { await controller.library.loadMore() } } }
                Color.clear.frame(height: 24)
            }
        }
        .scrollPosition($position)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { viewport.height = Double($0) }
        .onScrollGeometryChange(for: Double.self) { Double($0.contentOffset.y + $0.containerSize.height / 2) } action: { _, center in
            budget.setCenter(center)
        }
        .onScrollPhaseChange { _, phase in budget.setScrolling(phase != .idle) }
        .onChange(of: reduceMotion, initial: true) { budget.setEnvironment(reduceMotion: reduceMotion, sceneActive: scenePhase == .active) }
        .onChange(of: scenePhase) { budget.setEnvironment(reduceMotion: reduceMotion, sceneActive: scenePhase == .active) }
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

    /// A column's slots keyed by their post, not their position: a new save at the top or another sort shifts every
    /// index, and a tile keyed by index handed its picture, its failed state and its delete confirm to another post.
    private func tiles(_ slots: [MasonryPlan.Slot]) -> [MosaicTile] {
        slots.compactMap { slot in
            if skeleton { return MosaicTile(id: "ghost-\(slot.index)", slot: slot) }
            guard rows.indices.contains(slot.index) else { return nil }
            return MosaicTile(id: rows[slot.index].id, slot: slot)
        }
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
                selecting: controller.selecting, ticked: controller.picked.contains(row.id),
                pickNumber: numbers[row.id],
                reload: controller.reload,
                share: shareIndex.status(for: row.item), controller: controller, budget: budget, zoom: zoom,
                nearEnd: slot.index >= rows.count - 6)
            .equatable()
        }
    }

    /// Scrolls the tile to the centre of the viewport and lights it (decision 17).
    private func scrollTo(_ id: String) {
        let plan = plan(width: Double(max(width, 1)))
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

private struct MosaicTile: Identifiable {
    let id: String
    let slot: MasonryPlan.Slot
}
