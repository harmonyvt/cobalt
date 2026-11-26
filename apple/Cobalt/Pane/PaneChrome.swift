import CobaltKit
import SwiftUI
#if os(iOS)
import UIKit
#else
import AppKit
#endif

/// The pane's own frame around a page, wherever it is drawn (beside the tab, spanned, the sheet, the cover): the header
/// (span leading, context label centred, `more` and the xmark trailing, 44 pt glass circles), the page's own
/// `NavigationStack` (a page may push sub-pages: filters, add to set), the keys, and the VoiceOver container.
struct PaneChrome: View {
    let model: AppModel
    let item: PaneItem
    let shape: PaneShape
    var hinge: PaneHinge?

    @Environment(Pane.self) private var pane
    @Environment(\.paneOffline) private var offline
    @State private var floatingHeader = false

    /// The header bar's height (48 pt on macOS, 56 pt on iOS).
    static var headerHeight: CGFloat { Platform.isMac ? 48 : 56 }

    /// Extra clearance above the header when presented in an iOS compact sheet so the system drag indicator sits cleanly
    /// above the buttons and context label.
    private var sheetTopClearance: CGFloat {
        #if os(iOS)
        return pane.placement == .compact && pane.state == .screen ? 10 : 0
        #else
        return 0
        #endif
    }

    private var reservedHeaderHeight: CGFloat { Self.headerHeight + sheetTopClearance }

