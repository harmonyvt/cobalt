import CobaltKit
import SwiftUI

/// The content primitive of every pane page (apple/CONTRACT-PANE.md section 4). A page fills four slots and `PanePage`
/// arranges them for the shape it is in (`\.paneShape`):
///
///     PanePage(title: "the harbour", subtitle: "video · 0:42", actions: [share], more: [rename, delete]) {
///         hero      // media: bleeds under the header (tall), left half (wide), its own screen (split), a thumb (bar)
///     } controls: {
///         // the one thing you do: transport, live controls, progress + stop, a `PaneActionGrid`, or a form.
///         // In `.bar` show ONE control (read `\.paneShape`).
///     } body: {
///         // optional scrolling content (a link's files, a swarm board, booru tags)
///     } shelf: {
///         PaneCard("transcript") { … }; PaneCard("links") { … }
///     }
///
/// - `actions`: up to 2 icon buttons beside the title (hover names on the Mac and iPad). `more`: the header's menu.
/// - The header (span, context label, more, xmark) is the pane's, never the page's: a page never draws a close.
/// - `progress` (0...1): a hairline under the bar, and above the controls elsewhere.
/// - The title wraps to 2 lines; at accessibility sizes the hero shrinks and `PaneActionGrid` becomes a list.
/// - Loading: `PaneLoadingPage`; a deleted item: `PaneGonePage`. Offline: keep what is loaded, mark actions that
///   need the server with `needsServer` (they dim on their own).
struct PanePage<Hero: View, Controls: View, Details: View, Shelf: View>: View {
    let title: String
    let subtitle: String?
    let actions: [PaneAction]
    let more: [PaneAction]
    let progress: Double?
    let hero: Hero
    let controls: Controls
    let details: Details
    let shelf: Shelf

    @Environment(\.paneShape) private var shape
    @Environment(\.paneHinge) private var hinge
    @Environment(\.paneHeaderHeight) private var headerHeight
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(Pane.self) private var pane: Pane?

    init(
        title: String, subtitle: String? = nil, actions: [PaneAction] = [], more: [PaneAction] = [],
        progress: Double? = nil,
        @ViewBuilder hero: () -> Hero, @ViewBuilder controls: () -> Controls,
        @ViewBuilder body: () -> Details, @ViewBuilder shelf: () -> Shelf
    ) {
        self.title = title
        self.subtitle = subtitle
        self.actions = Array(actions.prefix(2))
        self.more = more
        self.progress = progress.map { min(max($0, 0), 1) }
        self.hero = hero()
        self.controls = controls()
        self.details = body()
        self.shelf = shelf()
    }

    var body: some View {
        Group {
            switch shape {
            case .tall: tall
            case .wide: wide
            case .split: split
            case .bar: bar
            }
        }
        .preference(key: PaneMoreKey.self, value: more)
        .onChange(of: title, initial: true) { pane?.reportTitle(title) }
    }

    // MARK: shapes

    private var heroMaxHeight: CGFloat { typeSize.isAccessibilitySize ? 200 : 380 }

