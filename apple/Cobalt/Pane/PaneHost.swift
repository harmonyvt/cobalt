import CobaltKit
import SwiftUI
import UniformTypeIdentifiers
#if os(iOS)
import UIKit
#endif

/// Wraps the window's tab content (the iPhone and iPad tab views, the Mac's detail) and lays out the pane for the
/// window's `PanePlacement` (apple/CONTRACT-PANE.md section 3):
///
/// - two screens: the pane is the leading (wide) or top (tall) screen, a hairline on the hinge; spanned, the page has
///   both screens (media on one, details on the other);
/// - column: the pane is a 440 / 400 pt leading column with a hairline divider; spanned, the whole area, wide shape;
/// - compact: a sheet (`.large`, drag indicator). On the iPhone that is all: there is no span (it was a full-screen cover
///   stacked over the sheet), and a pane still spanned when the window turns compact goes back to `screen`. The Mac's
///   sheet grows when spanned.
///
/// The tab keeps its room while the pane is spanned (it is only covered), so nothing behind reflows. The pane slides in
/// from the leading (top) edge with the `Motion` spring, or cross-fades under Reduce Motion. The route is saved per
/// scene with `@SceneStorage("pane")`. A drag held 0.6 s over the leading edge of a hidden pane brings its last item
/// back. The bar is `PaneBarAccessory` (applied to the tab view on iOS, here on the Mac).
///
/// What a page keeps across shape changes: inline, screen <-> span keeps the page's view (only `\.paneShape` changes, and
/// `PanePage` lays its hero out anew). Inline <-> compact (a rotation, a resize, folding) is a different presentation, so
/// SwiftUI rebuilds the page there; one page at a time is drawn (a stream never plays twice). Whatever must outlive that (a player and its playhead, a chat connection) lives in
/// `pane.keepAlive(_:for:make:)`, which keeps it while the pane holds the item, whatever it is drawn in.
struct PaneHost<Content: View>: View {
    let model: AppModel
    /// A drag is over the window (the shell's drop target): the leading edge listens for a held drag.
    var dragging: Bool
    let content: Content