    /// Shifts a horizontal hinge into `PaneDestination`'s coordinate space when the dedicated header sits above it so
    /// `PaneHalves` still lands precisely on the physical hinge.
    private var effectiveHinge: PaneHinge? {
        guard let hinge, !floatingHeader, hinge.axis == .horizontal else { return hinge }
        return PaneHinge(axis: .horizontal, position: max(0, hinge.position - reservedHeaderHeight - 0.5))
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if !floatingHeader {
                    Color.clear.frame(height: reservedHeaderHeight)
                    Rectangle()
                        .fill(CobaltColor.hairline)
                        .frame(height: 0.5)
                        .accessibilityHidden(true)
                }
                PaneDestination(item: item, model: model)
                    .environment(\.paneItem, item)
                    .environment(\.paneShape, shape)
                    .environment(\.paneHinge, effectiveHinge)
                    .environment(\.paneHeaderHeight, floatingHeader ? Self.headerHeight : 0)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .onPreferenceChange(PaneFloatingHeaderKey.self) { floatingHeader = $0 }
            .overlayPreferenceValue(PaneMoreKey.self, alignment: .top) { more in
                header(more, floating: floatingHeader)
            }
            #if os(iOS)
            .toolbar(.hidden, for: .navigationBar)
            #endif
        }
        .id(item)                                           // another item is another page, with a fresh stack
        .modifier(PaneChromeBackground())
        .background { keys }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Copy.Pane.container(pane.title ?? Copy.Pane.context(item)))
        .accessibilityIdentifier("pane")
        .accessibilityAddTraits(pane.state == .span ? .isModal : [])
        .accessibilityAction(.escape) { pane.requestClose() }
    }

    // MARK: header

    @ViewBuilder
    private func header(_ more: [PaneAction], floating: Bool) -> some View {
        MediaGlassGroup(spacing: 8) {
            if let halves = headerHalves {
                // nothing on the hinge (split), nothing over the hero's edge (wide: the media is the left half): span on
                // the left, the label centred on the right half with the closes
                PaneHalves(hinge: halves) {
                    HStack { spanButton; Spacer(minLength: 0) }
                    HStack(spacing: 8) {
                        Spacer(minLength: 0)
                        contextLabel(floating: floating)
                        Spacer(minLength: 0)
                        trailing(more)
                    }
                }
            } else {
                HStack(spacing: 8) {
                    spanButton
                    Spacer(minLength: 4)
                    contextLabel(floating: floating)
                    Spacer(minLength: 4)
                    trailing(more)
                }
            }
        }
        .padding(.horizontal, Platform.isMac ? 12 : 10)
        .frame(height: Self.headerHeight)
        .padding(.top, floating ? 0 : sheetTopClearance)
    }

    /// Where the header splits in two: on the hinge of a split pane on two screens side by side, and down the middle of
    /// a wide one (whose hero is its left half), so the context label never sits on a hinge or over the media's edge.
    /// `.some(nil)`: the middle (wide). `nil`: one centred row.
    private var headerHalves: PaneHinge?? {
        switch shape {
        case .split: if let hinge, hinge.axis == .vertical { return .some(hinge) }
        case .wide: return .some(nil)
        default: break
        }
        return nil
    }

    @ViewBuilder
    private func contextLabel(floating: Bool) -> some View {
        if floating {
            Text(Copy.Pane.context(item))
                .font(Font.cobalt(12, .semibold, relativeTo: .caption))
                .foregroundStyle(.white)
                .lineLimit(1)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .mediaGlassCapsule(interactive: false)
                .accessibilityHidden(true)                      // the container's label already says where this is
        } else {
            Text(Copy.Pane.context(item))
                .font(Font.cobalt(13, .semibold, relativeTo: .subheadline))
                .foregroundStyle(CobaltColor.caption)
                .lineLimit(1)
                .accessibilityHidden(true)                      // the container's label already says where this is
        }
    }

    /// Spanning is the iPad's and the Mac's (a pane beside the tab that can take the window). The iPhone's pane is one
    /// sheet: span there was a full-screen cover stacked over it, so the iPhone has no span button (and no ⌘⇧F).
    private var spanAllowed: Bool {
        #if os(iOS)
        return pane.placement != .compact
        #else
        return true
        #endif
    }

    @ViewBuilder
    private var spanButton: some View {
        if spanAllowed { spanControl }
    }

    private var spanControl: some View {
        let spanned = pane.state == .span
        let title = spanned ? Copy.Pane.unspan : Copy.Pane.span
        return Button { pane.toggleSpan() } label: {
            Label(title, systemImage: spanned ? Symbol.Pane.unspan : Symbol.Pane.span)
                .labelStyle(.iconOnly)
                .font(.system(size: Platform.isMac ? 12 : 14, weight: .semibold))
        }
        .buttonStyle(.glass)
        .buttonBorderShape(.circle)
        #if os(iOS)
        .controlSize(.large)
        #endif
        .help(title)
        .accessibilityLabel(title)
        .accessibilityIdentifier("pane.span")
    }

    @ViewBuilder
    private func trailing(_ more: [PaneAction]) -> some View {
        if !more.isEmpty {
            Menu {
                PaneActionMenuItems(actions: more, offline: offline)
            } label: {
                Label(Copy.Pane.more, systemImage: Symbol.Pane.more)
                    .labelStyle(.iconOnly)
                    .font(.system(size: Platform.isMac ? 13 : 14, weight: .semibold))
                    .frame(width: Platform.isMac ? 14 : 18, height: Platform.isMac ? 14 : 18)
            }
            .menuIndicator(.hidden)
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
            #if os(iOS)
            .controlSize(.large)
            #endif
            .help(Copy.Pane.more)
            .accessibilityLabel(Copy.Pane.more)
        }
        CloseButton { pane.requestClose() }
            .help(Copy.Pane.close)
            .accessibilityIdentifier("pane.close")
    }

    // MARK: keys

    /// Escape closes, ⌘⇧F spans and unspans, ⌘[ and ⌘] page the shelf. Drawn with the pane, so they work wherever it is
    /// (beside the tab, in the sheet, in the cover) and only while it is there. Escape in a text field (a search field,
    /// twitch chat, a form) is the field's: it ends the editing (clears a search on the Mac) and the pane stays; and a
    /// pushed editor holding the close (`.paneHoldsClose`) is asked instead.
    private var keys: some View {
        ZStack {
            Button {
                if PaneTextFocus.escapeInField() { return }
                pane.requestClose()
            } label: { EmptyView() }
                .keyboardShortcut(.escape, modifiers: [])
            Button { if spanAllowed { pane.toggleSpan() } } label: { EmptyView() }
                .keyboardShortcut("f", modifiers: [.command, .shift])
            Button { pane.shelfBack() } label: { EmptyView() }
                .keyboardShortcut("[", modifiers: .command)
            Button { pane.shelfNext() } label: { EmptyView() }
                .keyboardShortcut("]", modifiers: .command)
        }
        .buttonStyle(.plain)
        .accessibilityHidden(true)
    }
}

/// The running item as a bar over the tab (above the tab bar; the bottom of the detail area on the Mac): the current item
/// closed while running, a running item another open moved aside, or one under a peek (`Pane.barItem`). Its page stays
/// mounted here, so a stream keeps playing. Tapping it opens the item at `screen`.
struct PaneBar: View {
    let model: AppModel
    @Environment(Pane.self) private var pane

    var body: some View {
        if let item = pane.barItem {
            PaneDestination(item: item, model: model)
                .id(item)
                .environment(\.paneItem, item)
                .environment(\.paneShape, .bar)
                .contentShape(.rect)
                .onTapGesture { pane.tapBar() }
                .accessibilityElement(children: .contain)
                // the reported title is the current item's; a background item in the bar is named by its kind
                .accessibilityLabel(Copy.Pane.container((item == pane.item ? pane.title : nil) ?? Copy.Pane.context(item)))
                .accessibilityAction(named: Copy.Pane.reopen) { pane.tapBar() }
                .accessibilityIdentifier("pane.bar")
                .help(Copy.Pane.reopen)
        }
    }
}

