import CobaltKit
import ImageIO
import SwiftUI

// The cards of post frames (APP-API-CONTRACT 52, the mockup's section 4), drawn natively for the sheet's live preview: one
// small view per style, original drawings in each site's layout (no logos, no artwork of the sites). The server draws the
// real card (52.5); these only have to read the same. Player controls and buttons that only work on the site are left out.

/// Everything a card draws.
struct PostCardContent: Equatable {
    var details: PostDetails?
    var style: PostFrameStyle
    var theme: PostFrameTheme
    var show: PostFrameShow
    /// The video's width over its height (16:9 = 1.78).
    var videoAspect: CGFloat
    var poster: URL?
    var duration: Double?
    var avatar: Data?

    /// Who posted it: the name, else the site's host, else a placeholder.
    var name: String { details?.displayName ?? details?.host ?? "unknown" }
    /// The handle with its `@`, else `@` and the name without spaces.
    var handle: String {
        if let h = details?.handle, !h.isEmpty { return h.hasPrefix("@") ? h : "@\(h)" }
        return "@" + name.lowercased().replacingOccurrences(of: " ", with: "")
    }
    var text: String? { details?.text }
    var title: String? { details?.title ?? details?.text }
    var channel: String { details?.channel ?? name }
    var date: String? { details?.postedAt.map { Copy.PostFrame.cardDate($0) } }
    var counts: PostCounts { details?.counts ?? PostCounts() }
    var site: String { details?.siteName ?? details?.host ?? "link" }

    /// The video's box: very tall videos are shown at most 1.25× as tall as wide (52.5), very wide ones at 2:1.
    var slotAspect: CGFloat { min(2, max(0.8, videoAspect.isFinite && videoAspect > 0 ? videoAspect : 16 / 9)) }

    var palette: PostCardPalette { PostCardPalette(style: style, theme: theme) }
}

/// One card, by style.
struct PostFrameCard: View {
    let content: PostCardContent

    var body: some View {
        Group {
            switch content.style {
            case .x: XPostCard(c: content)
            case .instagram: InstagramPostCard(c: content)
            case .twitch: TwitchPostCard(c: content)
            case .youtube: YouTubePostCard(c: content)
            case .generic: GenericPostCard(c: content)
            }
        }
        .environment(\.colorScheme, content.theme == .dark ? .dark : .light)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Copy.PostFrame.preview)
    }

    /// The card's drawn width (the server's card is at most 1080 px wide; these are the mockup's sizes).
    static func width(_ style: PostFrameStyle) -> CGFloat {
        switch style {
        case .twitch, .youtube: return 420
        case .x, .instagram, .generic: return 360
        }
    }
}

// MARK: - colours

/// Each style's colours, light and dark (the mockup's).
struct PostCardPalette {
    let background: Color
    let text: Color
    let secondary: Color
    let line: Color
    let card: Color
    let accent: Color

    init(style: PostFrameStyle, theme: PostFrameTheme) {
        let dark = theme == .dark
        switch style {
        case .x:
            background = Color(hex: dark ? 0x000000 : 0xffffff)
            text = Color(hex: dark ? 0xe7e9ea : 0x0f1419)
            secondary = Color(hex: dark ? 0x8b98a5 : 0x536471)
            line = Color(hex: dark ? 0x2f3336 : 0xe5e7eb)
            card = Color(hex: dark ? 0x16181c : 0xf3f4f6)
            accent = Color(hex: 0x1d9bf0)
        case .instagram:
            background = Color(hex: dark ? 0x000000 : 0xffffff)
            text = Color(hex: dark ? 0xf5f5f5 : 0x0a0a0a)
            secondary = Color(hex: dark ? 0xa8a8a8 : 0x737373)
            line = Color(hex: dark ? 0x262626 : 0xdbdbdb)
            card = Color(hex: dark ? 0x121212 : 0xfafafa)
            accent = Color(hex: 0xe9457a)
        case .twitch:
            background = Color(hex: dark ? 0x0e0e10 : 0xf7f7f8)
            text = Color(hex: dark ? 0xefeff1 : 0x0e0e10)
            secondary = Color(hex: dark ? 0xadadb8 : 0x53535f)
            line = Color(hex: dark ? 0x2f2f35 : 0xdedee3)
            card = Color(hex: dark ? 0x1f1f23 : 0xe6e6ea)
            accent = Color(hex: 0x8a5cf6)
        case .youtube:
            background = Color(hex: dark ? 0x0f0f0f : 0xffffff)
            text = Color(hex: dark ? 0xf1f1f1 : 0x0f0f0f)
            secondary = Color(hex: dark ? 0xaaaaaa : 0x606060)
            line = Color(hex: dark ? 0x3f3f3f : 0xe5e5e5)
            card = Color(hex: dark ? 0x272727 : 0xf2f2f2)
            accent = Color(hex: dark ? 0xf1f1f1 : 0x0f0f0f)
        case .generic:
            background = Color(hex: dark ? 0x141519 : 0xffffff)
            text = Color(hex: dark ? 0xe9eaee : 0x1b1d24)
            secondary = Color(hex: dark ? 0x9196a4 : 0x6b7080)
            line = Color(hex: dark ? 0x2a2c33 : 0xe3e5ea)
            card = Color(hex: dark ? 0x1d1f25 : 0xf4f5f8)
            accent = Color(hex: 0x2563eb)
        }
    }