    @Environment(Pane.self) private var pane
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.lifecycle) private var lifecycle
    @Environment(\.horizontalSizeClass) private var sizeClass
    @SceneStorage("pane") private var saved: Data?
    @State private var size: CGSize = .zero
    @State private var reservedRegions: DuoReservedRegions = .empty
    @State private var edgeTargeted = false
    /// Work waiting for the compact sheet to finish going down (`PaneAfterDismiss`).
    @State private var afterDismiss = PaneAfterDismiss()

    init(model: AppModel, dragging: Bool = false, @ViewBuilder content: () -> Content) {
        self.model = model
        self.dragging = dragging
        self.content = content()
    }

    private var measured: Bool { size.width > 0 && size.height > 0 }

    /// Resolves placement from size class, window size, and live iOS 27.1+ `ReservedRegion(.division)`.
    ///
    /// In the background iOS lays the window out again at other sizes for the app switcher's snapshots. The placement the
    /// owner left stays meanwhile: a flip to `.compact` and back closed and reopened the pane (and the library's select
    /// actions with it), a 0.5-1 s main-thread stall on every trip away in the 8.40 sessions. Back in front it is measured
    /// again, so a fold made while away still lands.
    private var placement: PanePlacement {
        guard measured, lifecycle.phase != .background else { return pane.placement }
        return PanePlacement.resolve(
            size: size,
            isRegular: sizeClass == .regular,
            isMac: Platform.isMac,
            displayFeatureFrame: reservedRegions.activeDivision)
    }

    /// The pane is drawn beside (or over) the tab, not in a sheet.
    private var inline: Bool { measured && pane.isVisible && placement != .compact }

    var body: some View {
        let placement = self.placement
        let inline = self.inline
        let spanned = pane.state == .span
        // The tab stays in its own un-animated layout slot, anchored to its trailing (or bottom) edge, so opening or
        // closing the pane resizes `UITabBarController` / `UINavigationController` in a single atomic pass. Animating
        // the tab's frame across 60 fps caused subpixel trailing-edge jitter that made iOS 27 Duo's right chrome rail
        // repeatedly detach and re-dock the navigation bar buttons on every frame. The pane and seam animate in an
        // overlay above the tab so the pane still slides smoothly from the leading/top edge and spans cleanly over it.
        ZStack(alignment: .topLeading) {
            PaneTabLayout(placement: placement, hasPane: inline) {
                content
                    .accessibilityHidden(inline && spanned)
            }
            PaneOverlayLayout(placement: placement, spanned: spanned) {
                if inline, let item = pane.item {
                    PaneChrome(model: model, item: item, shape: inlineShape(placement, spanned: spanned),
                               hinge: inlineHinge(placement, spanned: spanned))
                        .layoutValue(key: PaneRoleKey.self, value: .pane)
                        .accessibilitySortPriority(1)            // reading order: the pane first
                        .transition(transition(placement))
                }
                if inline, showsSeam(placement, spanned: spanned) {
                    PaneSeam(queue: model.queue, activity: model.activity, axis: seamAxis(placement), showingJobID: showingJobID)
                        .layoutValue(key: PaneRoleKey.self, value: .seam)
                        .transition(.opacity)
                }
            }
            .accessibilitySortPriority(1)
            .motion(Motion.pane, value: LayoutKey(inline: inline, state: pane.state, placement: placement))
        }
        .cobaltPage()
        .hapticChange(.impact(weight: .light), trigger: inline ? placement.name : "off") { old, new in
            old != "off" && new != "off"                    // a posture change settling the pane somewhere new
        }
        // Measured as if the keyboard were down: `.onGeometryChange` must sit INSIDE `.ignoresSafeArea(.keyboard)`
        // because `.ignoresSafeArea` only expands its child and reports the keyboard-shrunk size outward. A Duo open
        // wide (about 951 x 669) less a keyboard falls under `phoneWideMinHeight`, and a Duo open tall less a keyboard
        // falls under `height > width`, which flipped placement to `.compact` and threw the pane up as a sheet when
        // typing in twitch chat. The window only changes shape on a fold, a rotation or a resize.
        .background {
            Color.clear
                .onGeometryChange(for: PaneHostGeometry.self) { proxy in
                    PaneHostGeometry(size: proxy.size, regions: DuoReservedRegions.readCompat(from: proxy))
                } action: { measuredGeometry in
                    size = measuredGeometry.size
                    reservedRegions = measuredGeometry.regions
                    pane.measure(measuredGeometry.size)
                }
                #if os(iOS)
                .ignoresSafeArea(.keyboard)
                #endif
        }
        .onChange(of: placement, initial: true) { _, now in if measured { pane.place(now) } }
        .onAppear {
            #if DEBUG
            // `-paneReset YES` (UI tests): start with no saved pane, so one test's pane is not the next one's
            if UserDefaults.standard.bool(forKey: "paneReset") {
                saved = nil
                pane.restoreOnce(nil)
                return
            }
            #endif
            pane.restoreOnce(saved)
        }
        .onChange(of: pane.machine.saved) { _, now in saved = now.encoded() }
        .onChange(of: sheetShown.wrappedValue, initial: true) { _, up in afterDismiss.sheetIsUp = up }
        .sheet(isPresented: sheetShown, onDismiss: { afterDismiss.sheetDidDismiss() }) { compactSheet }
        #if os(iOS)
        // no span on one narrow screen (the cover stacked over the sheet): a pane still spanned there goes back to screen
        .onChange(of: pane.state, initial: true) { _, state in
            if state == .span, measured, placement == .compact { pane.unspan() }
        }
        .onChange(of: placement) { _, now in
            if now == .compact, measured, pane.state == .span { pane.unspan() }
        }
        #endif
        .overlay(alignment: edgeAlignment(placement)) { edgeStrip(placement) }
        #if os(macOS)
        .modifier(PaneBarAccessory(model: model))
        #endif
        .environment(\.paneOffline, Self.isOffline(model))
        .environment(\.paneAfterDismiss, afterDismiss)
        .environment(\.mediaDetailModel, model)
    }

    /// The server can't be reached. DEBUG: `-previewPaneOffline YES` says so over the preview data (simulator evidence of the
    /// grid's offline words; the previews have no way to lose the network).
    static func isOffline(_ model: AppModel) -> Bool {
        #if DEBUG
        if UserDefaults.standard.bool(forKey: "previewPaneOffline") { return true }
        #endif
        return model.capabilities.kind == .unreachable
    }

    // MARK: inline

    private func inlineShape(_ placement: PanePlacement, spanned: Bool) -> PaneShape {
        switch placement {
        case .twoScreens(let axis, _): spanned ? .split(.media) : (axis == .vertical ? .tall : .wide)
        case .column: spanned ? .wide : .tall
        case .compact: .tall
        }
    }

    private func inlineHinge(_ placement: PanePlacement, spanned: Bool) -> PaneHinge? {
        guard spanned, case .twoScreens(let axis, let hinge) = placement else { return nil }
        return PaneHinge(axis: axis, position: hinge)
    }

    /// The hairline is on the hinge of two screens (spanned or not) and beside a column; a spanned column has none.
    private func showsSeam(_ placement: PanePlacement, spanned: Bool) -> Bool {
        if case .column = placement { return !spanned }
        return true
    }

    private func seamAxis(_ placement: PanePlacement) -> PanePlacement.Axis {
        if case .twoScreens(let axis, _) = placement { return axis }
        return .vertical
    }

    private var showingJobID: UUID? {
        switch pane.item {
        case .save(let id), .job(let id): return UUID(uuidString: id)
        default: return nil
        }
    }

    private func transition(_ placement: PanePlacement) -> AnyTransition {
        if reduceMotion { return .opacity }
        if case .twoScreens(axis: .horizontal, hinge: _) = placement { return .move(edge: .top) }
        return .move(edge: .leading)
    }

    // MARK: compact

    /// The compact sheet is up while the pane is visible on one narrow screen, and no other sheet is (`.coversPane`): a
    /// pane opened while the queue, a paste review or a title sheet is up waits for it to finish going, then presents,
    /// so the pane is never `screen` with nothing on screen.
    private var sheetShown: Binding<Bool> {
        Binding(
            get: { measured && placement == .compact && pane.isVisible && !pane.isCovered },
            set: { shown in
                // swiped down: hide (a running item goes to the bar). A posture change that took the sheet away is not
                // a close (the pane is drawn inline now), nor is another sheet coming up over the window.
                if !shown, pane.isVisible, placement == .compact, !pane.isCovered { pane.close() }
            })
    }

    @ViewBuilder
    private var compactSheet: some View {
        PaneCompactSheet(model: model)
            .environment(pane)
            .environment(\.paneOffline, Self.isOffline(model))
            .environment(\.paneAfterDismiss, afterDismiss)
            .environment(\.mediaDetailModel, model)
            .cobaltRoot(model: model)
    }

    // MARK: the leading edge, while a drag is over the window

    private func edgeAlignment(_ placement: PanePlacement) -> Alignment {
        if case .twoScreens(axis: .horizontal, hinge: _) = placement { return .top }
        return .leading
    }

    @ViewBuilder
    private func edgeStrip(_ placement: PanePlacement) -> some View {
        if dragging || edgeTargeted, placement != .compact, measured, !pane.isVisible, pane.item != nil {
            let horizontal = edgeAlignment(placement) == .top
            Color.clear
                .frame(width: horizontal ? nil : 28, height: horizontal ? 28 : nil)
                .contentShape(.rect)
                .onDrop(of: [UTType.item], isTargeted: $edgeTargeted) { _ in false }
                .task(id: edgeTargeted) {
                    guard edgeTargeted else { return }
                    try? await Task.sleep(for: .milliseconds(600))
                    if edgeTargeted, !Task.isCancelled { pane.reveal() }
                }
                .accessibilityHidden(true)
        }
    }
}

