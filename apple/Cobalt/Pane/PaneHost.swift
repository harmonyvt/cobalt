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
/// - compact: a sheet (`.large`, drag indicator), and spanned a full-screen cover over it (a bigger sheet on the Mac).
///
/// The tab keeps its room while the pane is spanned (it is only covered), so nothing behind reflows. The pane slides in
/// from the leading (top) edge with the `Motion` spring, or cross-fades under Reduce Motion. The route is saved per
/// scene with `@SceneStorage("pane")`. A drag held 0.6 s over the leading edge of a hidden pane brings its last item
/// back. The bar is `PaneBarAccessory` (applied to the tab view on iOS, here on the Mac).
struct PaneHost<Content: View>: View {
    let model: AppModel
    /// A drag is over the window (the shell's drop target): the leading edge listens for a held drag.
    var dragging: Bool
    let content: Content

    @Environment(Pane.self) private var pane
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @SceneStorage("pane") private var saved: Data?
    @State private var size: CGSize = .zero
    @State private var edgeTargeted = false

    init(model: AppModel, dragging: Bool = false, @ViewBuilder content: () -> Content) {
        self.model = model
        self.dragging = dragging
        self.content = content()
    }

    private var idiom: PanePlacement.Idiom {
        #if os(macOS)
        return .mac
        #else
        return UIDevice.current.userInterfaceIdiom == .pad ? .pad : .phone
        #endif
    }

    private var measured: Bool { size.width > 0 && size.height > 0 }

    /// Until iOS reports the Duo's hinge there is no display feature to pass (`PanePlacement.resolve` takes one).
    private var placement: PanePlacement {
        measured ? PanePlacement.resolve(size: size, idiom: idiom, displayFeatureFrame: nil) : pane.placement
    }

    /// The pane is drawn beside (or over) the tab, not in a sheet.
    private var inline: Bool { measured && pane.isVisible && placement != .compact }