    /// A letter avatar's colour, steady for a name.
    static func avatarColor(for name: String) -> Color {
        let colors: [UInt32] = [0xe9457a, 0xd97706, 0x7c3aed, 0x059669, 0x2563eb, 0x0891b2, 0xdc2626]
        let sum = name.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xffff }
        return Color(hex: colors[sum % colors.count])
    }
}

// MARK: - shared parts

/// The round avatar: the stored picture, else the name's first letter on its colour.
struct PostAvatar: View {
    let name: String
    let data: Data?
    let size: CGFloat

    private var initial: String { name.first.map { String($0).uppercased() } ?? "?" }

    private var picture: CGImage? {
        guard let data, let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    var body: some View {
        ZStack {
            Circle().fill(PostCardPalette.avatarColor(for: name))
            Text(initial)
                .font(.system(size: size * 0.42, weight: .bold))
                .foregroundStyle(.white)
            if let picture {
                Image(decorative: picture, scale: 1).resizable().scaledToFill()
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
    }
}

/// Where the video plays: the server's poster (or a dark gradient), a play mark, and the length.
struct PostVideoSlot: View {
    let c: PostCardContent
    let width: CGFloat
    var radius: CGFloat = 0
    var badge: String?

    private var height: CGFloat { (width / c.slotAspect).rounded() }

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(hex: 0x2a2a30), Color(hex: 0x0d0d10)], startPoint: .top, endPoint: .bottom)
            if let poster = c.poster {
                RemoteStill(poster: RemotePoster(url: poster, isVideo: false), maxPixel: 720)
            }
            PostPlayMark()
        }
        .frame(width: width, height: height)
        .overlay(alignment: .bottomLeading) { lengthBadge }
        .overlay(alignment: .topLeading) { cornerBadge }
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
    }

    @ViewBuilder
    private var lengthBadge: some View {
        if let d = c.duration, d.isFinite, d > 0 {
            PostBadge(text: Copy.Editor.clock(d)).padding(8)
        }
    }

    @ViewBuilder
    private var cornerBadge: some View {
        if let badge { PostBadge(text: badge).padding(8) }
    }
}

private struct PostPlayMark: View {
    var body: some View {
        Image(systemName: Symbol.PostFrame.play)
            .font(.system(size: 16, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: 42, height: 42)
            .background(Circle().fill(Color.black.opacity(0.45)))
    }
}

private struct PostBadge: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .bold))
            .monospacedDigit()
            .foregroundStyle(.white)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 4).fill(Color.black.opacity(0.65)))
    }
}

/// An icon and a count, in a row of counts.
private struct PostCount: View {
    let symbol: String
    let value: Int?

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: symbol).font(.system(size: 13))
            if let value { Text(PostCounts.compact(value)).font(.system(size: 12.5)) }
        }
    }
}

// MARK: - x

struct XPostCard: View {
    let c: PostCardContent