/// Measured window geometry + active hardware reserved regions (`ReservedRegion(.division)`).
private struct PaneHostGeometry: Equatable {
    var size: CGSize
    var regions: DuoReservedRegions
}

/// What the layout animation follows.
private struct LayoutKey: Equatable {
    var inline: Bool
    var state: PaneState
    var placement: PanePlacement
}

/// The pane in a sheet on one narrow screen. On the iPhone and a narrow iPad window that is the whole pane (no span, so no
/// cover over the sheet); on the Mac the sheet itself grows when spanned.
private struct PaneCompactSheet: View {
    let model: AppModel
    @Environment(Pane.self) private var pane
    /// The detent a resizable item (`PaneItem.compactSheet`) is at: it opens at `.medium`, and is `.medium` again whenever
    /// another resizable item takes the sheet. A fresh sheet (presented anew) starts here too.
    @State private var detent: PresentationDetent = .medium

    private var resizable: Bool { pane.item?.compactSheet == .resizable }

    var body: some View {
        Group {
            #if os(iOS)
            if let item = pane.item {
                PaneChrome(model: model, item: item, shape: .tall)
            }
            #else
            if let item = pane.item {
                PaneChrome(model: model, item: item, shape: pane.state == .span ? .wide : .tall)
                    .frame(minWidth: pane.state == .span ? 720 : 420, idealWidth: pane.state == .span ? 900 : 460,
                           minHeight: 520, idealHeight: 640)
            }
            #endif
        }
        .presentationDetents(resizable ? [.medium, .large] : [.large], selection: resizable ? $detent : .constant(.large))
        // resizable: the grid behind the sheet stays tappable at `.medium` (ticks update live in the sheet)
        .presentationBackgroundInteraction(resizable ? .enabled(upThrough: .medium) : .automatic)
        .presentationDragIndicator(.visible)
        .onChange(of: pane.item) { _, _ in detent = .medium }
        // a pushed editor with unsaved changes (`.paneHoldsClose`): no swipe down
        .interactiveDismissDisabled(pane.holdsClose)
    }
}

