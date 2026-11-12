import AuthenticationServices
import CobaltKit
import SwiftUI

// The music group of the studio tab (APP-API-CONTRACT 56.7): the Spotify connection, what is playing, the card on the
// canvas, song requests (the `song` reward's switch and cost, edited in the same sheet as the other rewards), the request
// rules, turning the music down on summons, and the songs waiting with "skip current". Shown only with
// `capabilities.stageSpotify`. Every switch is sent at once and put back if the server refuses; "down to" is a debounced slider.

struct StageMusicCard: View {
    let model: AppModel
    let stage: StageSettings
    let controller: StageController

    @Environment(\.shell) private var shell

    private var store: StageStore { controller.store }
    /// The music as the store holds it now (a switch shows at once), else as this render was given it.
    private var music: StageMusic { store.stage?.music ?? stage.music ?? StageMusic() }

    var body: some View {
        StageCard(title: Copy.Stage.music) {
            StageSpotifyRow(model: model, spotify: music.spotify, controller: controller)
            if music.spotify != nil {
                StageNowPlaying(nowPlaying: music.nowPlaying)
            }
            Divider().overlay(CobaltColor.hairline)
            settings
            Divider().overlay(CobaltColor.hairline)
            StageUpNext(music: music, controller: controller)
        }
    }

    // MARK: the settings

    @ViewBuilder
    private var settings: some View {
        cardPicker
        upNextSwitch
        songRequests
        youtubeSwitch
        longestSong
        waiting
        explicitSwitch
        duckSwitch
        if music.duck { duckLevel }
    }

    private var cardPicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(Copy.Stage.musicCard)
                .font(CobaltType.bodySemibold)
                .foregroundStyle(CobaltColor.text)
            Picker(
                Copy.Stage.musicCard,
                selection: Binding<StageMusic.Card>(
                    get: { music.card },
                    set: { controller.setMusic(StagePatch(musicCard: $0), key: "card", shell: shell) })
            ) {
                ForEach(StageMusic.Card.allCases) { card in
                    Text(Copy.Stage.cardName(card)).tag(card)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .accessibilityLabel(Copy.Stage.musicCard)
        }
    }

    private var upNextSwitch: some View {
        StageSwitchRow(
            title: Copy.Stage.upNextToggle, note: Copy.Stage.upNextToggleNote,
            isOn: Binding(
                get: { music.upNext },
                set: { controller.setMusic(StagePatch(musicUpNext: $0), key: "upNext", shell: shell) }),
            busy: controller.isBusy("music-upNext"))
    }

    private var songRequests: some View {
        StageSongRequestRow(reward: store.reward(.song), twitchConnected: stage.twitch != nil, controller: controller)
    }

    private var youtubeSwitch: some View {
        StageSwitchRow(
            title: Copy.Stage.youtubeLinks, note: Copy.Stage.youtubeLinksNote,
            isOn: Binding(
                get: { music.songYouTube },
                set: { controller.setMusic(StagePatch(songYouTube: $0), key: "youtube", shell: shell) }),
            busy: controller.isBusy("music-youtube"))
    }

    private var longestSong: some View {
        HStack {
            Text(Copy.Stage.longestSong)
                .font(CobaltType.bodySemibold)
                .foregroundStyle(CobaltColor.text)
            Spacer(minLength: 8)
            Picker(
                Copy.Stage.longestSong,
                selection: Binding<Int>(
                    get: { music.songMaxSeconds },
                    set: { controller.setMusic(StagePatch(songMaxSeconds: $0), key: "length", shell: shell) })
            ) {
                ForEach(lengthChoices, id: \.self) { seconds in
                    Text(Copy.Stage.songLength(seconds)).tag(seconds)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .accessibilityLabel(Copy.Stage.longestSong)
            .disabled(controller.isBusy("music-length"))
        }
        .frame(minHeight: Metrics.hit)
    }

    /// 3, 5, 10, 15 and 30 minutes, and the server's own value when it is none of those.
    private var lengthChoices: [Int] {
        var choices = StageRule.songSecondsChoices
        if !choices.contains(music.songMaxSeconds) {
            choices.append(music.songMaxSeconds)
            choices.sort()
        }
        return choices
    }

    private var waiting: some View {
        Stepper(
            Copy.Stage.waitingAtMost(music.songQueueMax),
            value: Binding<Int>(
                get: { music.songQueueMax },
                set: { controller.setMusic(StagePatch(songQueueMax: $0), key: "queue", shell: shell) }),
            in: StageRule.songQueueRange
        )
        .font(CobaltType.bodySemibold)
        .foregroundStyle(CobaltColor.text)
        .frame(minHeight: Metrics.hit)
        .disabled(controller.isBusy("music-queue"))
    }

    private var explicitSwitch: some View {
        StageSwitchRow(
            title: Copy.Stage.explicitSongs, note: Copy.Stage.explicitSongsNote,
            isOn: Binding(
                get: { music.songExplicit },
                set: { controller.setMusic(StagePatch(songExplicit: $0), key: "explicit", shell: shell) }),
            busy: controller.isBusy("music-explicit"))
    }

    private var duckSwitch: some View {
        StageSwitchRow(
            title: Copy.Stage.duckToggle, note: Copy.Stage.duckToggleNote,
            isOn: Binding(
                get: { music.duck },
                set: { controller.setMusic(StagePatch(duck: $0), key: "duck", shell: shell) }),
            busy: controller.isBusy("music-duck"))
    }

    private var duckLevel: some View {
        StageSliderRow(
            title: Copy.Stage.duckTo, value: Copy.Stage.percent(music.duckVolume), low: nil, high: nil,
            number: Binding(
                get: { Double(music.duckVolume) },
                set: { store.setDuckVolume(Int($0.rounded())) }),
            range: Double(StageRule.duckVolumeRange.lowerBound)...Double(StageRule.duckVolumeRange.upperBound), step: 5)
    }
}

// MARK: - the Spotify connection

/// "connect spotify", or the account with "connect again" when its sign-in ran out, a note when it is not premium, and a
/// disconnect (which asks first).
private struct StageSpotifyRow: View {
    let model: AppModel
    let spotify: StageMusic.Spotify?
    let controller: StageController

    @Environment(\.shell) private var shell
    @Environment(\.webAuthenticationSession) private var webAuthentication

    var body: some View {
        if let spotify {
            connected(spotify)
        } else {
            notConnected
        }
    }

    // MARK: connected

    private func connected(_ spotify: StageMusic.Spotify) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            account(spotify)
            buttons(spotify)
        }
    }

