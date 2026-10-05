import AVFoundation
import CobaltKit
import SwiftUI

// Media controls for a hero (the focus planet and the detail's video): a slim glass bar on the picture's bottom edge,
// play or pause, a scrubber, elapsed and remaining time, sound, full screen. App only: nothing here is compiled into
// the share extension (it lives beside the detail, not in `Cobalt/Shared`).
//
// The transport reads the hero's own player (the focus holder's, the detail's, the orbit's lent one); it never makes
// one. A tap on the picture shows or hides the bar, it hides by itself after 3 s of playing, it stays up while the
// clip is paused or the finger is on the scrubber, and a double tap goes full screen.

// MARK: - the transport

/// What the bar knows about one hero's player: playing or not, where it is, how long the clip is, and whether the bar
/// is showing. One per hero view; `attach` points it at a player, `detach` lets go.
@MainActor @Observable
final class HeroTransport {
    /// How long the bar stays up while the clip plays.
    static let hideAfter: Duration = .seconds(3)

    private(set) var isPlaying = false
    /// The owner paused it (not a stall): closing the hero puts a paused player back to work.
    private(set) var pausedByUser = false
    private(set) var time: Double = 0
    private(set) var duration: Double = 0
    private(set) var isScrubbing = false
    /// The bar has been asked for (a tap, a button, the clip starting); it goes after `hideAfter`.
    private(set) var revealed = true
    /// Counts the times a drag reached the first or the last frame: a haptic follows each one.
    private(set) var endHits = 0

    var hasPlayer: Bool { player != nil }

    /// Where the thumb sits, 0...1.
    var fraction: Double { duration > 0 ? min(1, max(0, time / duration)) : 0 }

    /// The bar is on screen: asked for, or the clip is not playing, or a finger is on the scrubber.
    var barShown: Bool { revealed || !isPlaying || isScrubbing }

    @ObservationIgnored private(set) weak var player: AVPlayer?
    @ObservationIgnored private var timeToken: Any?
    @ObservationIgnored private var statusWatch: NSKeyValueObservation?
    @ObservationIgnored private var hideTask: Task<Void, Never>?
    @ObservationIgnored private var chase: Task<Void, Never>?
    @ObservationIgnored private var pending: (time: CMTime, tolerance: CMTime)?
    @ObservationIgnored private var resumeAfterScrub = false
    @ObservationIgnored private var atEnd: Int?     // -1 first frame, 1 last frame, nil in between

    // MARK: attaching