    private var p: PostCardPalette { c.palette }
    private var column: CGFloat { PostFrameCard.width(.x) - 28 - (c.show.avatar ? 50 : 0) }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            if c.show.avatar { PostAvatar(name: c.name, data: c.avatar, size: 40) }
            VStack(alignment: .leading, spacing: 0) {
                header
                if c.show.text, let text = c.text {
                    Text(text).font(.system(size: 14)).foregroundStyle(p.text)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 2)
                }
                PostVideoSlot(c: c, width: column, radius: 14)
                    .overlay { RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(p.line, lineWidth: 1) }
                    .padding(.top, 10)
                if c.show.counts { counts }
            }
            .frame(width: column, alignment: .leading)
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 10)
        .frame(width: PostFrameCard.width(.x), alignment: .leading)
        .background(p.background)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var header: some View {
        HStack(spacing: 4) {
            Text(c.name).font(.system(size: 14, weight: .bold)).foregroundStyle(p.text).lineLimit(1)
            if c.details?.verified == true {
                Image(systemName: Symbol.PostFrame.verified).font(.system(size: 13)).foregroundStyle(p.accent)
            }
            Text(handleLine).font(.system(size: 14)).foregroundStyle(p.secondary).lineLimit(1)
            Spacer(minLength: 4)
            Image(systemName: Symbol.PostFrame.more).font(.system(size: 13)).foregroundStyle(p.secondary)
        }
    }

    private var handleLine: String {
        if c.show.time, let date = c.date { return "\(c.handle) · \(date)" }
        return c.handle
    }

    private var counts: some View {
        HStack {
            PostCount(symbol: Symbol.PostFrame.reply, value: c.counts.replies)
            Spacer()
            PostCount(symbol: Symbol.PostFrame.repost, value: c.counts.reposts)
            Spacer()
            PostCount(symbol: Symbol.PostFrame.like, value: c.counts.likes)
            Spacer()
            PostCount(symbol: Symbol.PostFrame.views, value: c.counts.views)
        }
        .foregroundStyle(p.secondary)
        .padding(.top, 10)
        .padding(.horizontal, 4)
    }
}

// MARK: - instagram

struct InstagramPostCard: View {
    let c: PostCardContent

    private var p: PostCardPalette { c.palette }
    private var width: CGFloat { PostFrameCard.width(.instagram) }
    /// Instagram's posts run from 4:5 to 1.91:1.
    private var slot: PostCardContent {
        var out = c
        out.videoAspect = min(1.91, max(0.8, c.slotAspect))
        return out
    }
    /// The ring around the avatar (an original gradient).
    private static let ring = AngularGradient(
        colors: [Color(hex: 0xf5a524), Color(hex: 0xe9457a), Color(hex: 0xa855f7), Color(hex: 0xf5a524)],
        center: .center, angle: .degrees(200))

