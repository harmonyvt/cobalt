import AVFoundation
import Combine
import CobaltKit
import SwiftUI

/// The trim preview: ONE player over the original that loops the selection, and the one source of the
/// strip's playhead. Owned by the focus layer for as long as the trim panel is open.
///
/// While a handle is dragged the preview is a scrubber, not a player:
/// - playback is paused, and the playhead is pinned to the time of the handle in the owner's hand (the in
///   handle shows the in frame, the out handle the out frame), so nothing else can move it;
/// - seeks are coalesced: one is in flight, the newest wanted time waits behind it (so a fast drag lands
///   frames instead of cancelling every seek before it finishes), with a relaxed tolerance so the decoder
///   may answer from the nearest cheap frame;
/// - on release the selection is applied: an exact seek to the in point, then the loop plays on from there.
///
/// The playhead is never an animation of its own: it reads `playhead` (the pinned time while scrubbing,
/// else the player's clock), so it cannot disagree with the picture.
@MainActor @Observable
final class TrimPreview {
    /// The player the picture layer shows; nil until `start`.
    private(set) var player: AVPlayer?
    /// The first seek has landed, so a frame is on screen (the picture fades in over the planet then).
    private(set) var isReady = false
    private(set) var isScrubbing = false

    /// How far a frame may be from the wanted time while dragging (seconds).
    static let scrubTolerance = 0.25

    @ObservationIgnored private var selection = TrimRange(start: 0, end: 10)
    @ObservationIgnored private var duration = 0.0
    @ObservationIgnored private var scrubSeconds = 0.0
    @ObservationIgnored private var wanted: Double?
    @ObservationIgnored private var seekInFlight = false
    /// Bumped whenever a seek chain is abandoned: late completions of the old chain are ignored.
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var subscriptions: Set<AnyCancellable> = []
    @ObservationIgnored private var url: URL?

    // MARK: lifecycle

    func start(url: URL, selection: TrimRange, duration: Double) {
        if player != nil, self.url == url {
            select(selection)
            return
        }
        stop()
        #if os(iOS)
        // muted and mixing: it never interrupts whatever the owner is listening to (AudioPolicy.ambient)
        let session = AVAudioSession.sharedInstance()
        if session.category != .ambient { try? session.setCategory(.ambient, mode: .default) }
        #endif
        self.url = url
        self.duration = duration
        self.selection = selection
        let item = AVPlayerItem(url: url)
        let queue = AVPlayer(playerItem: item)
        queue.isMuted = true
        queue.preventsDisplaySleepDuringVideoPlayback = false
        queue.actionAtItemEnd = .pause
        player = queue
        // reaching the out point (`forwardPlaybackEndTime`) ends the item: loop back to the in point
        NotificationCenter.default.publisher(for: AVPlayerItem.didPlayToEndTimeNotification, object: item)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                MainActor.assumeIsolated { self?.loop() }
            }
            .store(in: &subscriptions)
        apply(selection)
    }

    func stop() {
        generation += 1
        player?.pause()
        subscriptions.removeAll()
        player = nil
        url = nil
        isReady = false
        isScrubbing = false
        wanted = nil
        seekInFlight = false
    }

    // MARK: the selection

    /// The selection changed without a drag (a nudge, a release): loop it from its in point.
    func select(_ range: TrimRange) {
        guard !isScrubbing else { return }
        selection = range
        apply(range)
    }

    private func apply(_ range: TrimRange) {
        guard let player else { return }
        generation += 1
        seekInFlight = false
        wanted = nil
        let token = generation
        player.currentItem?.forwardPlaybackEndTime = CMTime(seconds: range.end, preferredTimescale: 600)
        player.seek(to: Self.time(range.start), toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.isReady = true
                guard self.generation == token, !self.isScrubbing else { return }
                self.player?.play()
            }
        }
    }

    private func loop() {
        guard !isScrubbing else { return }
        apply(selection)
    }

    // MARK: scrubbing

    func beginScrub() {
        guard !isScrubbing, let player else { return }
        isScrubbing = true
        generation += 1
        seekInFlight = false
        wanted = nil
        player.pause()
        // a drag may go past the old out point: the end time must not clamp the seeks
        player.currentItem?.forwardPlaybackEndTime = .invalid
        scrubSeconds = min(max(0, player.currentTime().seconds.isFinite ? player.currentTime().seconds : selection.start), duration)
    }

    /// The picture follows `seconds` (the time of the handle being dragged).
    func scrub(to seconds: Double) {
        guard isScrubbing else { return }
        scrubSeconds = min(max(0, seconds), duration > 0 ? duration : seconds)
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
                self.pump()
            }
        }
    }

    /// The handle was let go: the final selection loops from its in point (exact seek, then play).
    func endScrub(selection range: TrimRange) {
        guard isScrubbing else { return }
        isScrubbing = false
        selection = range
        apply(range)
    }

    // MARK: reading

    /// Where the playhead is, in seconds of the clip: the pinned time while scrubbing, else the player's own
    /// clock held inside the selection.
    func playhead(in range: TrimRange) -> Double {
        if isScrubbing { return scrubSeconds }
        guard let player else { return range.start }
        let t = player.currentTime().seconds
        guard t.isFinite else { return range.start }
        return min(max(t, range.start), range.end)
    }

    private static func time(_ seconds: Double) -> CMTime {
        CMTime(seconds: max(0, seconds), preferredTimescale: 600)
    }
}