    /// One column: the hero under the header, then title, controls, body and the paged shelf.
    private var tall: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Group(subviews: hero) { parts in
                    if parts.isEmpty {
                        Color.clear.frame(height: headerHeight)
                    } else {
                        ZStack { parts }
                            .frame(maxWidth: .infinity)
                            .frame(maxHeight: heroMaxHeight)
                            .clipped()
                    }
                }
                column(stackedShelf: false)
            }
            .padding(.bottom, 24)
        }
        .scrollBounceBehavior(.basedOnSize)
    }

    /// Media on the left half, everything else on the right.
    private var wide: some View {
        Group(subviews: hero) { parts in
            if parts.isEmpty {
                ScrollView { column(stackedShelf: false).padding(.top, headerHeight).padding(.bottom, 24) }
            } else {
                HStack(spacing: 0) {
                    ZStack { parts }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .clipped()
                    ScrollView { column(stackedShelf: false).padding(.top, headerHeight).padding(.bottom, 24) }
                        .frame(maxWidth: .infinity)
                }
            }
        }
    }

    /// Spanned over two screens: the media is one screen, the details (with the shelf stacked) the other.
    private var split: some View {
        PaneHalves(hinge: hinge) {
            ZStack { hero }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()
                .environment(\.paneShape, .split(.media))
            ScrollView { column(stackedShelf: true).padding(.top, headerHeight).padding(.bottom, 24) }
                .environment(\.paneShape, .split(.details))
        }
    }

    /// The bar over the tab: a thumb, the title, one control, a hairline of progress.
    private var bar: some View {
        HStack(spacing: 12) {
            ZStack { hero }
                .frame(width: 40, height: 40)
                .clipShape(.rect(cornerRadius: 8))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(CobaltType.bodySemibold)
                    .foregroundStyle(CobaltColor.text)
                    .lineLimit(1)
                if let subtitle {
                    Text(subtitle)
                        .font(CobaltType.captionSmall)
                        .foregroundStyle(CobaltColor.caption)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            controls
        }
        .padding(.horizontal, 12)
        .frame(minHeight: 48)
        .overlay(alignment: .bottom) {
            if let progress { PaneProgressLine(fraction: progress).padding(.horizontal, 16) }
        }
    }

    // MARK: parts

    private func column(stackedShelf: Bool) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            titleBlock
            VStack(alignment: .leading, spacing: 10) {
                if let progress { PaneProgressLine(fraction: progress) }
                controls
            }
            .padding(.horizontal, 16)
            details
            PaneShelf(stacked: stackedShelf) { shelf }
        }
    }

    private var titleBlock: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(Font.cobalt(20, .semibold, relativeTo: .title3))
                    .foregroundStyle(CobaltColor.text)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                if let subtitle {
                    Text(subtitle)
                        .font(CobaltType.caption)
                        .foregroundStyle(CobaltColor.caption)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 0)
            ForEach(actions) { PaneIconButton(action: $0) }
        }
        .padding(.horizontal, 16)
    }
}

// Pages without a body or a shelf.
extension PanePage where Details == EmptyView, Shelf == EmptyView {
    init(
        title: String, subtitle: String? = nil, actions: [PaneAction] = [], more: [PaneAction] = [],
        progress: Double? = nil, @ViewBuilder hero: () -> Hero, @ViewBuilder controls: () -> Controls
    ) {
        self.init(title: title, subtitle: subtitle, actions: actions, more: more, progress: progress,
                  hero: hero, controls: controls, body: { EmptyView() }, shelf: { EmptyView() })
    }
}

extension PanePage where Shelf == EmptyView {
    init(
        title: String, subtitle: String? = nil, actions: [PaneAction] = [], more: [PaneAction] = [],
        progress: Double? = nil, @ViewBuilder hero: () -> Hero, @ViewBuilder controls: () -> Controls,
        @ViewBuilder body: () -> Details
    ) {
        self.init(title: title, subtitle: subtitle, actions: actions, more: more, progress: progress,
                  hero: hero, controls: controls, body: body, shelf: { EmptyView() })
    }
}

extension PanePage where Details == EmptyView {
    init(
        title: String, subtitle: String? = nil, actions: [PaneAction] = [], more: [PaneAction] = [],
        progress: Double? = nil, @ViewBuilder hero: () -> Hero, @ViewBuilder controls: () -> Controls,
        @ViewBuilder shelf: () -> Shelf
    ) {
        self.init(title: title, subtitle: subtitle, actions: actions, more: more, progress: progress,
                  hero: hero, controls: controls, body: { EmptyView() }, shelf: shelf)
    }
}

/// One shelf card: a small lowercase title over its content, on the surface colour.
struct PaneCard<Content: View>: View {
    let title: String
    let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(Font.cobalt(12, .semibold, relativeTo: .caption))
                .foregroundStyle(CobaltColor.caption)
                .accessibilityAddTraits(.isHeader)
            content
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .padding(16)
        .background(CobaltColor.surface, in: .rect(cornerRadius: 20))
        .accessibilityElement(children: .contain)
    }
}

