import AVFoundation
import Combine
import CobaltKit
import SwiftUI

/// The clip trim's picture: one player over the clip's own source file, looping the selection when asked.
/// Owned for as long as the trim is on screen (the Mac bar under the preview, the iPhone clip sheet).
///
/// In and out are source seconds. While a handle or the strip is dragged the preview is a scrubber:
/// playback pauses, seeks are coalesced (one in flight, the newest time waits, a relaxed tolerance so a
/// fast drag lands frames), and the playhead is pinned to the time under the finger. On release the last
/// time is sought exactly (tolerance zero) and playback stays paused. Play then loops the selection when
/// `loop` is on.
///
/// The playhead is never an animation of its own. It reads `playheadSeconds` (the pinned time while
/// scrubbing or waiting on an exact seek, otherwise the player's clock).
@MainActor @Observable
final class ClipTrimPreview {
    /// The player the picture layer shows. Nil until `start` has a file.
    private(set) var player: AVPlayer?
    /// The first seek has landed, so a frame is on screen.
    private(set) var isReady = false
    private(set) var isPlaying = false
    private(set) var isScrubbing = false
    /// Play repeats the selection. `L` toggles it.
    var loop = true
    /// Bumped when the playhead moves without a playback tick (a step, an exact seek), so a paused picture redraws.
    private(set) var change = 0

    /// How far a frame may be from the wanted time while dragging (seconds). The release seek uses zero.
    static let scrubTolerance = 0.25

    @ObservationIgnored private var selection = TrimRange(start: 0, end: 0)
    @ObservationIgnored private var duration = 0.0
    @ObservationIgnored private var fps = 30
    @ObservationIgnored private var scrubSeconds = 0.0
    @ObservationIgnored private var pin = false
    @ObservationIgnored private var wanted: Double?
    @ObservationIgnored private var seekInFlight = false
    /// Bumped whenever a seek chain is abandoned. Late completions of the old chain are ignored.
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var subscriptions: Set<AnyCancellable> = []
    @ObservationIgnored private var url: URL?

    // MARK: lifecycle

    func start(url: URL, selection: TrimRange, duration: Double, fps: Int) {
        let previous = self.selection
        self.fps = max(1, fps)
        self.duration = max(0.001, max(duration, selection.end))
        if player != nil, self.url == url {
            let moved = abs(previous.start - selection.start) > 0.04 || abs(previous.end - selection.end) > 0.04
            updateSelection(selection)
            // A different clip of the same file. A duration update keeps the playhead where it is.
            if moved, !isScrubbing { show(selection.start) }
            return
        }
        self.selection = selection
        stop()
        #if os(iOS)
        // Muted and mixing: it never interrupts whatever is playing (the same rule as the webp trim).
        let session = AVAudioSession.sharedInstance()
        if session.category != .ambient { try? session.setCategory(.ambient, mode: .default) }
        #endif
        self.url = url
        let item = AVPlayerItem(url: url)
        let queue = AVPlayer(playerItem: item)
        queue.isMuted = true
        queue.automaticallyWaitsToMinimizeStalling = false
        queue.preventsDisplaySleepDuringVideoPlayback = false
        queue.actionAtItemEnd = .pause
        player = queue
        NotificationCenter.default.publisher(for: AVPlayerItem.didPlayToEndTimeNotification, object: item)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                MainActor.assumeIsolated { self?.ended() }
            }
            .store(in: &subscriptions)
        applyEnd()
        show(selection.start)
    }

    func stop() {
        generation += 1
        player?.pause()
        subscriptions.removeAll()
        player = nil
        url = nil
        isReady = false
        isPlaying = false
        isScrubbing = false
        pin = false
        wanted = nil
        seekInFlight = false
        bump()
    }

    // MARK: the selection

    /// The selection moved (a trim, a nudge). The loop's end moves with it. Playback is not restarted.
    func updateSelection(_ range: TrimRange) {
        let start = min(range.start, range.end)
        let end = max(range.start, range.end)
        selection = TrimRange(start: start, end: end)
        guard !isScrubbing else { return }
        applyEnd()
    }

    private func applyEnd() {
        guard let item = player?.currentItem else { return }
        item.forwardPlaybackEndTime = Self.time(selection.end)
    }

    // MARK: transport

    func togglePlay() {
        if isPlaying { pause() } else { play() }
    }

    func toggleLoop() {
        loop.toggle()
        bump()
    }

    /// Plays the selection. A playhead outside it starts at the in point. With `loop` off it plays once.
    func play() {
        guard let player else { return }
        isPlaying = true
        applyEnd()
        let t = playheadSeconds()
        if t < selection.start - 0.0005 || t >= selection.end - 0.0005 {
            exactSeek(selection.start) { [weak self] in
                guard let self, self.isPlaying else { return }
                self.player?.play()
            }
        } else {
            player.play()
        }
        bump()
    }

    func pause() {
        player?.pause()
        guard isPlaying else { return }
        isPlaying = false
        bump()
    }

    /// One source frame is `1 / fps` seconds. Shift-sized steps pass a whole second's worth of frames.
    func step(frames: Int) {
        let next = ClipTrimMath.clampedPlayhead(playheadSeconds() + Double(frames) / Double(max(1, fps)), duration: duration)
        if isScrubbing { isScrubbing = false }
        pause()
        exactSeek(next)
    }

    /// An exact seek, paused. Used when a handle is stepped from VoiceOver.
    func show(_ seconds: Double) {
        if isScrubbing {
            scrub(to: seconds)
            return
        }
        pause()
        exactSeek(ClipTrimMath.clampedPlayhead(seconds, duration: duration))
    }

    private func ended() {
        guard !isScrubbing else { return }
        if loop, isPlaying {
            exactSeek(selection.start) { [weak self] in
                guard let self, self.isPlaying, self.loop else { return }
                self.player?.play()
            }
        } else {
            isPlaying = false
            bump()
        }
    }

    // MARK: scrubbing

    func beginScrub() {
        guard player != nil, !isScrubbing else { return }
        let now = playheadSeconds()
        isScrubbing = true
        generation += 1
        seekInFlight = false
        wanted = nil
        pin = false
        player?.pause()
        isPlaying = false
        // A drag may go past the old out point. The end time must not clamp the seeks.
        player?.currentItem?.forwardPlaybackEndTime = .invalid
        scrubSeconds = now
        bump()
    }

    /// The picture follows `seconds` (the finger, or the handle in hand).
    func scrub(to seconds: Double) {
        guard isScrubbing else { return }
        scrubSeconds = ClipTrimMath.clampedPlayhead(seconds, duration: duration)
        wanted = scrubSeconds
        pump()
    }

    private func pump() {
        guard !seekInFlight, let t = wanted, let player else { return }
        wanted = nil
        seekInFlight = true
        let token = generation
        let tolerance = CMTime(seconds: Self.scrubTolerance, preferredTimescale: 600)
        player.seek(to: Self.time(t), toleranceBefore: tolerance, toleranceAfter: tolerance) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.generation == token else { return }
                self.seekInFlight = false
                self.isReady = true
                self.pump()
            }
        }
    }

    /// The finger went up: an exact seek to `seconds`, then the picture stays paused.
    func endScrub(at seconds: Double) {
        guard isScrubbing else { return }
        isScrubbing = false
        generation += 1
        seekInFlight = false
        wanted = nil
        applyEnd()
        exactSeek(seconds)
    }

    // MARK: reading

    /// Where the playhead is, in source seconds: the pinned time while scrubbing or waiting on an exact
    /// seek, otherwise the player's clock, held inside the file.
    func playheadSeconds() -> Double {
        if isScrubbing || pin { return scrubSeconds }
        guard let player else { return scrubSeconds }
        let t = player.currentTime().seconds
        guard t.isFinite else { return scrubSeconds }
        return ClipTrimMath.clampedPlayhead(t, duration: duration)
    }

    // MARK: seeks

    private func exactSeek(_ seconds: Double, then: (@MainActor () -> Void)? = nil) {
        guard let player else { then?(); return }
        generation += 1
        seekInFlight = false
        wanted = nil
        let t = ClipTrimMath.clampedPlayhead(seconds, duration: duration)
        scrubSeconds = t
        pin = true
        let token = generation
        bump()
        player.seek(to: Self.time(t), toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.generation == token else { return }
                self.pin = false
                self.isReady = true
                self.bump()
                then?()
            }
        }
    }

    private func bump() { change &+= 1 }

    private static func time(_ seconds: Double) -> CMTime {
        CMTime(seconds: max(0, seconds.isFinite ? seconds : 0), preferredTimescale: 600)
    }
}