    func attach(_ new: AVPlayer?) {
        guard new !== player else { return }
        detach()
        guard let new else { return }
        player = new
        // The observer's queue is the main queue and the closure is `@Sendable`, so nothing here is inferred
        // main-actor: it states the isolation it is running on (CONCURRENCY RULE, a system-called closure is never
        // left to inference).
        timeToken = new.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.1, preferredTimescale: 600), queue: .main
        ) { [weak self] now in
            MainActor.assumeIsolated { self?.tick(now) }
        }
        statusWatch = new.observe(\.timeControlStatus, options: [.initial, .new]) { [weak self] observed, _ in
            let running = observed.timeControlStatus != .paused
            Task { @MainActor in self?.statusChanged(running) }
        }
        tick(new.currentTime())
    }

    func detach() {
        if let player, let timeToken { player.removeTimeObserver(timeToken) }
        timeToken = nil
        statusWatch?.invalidate()
        statusWatch = nil
        hideTask?.cancel()
        chase?.cancel()
        chase = nil
        pending = nil
        player = nil
        isPlaying = false
        isScrubbing = false
        time = 0
        duration = 0
    }

    private func tick(_ now: CMTime) {
        if let item = player?.currentItem {
            let d = item.duration.seconds
            if d.isFinite, d > 0, abs(d - duration) > 0.01 { duration = d }
        }
        guard !isScrubbing, now.isValid else { return }
        let t = now.seconds
        if t.isFinite { time = min(max(0, t), duration > 0 ? duration : t) }
    }

    private func statusChanged(_ running: Bool) {
        guard running != isPlaying else { return }
        isPlaying = running
        if running { reveal() } else { hideTask?.cancel() }
    }

    // MARK: showing and hiding

    /// Shows the bar and starts its 3 s.
    func reveal() {
        revealed = true
        hideTask?.cancel()
        guard isPlaying else { return }
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: Self.hideAfter)
            guard !Task.isCancelled, let self, !self.isScrubbing else { return }
            self.revealed = false
        }
    }

    /// A tap on the picture.
    func tapped() {
        if barShown && isPlaying { hide() } else { reveal() }
    }

    func hide() {
        hideTask?.cancel()
        revealed = false
    }

    // MARK: playing

    func togglePlay() {
        guard let player else { return }
        if isPlaying {
            pausedByUser = true
            player.pause()
        } else {
            pausedByUser = false
            player.play()
        }
        reveal()
    }

    /// Gives a player the owner paused back to whoever takes it next (the orbit shows a moving picture).
    func resumeIfPausedByUser() {
        guard pausedByUser, let player else { return }
        pausedByUser = false
        player.play()
    }

    // MARK: scrubbing

    /// The finger is down at `fraction` (0...1): the player pauses on the frame under it and chases the thumb.
    func scrub(to fraction: Double) {
        guard let player, duration > 0 else { return }
        if !isScrubbing {
            isScrubbing = true
            resumeAfterScrub = isPlaying
            hideTask?.cancel()
            revealed = true
            player.pause()
        }
        let f = min(1, max(0, fraction))
        let hit = f <= 0.0005 ? -1 : (f >= 0.9995 ? 1 : nil as Int?)
        if let hit, hit != atEnd { endHits += 1 }
        atEnd = hit
        time = f * duration
        // a frame near the target is enough while the finger moves: the chase keeps up
        seek(to: time, tolerance: 0.15)
    }

    func endScrub() {
        guard isScrubbing, let player else { return }
        // the last frame itself would loop at once: stop a hair short of it
        let target = min(time, max(0, duration - 0.05))
        seek(to: target, tolerance: 0.05)
        isScrubbing = false
        atEnd = nil
        if resumeAfterScrub {
            pausedByUser = false
            player.play()
        }
        reveal()
    }

    /// VoiceOver's adjustable action: `seconds` earlier or later, no finger.
    func skip(by seconds: Double) {
        guard duration > 0 else { return }
        let target = min(max(0, time + seconds), max(0, duration - 0.05))
        time = target
        seek(to: target, tolerance: 0.05)
        reveal()
    }

    private func seek(to seconds: Double, tolerance: Double) {
        pending = (CMTime(seconds: seconds, preferredTimescale: 600), CMTime(seconds: tolerance, preferredTimescale: 600))
        guard chase == nil else { return }
        // One seek in flight at a time, always to the newest target: a drag never queues up a backlog.
        chase = Task { [weak self] in
            while let self, let player = self.player, let next = self.pending {
                self.pending = nil
                await player.seek(to: next.time, toleranceBefore: next.tolerance, toleranceAfter: next.tolerance)
            }
            self?.chase = nil
        }
    }
}

// MARK: - the bar

/// How the hero's controls look: the whole bar for a video, a lone full-screen button for a webp.
enum HeroControlsMode { case video, webp }

/// The bar, the touch layer under it (tap shows or hides, double tap is full screen) and nothing else. Laid over a
/// hero's picture at the picture's own size; the hero's corner badges keep the top-right.
struct HeroControls: View {
    let transport: HeroTransport
    var mode: HeroControlsMode = .video
    let muted: Bool
    let onSound: () -> Void
    /// Opens the full-screen player or viewer; nil hides the button (and the double tap).
    var onFullScreen: (() -> Void)?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOver
    @Environment(\.hapticsEnabled) private var haptics

    private var shown: Bool { mode == .webp || voiceOver || transport.barShown }

