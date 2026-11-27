import CobaltKit
import SwiftUI

// One chat line (APP-API-CONTRACT 70): badges, the name in its colour or 7TV paint, then the words and emotes wrapped like
// text. Rows take only the values they draw (apple/ARCHITECTURE.md rule 3).

/// The height of an emote in a line; badges are a little smaller.
enum TwitchChatMetrics {
    static let emote: CGFloat = 28
    static let badge: CGFloat = 18
    static let font = Font.system(size: 14.5)
}

struct TwitchChatRow: View, Equatable {
    let line: TwitchChatLine
    let paint: SevenTvPaint?
    let sevenTvBadge: ChatBadge?
    /// "add to a 7tv set…" on a 7TV emote's menu (the account is linked).
    let canAddEmotes: Bool
    /// Non-nil only in combined dual-stream mode: draws the left channel color stripe and compact 1-letter badge.
    var channelAccent: TwitchChannelAccent? = nil
    /// Protected channel accent hues in dual-stream mode so colliding Twitch username colors shift cleanly away.
    var avoidAccentHues: [Double] = []
    /// When true (dual-stream mode), tapping any non-deleted chat line locks composer target to that line's channel.
    var tapToReply: Bool = false

    var onReply: ((TwitchChatLine) -> Void)?
    var onAddEmote: ((ChatEmote) -> Void)?

    nonisolated static func == (a: TwitchChatRow, b: TwitchChatRow) -> Bool {
        a.line == b.line
            && a.paint == b.paint
            && a.sevenTvBadge == b.sevenTvBadge
            && a.canAddEmotes == b.canAddEmotes
            && a.channelAccent == b.channelAccent
            && a.avoidAccentHues == b.avoidAccentHues
            && a.tapToReply == b.tapToReply
    }

    @Environment(\.colorScheme) private var scheme