    private var user: String {
        let h = c.handle
        return h.hasPrefix("@") ? String(h.dropFirst()) : h
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            PostVideoSlot(c: slot, width: width)
            actions
            caption
        }
        .frame(width: width, alignment: .leading)
        .background(p.background)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var header: some View {
        HStack(spacing: 9) {
            if c.show.avatar {
                PostAvatar(name: user, data: c.avatar, size: 30)
                    .padding(2)
                    .background(Circle().fill(p.background))
                    .padding(2)
                    .background(Circle().fill(Self.ring))
            }
            Text(user).font(.system(size: 13.5, weight: .semibold)).foregroundStyle(p.text).lineLimit(1)
            Text("• \(Copy.PostFrame.Card.follow)").font(.system(size: 13.5)).foregroundStyle(p.secondary)
            Spacer(minLength: 4)
            Image(systemName: Symbol.PostFrame.more).foregroundStyle(p.text)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private var actions: some View {
        HStack(spacing: 14) {
            Image(systemName: Symbol.PostFrame.like)
            Image(systemName: Symbol.PostFrame.comment)
            Image(systemName: Symbol.PostFrame.send)
            Spacer()
            Image(systemName: Symbol.PostFrame.bookmark)
        }
        .font(.system(size: 20))
        .foregroundStyle(p.text)
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 4)
    }

    private var caption: some View {
        VStack(alignment: .leading, spacing: 3) {
            if c.show.counts, let likes = c.counts.likes {
                Text(Copy.PostFrame.Card.likes(likes)).font(.system(size: 13.5, weight: .semibold)).foregroundStyle(p.text)
            }
            if c.show.text, let text = c.text {
                Text("\(Text(user).fontWeight(.semibold)) \(text)")
                    .font(.system(size: 13.5))
                    .foregroundStyle(p.text)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if c.show.counts, let comments = c.counts.comments {
                Text(Copy.PostFrame.Card.comments(comments)).font(.system(size: 13.5)).foregroundStyle(p.secondary)
            }
            if c.show.time, let date = c.date {
                Text(date).font(.system(size: 11.5)).foregroundStyle(p.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 12)
    }
}

// MARK: - twitch

struct TwitchPostCard: View {
    let c: PostCardContent

    private var p: PostCardPalette { c.palette }
    private var width: CGFloat { PostFrameCard.width(.twitch) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PostVideoSlot(c: c, width: width, badge: Copy.PostFrame.Card.clip)
            HStack(alignment: .top, spacing: 12) {
                if c.show.avatar {
                    PostAvatar(name: c.channel, data: c.avatar, size: 42)
                        .padding(2)
                        .overlay(Circle().stroke(p.accent, lineWidth: 2))
                }
                info
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .padding(.bottom, 14)
        }
        .frame(width: width, alignment: .leading)
        .background(p.background)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var info: some View {
        VStack(alignment: .leading, spacing: 3) {
            if c.show.text, let title = c.title {
                Text(title).font(.system(size: 15, weight: .bold)).foregroundStyle(p.text)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(c.channel).font(.system(size: 13.5, weight: .semibold)).foregroundStyle(p.accent)
            if let game = c.details?.game {
                Text(game).font(.system(size: 13)).foregroundStyle(p.secondary)
            }
            if let line = metaLine {
                Text(line).font(.system(size: 12.5)).foregroundStyle(p.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// `clipped by nightowl_44 · 58K views · Nov 6`.
    private var metaLine: String? {
        var parts: [String] = []
        if let name = c.details?.name, name != c.channel { parts.append(Copy.PostFrame.Card.clippedBy(name)) }
        if c.show.counts, let views = c.counts.views { parts.append(Copy.PostFrame.Card.views(views)) }
        if c.show.time, let date = c.date { parts.append(date) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

// MARK: - youtube

struct YouTubePostCard: View {
    let c: PostCardContent

    private var p: PostCardPalette { c.palette }
    private var width: CGFloat { PostFrameCard.width(.youtube) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PostVideoSlot(c: c, width: width)
            if c.show.text, let title = c.details?.title ?? c.text {
                Text(title).font(.system(size: 16.5, weight: .bold)).foregroundStyle(p.text)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 12)
                    .padding(.top, 10)
                    .padding(.bottom, 8)
            } else {
                Color.clear.frame(height: 10)
            }
            channelRow
            aboutBox
        }
        .padding(.bottom, 12)
        .frame(width: width, alignment: .leading)
        .background(p.background)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var channelRow: some View {
        HStack(spacing: 10) {
            if c.show.avatar { PostAvatar(name: c.channel, data: c.avatar, size: 36) }
            VStack(alignment: .leading, spacing: 1) {
                Text(c.channel).font(.system(size: 14, weight: .semibold)).foregroundStyle(p.text).lineLimit(1)
                if c.show.counts, let subs = c.counts.subscribers {
                    Text(Copy.PostFrame.Card.subscribers(subs)).font(.system(size: 12)).foregroundStyle(p.secondary)
                }
            }
            Text(Copy.PostFrame.Card.subscribe)
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(p.background)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Capsule().fill(p.text))
            Spacer(minLength: 4)
            if c.show.counts, let likes = c.counts.likes {
                PostCount(symbol: Symbol.PostFrame.thumbUp, value: likes)
                    .foregroundStyle(p.text)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(p.card))
            }
        }
        .padding(.horizontal, 12)
    }

    /// `2.3M views  Nov 9, 2025`.
    private var topLine: String {
        var parts: [String] = []
        if c.show.counts, let views = c.counts.views { parts.append(Copy.PostFrame.Card.views(views)) }
        if c.show.time, let date = c.date { parts.append(date) }
        return parts.joined(separator: "  ")
    }

    /// The description, when the title is drawn above it.
    private var about: String? { c.show.text && c.details?.title != nil ? c.text : nil }

    @ViewBuilder
    private var aboutBox: some View {
        let top = topLine
        if !top.isEmpty || about != nil {
            VStack(alignment: .leading, spacing: 3) {
                if !top.isEmpty { Text(top).font(.system(size: 13, weight: .semibold)).foregroundStyle(p.text) }
                if let about {
                    Text(about).font(.system(size: 13)).foregroundStyle(p.text).lineLimit(3)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 11)
            .padding(.vertical, 9)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(p.card))
            .padding(.horizontal, 12)
            .padding(.top, 10)
        }
    }
}

// MARK: - generic

struct GenericPostCard: View {
    let c: PostCardContent

    private var p: PostCardPalette { c.palette }
    private var width: CGFloat { PostFrameCard.width(.generic) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            siteRow
            header
            words
            PostVideoSlot(c: c, width: width - 26, radius: 10)
            HStack {
                Text("\(c.details?.host ?? c.site)/…")
                Spacer()
                Text(Copy.PostFrame.Card.savedWith)
            }
            .font(.system(size: 12))
            .foregroundStyle(p.secondary)
            .padding(.top, 9)
        }
        .padding(12)
        .frame(width: width, alignment: .leading)
        .background(p.background)
        .overlay { RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(p.line, lineWidth: 1) }
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var siteRow: some View {
        HStack(spacing: 8) {
            Text(c.site.first.map { String($0).uppercased() } ?? "•")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(p.text)
                .frame(width: 18, height: 18)
                .background(RoundedRectangle(cornerRadius: 5).fill(p.card))
                .overlay { RoundedRectangle(cornerRadius: 5).stroke(p.line, lineWidth: 1) }
            Text(c.site).font(.system(size: 12)).foregroundStyle(p.secondary)
        }
        .padding(.bottom, 10)
    }

    private var header: some View {
        HStack(spacing: 10) {
            if c.show.avatar { PostAvatar(name: c.name, data: c.avatar, size: 32) }
            VStack(alignment: .leading, spacing: 1) {
                Text(c.name).font(.system(size: 13.5, weight: .semibold)).foregroundStyle(p.text).lineLimit(1)
                if c.show.time, let date = c.date {
                    Text(date).font(.system(size: 12)).foregroundStyle(p.secondary)
                }
            }
        }
        .padding(.bottom, 8)
    }

    @ViewBuilder
    private var words: some View {
        if c.show.text, c.details?.title != nil || c.text != nil {
            VStack(alignment: .leading, spacing: 3) {
                if let title = c.details?.title {
                    Text(title).font(.system(size: 14, weight: .semibold)).foregroundStyle(p.text)
                }
                if let text = c.text {
                    Text(text).font(.system(size: 13)).foregroundStyle(p.secondary).lineLimit(4)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            .padding(.bottom, 10)
        }
    }
}

// MARK: - fitting a card into the sheet

/// A card at its own size, scaled down to fit a box; on a 9:16 or 1:1 canvas, centred on a blurred, darkened copy of the
/// video, as the server makes it (52.2).
struct PostFramePreview: View {
    let content: PostCardContent
    let canvas: PostFrameCanvas
    let maxWidth: CGFloat
    let maxHeight: CGFloat

    @State private var cardSize = CGSize(width: 360, height: 480)

    private var canvasSize: CGSize {
        switch canvas {
        case .fit: return fitted(cardSize, into: CGSize(width: maxWidth, height: maxHeight))
        case .portrait: return fitted(CGSize(width: 9, height: 16), into: CGSize(width: maxWidth, height: maxHeight))
        case .square: return fitted(CGSize(width: 1, height: 1), into: CGSize(width: maxWidth, height: maxHeight))
        }
    }

    /// The card's scale inside the canvas (a margin of 8% on a 9:16 or 1:1 canvas).
    private var cardScale: CGFloat {
        let box = canvasSize
        let room = canvas == .fit ? box : CGSize(width: box.width * 0.84, height: box.height * 0.84)
        guard cardSize.width > 0, cardSize.height > 0 else { return 1 }
        return min(room.width / cardSize.width, room.height / cardSize.height, 1.5)
    }

    var body: some View {
        ZStack {
            if canvas != .fit { PostCanvasBackdrop(poster: content.poster) }
            PostFrameCard(content: content)
                .fixedSize()
                .onGeometryChange(for: CGSize.self) { $0.size } action: { cardSize = $0 }
                .scaleEffect(cardScale)
                .frame(width: cardSize.width * cardScale, height: cardSize.height * cardScale)
        }
        .frame(width: canvasSize.width, height: canvasSize.height)
        .clipShape(RoundedRectangle(cornerRadius: canvas == .fit ? 0 : 8, style: .continuous))
        .motion(Motion.card, value: canvas)
    }

    private func fitted(_ size: CGSize, into box: CGSize) -> CGSize {
        guard size.width > 0, size.height > 0 else { return box }
        let s = min(box.width / size.width, box.height / size.height)
        return CGSize(width: (size.width * s).rounded(), height: (size.height * s).rounded())
    }
}

/// The blurred, darkened video behind a card on a 9:16 or 1:1 canvas.
private struct PostCanvasBackdrop: View {
    let poster: URL?

    var body: some View {
        ZStack {
            Color.black
            if let poster {
                RemoteStill(poster: RemotePoster(url: poster, isVideo: false), maxPixel: 240)
                    .blur(radius: 14)
                    .brightness(-0.35)
                    .scaleEffect(1.2)
            }
        }
    }
}
