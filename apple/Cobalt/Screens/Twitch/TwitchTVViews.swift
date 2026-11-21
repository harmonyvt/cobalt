import CobaltKit
import SwiftUI

// The phone side of the stream on a TV (APP-API-CONTRACT 70.5): the card that stands in for the player while the TV plays
// it, and the "watch on the tv" sheet behind the tv button. iPhone and iPad only; the Mac drags windows to a TV itself.

#if os(iOS)
/// In place of the player while capystore's window is on the TV: what's on, how far behind live, and the few controls that
/// matter from the couch.
struct TwitchTVCard: View {
    let model: AppModel
    var compact = false

    private var tv: TwitchTV { .shared }
    private var host: TwitchPlayerHost { .shared }
    private var store: TwitchStore { model.twitch }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                still
                    .frame(width: compact ? 112 : 176)
                VStack(alignment: .leading, spacing: 4) {
                    Label(Copy.Twitch.onTV, systemImage: Symbol.Twitch.tv)
                        .font(Font.cobalt(12, .semibold))
                        .foregroundStyle(TwitchTVPalette.tv)
                    Text(store.channelInfo?.displayName ?? store.channel ?? "")
                        .font(Font.cobalt(compact ? 14 : 16, .semibold))
                        .foregroundStyle(CobaltColor.text)
                        .lineLimit(1)
                    if let s = store.stream {
                        Text(s.title)
                            .font(Font.cobalt(12.5))
                            .foregroundStyle(CobaltColor.caption)
                            .lineLimit(compact ? 1 : 2)
                    }
                    TwitchDelayBadge(host: host)
                }
                Spacer(minLength: 0)
            }
            HStack(spacing: 6) {
                control(tv.dimmed ? Copy.Twitch.undim : Copy.Twitch.dim,
                        icon: tv.dimmed ? Symbol.Twitch.undim : Symbol.Twitch.dim, on: tv.dimmed) { tv.toggleDim() }
                control(Copy.Twitch.toLive, icon: Symbol.Twitch.jumpToLive, on: false) { host.jumpToLive() }
                    .disabled(host.delay == nil || host.isCatchingUp)
                control(Copy.Twitch.chatOnTV, icon: Symbol.Twitch.chatOnTV, on: tv.chatOnTV) { tv.chatOnTV.toggle() }
                control(Copy.Twitch.mirrorInstead, icon: Symbol.Twitch.mirror, on: false) { tv.wanted = false }
            }
        }
        .padding(10)
        .background(CobaltColor.surface, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(TwitchTVPalette.tv.opacity(0.35)))
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    /// Twitch's preview still for the channel (refreshed by Twitch every few minutes): not the stream itself, which plays
    /// once, on the TV.
    private var still: some View {
        ZStack {
            Rectangle().fill(CobaltColor.frameBase)
            if let url = store.stream?.thumbnail { StillImage(url: url) }
            Image(systemName: Symbol.Twitch.tv)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.white)
                .padding(6)
                .background(.black.opacity(0.5), in: Circle())
        }
        .aspectRatio(16 / 9, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .mediaMask()
    }

    private func control(_ title: String, icon: String, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: icon).font(.system(size: 15, weight: .semibold))
                Text(title).font(Font.cobalt(11, .medium)).lineLimit(1).minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity, minHeight: Metrics.hit)
            .foregroundStyle(on ? TwitchTVPalette.onTV : CobaltColor.text)
            .background(on ? TwitchTVPalette.tv : CobaltColor.elevated, in: RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

/// "watch on the tv": tv mode (screen mirroring, capystore's own picture on the TV) or video only (AirPlay).
struct TwitchTVSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable private var tv = TwitchTV.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text(Copy.Twitch.tvTitle)
                        .font(Font.cobalt(18, .semibold))
                        .foregroundStyle(CobaltColor.text)
                    Spacer()
                    Button(Copy.Twitch.close, systemImage: Symbol.Twitch.close) { dismiss() }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.cobaltSecondary(fullWidth: false, compact: true))
                }
                tvMode
                videoOnly
            }
            .padding(16)
        }
        .background(CobaltColor.bg)
        // tv mode took over: nothing left to choose here
        .onChange(of: tv.onTV) { _, on in if on { dismiss() } }
    }

    private var tvMode: some View {
        option(selected: true) {
            HStack {
                Label(Copy.Twitch.tvModeTitle, systemImage: Symbol.Twitch.tv)
                    .font(Font.cobalt(15, .semibold))
                    .foregroundStyle(CobaltColor.text)
                Spacer()
                Text(Copy.Twitch.tvModeBadge)
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(TwitchTVPalette.tv)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(TwitchTVPalette.tv.opacity(0.12), in: Capsule())
            }
            Text(Copy.Twitch.tvModeBody)
                .font(Font.cobalt(13))
                .foregroundStyle(CobaltColor.caption)
                .fixedSize(horizontal: false, vertical: true)
            if tv.screenConnected, !tv.wanted {
                Button(Copy.Twitch.tvModeUse) { tv.wanted = true }
                    .buttonStyle(.cobaltPrimary(fullWidth: true, compact: true))
            } else {
                VStack(alignment: .leading, spacing: 7) {
                    ForEach(Array(Copy.Twitch.tvModeSteps.enumerated()), id: \.offset) { i, step in
                        HStack(spacing: 9) {
                            Text("\(i + 1)")
                                .font(Font.cobalt(11.5, .semibold))
                                .frame(width: 22, height: 22)
                                .background(CobaltColor.elevated, in: Circle())
                            Text(step).font(Font.cobalt(13))
                        }
                        .foregroundStyle(CobaltColor.text)
                    }
                }
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small).tint(TwitchTVPalette.tv)
                    Text(Copy.Twitch.tvModeWaiting)
                        .font(Font.cobalt(12.5))
                        .foregroundStyle(TwitchTVPalette.tv)
                }
            }
        }
    }

    private var videoOnly: some View {
        option(selected: false) {
            Label(Copy.Twitch.videoOnlyTitle, systemImage: Symbol.Twitch.airPlay)
                .font(Font.cobalt(15, .semibold))
                .foregroundStyle(CobaltColor.text)
            Text(Copy.Twitch.videoOnlyBody)
                .font(Font.cobalt(13))
                .foregroundStyle(CobaltColor.caption)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                Menu {
                    Picker(Copy.Twitch.chatDelayTitle, selection: $tv.chatDelay) {
                        ForEach(TwitchTV.delayChoices, id: \.self) { s in
                            Text(Copy.Twitch.chatDelayChoice(s)).tag(s)
                        }
                    }
                } label: {
                    Label(Copy.Twitch.chatDelay(tv.chatDelay), systemImage: Symbol.Twitch.slow)
                        .font(Font.cobalt(12.5, .medium))
                        .padding(.horizontal, 12)
                        .frame(minHeight: 34)
                        .background(CobaltColor.elevated, in: Capsule())
                        .foregroundStyle(CobaltColor.text)
                }
                Spacer()
                TwitchAirPlayButton()
                    .frame(width: Metrics.hit, height: Metrics.hit)
                    .background(CobaltColor.elevated, in: Circle())
                    .accessibilityLabel(Copy.Twitch.pickTV)
            }
        }
    }

    private func option<Content: View>(selected: Bool, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 9) { content() }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(CobaltColor.surface, in: RoundedRectangle(cornerRadius: 18))
            .overlay {
                if selected { RoundedRectangle(cornerRadius: 18).strokeBorder(TwitchTVPalette.tv, lineWidth: 2) }
            }
    }
}
#endif

enum TwitchTVPalette {
    /// The cyan that means "going out to a TV" (the mockup's seam light).
    static let tv = Color(red: 0.16, green: 0.85, blue: 0.96)
    static let onTV = Color(red: 0, green: 0.07, blue: 0.09)
}