extension AppModel {
    /// The server can't be reached (`PaneHost.isOffline`): what `\.paneOffline` carries into a page.
    var serverIsAway: Bool { PaneHost<EmptyView>.isOffline(self) }
}

// MARK: - after the sheet

/// Work that must wait for the compact sheet to be gone before it presents something of its own (the library's share sheet
/// and its link picker, the confirm of hiding): a sheet cannot be presented from under another. `PaneHost` owns one and
/// reads `onDismiss` of its sheet, so the work runs the moment the sheet has really finished going down, not after a guessed
/// delay. Where no sheet is up the work runs at once.
///
///     afterDismiss.run { controller.addPicksToLink(picks) }   // then close the pane
@MainActor
final class PaneAfterDismiss {
    /// The compact sheet is up (set by `PaneHost`).
    var sheetIsUp = false
    private var pending: [@MainActor () -> Void] = []

    /// Queues `work` for the sheet's dismissal; runs it now when no sheet is up. Call before closing the pane.
    func run(_ work: @escaping @MainActor () -> Void) {
        if sheetIsUp { pending.append(work) } else { work() }
    }

    /// The sheet is gone (`sheet(isPresented:onDismiss:)`): promotes the queued work, in order.
    func sheetDidDismiss() {
        let queued = pending
        pending = []
        for work in queued { work() }
    }
}

extension EnvironmentValues {
    /// The pane's after-the-sheet queue; nil outside a `PaneHost` (previews), where work runs at once.
    @Entry var paneAfterDismiss: PaneAfterDismiss? = nil
    /// The model for `MediaDetailRoute`'s destination (`.mediaDetailDestination()`), set by the window's `PaneHost`.
    @Entry var mediaDetailModel: AppModel? = nil
}

