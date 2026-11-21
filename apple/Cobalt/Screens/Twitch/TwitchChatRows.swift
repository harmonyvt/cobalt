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

    var onReply: ((TwitchChatLine) -> Void)?
    var onAddEmote: ((ChatEmote) -> Void)?

    nonisolated static func == (a: TwitchChatRow, b: TwitchChatRow) -> Bool {
        a.line == b.line && a.paint == b.paint && a.sevenTvBadge == b.sevenTvBadge && a.canAddEmotes == b.canAddEmotes
    }

    @Environment(\.colorScheme) private var scheme

    var body: some View {
        switch line.kind {
        case .system:
            Text(line.plainText)
                .font(Font.cobalt(11.5, relativeTo: .caption))
                .foregroundStyle(CobaltColor.caption)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 4)
        case .notice(let said):
            VStack(alignment: .leading, spacing: 4) {
                Text(said)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(TwitchChatPalette.twitch)
                if !line.fragments.isEmpty { message }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(TwitchChatPalette.twitch.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
            .overlay(alignment: .leading) { Rectangle().fill(TwitchChatPalette.twitch).frame(width: 3) }
            .clipShape(RoundedRectangle(cornerRadius: 10))
        case .message, .action:
            VStack(alignment: .leading, spacing: 2) {
                if let reply = line.replyTo {
                    Label {
                        Text("\(Copy.Twitch.replyingTo(reply.displayName)): \(reply.text)").lineLimit(1)
                    } icon: {
                        Image(systemName: Symbol.Twitch.reply)
                    }
                    .font(.system(size: 11))
                    .foregroundStyle(CobaltColor.caption)
                    .labelStyle(.titleAndIcon)
                }
                message
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(background, in: RoundedRectangle(cornerRadius: 8))
            .overlay(alignment: .leading) {
                if line.mentionsMe { Rectangle().fill(TwitchChatPalette.twitch).frame(width: 3) }
            }
            .opacity(line.deleted ? 0.45 : 1)
            .contentShape(Rectangle())
            .contextMenu { menu }
        }
    }

    private var background: Color {
        if line.mentionsMe { return TwitchChatPalette.twitch.opacity(0.16) }
        if line.mine { return CobaltColor.hairline }
        return .clear
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

    private var nameStyle: AnyShapeStyle {
        if let paint, let style = TwitchChatPalette.style(for: paint) { return style }
        return AnyShapeStyle(TwitchChatPalette.color(line.color, login: line.login, dark: scheme == .dark))
    }

    private var message: some View {
        TwitchFlow(spacing: 4, lineSpacing: 2) {
            ForEach(Array(line.badges.enumerated()), id: \.offset) { _, badge in
                badgeView(badge)
            }
            if let sevenTvBadge { badgeView(sevenTvBadge) }
            Text(line.displayName)
                .font(TwitchChatMetrics.font.weight(.bold))
                .foregroundStyle(nameStyle)
            if line.kind == .message {
                Text(":").font(TwitchChatMetrics.font).foregroundStyle(CobaltColor.caption).padding(.leading, -4)
            }
            ForEach(Array(pieces.enumerated()), id: \.offset) { _, piece in
                pieceView(piece)
            }
        }
    }

    private func badgeView(_ badge: ChatBadge) -> some View {
        EmotePicture(url: badge.url, animated: false, side: TwitchChatMetrics.badge)
            .frame(width: TwitchChatMetrics.badge, height: TwitchChatMetrics.badge)
            .accessibilityLabel(badge.title)
            .help(badge.title)
    }

    /// The fragments as wrap-able pieces: each word its own piece.
    private enum Piece {
        case word(String)
        case emote(ChatEmote, [ChatEmote])
        case mention(String)
        case link(URL)
    }

    private var pieces: [Piece] {
        var out: [Piece] = []
        for f in line.fragments {
            switch f {
            case .text(let s):
                for w in s.split(separator: " ", omittingEmptySubsequences: true) { out.append(.word(String(w))) }
            case .emote(let e): out.append(.emote(e, []))
            case .stack(let e, let more): out.append(.emote(e, more))
            case .mention(let m): out.append(.mention(m))
            case .link(let u): out.append(.link(u))
            }
        }
        return out
    }

    @ViewBuilder private func pieceView(_ piece: Piece) -> some View {
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
                .padding(.horizontal, 3)
                .background(CobaltColor.elevated, in: RoundedRectangle(cornerRadius: 4))
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
struct TwitchFlow: Layout {
    var spacing: CGFloat = 4
    var lineSpacing: CGFloat = 2

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        let height = rows.reduce(0) { $0 + $1.height } + lineSpacing * CGFloat(max(0, rows.count - 1))
        let width = rows.map(\.width).max() ?? 0
        return CGSize(width: proposal.width ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let rows = arrange(width: bounds.width, subviews: subviews)
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

    private struct Item {
        var index: Int
        var size: CGSize
    }

    private struct Row {
        var items: [Item] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func arrange(width: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = []
        var row = Row()
        for (i, sub) in subviews.enumerated() {
            var size = sub.sizeThatFits(.unspecified)
            if size.width > width {
                // a very long word or link: as wide as the line, wrapped inside
                size = sub.sizeThatFits(ProposedViewSize(width: width, height: nil))
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
        return rows
    }
}

enum TwitchChatPalette {
    static let twitch = Color(hex: 0x9146FF)

    /// Twitch's default name colours, for people who never picked one.
    private static let defaults: [UInt32] = [
        0xFF0000, 0x0000FF, 0x008000, 0xB22222, 0xFF7F50, 0x9ACD32, 0xFF4500, 0x2E8B57,
        0xDAA520, 0xD2691E, 0x5F9EA0, 0x1E90FF, 0xFF69B4, 0x8A2BE2, 0x00FF7F,
    ]

    static func color(_ rgb: UInt32?, login: String, dark: Bool) -> Color {
        let value = rgb ?? defaults[Int(login.unicodeScalars.reduce(UInt32(0)) { $0 &+ $1.value } % UInt32(defaults.count))]
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
        return Color(.sRGB, red: r, green: g, blue: b, opacity: 1)
    }

    static func rgba(_ v: UInt32) -> Color {
        Color(
            .sRGB, red: Double((v >> 24) & 0xFF) / 255, green: Double((v >> 16) & 0xFF) / 255,
            blue: Double((v >> 8) & 0xFF) / 255, opacity: max(0.35, Double(v & 0xFF) / 255))
    }

    /// A 7TV paint as a fill for the name.
    static func style(for paint: SevenTvPaint) -> AnyShapeStyle? {
        let stops = paint.stops.map { Gradient.Stop(color: rgba($0.rgba), location: $0.at) }
        switch paint.kind {
        case .plain:
            guard let c = paint.color else { return nil }
            return AnyShapeStyle(rgba(c))
        case .linear:
            // CSS angles: 0 points up, 90 right
            let a = paint.angle * .pi / 180
            let dx = sin(a) / 2
            let dy = -cos(a) / 2
            return AnyShapeStyle(LinearGradient(
                stops: stops, startPoint: UnitPoint(x: 0.5 - dx, y: 0.5 - dy), endPoint: UnitPoint(x: 0.5 + dx, y: 0.5 + dy)))
        case .radial:
            return AnyShapeStyle(RadialGradient(stops: stops, center: .center, startRadius: 0, endRadius: 60))
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