/// The shelf: one card at a time with dots (swipe, tap a dot, ⌘[ / ⌘]), or every card stacked (the details screen of a
/// split). The card on show is the pane's (`Pane.shelf`), so it survives folding and rotating.
private struct PaneShelf<Cards: View>: View {
    let stacked: Bool
    let cards: Cards
    @Environment(Pane.self) private var pane: Pane?

    init(stacked: Bool, @ViewBuilder cards: () -> Cards) {
        self.stacked = stacked
        self.cards = cards()
    }

    var body: some View {
        Group(subviews: cards) { parts in
            if !parts.isEmpty {
                Group {
                    if stacked || parts.count == 1 {
                        VStack(spacing: 12) { ForEach(parts) { $0 } }
                            .padding(.horizontal, 16)
                    } else {
                        pager(parts)
                    }
                }
                .onChange(of: parts.count, initial: true) { _, count in pane?.reportShelf(count: count) }
            }
        }
    }

    private func pager(_ parts: SubviewsCollection) -> some View {
        let index = min(pane?.shelf ?? 0, parts.count - 1)
        return VStack(spacing: 10) {
            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: 0) {
                    ForEach(parts.indices, id: \.self) { i in
                        parts[i]
                            .padding(.horizontal, 16)
                            .containerRelativeFrame(.horizontal)
                            .id(i)
                    }
                }
                .scrollTargetLayout()
            }
            .scrollTargetBehavior(.paging)
            .scrollIndicators(.hidden)
            .scrollPosition(id: Binding<Int?>(get: { index }, set: { if let i = $0 { pane?.setShelf(i) } }))
            .motion(Motion.card, value: index)
            PaneDots(count: parts.count, index: index) { pane?.setShelf($0) }
        }
    }
}

/// The shelf's dots: tap one to show its card; VoiceOver adjusts.
private struct PaneDots: View {
    let count: Int
    let index: Int
    let select: (Int) -> Void

    var body: some View {
        HStack(spacing: 8) {
            ForEach(0..<count, id: \.self) { i in
                Circle()
                    .fill(i == index ? CobaltColor.text : CobaltColor.border)
                    .frame(width: 7, height: 7)
                    .frame(width: 18, height: 22)
                    .contentShape(.rect)
                    .onTapGesture { select(i) }
            }
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement()
        .accessibilityLabel(Copy.Pane.shelfPosition(index, of: count))
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: select(min(index + 1, count - 1))
            case .decrement: select(max(index - 1, 0))
            @unknown default: break
            }
        }
    }
}

/// A round glass icon button with its hover name (the header's and the title row's).
struct PaneIconButton: View {
    let action: PaneAction
    @Environment(\.paneOffline) private var offline

    var body: some View {
        let off = action.off(offline: offline)
        Button(role: action.role) { action.perform() } label: {
            Image(systemName: action.systemImage)
                .font(.system(size: 15, weight: .semibold))
        }
        .buttonStyle(.glass)
        .buttonBorderShape(.circle)
        #if os(iOS)
        .controlSize(.large)
        #endif
        .disabled(off)
        .opacity(off ? 0.45 : 1)
        .help(action.title)
        .accessibilityLabel(action.title)
    }
}

/// A hairline of progress (the bar's bottom edge, above the controls elsewhere).
struct PaneProgressLine: View {
    let fraction: Double

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(CobaltColor.hairline)
                Capsule().fill(CobaltColor.success).frame(width: geo.size.width * fraction)
            }
        }
        .frame(height: 2)
        .animation(.easeOut(duration: 0.4), value: fraction)
        .accessibilityElement()
        .accessibilityValue(Text(fraction, format: .percent.precision(.fractionLength(0))))
    }
}