// MARK: layout

private enum PaneRole: Sendable { case pane, seam }

private struct PaneRoleKey: LayoutValueKey {
    static let defaultValue: PaneRole = .pane
}

/// Places the tab alone, un-animated and anchored to its stationary edge (trailing for a vertical hinge or column,
/// bottom for a horizontal hinge). The tab always stays the sole subview here, so folding, unfolding and opening the
/// pane never rebuild it (its navigation stacks, scroll and selection survive).
private struct PaneTabLayout: Layout {
    var placement: PanePlacement
    var hasPane: Bool

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        proposal.replacingUnspecifiedDimensions()
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let tabView = subviews.first else { return }
        var size = bounds.size
        if hasPane {
            switch placement {
            case .twoScreens(axis: .vertical, hinge: let hinge):
                size.width = bounds.width - min(max(hinge, 0), bounds.width)
            case .twoScreens(axis: .horizontal, hinge: let hinge):
                size.height = bounds.height - min(max(hinge, 0), bounds.height)
            case .column(let width):
                size.width = bounds.width - min(width, bounds.width)
            case .compact:
                break
            }
        }
        switch placement {
        case .twoScreens(axis: .horizontal, hinge: _):
            tabView.place(at: CGPoint(x: bounds.minX, y: bounds.maxY), anchor: .bottomLeading, proposal: ProposedViewSize(size))
        case .twoScreens(axis: .vertical, hinge: _), .column:
            tabView.place(at: CGPoint(x: bounds.maxX, y: bounds.minY), anchor: .topTrailing, proposal: ProposedViewSize(size))
        case .compact:
            tabView.place(at: bounds.origin, proposal: ProposedViewSize(size))
        }
    }
}

/// Places the pane and the hairline over the leading (or top) half of `PaneHost`, or across the whole host when spanned.
private struct PaneOverlayLayout: Layout {
    var placement: PanePlacement
    var spanned: Bool

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        proposal.replacingUnspecifiedDimensions()
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard !subviews.isEmpty else { return }
        var paneRect = bounds
        // the line: its centre and whether it runs top to bottom
        var seam: (center: CGPoint, vertical: Bool, length: CGFloat)?

        switch placement {
        case .twoScreens(axis: .vertical, hinge: let hinge):
            let x = min(max(hinge, 0), bounds.width)
            paneRect = CGRect(x: bounds.minX, y: bounds.minY, width: x, height: bounds.height)
            seam = (CGPoint(x: bounds.minX + x, y: bounds.midY), true, bounds.height)
        case .twoScreens(axis: .horizontal, hinge: let hinge):
            let y = min(max(hinge, 0), bounds.height)
            paneRect = CGRect(x: bounds.minX, y: bounds.minY, width: bounds.width, height: y)
            seam = (CGPoint(x: bounds.midX, y: bounds.minY + y), false, bounds.width)
        case .column(let width):
            let w = min(width, bounds.width)
            paneRect = CGRect(x: bounds.minX, y: bounds.minY, width: w, height: bounds.height)
            seam = spanned ? nil : (CGPoint(x: bounds.minX + w, y: bounds.midY), true, bounds.height)
        case .compact:
            break
        }
        // spanned: the page has the whole area; the tab keeps its room underneath, covered
        if spanned { paneRect = bounds }

        for subview in subviews {
            switch subview[PaneRoleKey.self] {
            case .pane:
                subview.place(at: paneRect.origin, proposal: ProposedViewSize(paneRect.size))
            case .seam:
                if let seam {
                    let size = seam.vertical ? CGSize(width: 5, height: seam.length) : CGSize(width: seam.length, height: 5)
                    subview.place(at: seam.center, anchor: .center, proposal: ProposedViewSize(size))
                } else {
                    subview.place(at: bounds.origin, proposal: .zero)
                }
            }
        }
    }
}
