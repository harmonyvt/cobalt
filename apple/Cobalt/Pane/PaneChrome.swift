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

    /// The header's height over the top of the page (a 44 pt circle and its margins).
    static let headerHeight: CGFloat = 60

    var body: some View {
        NavigationStack {
            PaneDestination(item: item, model: model)
                .environment(\.paneItem, item)
                .environment(\.paneShape, shape)
                .environment(\.paneHinge, hinge)
                .environment(\.paneHeaderHeight, Self.headerHeight)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .overlayPreferenceValue(PaneMoreKey.self, alignment: .top) { more in header(more) }
                #if os(iOS)
                .toolbar(.hidden, for: .navigationBar)
                #endif
        }
        .id(item)                                           // another item is another page, with a fresh stack
        .background(CobaltColor.bg)
        .background { keys }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Copy.Pane.container(pane.title ?? Copy.Pane.context(item)))
        .accessibilityIdentifier("pane")
        .accessibilityAddTraits(pane.state == .span ? .isModal : [])
        .accessibilityAction(.escape) { pane.requestClose() }
    }

    // MARK: header

    @ViewBuilder
    private func header(_ more: [PaneAction]) -> some View {
        Group {
            if let halves = headerHalves {
                // nothing on the hinge (split), nothing over the hero's edge (wide: the media is the left half): span on
                // the left, the label centred on the right half with the closes
                PaneHalves(hinge: halves) {
                    HStack { spanButton; Spacer(minLength: 0) }
                    ZStack {
                        contextLabel.padding(.horizontal, 100)
                        HStack(spacing: 8) { Spacer(minLength: 0); trailing(more) }
                    }
                }
            } else {
                ZStack {
                    contextLabel.padding(.horizontal, 110)
                    HStack(spacing: 8) {
                        spanButton
                        Spacer(minLength: 0)
                        trailing(more)
                    }
                }
            }
        }
        .padding(.horizontal, 10)
        .frame(height: Self.headerHeight)
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

    private var contextLabel: some View {
        Text(Copy.Pane.context(item))
            .font(Font.cobalt(12, .semibold, relativeTo: .caption))
            .foregroundStyle(CobaltColor.text)
            .lineLimit(1)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .glassEffect(.regular, in: .capsule)
            .accessibilityHidden(true)                      // the container's label already says where this is
    }

    private var spanButton: some View {
        let spanned = pane.state == .span
        let title = spanned ? Copy.Pane.unspan : Copy.Pane.span
        return Button { pane.toggleSpan() } label: {
            Image(systemName: spanned ? Symbol.Pane.unspan : Symbol.Pane.span)
                .font(.system(size: 14, weight: .semibold))
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
                ForEach(more) { action in
                    if action.choices.isEmpty {
                        Button(role: action.role) { action.perform() } label: {
                            Label(action.title, systemImage: action.systemImage)
                        }
                        .disabled(action.off(offline: offline))
                    } else {
                        Menu(action.title, systemImage: action.systemImage) { PaneChoiceItems(choices: action.choices) }
                            .disabled(action.off(offline: offline))
                    }
                }
            } label: {
                Image(systemName: Symbol.Pane.more)
                    .font(.system(size: 15, weight: .semibold))
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
            Button { pane.toggleSpan() } label: { EmptyView() }
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

/// The line on the hinge (or the column's divider). While a save or make runs it is the job's progress light, a green
/// bar filling along the line, so no banner covers either side (the old spread seam did the same).
struct PaneSeam: View {
    let queue: JobQueue
    let axis: PanePlacement.Axis

    private var vertical: Bool { axis == .vertical }

    var body: some View {
        ZStack(alignment: vertical ? .bottom : .leading) {
            Rectangle()
                .fill(CobaltColor.hairline)
                .frame(width: vertical ? 1 : nil, height: vertical ? nil : 1)
            if !queue.live.isEmpty {
                TimelineView(.periodic(from: .now, by: 0.5)) { context in
                    let f = queue.seamFraction(now: context.date) ?? 0
                    GeometryReader { geo in
                        let length = vertical ? geo.size.height : geo.size.width
                        let fill = max(12, length * f)
                        let light = Capsule()
                            .fill(LinearGradient(
                                colors: [CobaltColor.success.opacity(0.25), CobaltColor.success],
                                startPoint: vertical ? .top : .trailing, endPoint: vertical ? .bottom : .leading))
                            .shadow(color: CobaltColor.success.opacity(0.8), radius: 5)
                        if vertical {
                            light.frame(width: 3, height: fill)
                                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                        } else {
                            light.frame(width: fill, height: 3)
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
