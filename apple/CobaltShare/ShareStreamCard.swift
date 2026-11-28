import CobaltKit
import SwiftUI

/// Compact Liquid Glass chooser shown in the iOS Share Extension when:
/// - a live Twitch / Kick / YouTube stream is shared while 1...3 streams are already playing in Capystore
///   ("Watch Now", "Add to Stream", subtle "Save Link Instead"),
/// - an ambiguous YouTube URL (`watch?v=...`, `youtu.be/...`, `/@handle`) is shared
///   ("Watch Live", optional "Add to Stream", "Save to Library"), or
/// - an automatic hand-off to Capystore needs an explicit tap to open.
struct ShareStreamCard: View {
    let match: SharedStreamMatch
    var openFailed: Bool = false
    let onWatch: (WatchDeepLinkMode) -> Void
    let onSaveInstead: () -> Void
    let close: () -> Void
    /// The content's own height, so `ShareViewController`'s `SheetFitter` sizes the sheet tightly.
    var onFit: ((CGFloat) -> Void)?

    private var platform: StreamPlatform { match.address.platform }

    private var subtitle: String {
        if openFailed { return ShareCopy.streamOpenRetry }
        if match.canAddToStream {
            return ShareCopy.streamActiveSubtitle(platform: platform, activeChannels: match.activeChannels)
        }
        if match.kind.isLive {
            return "Live on \(platform.displayName)"
        }
        return ShareCopy.streamYouTubeSubtitle
    }

    private var primaryTitle: String {
        match.kind.isLive ? ShareCopy.streamWatchNow : ShareCopy.streamWatchLive
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 12) {
                platformBadge
                VStack(alignment: .leading, spacing: 2) {
                    Text(match.address.displayLabel)
                        .font(CobaltType.bodySemibold)
                        .foregroundStyle(CobaltColor.text)
                        .lineLimit(1)
                    Text(subtitle)
                        .font(CobaltType.captionSmall)
                        .foregroundStyle(CobaltColor.caption)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                CloseButton(action: close)
            }

            GlassEffectContainer(spacing: 10) {
                VStack(spacing: 10) {
                    if match.canAddToStream {
                        ButtonRow {
                            Button(primaryTitle, systemImage: Symbol.Twitch.live) {
                                onWatch(.open)
                            }
                            .buttonStyle(.cobaltPrimary(compact: true))

                            Button(ShareCopy.streamAddToStream, systemImage: Symbol.Twitch.addStream) {
                                onWatch(.add)
                            }
                            .buttonStyle(.cobaltSecondary(compact: true))
                        }
                    } else {
                        Button(primaryTitle, systemImage: Symbol.Twitch.live) {
                            onWatch(.open)
                        }
                        .buttonStyle(.cobaltPrimary(compact: true))
                    }

                    if match.kind.isLive {
                        Button(action: onSaveInstead) {
                            Label(ShareCopy.streamSaveLinkInstead, systemImage: Symbol.save)
                                .font(CobaltType.caption)
                                .foregroundStyle(CobaltColor.caption)
                                .frame(maxWidth: .infinity, minHeight: Metrics.hit)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    } else {
                        Button(ShareCopy.streamSaveToLibrary, systemImage: Symbol.save, action: onSaveInstead)
                            .buttonStyle(.cobaltSecondary(compact: true))
                    }
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 18)
        .padding(.bottom, match.kind.isLive ? 10 : 20)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(CobaltColor.bg.ignoresSafeArea())
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { onFit?($0) }
        .dynamicTypeSize(...DynamicTypeSize.accessibility2)
        .accessibilityElement(children: .contain)
    }

    private var platformBadge: some View {
        let accent = Self.brandColor(for: platform)
        let ink: Color = platform == .kick ? .black : .white
        return Text(platform.badgeMark)
            .font(CobaltType.badge)
            .fontWeight(.bold)
            .foregroundStyle(ink)
            .frame(width: 34, height: 34)
            .background(accent, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .accessibilityLabel(platform.displayName)
    }

    private static func brandColor(for platform: StreamPlatform) -> Color {
        let rgb = platform.brandRGB
        let r = Double((rgb >> 16) & 0xFF) / 255.0
        let g = Double((rgb >> 8) & 0xFF) / 255.0
        let b = Double(rgb & 0xFF) / 255.0
        return Color(red: r, green: g, blue: b)
    }
}

#if DEBUG
#Preview("stream · twitch with active stream") {
    ShareStreamCard(
        match: SharedStreamMatch(
            url: URL(string: "https://www.twitch.tv/gigguk")!,
            kind: .live(StreamAddress(platform: .twitch, identifier: "gigguk")),
            activeChannels: ["caedrel"]
        ),
        onWatch: { _ in },
        onSaveInstead: {},
        close: {}
    )
}

#Preview("stream · ambiguous youtube") {
    ShareStreamCard(
        match: SharedStreamMatch(
            url: URL(string: "https://www.youtube.com/watch?v=jfKfPfyJRdk")!,
            kind: .ambiguousYouTube(StreamAddress(platform: .youtube, identifier: "jfKfPfyJRdk", youtubeTarget: .videoID("jfKfPfyJRdk"))),
            activeChannels: []
        ),
        onWatch: { _ in },
        onSaveInstead: {},
        close: {}
    )
}

#Preview("stream · kick open fallback") {
    ShareStreamCard(
        match: SharedStreamMatch(
            url: URL(string: "https://kick.com/xqc")!,
            kind: .live(StreamAddress(platform: .kick, identifier: "xqc")),
            activeChannels: []
        ),
        openFailed: true,
        onWatch: { _ in },
        onSaveInstead: {},
        close: {}
    )
}
#endif
