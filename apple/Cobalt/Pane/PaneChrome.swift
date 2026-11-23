import CobaltKit
import SwiftUI

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
        .accessibilityAddTraits(pane.state == .span ? .isModal : [])
        .accessibilityAction(.escape) { pane.close() }
    }

    // MARK: header

    @ViewBuilder
    private func header(_ more: [PaneAction]) -> some View {
        Group {
            if case .split = shape, let hinge, hinge.axis == .vertical {
                // nothing on the hinge: span on the left screen, the label and the closes centred on the right one
                PaneHalves(hinge: hinge) {
                    HStack { spanButton; Spacer(minLength: 0) }
                    ZStack {
                        contextLabel
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
    }

    @ViewBuilder
    private func trailing(_ more: [PaneAction]) -> some View {
        if !more.isEmpty {
            Menu {
                ForEach(more) { action in
                    Button(role: action.role) { action.perform() } label: {
                        Label(action.title, systemImage: action.systemImage)
                    }
                    .disabled(action.off(offline: offline))
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
        CloseButton { pane.close() }
            .help(Copy.Pane.close)
    }

    // MARK: keys

    /// Escape closes, ⌘⇧F spans and unspans, ⌘[ and ⌘] page the shelf. Drawn with the pane, so they work wherever it is
    /// (beside the tab, in the sheet, in the cover) and only while it is there.
    private var keys: some View {
        ZStack {
            Button { pane.close() } label: { EmptyView() }
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

/// The running item as a bar over the tab (above the tab bar; the bottom of the detail area on the Mac). Tapping it
/// opens the item at `screen`.
struct PaneBar: View {
    let model: AppModel
    @Environment(Pane.self) private var pane

    var body: some View {
        if let item = pane.item {
            PaneDestination(item: item, model: model)
                .id(item)
                .environment(\.paneShape, .bar)
                .contentShape(.rect)
                .onTapGesture { pane.tapBar() }
                .accessibilityElement(children: .contain)
                .accessibilityLabel(Copy.Pane.container(pane.title ?? Copy.Pane.context(item)))
                .accessibilityAction(named: Copy.Pane.reopen) { pane.tapBar() }
                .help(Copy.Pane.reopen)
        }
    }
}

/// Puts the bar where the platform keeps it: the tab view's bottom accessory on iOS 26.1+ (apply this to the
/// `TabView`), a capsule inset at the bottom otherwise and on the Mac (`PaneHost` applies it there).
struct PaneBarAccessory: ViewModifier {
    let model: AppModel
    @Environment(Pane.self) private var pane

    private var shown: Bool { pane.state == .bar && pane.item != nil }

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
/// bar filling along the line, so no banner covers either side (what `HingeSeam` did for the spreads).
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