/// Puts the bar where the platform keeps it: the tab view's bottom accessory on iOS 26.1+ (apply this to the
/// `TabView`), a capsule inset at the bottom otherwise and on the Mac (`PaneHost` applies it there).
struct PaneBarAccessory: ViewModifier {
    let model: AppModel
    @Environment(Pane.self) private var pane

    private var shown: Bool { pane.barItem != nil }

    func body(content: Content) -> some View {
        #if os(iOS)
        if #available(iOS 26.1, *) {
            content.tabViewBottomAccessory(isEnabled: shown) { PaneBar(model: model) }
        } else {
            content.safeAreaInset(edge: .bottom) { capsule }
        }
        #else
        content.safeAreaInset(edge: .bottom) { capsule }
        #endif
    }

    @ViewBuilder
    private var capsule: some View {
        if shown {
            PaneBar(model: model)
                .frame(maxWidth: 520)
                .glassEffect(.regular.interactive(), in: .capsule)
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
                .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }
}

/// The pane's surface: flat `CobaltColor.bg` on iOS, native frosted material on macOS so the column harmonizes with
/// the translucent window and sidebar while still cleanly occluding the tab underneath when spanned.
private struct PaneChromeBackground: ViewModifier {
    func body(content: Content) -> some View {
        #if os(macOS)
        content.background(.thickMaterial)
        #else
        content.background(CobaltColor.bg)
        #endif
    }
}

/// The line on the hinge (or the column's divider). While another save or make runs in the background (not the one
/// already displayed in the pane), a quiet 2 pt progress bar fills along the line.
struct PaneSeam: View {
    /// The fraction on the line (`seamFraction`) is the queue's; whether there is any work to show is the one count's.
    let queue: JobQueue
    let activity: ActivityModel
    let axis: PanePlacement.Axis
    /// The job already displayed in the pane, if any: no need to mirror its progress on the divider beside it.
    var showingJobID: UUID? = nil

    private var vertical: Bool { axis == .vertical }
    /// Any work in motion but the one the pane shows (apple 03-PHASE3 3.2: the seam reads `activity`, so a download or a render
    /// somewhere else lights it as well as a job of this device does).
    private var showsBackgroundProgress: Bool {
        let showing = showingJobID.map(JobStatus.Ref.pipeline)
        return activity.items.contains { $0.isActive && $0.ref != showing }
    }

    var body: some View {
        ZStack(alignment: vertical ? .bottom : .leading) {
            Rectangle()
                .fill(CobaltColor.hairline)
                .frame(width: vertical ? 1 : nil, height: vertical ? nil : 1)
            if showsBackgroundProgress {
                TimelineView(.periodic(from: .now, by: 0.5)) { context in
                    let f = queue.seamFraction(now: context.date) ?? 0
                    GeometryReader { geo in
                        let length = vertical ? geo.size.height : geo.size.width
                        let fill = max(12, length * f)
                        let light = Capsule()
                            .fill(LinearGradient(
                                colors: [CobaltColor.success.opacity(0.25), CobaltColor.success.opacity(0.8)],
                                startPoint: vertical ? .top : .trailing, endPoint: vertical ? .bottom : .leading))
                        if vertical {
                            light.frame(width: 2, height: fill)
                                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                        } else {
                            light.frame(width: fill, height: 2)
                                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                        }
                    }
                    .animation(.easeOut(duration: 0.5), value: f)
                }
                .padding(vertical ? .vertical : .horizontal, 24)
                .transition(.opacity)
            }
        }
        .frame(width: vertical ? 5 : nil, height: vertical ? nil : 5)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

// MARK: - Escape in a text field

/// Whether the keyboard focus is in a text field or text view, where Escape belongs to the field and not to the pane.
@MainActor
enum PaneTextFocus {
    /// Escape was pressed: when a text field or view has the focus, gives the field its Escape (iOS: the editing ends;
    /// the Mac: the field's own cancel, which clears a search field) and returns true; the pane is left alone.
    static func escapeInField() -> Bool {
        #if os(iOS)
        FirstResponderProbe.found = nil
        UIApplication.shared.sendAction(#selector(UIResponder.paneProbeFirstResponder(_:)), to: nil, from: nil, for: nil)
        let responder = FirstResponderProbe.found
        FirstResponderProbe.found = nil
        guard let responder, responder is UITextField || responder is UITextView else { return false }
        responder.resignFirstResponder()
        return true
        #else
        guard let window = NSApp.keyWindow, let responder = window.firstResponder, responder is NSText else { return false }
        NSApp.sendAction(#selector(NSResponder.cancelOperation(_:)), to: nil, from: nil)
        return true
        #endif
    }
}

#if os(iOS)
@MainActor
private enum FirstResponderProbe {
    static weak var found: UIResponder?
}

extension UIResponder {
    /// Sent down the responder chain from nil: the first responder answers.
    @objc fileprivate func paneProbeFirstResponder(_ sender: Any?) {
        FirstResponderProbe.found = self
    }
}
#endif
