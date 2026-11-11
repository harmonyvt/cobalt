import AVFoundation
import CobaltKit
import SwiftUI

// The detail's video hero, rebuilt (owner, 2026-11-11: "the preview's unreliable, wrong aspect ratio, sometimes doesn't
// play"). One player over the whole clip, the same for a file on this device, a hosted mp4 and a private keyed stream:
//
// - the frame takes the picture's real shape, read from the playing item (`presentationSize`, which already has the
//   clip's rotation applied), never the record's guess; the shape is kept per clip so a second opening is right at once;
// - the player is a plain `AVPlayer` over the clip's own asset (no picture-only composition: a composition over a
//   streamed asset was the "sometimes it never starts" case), muted until the owner asks for sound;
// - a clip that fails, or shows no frame within `HeroVideo.giveUpAfter`, says so with a retry, instead of a poster that
//   never leaves;
// - leaving pauses and empties the player before the audio session is let go (off the main thread, `AudioPolicy`).

/// One hero's player and what it knows: loading, playing, failed, the picture's shape.
@MainActor @Observable
final class HeroVideo {
    enum Phase: Equatable { case idle, loading, ready, failed }

    /// How long a clip may take to show its first frame before the hero offers a retry.
    static let giveUpAfter: Duration = .seconds(20)

    private(set) var phase: Phase = .idle
    /// width / height of the picture as it plays (rotation applied); nil until the item knows it.
    private(set) var aspect: CGFloat?
    /// Frames have run at least once: the poster stays away from then on, so a paused clip shows its own frame.
    private(set) var hasFrames = false
    private(set) var player: AVPlayer?

    /// Shapes measured this launch, by clip: a clip opened again starts at its real shape.
    private static var shapes: [String: CGFloat] = [:]

    @ObservationIgnored private var url: URL?
    /// The orbit lent this player: leaving gives it back (muted, playing) instead of emptying it.
    @ObservationIgnored private var borrowed = false
    @ObservationIgnored private var watches: [NSKeyValueObservation] = []
    @ObservationIgnored private var tokens: [NSObjectProtocol] = []
    @ObservationIgnored private var watchdog: Task<Void, Never>?

    /// The shape this clip was measured at earlier in this launch.
    static func knownShape(of url: URL) -> CGFloat? { shapes[url.absoluteString] }

    // MARK: starting

    /// Plays `url` muted and looping, from `start`.
    func load(_ url: URL, from start: CMTime = .zero) async {
        stop()
        if self.url != url { aspect = Self.knownShape(of: url) }
        self.url = url
        phase = .loading
        AudioPolicy.ambient()
        // a private library file streams through its keyed loader (KeyedStream); anything else plays as it is
        let item = AVPlayerItem(asset: KeyedStream.asset(url))
        let next = AVPlayer(playerItem: item)
        next.isMuted = true
        next.actionAtItemEnd = .none
        player = next
        watch(next, item: item, loops: true)
        if start.isValid, start.isNumeric, start.seconds > 0 {
            await next.seek(to: start, toleranceBefore: .zero, toleranceAfter: CMTime(seconds: 0.2, preferredTimescale: 600))
        }
        guard player === next else { return }
        next.play()
        armWatchdog(for: next)
    }

    /// Shows a player someone else owns and keeps playing (the orbit's, already over the whole clip).
    func adopt(_ lent: AVPlayer) {
        stop()
        borrowed = true
        phase = .loading
        player = lent
        if let item = lent.currentItem { watch(lent, item: item, loops: false) }
    }

    // MARK: sound

    func setMuted(_ muted: Bool) {
        guard let player else { return }
        player.isMuted = muted
        if muted { AudioPolicy.release() } else { AudioPolicy.playback() }
    }

    // MARK: leaving

    /// Lets go of the player: an owned one is paused and emptied (its streams close now, not whenever it is freed), a
    /// borrowed one goes back muted.
    func stop() {
        watchdog?.cancel()
        watchdog = nil
        for w in watches { w.invalidate() }
        watches = []
        for t in tokens { NotificationCenter.default.removeObserver(t) }
        tokens = []
        if let player {
            if borrowed {
                player.isMuted = true
            } else {
                player.pause()
                player.replaceCurrentItem(with: nil)
            }
        }
        player = nil
        borrowed = false
        phase = .idle
        hasFrames = false
    }

    // MARK: watching

    /// The player on show is still `id` (a callback from a player this hero has let go of changes nothing).
    private func shows(_ id: ObjectIdentifier) -> Bool { player.map(ObjectIdentifier.init) == id }