    var body: some View {
        let placement = self.placement
        let inline = self.inline
        let spanned = pane.state == .span
        PaneSplitLayout(placement: placement, spanned: spanned) {
            content
                .layoutValue(key: PaneRoleKey.self, value: .tab)
                .accessibilityHidden(inline && spanned)
            if inline, let item = pane.item {
                PaneChrome(model: model, item: item, shape: inlineShape(placement, spanned: spanned),
                           hinge: inlineHinge(placement, spanned: spanned))
                    .layoutValue(key: PaneRoleKey.self, value: .pane)
                    .accessibilitySortPriority(1)            // reading order: the pane first
                    .transition(transition(placement))
            }
            if inline, showsSeam(placement, spanned: spanned) {
                PaneSeam(queue: model.queue, axis: seamAxis(placement))
                    .layoutValue(key: PaneRoleKey.self, value: .seam)
                    .transition(.opacity)
            }
        }
        .motion(Motion.card, value: LayoutKey(inline: inline, state: pane.state, placement: placement))
        .hapticChange(.impact(weight: .light), trigger: inline ? placement.name : "off") { old, new in
            old != "off" && new != "off"                    // a posture change settling the pane somewhere new
        }
        .onGeometryChange(for: CGSize.self) { $0.size } action: { size = $0 }
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
        .sheet(isPresented: sheetShown) { compactSheet }
        .overlay(alignment: edgeAlignment(placement)) { edgeStrip(placement) }
        #if os(macOS)
        .modifier(PaneBarAccessory(model: model))
        #endif
        .environment(\.paneOffline, model.capabilities.kind == .unreachable)
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

    private func transition(_ placement: PanePlacement) -> AnyTransition {
        if reduceMotion { return .opacity }
        if case .twoScreens(axis: .horizontal, hinge: _) = placement { return .move(edge: .top) }
        return .move(edge: .leading)
    }

    // MARK: compact

    private var sheetShown: Binding<Bool> {
        Binding(
            get: { measured && placement == .compact && pane.isVisible },
            set: { shown in
                // swiped down: hide (a running item goes to the bar). A posture change that took the sheet away is not
                // a close: the pane is drawn inline now.
                if !shown, pane.isVisible, placement == .compact { pane.close() }
            })
    }

    @ViewBuilder
    private var compactSheet: some View {
        PaneCompactSheet(model: model)
            .environment(pane)
            .environment(\.paneOffline, model.capabilities.kind == .unreachable)
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

/// What the layout animation follows.
private struct LayoutKey: Equatable {
    var inline: Bool
    var state: PaneState
    var placement: PanePlacement
}

/// The pane in a sheet on one narrow screen; spanned, a full-screen cover over it (on the Mac, the sheet itself grows).
private struct PaneCompactSheet: View {
    let model: AppModel
    @Environment(Pane.self) private var pane

    var body: some View {
        Group {
            #if os(iOS)
            if pane.state == .screen, let item = pane.item {
                PaneChrome(model: model, item: item, shape: .tall)
            } else {
                // spanned: the cover has the page (one page at a time, so a stream never plays twice)
                CobaltColor.bg
            }
            #else
            if let item = pane.item {
                PaneChrome(model: model, item: item, shape: pane.state == .span ? .wide : .tall)
                    .frame(minWidth: pane.state == .span ? 720 : 420, idealWidth: pane.state == .span ? 900 : 460,
                           minHeight: 520, idealHeight: 640)
            }
            #endif
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        #if os(iOS)
        .fullScreenCover(isPresented: coverShown) {
            PaneCover(model: model)
                .environment(pane)
                .cobaltRoot(model: model)
        }
        #endif
    }

    #if os(iOS)
    private var coverShown: Binding<Bool> {
        Binding(
            get: { pane.state == .span && pane.item != nil },
            set: { shown in if !shown, pane.state == .span { pane.unspan() } })
    }
    #endif
}

#if os(iOS)
/// The spanned pane on one narrow screen: tall in portrait, wide in landscape.
private struct PaneCover: View {
    let model: AppModel
    @Environment(Pane.self) private var pane
    @State private var wide = false

    var body: some View {
        Group {
            if let item = pane.item {
                PaneChrome(model: model, item: item, shape: wide ? .wide : .tall)
            }
        }
        .onGeometryChange(for: Bool.self) { $0.size.width > $0.size.height * 1.1 } action: { wide = $0 }
    }
}
#endif

// MARK: layout

private enum PaneRole: Sendable { case tab, pane, seam }

private struct PaneRoleKey: LayoutValueKey {
    static let defaultValue: PaneRole = .tab
}

/// Places the tab, the pane and the hairline for a placement. The tab always stays the first subview, so folding,
/// unfolding and opening the pane never rebuild it (its navigation stacks, scroll and selection survive).
private struct PaneSplitLayout: Layout {
    var placement: PanePlacement
    var spanned: Bool

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        proposal.replacingUnspecifiedDimensions()
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let hasPane = subviews.contains { $0[PaneRoleKey.self] == .pane }
        var tab = bounds
        var paneRect = bounds
        // the line: its centre and whether it runs top to bottom
        var seam: (center: CGPoint, vertical: Bool, length: CGFloat)?

        if hasPane {
            switch placement {
            case .twoScreens(axis: .vertical, hinge: let hinge):
                let x = min(max(hinge, 0), bounds.width)
                paneRect = CGRect(x: bounds.minX, y: bounds.minY, width: x, height: bounds.height)
                tab = CGRect(x: bounds.minX + x, y: bounds.minY, width: bounds.width - x, height: bounds.height)
                seam = (CGPoint(x: bounds.minX + x, y: bounds.midY), true, bounds.height)
            case .twoScreens(axis: .horizontal, hinge: let hinge):
                let y = min(max(hinge, 0), bounds.height)
                paneRect = CGRect(x: bounds.minX, y: bounds.minY, width: bounds.width, height: y)
                tab = CGRect(x: bounds.minX, y: bounds.minY + y, width: bounds.width, height: bounds.height - y)
                seam = (CGPoint(x: bounds.midX, y: bounds.minY + y), false, bounds.width)
            case .column(let width):
                let w = min(width, bounds.width)
                paneRect = CGRect(x: bounds.minX, y: bounds.minY, width: w, height: bounds.height)
                tab = CGRect(x: bounds.minX + w, y: bounds.minY, width: bounds.width - w, height: bounds.height)
                seam = spanned ? nil : (CGPoint(x: bounds.minX + w, y: bounds.midY), true, bounds.height)
            case .compact:
                break
            }
            // spanned: the page has the whole area; the tab keeps its room underneath, covered
            if spanned { paneRect = bounds }
        }

        for subview in subviews {
            switch subview[PaneRoleKey.self] {
            case .tab:
                subview.place(at: tab.origin, proposal: ProposedViewSize(tab.size))
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