    var body: some View {
        ZStack {
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture(count: 2) { onFullScreen?() }
                .onTapGesture { if mode == .video { transport.tapped() } }
                .accessibilityHidden(true)
            switch mode {
            case .video:
                bar
                    .opacity(shown ? 1 : 0)
                    .allowsHitTesting(shown)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.22), value: shown)
                if !shown { quietSoundBadge }
            case .webp:
                if let onFullScreen {
                    HeroFullScreenButton(action: onFullScreen)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                        .padding(2)
                }
            }
        }
        .environment(\.colorScheme, .dark)
        .haptic(.impact(weight: .light), trigger: transport.endHits, enabled: haptics) { $0 > 0 }
        .onHover { if $0, mode == .video { transport.reveal() } }
    }

    // MARK: pieces

    private var bar: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 2) {
                playButton
                elapsed
                scrubber
                remaining
                soundButton
                fullScreenButton
            }
            .padding(.horizontal, 4)
            .frame(height: 44)
            .glassEffect(.regular.tint(CobaltColor.badgeBack), in: Capsule())
            VStack(spacing: 0) {
                HStack(spacing: 6) {
                    elapsed
                    scrubber
                    remaining
                }
                .padding(.horizontal, 12)
                .frame(height: 32)
                HStack(spacing: 0) {
                    playButton
                    Spacer(minLength: 0)
                    soundButton
                    fullScreenButton
                }
                .frame(height: 44)
                .padding(.horizontal, 4)
            }
            .padding(.top, 2)
            .glassEffect(.regular.tint(CobaltColor.badgeBack), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        }
        .padding(8)
        .accessibilityElement(children: .contain)
    }

    private var playButton: some View {
        Button { transport.togglePlay() } label: {
            Image(systemName: transport.isPlaying ? "pause.fill" : "play.fill")
                .font(.system(size: 17, weight: .semibold))
                .contentTransition(reduceMotion ? .identity : .symbolEffect(.replace, options: .speed(2)))
                .foregroundStyle(CobaltColor.badgeInk)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(transport.isPlaying ? Copy.Media.pause : Copy.Media.play)
    }

    private var soundButton: some View {
        Button {
            onSound()
            transport.reveal()
        } label: {
            Image(systemName: muted ? Symbol.soundOff : Symbol.soundOn)
                .font(.system(size: 15, weight: .semibold))
                .contentTransition(reduceMotion ? .identity : .symbolEffect(.replace, options: .speed(2)))
                .foregroundStyle(CobaltColor.badgeInk)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(muted ? Copy.soundOn : Copy.soundOff)
    }

    @ViewBuilder
    private var fullScreenButton: some View {
        if let onFullScreen {
            Button {
                onFullScreen()
            } label: {
                Image(systemName: DetailSymbol.fullScreen)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(CobaltColor.badgeInk)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .keyboardShortcut("f", modifiers: [.command, .control])
            .accessibilityLabel(Copy.Media.fullScreen)
        }
    }

    private var elapsed: some View {
        Text(HeroClock.text(transport.time))
            .font(Font.cobalt(11, .medium, relativeTo: .caption))
            .dynamicTypeSize(...DynamicTypeSize.large)
            .monospacedDigit()
            .foregroundStyle(CobaltColor.badgeInk)
            .lineLimit(1)
            .fixedSize()
            .accessibilityHidden(true)
    }

    private var remaining: some View {
        Text(HeroClock.text(max(0, transport.duration - transport.time), minus: true))
            .font(Font.cobalt(11, .medium, relativeTo: .caption))
            .dynamicTypeSize(...DynamicTypeSize.large)
            .monospacedDigit()
            .foregroundStyle(CobaltColor.badgeInk)
            .lineLimit(1)
            .fixedSize()
            .accessibilityHidden(true)
    }

    private var scrubber: some View {
        HeroScrubber(transport: transport)
            .frame(minWidth: 72, idealWidth: 72, maxWidth: .infinity)
    }

    /// While the bar is away the sound's state stays in the corner, as the planet always wore it.
    private var quietSoundBadge: some View {
        Image(systemName: muted ? Symbol.soundOff : Symbol.soundOn)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(CobaltColor.badgeInk)
            .frame(width: 24, height: 24)
            .glassEffect(.regular.tint(CobaltColor.badgeBack), in: .circle)
            .padding(8)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

/// "0:03", "-0:09", "1:02:03" for the long ones.
enum HeroClock {
    static func text(_ seconds: Double, minus: Bool = false) -> String {
        let s = Int(max(0, seconds.isFinite ? seconds : 0).rounded(.down))
        let body = s >= 3600
            ? String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
            : String(format: "%d:%02d", s / 60, s % 60)
        return minus ? "-" + body : body
    }
}

// MARK: - the scrubber

/// A thin track with a thumb: touch anywhere on it to seek, drag to follow the finger with a live frame. Adjustable for
/// VoiceOver (five seconds a step).
private struct HeroScrubber: View {
    let transport: HeroTransport
    private let thumb: CGFloat = 12

    var body: some View {
        GeometryReader { geo in
            let active = transport.isScrubbing
            let size = active ? thumb + 4 : thumb
            let travel = max(1, geo.size.width - size)
            let x = size / 2 + travel * transport.fraction
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.28)).frame(height: 4)
                Capsule().fill(CobaltColor.badgeInk).frame(width: max(0, x), height: 4)
                Circle()
                    .fill(CobaltColor.badgeInk)
                    .frame(width: size, height: size)
                    .shadow(color: .black.opacity(0.35), radius: 2, y: 1)
                    .position(x: x, y: geo.size.height / 2)
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .local)
                    .onChanged { value in
                        transport.scrub(to: (value.location.x - size / 2) / travel)
                    }
                    .onEnded { _ in transport.endScrub() })
            .animation(.easeOut(duration: 0.12), value: active)
        }
        .frame(height: 32)
        .accessibilityElement()
        .accessibilityLabel(Copy.Media.scrubber)
        .accessibilityValue(Copy.Media.scrubberValue(HeroClock.text(transport.time), of: HeroClock.text(transport.duration)))
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: transport.skip(by: 5)
            case .decrement: transport.skip(by: -5)
            @unknown default: break
            }
        }
    }
}