    private func watch(_ player: AVPlayer, item: AVPlayerItem, loops: Bool) {
        // KVO and the item's notifications arrive on whatever thread AVFoundation is on: each hops to the main actor
        // and only touches this hero if the player is still the one it shows.
        let id = ObjectIdentifier(player)
        watches.append(player.observe(\.timeControlStatus, options: [.initial, .new]) { [weak self] observed, _ in
            let playing = observed.timeControlStatus == .playing
            Task { @MainActor [weak self] in
                guard let self, self.shows(id), playing else { return }
                self.hasFrames = true
                self.phase = .ready
                self.watchdog?.cancel()
            }
        })
        watches.append(item.observe(\.status, options: [.initial, .new]) { [weak self] observed, _ in
            let failed = observed.status == .failed
            Task { @MainActor [weak self] in
                guard let self, self.shows(id), failed else { return }
                self.fail()
            }
        })
        watches.append(item.observe(\.presentationSize, options: [.initial, .new]) { [weak self] observed, _ in
            let size = observed.presentationSize
            Task { @MainActor [weak self] in
                guard let self, self.shows(id), size.width > 0, size.height > 0 else { return }
                let shape = size.width / size.height
                if let url = self.url { Self.shapes[url.absoluteString] = shape }
                if self.aspect.map({ abs($0 - shape) > 0.005 }) ?? true { self.aspect = shape }
            }
        })
        let centre = NotificationCenter.default
        tokens.append(centre.addObserver(forName: AVPlayerItem.failedToPlayToEndTimeNotification, object: item, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.shows(id) else { return }
                self.fail()
            }
        })
        if loops {
            // a plain end-of-item seek, not an `AVPlayerLooper` (it stayed in "evaluating buffering rate" on the dev OS)
            tokens.append(centre.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification, object: item, queue: .main) { [weak player] _ in
                player?.seek(to: .zero)
                player?.play()
            })
        }
    }

    private func armWatchdog(for player: AVPlayer) {
        watchdog?.cancel()
        let id = ObjectIdentifier(player)
        watchdog = Task { [weak self] in
            try? await Task.sleep(for: Self.giveUpAfter)
            guard !Task.isCancelled, let self, self.shows(id), !self.hasFrames else { return }
            self.fail()
        }
    }

    private func fail() {
        watchdog?.cancel()
        player?.pause()
        phase = .failed
    }
}

/// The video hero: the picture at its real shape under the media controls, the poster until frames run, a retry when the
/// clip will not play. Used for a file on this device and for a hosted or streamed clip alike.
struct HeroVideoBox: View {
    let url: URL
    /// The clip's name, for the full-screen player and VoiceOver.
    let name: String
    /// The corner capsule (`mp4`, `mov`).
    let label: String
    /// The shape the record carries (nil: not known). The measured shape replaces it once the clip runs.
    var recordedAspect: CGFloat?
    var maxHeight: CGFloat = 420
    /// The poster this device keeps.
    var poster: URL?
    /// The server's poster, or the first frame of a public file.
    var remoteStill: RemotePoster?
    /// The clip is not on this device (the small cloud badge until the bar is up).
    var streamed = false
    /// The orbit's player for this planet, when it lent it.
    var lent: LentPlayer?

    @State private var video = HeroVideo()
    @State private var transport = HeroTransport()
    @State private var muted = true
    /// The orbit's short-loop player, shown while this hero's own one gets its first frames up (never played from here).
    @State private var bridge: AVPlayer?
    /// The clip's first frame, for a file on this device with no poster.
    @State private var firstFrame: CGImage?
    @State private var fullScreen: HeroFullScreen?
    /// The clip was running when the full-screen player took over.
    @State private var wasPlaying = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The measured shape, else what this launch measured before, else the record's, else a landscape frame.
    private var shape: CGFloat {
        let raw = video.aspect ?? HeroVideo.knownShape(of: url) ?? recordedAspect ?? 16.0 / 9.0
        // a sliver or a ribbon is still a frame you can see and tap
        return min(max(raw, 0.25), 4)
    }

    private var hasBar: Bool { video.player != nil && video.phase != .failed && (video.hasFrames || transport.isPlaying) }