/// Two screens of a spanned pane: the first subview on the leading / top screen, the second on the other, split at the
/// hinge (or the middle of the longer side when there is none).
struct PaneHalves: Layout {
    var hinge: PaneHinge?

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        proposal.replacingUnspecifiedDimensions()
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let (first, second) = Self.split(bounds, hinge: hinge)
        if subviews.indices.contains(0) {
            subviews[0].place(at: first.origin, proposal: ProposedViewSize(first.size))
        }
        if subviews.indices.contains(1) {
            subviews[1].place(at: second.origin, proposal: ProposedViewSize(second.size))
        }
    }

    static func split(_ bounds: CGRect, hinge: PaneHinge?) -> (CGRect, CGRect) {
        let axis = hinge?.axis ?? (bounds.width >= bounds.height ? .vertical : .horizontal)
        switch axis {
        case .vertical:
            let x = min(max(hinge?.position ?? bounds.width / 2, 0), bounds.width)
            return (CGRect(x: bounds.minX, y: bounds.minY, width: x, height: bounds.height),
                    CGRect(x: bounds.minX + x, y: bounds.minY, width: bounds.width - x, height: bounds.height))
        case .horizontal:
            let y = min(max(hinge?.position ?? bounds.height / 2, 0), bounds.height)
            return (CGRect(x: bounds.minX, y: bounds.minY, width: bounds.width, height: y),
                    CGRect(x: bounds.minX, y: bounds.minY + y, width: bounds.width, height: bounds.height - y))
        }
    }
}

// MARK: states

/// A page still loading: grey shapes in the page's own shape (never a spinner).
struct PaneLoadingPage: View {
    @Environment(\.paneShape) private var shape
    @Environment(\.paneHinge) private var hinge
    @Environment(\.paneHeaderHeight) private var headerHeight

    var body: some View {
        Group {
            switch shape {
            case .tall:
                VStack(alignment: .leading, spacing: 18) {
                    block.aspectRatio(16 / 10, contentMode: .fit)
                    lines.padding(.horizontal, 16)
                    Spacer(minLength: 0)
                }
            case .wide:
                HStack(spacing: 0) {
                    block
                    lines.padding(16).padding(.top, headerHeight).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                }
            case .split:
                PaneHalves(hinge: hinge) {
                    block
                    lines.padding(16).padding(.top, headerHeight).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                }
            case .bar:
                HStack(spacing: 12) {
                    RoundedRectangle(cornerRadius: 8).fill(Skeleton.fill).frame(width: 40, height: 40)
                    VStack(alignment: .leading, spacing: 6) {
                        Capsule().fill(Skeleton.fill).frame(width: 140, height: 10)
                        Capsule().fill(Skeleton.fill).frame(width: 90, height: 8)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 12)
                .frame(minHeight: 48)
            }
        }
        .skeletonShimmer()
        .accessibilityElement()
        .accessibilityLabel(Copy.Pane.loading)
    }

    private var block: some View { Rectangle().fill(Skeleton.fill) }

    private var lines: some View {
        VStack(alignment: .leading, spacing: 10) {
            Capsule().fill(Skeleton.fill).frame(width: 220, height: 16)
            Capsule().fill(Skeleton.fill).frame(width: 140, height: 10)
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 22).fill(Skeleton.fill).frame(height: 96)
                RoundedRectangle(cornerRadius: 22).fill(Skeleton.fill).frame(height: 96)
            }
            .padding(.top, 8)
        }
    }
}

/// An item that was deleted (or never existed): one line and one action, close.
struct PaneGonePage: View {
    var message: String = Copy.Pane.gone
    @Environment(\.paneShape) private var shape
    @Environment(\.paneHeaderHeight) private var headerHeight
    @Environment(Pane.self) private var pane: Pane?

    var body: some View {
        if shape == .bar {
            HStack(spacing: 10) {
                Image(systemName: Symbol.Pane.gone).foregroundStyle(CobaltColor.caption)
                Text(message).font(CobaltType.body).foregroundStyle(CobaltColor.caption).lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .frame(minHeight: 48)
        } else {
            VStack(spacing: 14) {
                Image(systemName: Symbol.Pane.gone)
                    .font(.system(size: 30, weight: .regular))
                    .foregroundStyle(CobaltColor.caption)
                    .accessibilityHidden(true)
                Text(message)
                    .font(CobaltType.body)
                    .foregroundStyle(CobaltColor.text)
                    .multilineTextAlignment(.center)
                Button(Copy.Pane.close) { pane?.close() }
                    .buttonStyle(.glass)
                    .font(CobaltType.button)
            }
            .padding(24)
            .padding(.top, headerHeight)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