    var body: some View {
        switch line.kind {
        case .system:
            HStack(spacing: 5) {
                if let accent = channelAccent {
                    channelMarkBadge(accent)
                }
                Text(line.plainText)
                    .font(Font.cobalt(11.5, relativeTo: .caption))
                    .foregroundStyle(CobaltColor.caption)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 4)
        case .notice(let said):
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 5) {
                    if let accent = channelAccent {
                        channelMarkBadge(accent)
                    }
                    Text(said)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(TwitchChatPalette.twitch)
                }
                if !line.fragments.isEmpty { message }
            }
            .padding(.leading, 12)
            .padding(.trailing, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(noticeWash, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(alignment: .leading) {
                let stripe = channelAccent.map { TwitchChatPalette.accentColor($0) } ?? TwitchChatPalette.twitch
                Capsule()
                    .fill(
                        LinearGradient(
                            colors: [stripe, stripe.opacity(0.65)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .frame(width: 3)
                    .padding(.leading, 3)
                    .padding(.vertical, 5)
            }
        case .message, .action:
            let hasLeadingRail = line.mentionsMe || channelAccent != nil || line.mine
            VStack(alignment: .leading, spacing: 2) {
                if let reply = line.replyTo {
                    HStack(spacing: 4) {
                        Image(systemName: Symbol.Twitch.reply)
                            .font(.system(size: 9.5, weight: .semibold))
                        Text("\(Copy.Twitch.replyingTo(reply.displayName)): \(reply.text)")
                            .lineLimit(1)
                    }
                    .font(.system(size: 11))
                    .foregroundStyle(CobaltColor.caption)
                }
                message
            }
            .padding(.leading, hasLeadingRail ? 11 : 8)
            .padding(.trailing, 8)
            .padding(.vertical, line.mentionsMe ? 4 : 3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(rowWash, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(alignment: .leading) {
                leadingRail
            }
            .opacity(line.deleted ? 0.45 : 1)
            .contentShape(Rectangle())
            .modifier(TapToReplyModifier(enabled: tapToReply && onReply != nil && !line.deleted) {
                onReply?(line)
            })
            .contextMenu { menu }
        }
    }

    private var noticeWash: LinearGradient {
        LinearGradient(
            colors: [
                TwitchChatPalette.twitch.opacity(scheme == .dark ? 0.22 : 0.16),
                TwitchChatPalette.twitch.opacity(scheme == .dark ? 0.05 : 0.04),
            ],
            startPoint: .leading,
            endPoint: .trailing
        )
    }

    /// Option 1: directional left-to-right ambient wash that fades softly across the row (zero heavy box outline).
    private var rowWash: LinearGradient {
        if line.mentionsMe {
            return LinearGradient(
                colors: [
                    TwitchChatPalette.twitch.opacity(scheme == .dark ? 0.24 : 0.18),
                    TwitchChatPalette.twitch.opacity(scheme == .dark ? 0.04 : 0.03),
                ],
                startPoint: .leading,
                endPoint: .trailing
            )
        }
        if line.mine {
            return LinearGradient(
                colors: [
                    Color.primary.opacity(scheme == .dark ? 0.085 : 0.06),
                    Color.primary.opacity(scheme == .dark ? 0.015 : 0.01),
                ],
                startPoint: .leading,
                endPoint: .trailing
            )
        }
        return LinearGradient(colors: [.clear, .clear], startPoint: .leading, endPoint: .trailing)
    }

    /// Option 1: detached inset vertical Capsule rail (`2.5–3pt`) that never curves with corner clipping.
    /// Mentions always take precedence (even in dual-stream mode; the channel `[C]`/`[T]` badge keeps attribution clear).
    @ViewBuilder private var leadingRail: some View {
        if line.mentionsMe {
            Capsule()
                .fill(TwitchChatPalette.twitch)
                .frame(width: 3)
                .shadow(color: TwitchChatPalette.twitch.opacity(scheme == .dark ? 0.65 : 0.35), radius: 4)
                .padding(.leading, 3)
                .padding(.vertical, 4)
        } else if let accent = channelAccent {
            Capsule()
                .fill(TwitchChatPalette.accentColor(accent).opacity(0.85))
                .frame(width: 2.5)
                .padding(.leading, 3)
                .padding(.vertical, 4)
        } else if line.mine {
            Capsule()
                .fill(CobaltColor.caption.opacity(0.55))
                .frame(width: 2.5)
                .padding(.leading, 3)
                .padding(.vertical, 4)
        }
    }

    @ViewBuilder private var menu: some View {
        if let onReply, !line.deleted {
            Button(Copy.Twitch.reply, systemImage: Symbol.Twitch.reply) { onReply(line) }
        }
        Button(Copy.Twitch.copyText, systemImage: Symbol.Twitch.copy) { TwitchPasteboard.copy(line.plainText) }
        if canAddEmotes, let onAddEmote {
            ForEach(sevenTvEmotes, id: \.self) { emote in
                Button("\(Copy.Twitch.addToSet) \(emote.name)", systemImage: Symbol.SevenTv.add) { onAddEmote(emote) }
            }
        }
    }

    /// The line's 7TV emotes, once each.
    private var sevenTvEmotes: [ChatEmote] {
        var seen = Set<String>()
        var out: [ChatEmote] = []
        for f in line.fragments {
            let all: [ChatEmote]
            switch f {
            case .emote(let e): all = [e]
            case .stack(let e, let more): all = [e] + more
            default: all = []
            }
            for e in all where e.source != .twitch && seen.insert(e.id).inserted { out.append(e) }
        }
        return Array(out.prefix(4))
    }

    private var fallbackNameRGBA: SevenTvRGBA {
        TwitchChatPalette.rgbaValues(line.color, login: line.login, dark: scheme == .dark, avoiding: avoidAccentHues)
    }

    private var fallbackNameColor: Color {
        let c = fallbackNameRGBA
        return Color(.sRGB, red: Double(c.r), green: Double(c.g), blue: Double(c.b), opacity: Double(c.a))
    }

    private var nameStyle: AnyShapeStyle {
        if let paint, let style = TwitchChatPalette.style(for: paint) { return style }
        return AnyShapeStyle(fallbackNameColor)
    }

    private var message: some View {
        TwitchFlow(spacing: 4, lineSpacing: 2) {
            if let accent = channelAccent {
                channelMarkBadge(accent)
            }
            if line.mentionsMe {
                mentionMicroBadge
            }
            ForEach(Array(line.badges.enumerated()), id: \.offset) { _, badge in
                badgeView(badge)
            }
            if let sevenTvBadge { badgeView(sevenTvBadge) }
            nameView
            if line.kind == .message {
                Text(":").font(TwitchChatMetrics.font).foregroundStyle(CobaltColor.caption).padding(.leading, -4)
            }
            ForEach(Array(line.renderPieces.enumerated()), id: \.offset) { _, piece in
                pieceView(piece)
            }
        }
    }

    private var mentionMicroBadge: some View {
        Text("@")
            .font(.system(size: 9.5, weight: .heavy, design: .rounded))
            .foregroundStyle(TwitchChatPalette.twitch)
            .frame(width: 16, height: 16)
            .background(TwitchChatPalette.twitch.opacity(0.22), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .strokeBorder(TwitchChatPalette.twitch.opacity(0.45), lineWidth: 0.75)
            )
            .accessibilityHidden(true)
    }

    private func channelMarkBadge(_ accent: TwitchChannelAccent) -> some View {
        let tint = TwitchChatPalette.accentColor(accent)
        return Text(accent.mark)
            .font(.system(size: 10, weight: .bold, design: .rounded))
            .foregroundStyle(tint)
            .padding(.horizontal, accent.mark.count > 1 ? 3 : 0)
            .frame(minWidth: 16, minHeight: 16)
            .background(tint.opacity(0.18), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .strokeBorder(tint.opacity(0.45), lineWidth: 0.75)
            )
            .accessibilityLabel(Copy.TwitchDualChat.fromChannel(accent.displayName))
            .help(accent.displayName)
    }

    @ViewBuilder private var nameView: some View {
        if let paint {
            SevenTvPaintedLabel(
                text: line.displayName,
                font: TwitchChatMetrics.font.weight(.bold),
                paint: paint,
                fallback: fallbackNameRGBA
            )
        } else {
            Text(line.displayName)
                .font(TwitchChatMetrics.font.weight(.bold))
                .foregroundStyle(fallbackNameColor)
        }
    }

    private func badgeView(_ badge: ChatBadge) -> some View {
        EmotePicture(url: badge.url, animated: badge.animated, side: TwitchChatMetrics.badge)
            .frame(width: TwitchChatMetrics.badge, height: TwitchChatMetrics.badge)
            .accessibilityLabel(badge.title)
            .help(badge.title)
    }

    @ViewBuilder private func pieceView(_ piece: ChatRenderPiece) -> some View {
        switch piece {
        case .word(let w):
            Text(w)
                .font(TwitchChatMetrics.font)
                .foregroundStyle(line.kind == .action ? nameStyle : AnyShapeStyle(CobaltColor.text))
                .strikethrough(line.deleted)
        case .mention(let m):
            Text("@\(m)")
                .font(TwitchChatMetrics.font.weight(.semibold))
                .foregroundStyle(CobaltColor.text)
                .padding(.horizontal, 4)
                .background(
                    line.mentionsMe ? TwitchChatPalette.twitch.opacity(0.24) : CobaltColor.elevated,
                    in: RoundedRectangle(cornerRadius: 4, style: .continuous)
                )
        case .link(let url):
            Link(url.host() ?? url.absoluteString, destination: url)
                .font(TwitchChatMetrics.font)
                .foregroundStyle(CobaltColor.linkBlue)
                .lineLimit(1)
        case .emote(let base, let over):
            TwitchEmoteView(emote: base, over: over)
        }
    }
}

/// An emote at line height (wide ones wider), with zero-width emotes drawn on top.
struct TwitchEmoteView: View {
    let emote: ChatEmote
    var over: [ChatEmote] = []
    var height: CGFloat = TwitchChatMetrics.emote

    private var width: CGFloat { height * CGFloat(max(0.5, min(4, emote.aspect))) }

    var body: some View {
        ZStack {
            picture(emote, width: width)
            ForEach(Array(over.enumerated()), id: \.offset) { _, top in
                picture(top, width: height * CGFloat(max(0.5, min(4, top.aspect))))
            }
        }
        .frame(width: width, height: height)
        .accessibilityLabel(([emote] + over).map(\.name).joined(separator: " "))
        .help(emote.name)
    }

    private func picture(_ e: ChatEmote, width: CGFloat) -> some View {
        // EmotePicture is square: a wide emote gets a square as wide as it, cropped to the line's height
        EmotePicture(url: e.url, animated: e.animated, side: width)
            .frame(width: width, height: height)
            .clipped()
    }
}

/// Wraps its children like words: left to right, a new line when the next one does not fit, each line centred vertically.
/// Caches natural subview sizes and the last arranged rows across `sizeThatFits` -> `placeSubviews` so rotations and
/// scrolling do not measure every word twice.
struct TwitchFlow: Layout {
    var spacing: CGFloat = 4
    var lineSpacing: CGFloat = 2

    struct Cache {
        var naturalSizes: [CGSize] = []
        var lastWidth: CGFloat = -1
        var lastRows: [Row] = []
    }

    func makeCache(subviews: Subviews) -> Cache {
        var cache = Cache()
        cache.naturalSizes = subviews.map { $0.sizeThatFits(.unspecified) }
        return cache
    }

    func updateCache(_ cache: inout Cache, subviews: Subviews) {
        cache.naturalSizes = subviews.map { $0.sizeThatFits(.unspecified) }
        cache.lastWidth = -1
        cache.lastRows = []
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews, cache: &cache)
        let height = rows.reduce(0) { $0 + $1.height } + lineSpacing * CGFloat(max(0, rows.count - 1))
        let width = rows.map(\.width).max() ?? 0
        return CGSize(width: proposal.width ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) {
        let rows = arrange(width: bounds.width, subviews: subviews, cache: &cache)
        var y = bounds.minY
        for row in rows {
            var x = bounds.minX
            for item in row.items {
                let size = item.size
                subviews[item.index].place(
                    at: CGPoint(x: x, y: y + (row.height - size.height) / 2),
                    proposal: ProposedViewSize(width: size.width, height: size.height))
                x += size.width + spacing
            }
            y += row.height + lineSpacing
        }
    }

    struct Item {
        var index: Int
        var size: CGSize
    }

    struct Row {
        var items: [Item] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func arrange(width: CGFloat, subviews: Subviews, cache: inout Cache) -> [Row] {
        if cache.naturalSizes.count != subviews.count {
            cache.naturalSizes = subviews.map { $0.sizeThatFits(.unspecified) }
            cache.lastWidth = -1
        }
        if cache.lastWidth == width {
            return cache.lastRows
        }
        var rows: [Row] = []
        var row = Row()
        for i in subviews.indices {
            var size = cache.naturalSizes[i]
            if size.width > width {
                // a very long word or link: as wide as the line, wrapped inside
                size = subviews[i].sizeThatFits(ProposedViewSize(width: width, height: nil))
                size.width = min(size.width, width)
            }
            let needed = row.items.isEmpty ? size.width : row.width + spacing + size.width
            if needed > width, !row.items.isEmpty {
                rows.append(row)
                row = Row()
            }
            row.width = row.items.isEmpty ? size.width : row.width + spacing + size.width
            row.height = max(row.height, size.height)
            row.items.append(Item(index: i, size: size))
        }
        if !row.items.isEmpty { rows.append(row) }
        cache.lastWidth = width
        cache.lastRows = rows
        return rows
    }
}

private struct TapToReplyModifier: ViewModifier {
    let enabled: Bool
    let action: () -> Void

    func body(content: Content) -> some View {
        if enabled {
            content
                .onTapGesture(perform: action)
                .accessibilityHint(Copy.TwitchDualChat.tapToReplyHint)
        } else {
            content
        }
    }
}

enum TwitchChatPalette {
    static let twitch = Color(hex: 0x9146FF)

    static let primaryChannel = Color(
        light: TwitchChannelAccent.primaryLightRGB,
        dark: TwitchChannelAccent.primaryDarkRGB)
    static let secondaryChannel = Color(
        light: TwitchChannelAccent.secondaryLightRGB,
        dark: TwitchChannelAccent.secondaryDarkRGB)
    static let tertiaryChannel = Color(
        light: TwitchChannelAccent.tertiaryLightRGB,
        dark: TwitchChannelAccent.tertiaryDarkRGB)
    static let quaternaryChannel = Color(
        light: TwitchChannelAccent.quaternaryLightRGB,
        dark: TwitchChannelAccent.quaternaryDarkRGB)

    static func accentColor(_ accent: TwitchChannelAccent) -> Color {
        Color(light: accent.lightRGB, dark: accent.darkRGB)
    }

    static func dualAccentGradient(for accents: [TwitchChannelAccent]) -> LinearGradient {
        let colors: [Color]
        if accents.count >= 2 {
            colors = accents.map(accentColor)
        } else {
            colors = [primaryChannel, secondaryChannel]
        }
        return LinearGradient(colors: colors, startPoint: .leading, endPoint: .trailing)
    }

    static func rgbaValues(_ rgb: UInt32?, login: String, dark: Bool, avoiding accentHues: [Double] = []) -> SevenTvRGBA {
        let raw = rgb ?? TwitchUsernameColorShifter.defaultTwitchColor(for: login)
        let threshold: Double = accentHues.count >= 3 ? 18 : 24
        let safeDistance: Double = accentHues.count >= 3 ? 24 : 32
        let value = accentHues.isEmpty
            ? raw
            : TwitchUsernameColorShifter.shiftedIfColliding(
                raw,
                avoiding: accentHues,
                threshold: threshold,
                safeDistance: safeDistance)
        var r = Double((value >> 16) & 0xFF) / 255
        var g = Double((value >> 8) & 0xFF) / 255
        var b = Double(value & 0xFF) / 255
        let luma = 0.2126 * r + 0.7152 * g + 0.0722 * b
        // like Twitch: a name too dark for a dark page (or too light for a light one) is moved toward readable
        if dark, luma < 0.35 {
            let t = 0.45
            r += (1 - r) * t; g += (1 - g) * t; b += (1 - b) * t
        } else if !dark, luma > 0.75 {
            let t = 0.4
            r *= 1 - t; g *= 1 - t; b *= 1 - t
        }
        return SevenTvRGBA(r: Float(r), g: Float(g), b: Float(b), a: 1)
    }

    static func color(_ rgb: UInt32?, login: String, dark: Bool, avoiding accentHues: [Double] = []) -> Color {
        let c = rgbaValues(rgb, login: login, dark: dark, avoiding: accentHues)
        return Color(.sRGB, red: Double(c.r), green: Double(c.g), blue: Double(c.b), opacity: Double(c.a))
    }

    static func rgba(_ v: UInt32) -> Color {
        Color(
            .sRGB, red: Double((v >> 24) & 0xFF) / 255, green: Double((v >> 16) & 0xFF) / 255,
            blue: Double((v >> 8) & 0xFF) / 255, opacity: max(0.35, Double(v & 0xFF) / 255))
    }

    /// A 7TV paint as a SwiftUI ShapeStyle (used for `/me` action message text; usernames use `SevenTvPaintedLabel`).
    static func style(for paint: SevenTvPaint) -> AnyShapeStyle? {
        let primary = paint.resolvedLayers.last(where: { $0.kind != .image }) ?? paint.resolvedLayers.last
        let kind = primary?.kind ?? paint.kind
        let angle = primary?.angle ?? paint.angle
        let shape = primary?.shape ?? paint.shape
        let rawStops = primary.map { SevenTvPaint.resolveStops($0.stops, repeats: $0.repeats) } ?? paint.resolvedStops
        let stops = rawStops.map { Gradient.Stop(color: rgba($0.rgba), location: $0.at) }
        switch kind {
        case .plain:
            guard let c = primary?.color ?? paint.color else { return nil }
            return AnyShapeStyle(rgba(c))
        case .linear:
            guard !stops.isEmpty else { return (primary?.color ?? paint.color).map { AnyShapeStyle(rgba($0)) } }
            // CSS angles: 0 points up, 90 right
            let a = angle * .pi / 180
            let dx = sin(a) / 2
            let dy = -cos(a) / 2
            return AnyShapeStyle(LinearGradient(
                stops: stops, startPoint: UnitPoint(x: 0.5 - dx, y: 0.5 - dy), endPoint: UnitPoint(x: 0.5 + dx, y: 0.5 + dy)))
        case .radial:
            guard !stops.isEmpty else { return (primary?.color ?? paint.color).map { AnyShapeStyle(rgba($0)) } }
            if shape == .circle {
                return AnyShapeStyle(RadialGradient(stops: stops, center: .center, startRadius: 0, endRadius: 48))
            }
            return AnyShapeStyle(EllipticalGradient(stops: stops, center: .center, startRadiusFraction: 0, endRadiusFraction: 0.5))
        case .image:
            return (primary?.color ?? paint.color).map { AnyShapeStyle(rgba($0)) }
        }
    }
}

enum TwitchPasteboard {
    @MainActor static func copy(_ text: String) {
        #if os(iOS)
        UIPasteboard.general.string = text
        #else
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #endif
    }
}