    var body: some View {
        ZStack {
            Rectangle().fill(FrameGradient.fill(1))
            if !video.hasFrames, bridge == nil {
                posterLayer.allowsHitTesting(false)
            }
            if let player = video.player {
                // in the tree from the start, so its layer has the first frame when it shows; invisible until frames run
                PlayerSurface(player: player, gravity: .resizeAspect).allowsHitTesting(false).opacity(video.hasFrames ? 1 : 0)
            }
            if let bridge, !video.hasFrames {
                PlayerSurface(player: bridge, gravity: .resizeAspect).allowsHitTesting(false)
            }
            if video.phase == .failed {
                failedLayer
            } else if video.phase == .loading, !video.hasFrames, bridge == nil {
                LoadingSpinner()
            }
        }
        .animation(.easeOut(duration: 0.2), value: video.hasFrames)
        .overlay(alignment: .bottomLeading) {
            if streamed, !hasBar { cloudBadge }
        }
        .overlay {
            if hasBar {
                HeroControls(transport: transport, muted: muted, onSound: toggleSound, onFullScreen: { openFullScreen() })
            }
        }
        .heroFrame(aspect: shape, maxHeight: maxHeight, label: label, expand: hasBar || video.phase == .failed ? nil : { openFullScreen() })
        .animation(reduceMotion ? nil : .easeOut(duration: 0.22), value: shape)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { if !hasBar { openFullScreen() } }
        .task(id: url) { await start() }
        .onDisappear { leave() }
        .heroFullScreen(item: $fullScreen) { closedFullScreen(at: $0) }
        #if DEBUG
        .task(id: url) {
            // `-previewHeroFullScreen 1` (simulator evidence): opens the full-screen player by itself
            guard UserDefaults.standard.bool(forKey: "previewHeroFullScreen") else { return }
            try? await Task.sleep(for: .seconds(2.5))
            openFullScreen()
        }
        #endif
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Copy.Media.heroA11y(name, evicted: streamed))
    }

    // MARK: pieces

    @ViewBuilder
    private var posterLayer: some View {
        if let poster {
            StillImage(url: poster)
        } else if let firstFrame {
            // held to the hero's box: a bare `scaledToFill` reports its overflow as its size
            Color.clear.overlay { Image(decorative: firstFrame, scale: 1).resizable().scaledToFill() }.clipped()
        } else if let remoteStill {
            RemoteStill(poster: remoteStill, maxPixel: 960)
        }
    }

    private var failedLayer: some View {
        Button { retry() } label: {
            VStack(spacing: 6) {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 16, weight: .semibold))
                    .frame(width: 40, height: 40)
                    .background(CobaltColor.badgeBack, in: Circle())
                Text(Copy.Media.heroCannotPlay)
                    .font(Font.cobalt(12, .medium, relativeTo: .caption))
            }
            .foregroundStyle(CobaltColor.badgeInk)
            .padding(10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Copy.Media.heroRetryA11y)
    }

    private var cloudBadge: some View {
        Image(systemName: Symbol.offlineMissing)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(CobaltColor.badgeInk)
            .frame(width: 24, height: 24)
            .background(CobaltColor.badgeBack, in: Circle())
            .padding(8)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    // MARK: life

    private func start() async {
        var resume = CMTime.zero
        if let lent {
            if lent.wholeClip {
                // the planet's own player, already over the whole clip: the picture is on screen now
                video.adopt(lent.player)
                transport.attach(lent.player)
                return
            }
            // the orbit's player loops only the first seconds: it holds the picture while this hero's own player, over
            // the whole clip, starts from where the orbit's is
            bridge = lent.player
            resume = lent.player.currentTime()
        }
        if poster == nil, bridge == nil, url.isFileURL { firstFrame = await Self.frame(of: url) }
        guard !Task.isCancelled else { return }
        await video.load(url, from: resume)
        guard !Task.isCancelled else { return }
        transport.attach(video.player)
    }

    private func leave() {
        // the player stops before the sound is let go: deactivating a session with audio still running is what held
        // the main thread on the way back to the library
        // the orbit's own player goes back to the orbit still playing (a pause was the owner's, and ends here)
        if let lent, video.player === lent.player { transport.resumeIfPausedByUser() }
        transport.detach()
        video.stop()
        if !muted { AudioPolicy.release() }
        muted = true
        bridge = nil
    }

    /// The same clip again, from the start: after a failure or a stall.
    private func retry() {
        Task {
            await video.load(url)
            transport.attach(video.player)
        }
    }

    private func toggleSound() {
        muted.toggle()
        video.setMuted(muted)
    }

    private func openFullScreen() {
        guard video.phase != .failed else { retry(); return }
        let seconds = video.player?.currentTime().seconds ?? 0
        let start = seconds.isFinite && seconds > 0 ? CMTime(seconds: seconds, preferredTimescale: 600) : .zero
        wasPlaying = transport.isPlaying
        if !muted {
            muted = true
            video.setMuted(true)
        }
        video.player?.pause()
        var transaction = Transaction()
        transaction.disablesAnimations = reduceMotion
        withTransaction(transaction) { fullScreen = .video(url: url, name: name, start: start) }
    }

    /// Back from the full-screen player: the same clip, muted, from where it got to.
    private func closedFullScreen(at time: CMTime?) {
        guard let player = video.player else { return }
        player.isMuted = true
        let resumes = wasPlaying
        Task {
            if let time, time.isValid { await player.seek(to: time) }
            if resumes { player.play() }
        }
    }

    /// The first frame of a file on this device, so the hero is never an empty box while the player starts.
    private static func frame(of url: URL) async -> CGImage? {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 720, height: 720)
        return try? await generator.image(at: .zero).image
    }
}

/// A small spinner over the poster while a clip is on its way. It waits a moment first, so a quick start never flashes it.
private struct LoadingSpinner: View {
    @State private var shown = false

    var body: some View {
        ProgressView()
            .tint(CobaltColor.badgeInk)
            .padding(10)
            .background(CobaltColor.badgeBack, in: Circle())
            .opacity(shown ? 1 : 0)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .task {
                try? await Task.sleep(for: .milliseconds(700))
                withAnimation(.easeOut(duration: 0.2)) { shown = true }
            }
    }
}