    private func account(_ spotify: StageMusic.Spotify) -> some View {
        let needsSignIn = spotify.status == .reconnect
        return HStack(alignment: .top, spacing: 10) {
            Image(systemName: needsSignIn ? Symbol.stageMusicWarn : Symbol.stageMusic)
                .font(.system(size: 17))
                .foregroundStyle(needsSignIn ? CobaltColor.errorText : CobaltColor.success)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(Copy.Stage.connectedAsSpotify(spotify.displayName))
                    .font(CobaltType.bodyMedium)
                    .foregroundStyle(CobaltColor.text)
                if needsSignIn {
                    Text(Copy.Stage.spotifyNeedsReconnect)
                        .font(CobaltType.captionSmall)
                        .foregroundStyle(CobaltColor.errorText)
                } else if !spotify.isPremium {
                    Text(Copy.Stage.premiumNote)
                        .font(CobaltType.captionSmall)
                        .foregroundStyle(CobaltColor.errorText)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func buttons(_ spotify: StageMusic.Spotify) -> some View {
        GlassEffectContainer(spacing: 10) {
            HStack(spacing: 10) {
                if spotify.status == .reconnect {
                    Button(Copy.Stage.connectAgain, systemImage: Symbol.stageConnect) {
                        controller.connectSpotify(using: webAuthentication, shell: shell)
                    }
                    .buttonStyle(.cobaltPrimary(compact: true))
                    .disabled(controller.connectingSpotify || !model.capabilities.stageSpotify)
                }
                Button { controller.confirmingSpotifyDisconnect = true } label: {
                    Label(Copy.Stage.disconnect, systemImage: Symbol.stageDisconnect)
                }
                .buttonStyle(.cobaltIcon(state: controller.isBusy("spotify") ? .working : .idle))
                .disabled(controller.isBusy("spotify"))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: not connected

    private var notConnected: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(Copy.Stage.spotifyNotConnectedBody)
                .font(CobaltType.caption)
                .foregroundStyle(CobaltColor.caption)
            Button(
                controller.connectingSpotify ? Copy.Stage.connecting : Copy.Stage.connectSpotify, systemImage: Symbol.stageConnect
            ) {
                controller.connectSpotify(using: webAuthentication, shell: shell)
            }
            .buttonStyle(.cobaltPrimary(compact: true))
            .disabled(controller.connectingSpotify || !model.capabilities.stageSpotify)
        }
    }
}

// MARK: - now playing

/// The cover, the title, and "artist · requested by @name"; "nothing is playing" otherwise.
private struct StageNowPlaying: View {
    let nowPlaying: StageMusic.NowPlaying?

    var body: some View {
        if let nowPlaying {
            playing(nowPlaying)
        } else {
            Text(Copy.Stage.nothingPlaying)
                .font(CobaltType.caption)
                .foregroundStyle(CobaltColor.caption)
        }
    }

    private func playing(_ np: StageMusic.NowPlaying) -> some View {
        let line = Copy.Stage.nowPlayingLine(artist: np.artist, by: np.by)
        return HStack(spacing: 12) {
            StageCover(url: np.artURL, size: 44)
            VStack(alignment: .leading, spacing: 2) {
                Text(np.playing ? Copy.Stage.nowPlaying : Copy.Stage.paused)
                    .font(CobaltType.badge)
                    .foregroundStyle(CobaltColor.caption)
                Text(np.title)
                    .font(CobaltType.bodySemibold)
                    .foregroundStyle(CobaltColor.text)
                    .lineLimit(1)
                if !line.isEmpty {
                    Text(line)
                        .font(CobaltType.captionSmall)
                        .foregroundStyle(CobaltColor.caption)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .opacity(np.playing ? 1 : 0.6)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Copy.Stage.nowPlayingA11y(title: np.title, line: line, playing: np.playing))
    }
}

/// A square cover on the video-frame grey, with a note while it has no picture.
private struct StageCover: View {
    let url: URL?
    var size: CGFloat = 40

    var body: some View {
        ZStack {
            Rectangle().fill(FrameGradient.fill(0))
            if let url {
                RemoteStill(poster: RemotePoster(url: url, isVideo: false), maxPixel: max(120, Int(size * 3)))
            } else {
                Image(systemName: Symbol.stageMusic)
                    .font(.system(size: size * 0.4))
                    .foregroundStyle(CobaltColor.badgeInk)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: Metrics.radius, style: .continuous))
        .accessibilityHidden(true)
    }
}

// MARK: - song requests

/// The `song` reward: its switch, its cost and cooldown (a tap opens the same editor as the other rewards).
private struct StageSongRequestRow: View {
    let reward: StageReward?
    let twitchConnected: Bool
    let controller: StageController

    @Environment(\.shell) private var shell

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Button {
                controller.editingReward = .song
            } label: {
                label
            }
            .buttonStyle(.plain)
            .disabled(reward == nil)
            .accessibilityHint(Copy.Stage.editHint)
            Toggle(isOn: Binding(
                get: { reward?.enabled ?? false },
                set: { controller.setReward(.song, enabled: $0, shell: shell) })
            ) {
                Text(Copy.Stage.rewardToggleA11y(.song, on: reward?.enabled ?? false))
            }
            .labelsHidden()
            .toggleStyle(.switch)
            .tint(CobaltColor.success)
            .disabled(reward == nil || controller.isBusy("reward-song"))
        }
        .frame(minHeight: Metrics.hit)
    }

    private var label: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(Copy.Stage.songRequests)
                .font(CobaltType.bodySemibold)
                .foregroundStyle(CobaltColor.text)
            if let reward {
                Text(Copy.Stage.rewardLine(cost: reward.cost, cooldownSeconds: reward.cooldownSeconds))
                    .font(CobaltType.caption)
                    .foregroundStyle(CobaltColor.caption)
            }
            Text(twitchConnected ? Copy.Stage.songRequestsNote : Copy.Stage.songNeedsTwitch)
                .font(CobaltType.badge)
                .foregroundStyle(CobaltColor.caption)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }
}

// MARK: - up next

/// The songs waiting, oldest first, "n of max", and "skip current".
private struct StageUpNext: View {
    let music: StageMusic
    let controller: StageController

    @Environment(\.shell) private var shell

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            if music.queue.isEmpty {
                Text(Copy.Stage.upNextEmpty)
                    .font(CobaltType.caption)
                    .foregroundStyle(CobaltColor.caption)
            } else {
                ForEach(music.queue) { song in
                    StageSongRow(song: song)
                }
            }
            if music.spotify != nil {
                Button(Copy.Stage.skipCurrent, systemImage: Symbol.stageMusicSkip) { controller.skipSong(shell: shell) }
                    .buttonStyle(.cobaltSecondary(fullWidth: false, compact: true))
                    .disabled(controller.isBusy("song-skip"))
                    .accessibilityHint(Copy.Stage.skipHint)
            }
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(Copy.Stage.upNext)
                .font(CobaltType.bodySemibold)
                .foregroundStyle(CobaltColor.text)
            Spacer(minLength: 8)
            Text(Copy.Stage.upNextCount(music.queue.count, max: music.songQueueMax))
                .font(CobaltType.caption)
                .foregroundStyle(CobaltColor.caption)
                .monospacedDigit()
        }
        .accessibilityElement(children: .combine)
    }
}

private struct StageSongRow: View {
    let song: StageMusic.Song

    var body: some View {
        HStack(spacing: 10) {
            StageCover(url: song.artURL, size: 36)
            VStack(alignment: .leading, spacing: 1) {
                Text(song.title)
                    .font(CobaltType.bodyMedium)
                    .foregroundStyle(CobaltColor.text)
                    .lineLimit(1)
                Text(detail)
                    .font(CobaltType.captionSmall)
                    .foregroundStyle(CobaltColor.caption)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(song.title), \(detail)")
    }

    private var detail: String {
        var parts: [String] = []
        if !song.artist.isEmpty { parts.append(song.artist) }
        let viewer = Copy.Stage.requestedBy(song.by)
        if !viewer.isEmpty { parts.append(viewer) }
        if song.source == .youtube { parts.append(Copy.Stage.fromYouTube) }
        return parts.joined(separator: " · ")
    }
}