// MARK: - keeping the player on the clip

/// Starts the preview on the clip's file, moves its loop when in or out changes, and stops it when the
/// trim leaves the screen. `playable` and the download are part of the identity because `localVideoURL`
/// is not observed.
struct ClipTrimSync: ViewModifier {
    let session: EditSession
    let clip: EditClip?
    let preview: ClipTrimPreview

    private var key: String {
        guard let clip else { return "none" }
        let url = session.localVideoURL(for: clip.item)?.path ?? ""
        let duration = session.source(for: clip.item)?.duration ?? 0
        return "\(clip.id)|\(url)|\(duration)|\(session.playable != nil)"
    }

    func body(content: Content) -> some View {
        content
            .task(id: key) { open() }
            .onDisappear { preview.stop() }
            .onChange(of: clip?.`in`) { _, _ in push() }
            .onChange(of: clip?.out) { _, _ in push() }
            .onChange(of: session.isPlaying) { _, playing in
                if playing { preview.pause() }
            }
    }

    private func open() {
        guard let clip, let url = session.localVideoURL(for: clip.item) else { return }
        let known = session.source(for: clip.item)?.duration ?? 0
        preview.start(
            url: url,
            selection: TrimRange(start: clip.`in`, end: clip.out),
            duration: max(clip.out, known),
            fps: session.timing.fps)
    }

    private func push() {
        guard let clip else { return }
        preview.updateSelection(TrimRange(start: clip.`in`, end: clip.out))
    }
}

/// Set in or out at the trim playhead when the source player is up, otherwise at the edit's playhead.
@MainActor enum ClipTrimEditing {
    static func setIn(session: EditSession, clip id: String, preview: ClipTrimPreview) {
        guard preview.player != nil else {
            session.setIn(atPlayheadFor: id)
            return
        }
        session.trim(clip: id, in: preview.playheadSeconds(), out: nil)
        session.endGesture()
    }

    static func setOut(session: EditSession, clip id: String, preview: ClipTrimPreview) {
        guard preview.player != nil else {
            session.setOut(atPlayheadFor: id)
            return
        }
        session.trim(clip: id, in: nil, out: preview.playheadSeconds())
        session.endGesture()
    }

    /// A main clip is selected and its source file is on the device, so the trim keys apply.
    static func isTrimming(session: EditSession, preview: ClipTrimPreview) -> Bool {
        if case .main = session.selection, preview.player != nil { return true }
        return false
    }
}
