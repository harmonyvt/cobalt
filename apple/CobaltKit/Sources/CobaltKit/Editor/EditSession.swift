import AVFoundation
import Foundation
import Observation

/// The open project (apple/CONTRACT-EDITOR.md 3.6): the timeline, its sources, the player, autosave, undo and the render.
///
/// - Every edit goes through the methods below. Each one is validated and rounded (31.2), changes only what it names, and
///   leaves the timeline in a state the server accepts: overlays stay inside the canvas, in order, inside the main track and
///   never overlapping (in frames, 31.4).
/// - Autosave runs 1 s after the last change: one PUT in flight, a change during it queues the next. `saved` shows only when
///   the server has the current revision. A `409` becomes `.conflict(<the server's project>)` and stops autosave until
///   `resolveConflict`. Offline or `503` is `.failed`, retried at 2, 5, 10, then every 30 s while the session is open.
/// - Undo and redo keep whole-timeline snapshots (at most 100). Edits that arrive in a run with the same key within 0.6 s (a
///   drag, a slider) are one step; `endGesture()` ends a run at once. A save never clears the stacks.
/// - The player is rebuilt (`EditComposition`) 150 ms after the timeline settles, and keeps the playhead.
@MainActor @Observable
public final class EditSession {
    public enum Tool: String, CaseIterable, Sendable { case select, blade, crop }
    public enum SaveState: Equatable, Sendable { case saved, saving, unsaved, failed(EditError), conflict(EditProject) }
    public enum Selection: Equatable, Sendable { case none, main(String), overlay(String) }     // clip ids

    // MARK: state

    public private(set) var project: EditProject
    /// Always rounded and normalized (31.2).
    public private(set) var timeline: EditTimeline
    public private(set) var sources: [String: EditSource]
    public private(set) var timing: EditTiming
    /// What the server would refuse (or render with a problem); `[]` = ready to render.
    public private(set) var problems: [EditProblem]
    public private(set) var saveState: SaveState = .saved
    /// File id -> download progress (0...1) while a clip's file is being fetched.
    public private(set) var loadingSources: [String: Double] = [:]
    /// File id -> why a clip's file could not be fetched (`retrySource` tries again).
    public private(set) var sourceFailures: [String: EditError] = [:]
    public var selection: Selection = .none
    public var tool: Tool = .select
    /// Set by the queue's "try again" (CONTRACT-EDITOR 6): the render confirmation should come up. The presenter clears it.
    public var renderConfirmRequested = false
    public let player = AVPlayer()
    /// The output frame under the playhead.
    public private(set) var playhead = 0
    public private(set) var isPlaying = false
    /// The newest render of this project.
    public private(set) var activeRender: EditRender?
    /// The composition the player plays; nil until every main clip's file is on the device.
    public private(set) var playable: EditPlayable?
    public private(set) var isPlayerReady = false
    public private(set) var canUndo = false
    public private(set) var canRedo = false

    // MARK: wiring

    @ObservationIgnored let ctx: PipelineContext
    @ObservationIgnored let cache: EditSourceCache
    @ObservationIgnored private let onProject: @MainActor (EditProject) -> Void
    @ObservationIgnored private let onRender: @MainActor (EditRender) -> Void

    // history
    @ObservationIgnored private var undoStack: [EditTimeline] = []
    @ObservationIgnored private var redoStack: [EditTimeline] = []
    @ObservationIgnored private var lastKey: String?
    @ObservationIgnored private var lastEditAt = Date.distantPast

    // saving
    @ObservationIgnored private var dirty = false
    @ObservationIgnored private var pendingTitle: String?
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var retryTask: Task<Void, Never>?
    @ObservationIgnored private var retryStep = 0
    @ObservationIgnored private var flushing = false
    @ObservationIgnored private var flushTask: Task<Void, Never>?
    @ObservationIgnored private var flushAgain = false
    @ObservationIgnored private var conflict: EditProject?
    @ObservationIgnored private(set) var saveCalls = 0
    @ObservationIgnored private(set) var isClosed = false

    // the player
    @ObservationIgnored private var rebuildTask: Task<Void, Never>?
    @ObservationIgnored private var rebuildGeneration = 0
    @ObservationIgnored private var assets: [String: EditSourceAsset] = [:]
    @ObservationIgnored private var loads: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var endObserver: (any NSObjectProtocol)?
    @ObservationIgnored private var renderPoll: Task<Void, Never>?
    @ObservationIgnored private(set) var builds = 0

    public static let saveDelay: Double = 1
    public static let rebuildDelay: Double = 0.15
    public static let retryDelays: [Double] = [2, 5, 10, 30]
    public static let renderPollSeconds: Double = 3
    public static let undoLimit = 100
    static let coalesceWindow: TimeInterval = 0.6
    static let minSeconds = 0.1

    init(
        project: EditProject, timeline: EditTimeline, sources: [String: EditSource], context: PipelineContext,
        cache: EditSourceCache, onProject: @escaping @MainActor (EditProject) -> Void,
        onRender: @escaping @MainActor (EditRender) -> Void
    ) {
        let rounded = EditJSON.rounded(timeline)
        self.project = project
        self.timeline = rounded
        self.sources = sources
        self.timing = EditTiming(rounded, sourceDurations: Self.durations(of: sources))
        self.problems = EditValidation.check(rounded, sources: sources)
        self.ctx = context
        self.cache = cache
        self.onProject = onProject
        self.onRender = onRender
        self.activeRender = project.render
        player.actionAtItemEnd = .pause
        installTimeObserver()
        scheduleRebuild(delay: 0)
        startRenderPolling()
    }

    private var editorClient: (any EditorClient)? { ctx.client as? any EditorClient }

    // MARK: - Transport

    public func play() {
        guard isPlayerReady, timing.frames > 0 else { return }
        if playhead >= timing.frames - 1 { seek(frame: 0) }
        player.play()
        isPlaying = true
    }

    public func pause() {
        player.pause()
        isPlaying = false
    }

    public func togglePlay() {
        if isPlaying { pause() } else { play() }
    }

    public func seek(frame k: Int) {
        let clamped = min(max(0, k), max(0, timing.frames - 1))
        playhead = clamped
        guard player.currentItem != nil else { return }
        let time = CMTime(value: Int64(clamped), timescale: Int32(timing.fps))
        player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
    }

    public func step(frames: Int) { seek(frame: playhead + frames) }

    /// `rate` -4...4 (J, K, L): a negative rate on an item that cannot play backwards jumps back one second instead.
    public func shuttle(_ rate: Double) {
        guard isPlayerReady else { return }
        if rate == 0 { pause(); return }
        let clamped = min(4, max(-4, rate))
        if clamped < 0, player.currentItem?.canPlayReverse != true {
            seek(frame: playhead - timing.fps)
            return
        }
        player.rate = Float(clamped)
        isPlaying = true
    }

    private func installTimeObserver() {
        let interval = CMTime(value: 1, timescale: 30)
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            MainActor.assumeIsolated { self?.tick(time) }
        }
    }

    private func tick(_ time: CMTime) {
        guard isPlaying, time.isNumeric else { return }
        let k = timing.frame(at: time.seconds)
        if k != playhead { playhead = k }
    }

    private func observeEnd(of item: AVPlayerItem) {
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.reachedEnd() }
        }
    }

    private func reachedEnd() {
        isPlaying = false
        playhead = max(0, timing.frames - 1)
    }

    // MARK: - Main track

    /// Videos only (a gif or photo goes on the overlay); `nil` = the end. A clip is its whole file, speed 1 (31.2.1).
    public func add(_ files: [EditSource], at index: Int?) {
        let videos = files.filter { $0.kind == .video && $0.available && ($0.duration ?? 0) >= Self.minSeconds }
        guard !videos.isEmpty else { return }
        for file in videos { sources[file.id] = file }
        var firstID: String?
        commit(key: nil) { t in
            var at = min(max(0, index ?? t.main.count), t.main.count)
            for file in videos {
                guard t.main.count + t.overlay.count < EditValidation.maxClips + 1 else { break }       // one past: the problem shows
                let clip = EditClip.added(item: file.id, duration: file.duration ?? 0)
                if firstID == nil { firstID = clip.id }
                t.main.insert(clip, at: at)
                at += 1
            }
        }
        if let firstID { selection = .main(firstID) }
    }

    /// `index` is the place in the track after the move.
    public func move(clip id: String, to index: Int) {
        commit(key: nil) { t in
            guard let from = t.main.firstIndex(where: { $0.id == id }) else { return }
            let clip = t.main.remove(at: from)
            t.main.insert(clip, at: min(max(0, index), t.main.count))
        }
    }

    /// Source seconds, clamped to `0...duration` and 0.1 s of output at least.
    public func trim(clip id: String, in newIn: Double?, out newOut: Double?) {
        editClip(id, key: "trim:\(id)") { clip, source in
            (clip.`in`, clip.out) = Self.clampTrim(
                in: clip.`in`, out: clip.out, minSpan: Self.minSeconds * max(1, clip.speed), newIn: newIn, newOut: newOut,
                duration: source?.duration)
        }
    }

    /// `I`: the clip's start moves to the playhead (when the playhead is inside that clip).
    public func setIn(atPlayheadFor id: String) {
        guard let t = sourceTimeAtPlayhead(of: id) else { return }
        trim(clip: id, in: t, out: nil)
    }

    /// `O`: the clip's end moves to the playhead (when the playhead is inside that clip).
    public func setOut(atPlayheadFor id: String) {
        guard let t = sourceTimeAtPlayhead(of: id) else { return }
        trim(clip: id, in: nil, out: t)
    }

    private func sourceTimeAtPlayhead(of id: String) -> Double? {
        guard let (index, offset) = timing.clip(atFrame: playhead), timeline.main[index].id == id else { return nil }
        return timing.sourceTime(clip: index, offset: offset, in: timeline)
    }

    /// Splits the main clip under the playhead; both halves keep every setting.
    public func splitAtPlayhead() {
        guard let (index, _) = timing.clip(atFrame: playhead) else { return }
        split(clip: timeline.main[index].id, atFrame: playhead)
    }

    /// Splits at output frame `k`. Nothing happens when `k` is on the clip's edge or a half would be under 0.1 s.
    public func split(clip id: String, atFrame k: Int) {
        guard let index = timeline.main.firstIndex(where: { $0.id == id }), index < timing.main.count else { return }
        let slot = timing.main[index]
        let offset = k - slot.start
        guard offset > 0, offset < slot.frames else { return }
        let clip = timeline.main[index]
        let point = EditJSON.time(timing.sourceTime(clip: index, offset: offset, in: timeline))
        let minSpan = Self.minSeconds * max(1, clip.speed)
        guard point - clip.`in` >= minSpan - 1e-9, clip.out - point >= minSpan - 1e-9 else { return }
        commit(key: nil) { t in
            guard let i = t.main.firstIndex(where: { $0.id == id }) else { return }
            var second = t.main[i]
            second.id = EditID.mint()
            second.`in` = point
            t.main[i].out = point
            t.main.insert(second, at: i + 1)
        }
    }

    public func remove(_ selection: Selection) {
        switch selection {
        case .none: return
        case .main(let id): commit(key: nil) { $0.main.removeAll { $0.id == id } }
        case .overlay(let id): commit(key: nil) { $0.overlay.removeAll { $0.id == id } }
        }
    }

    /// 0.25...4, snapped to 0.05, and slow enough to keep the clip 0.1 s of output at least.
    public func setSpeed(_ speed: Double, clip id: String) {
        editClip(id, key: "speed:\(id)") { clip, _ in
            let span = clip.out - clip.`in`
            var s = min(4, max(0.25, speed.isFinite ? speed : 1))
            let most = (span / Self.minSeconds * 20).rounded(.down) / 20      // a multiple of 0.05 that keeps span / speed >= 0.1
            s = min(s, max(0.25, most))
            clip.speed = EditJSON.speed(s)
        }
    }

    /// nil = the whole frame. The rectangle is kept inside the frame and at least 64 px a side.
    public func setCrop(_ crop: EditCrop?, clip id: String) {
        editClip(id, key: "crop:\(id)") { clip, source in
            clip.crop = crop.map { Self.clampCrop($0, display: source?.display) }
        }
    }

    public func setFit(_ fit: EditFit, clip id: String) {
        editClip(id, key: nil) { clip, _ in clip.fit = fit }
    }

    public func setVolume(_ v: Double, clip id: String) {
        editClip(id, key: "volume:\(id)") { clip, _ in clip.volume = min(1, max(0, v.isFinite ? v : 1)) }
    }

    public func setMuted(_ m: Bool, clip id: String) {
        editClip(id, key: nil) { clip, _ in clip.muted = m }
    }

    // MARK: - Overlay

    /// Puts a video, gif or photo on the overlay track at frame `k` (nil = the playhead). Refuses (false) when `k` is inside
    /// another overlay or less than 0.1 s of room is left; a longer one is cut at the next overlay.
    @discardableResult
    public func addOverlay(_ file: EditSource, atFrame k: Int?) -> Bool {
        guard file.available, file.kind != .unsupported, timeline.main.count + timeline.overlay.count < EditValidation.maxClips,
              timing.frames > 0 else { return false }
        let start = min(max(0, k ?? playhead), timing.frames - 1)
        var room = timing.frames - start
        for o in timing.overlay {
            if start >= o.start, start < o.start + o.frames { return false }
            if o.start > start { room = min(room, o.start - start) }
        }
        guard room >= Self.minFrames(fps: timing.fps) else { return false }
        sources[file.id] = file
        var overlay = EditOverlay.added(
            item: file.id, kind: file.kind, duration: file.duration, at: timing.time(ofFrame: start),
            remaining: Double(room) / Double(timing.fps))
        if let display = file.display {
            overlay.frame = EditGeometry.clampInside(overlay.frame, display: display, canvas: timeline.canvas)
        }
        let id = overlay.id
        commit(key: nil) { $0.overlay.append(overlay) }
        selection = .overlay(id)
        return true
    }

    /// Moves the overlay's start to output frame `k`, between its neighbours and the end.
    public func moveOverlay(id: String, toFrame k: Int) {
        commit(key: "move:\(id)") { t in
            guard let i = t.overlay.firstIndex(where: { $0.id == id }) else { return }
            let timing = EditTiming(t)
            guard i < timing.overlay.count else { return }
            let me = timing.overlay[i]
            let previousEnd = i > 0 ? timing.overlay[i - 1].start + timing.overlay[i - 1].frames : 0
            let nextStart = i + 1 < timing.overlay.count ? timing.overlay[i + 1].start : timing.frames
            let latest = nextStart - me.frames
            guard latest >= previousEnd else { return }
            let start = min(max(k, previousEnd), latest)
            t.overlay[i].at = Double(start) / Double(timing.fps)
        }
    }

    /// How long it stays up, 0.1 s to the room it has (the next overlay, the end, the file's own length for a video).
    public func setOverlayLength(id: String, seconds: Double) {
        commit(key: "length:\(id)") { t in
            guard let i = t.overlay.firstIndex(where: { $0.id == id }) else { return }
            let timing = EditTiming(t)
            guard i < timing.overlay.count else { return }
            let me = timing.overlay[i]
            let nextStart = i + 1 < timing.overlay.count ? timing.overlay[i + 1].start : timing.frames
            var most = Double(nextStart - me.start) / Double(timing.fps)
            let source = self.sources[t.overlay[i].item]
            if source?.kind == .video, let duration = source?.duration { most = min(most, duration - t.overlay[i].`in`) }
            else { most = min(most, EditValidation.maxSeconds) }
            let length = min(max(Self.minSeconds, seconds.isFinite ? seconds : Self.minSeconds), max(Self.minSeconds, most))
            t.overlay[i].out = t.overlay[i].`in` + length
        }
    }

    /// A video overlay's in and out (source seconds); its start on the timeline stays.
    public func trimOverlay(id: String, in newIn: Double?, out newOut: Double?) {
        commit(key: "otrim:\(id)") { t in
            guard let i = t.overlay.firstIndex(where: { $0.id == id }), self.sources[t.overlay[i].item]?.kind == .video else { return }
            let timing = EditTiming(t)
            guard i < timing.overlay.count else { return }
            let me = timing.overlay[i]
            let nextStart = i + 1 < timing.overlay.count ? timing.overlay[i + 1].start : timing.frames
            let room = Double(nextStart - me.start) / Double(timing.fps)
            var (inP, outP) = Self.clampTrim(
                in: t.overlay[i].`in`, out: t.overlay[i].out, minSpan: Self.minSeconds, newIn: newIn, newOut: newOut,
                duration: self.sources[t.overlay[i].item]?.duration)
            if outP - inP > room { outP = inP + max(Self.minSeconds, room) }
            t.overlay[i].`in` = inP
            t.overlay[i].out = outP
        }
    }

    /// The overlay's place and width, kept inside the canvas.
    public func setOverlayFrame(id: String, _ frame: EditFrame) {
        commit(key: "frame:\(id)") { t in
            guard let i = t.overlay.firstIndex(where: { $0.id == id }) else { return }
            if let display = self.sources[t.overlay[i].item]?.display {
                t.overlay[i].frame = EditGeometry.clampInside(frame, display: display, canvas: t.canvas)
            } else {
                t.overlay[i].frame = EditFrame(
                    x: min(max(0, frame.x), 0.95), y: min(max(0, frame.y), 0.95), w: min(1, max(0.05, frame.w)))
            }
        }
    }

    public func setOverlayOpacity(id: String, _ v: Double) {
        editOverlay(id, key: "opacity:\(id)") { $0.opacity = min(1, max(0.1, v.isFinite ? v : 1)) }
    }

    public func setOverlayVolume(id: String, _ v: Double) {
        editOverlay(id, key: "ovolume:\(id)") { $0.volume = min(1, max(0, v.isFinite ? v : 1)) }
    }

    public func setOverlayMuted(id: String, _ m: Bool) {
        editOverlay(id, key: nil) { $0.muted = m }
    }

    // MARK: - Canvas, title

    /// One of the six sizes at 30 or 60 fps. Overlays are moved inside the new canvas and cut to fit the frames it has.
    public func setCanvas(_ c: EditCanvas) {
        guard c.isValidSize, EditCanvas.fpsChoices.contains(c.fps) else { return }
        commit(key: nil) { $0.canvas = c }
    }

    /// The project's name (1...80 characters; an empty one is ignored). Saved with the next autosave.
    public func rename(_ title: String) {
        guard let clean = MediaTitle.clean(title), clean != project.title else { return }
        project.title = clean
        pendingTitle = clean
        markChanged()
    }

    // MARK: - Undo

    /// Ends a run of drag or slider edits: the next edit is a step of its own.
    public func endGesture() { lastKey = nil }

    public func undo() {
        guard let previous = undoStack.popLast() else { return }
        redoStack.append(timeline)
        updateHistoryFlags()
        applyHistory(previous)
    }

    public func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(timeline)
        updateHistoryFlags()
        applyHistory(next)
    }

    private func applyHistory(_ t: EditTimeline) {
        timeline = normalized(t)
        lastKey = nil
        afterChange()
    }

    private func updateHistoryFlags() {
        canUndo = !undoStack.isEmpty
        canRedo = !redoStack.isEmpty
    }

    // MARK: - The change pipeline

    private func editClip(_ id: String, key: String?, _ body: (inout EditClip, EditSource?) -> Void) {
        commit(key: key) { t in
            guard let i = t.main.firstIndex(where: { $0.id == id }) else { return }
            body(&t.main[i], self.sources[t.main[i].item])
        }
    }

    private func editOverlay(_ id: String, key: String?, _ body: (inout EditOverlay) -> Void) {
        commit(key: key) { t in
            guard let i = t.overlay.firstIndex(where: { $0.id == id }) else { return }
            body(&t.overlay[i])
        }
    }

    /// Applies `change` to a copy, normalizes it, and (if anything changed) records the undo step and takes it.
    private func commit(key: String?, _ change: (inout EditTimeline) -> Void) {
        var t = timeline
        change(&t)
        t = normalized(t)
        guard t != timeline else { return }
        let now = ctx.clock.now()
        if let key, key == lastKey, now.timeIntervalSince(lastEditAt) < Self.coalesceWindow {
            // the same drag or slider: one step
        } else {
            undoStack.append(timeline)
            if undoStack.count > Self.undoLimit { undoStack.removeFirst(undoStack.count - Self.undoLimit) }
        }
        redoStack = []
        updateHistoryFlags()
        lastKey = key
        lastEditAt = now
        timeline = t
        afterChange()
    }

    private func afterChange() {
        timing = EditTiming(timeline, sourceDurations: Self.durations(of: sources))
        problems = EditValidation.check(timeline, sources: sources)
        switch selection {
        case .none: break
        case .main(let id): if !timeline.main.contains(where: { $0.id == id }) { selection = .none }
        case .overlay(let id): if !timeline.overlay.contains(where: { $0.id == id }) { selection = .none }
        }
        if playhead > max(0, timing.frames - 1) { playhead = max(0, timing.frames - 1) }
        markChanged()
        scheduleRebuild()
    }

    /// The probed length of every video file, for the end-of-source clamp the renderer applies.
    static func durations(of sources: [String: EditSource]) -> [String: Double] {
        var out: [String: Double] = [:]
        for (id, source) in sources where source.kind == .video && source.available {
            if let d = source.duration, d > 0 { out[id] = d }
        }
        return out
    }

    static func minFrames(fps: Int) -> Int { max(1, Int((Self.minSeconds * Double(fps) - 1e-9).rounded(.up))) }

    /// Rounded, and with the overlays made safe: sorted, inside the canvas, never overlapping (in frames), inside the main track.
    /// An overlay with under 0.1 s of room is dropped.
    private func normalized(_ input: EditTimeline) -> EditTimeline {
        var t = EditJSON.rounded(input)
        let fps = Double(max(1, t.canvas.fps))
        let total = EditTiming(t).frames
        let minFrames = Self.minFrames(fps: t.canvas.fps)
        t.overlay.sort { $0.at < $1.at }
        var kept: [EditOverlay] = []
        var previousEnd = 0
        for var o in t.overlay {
            if let display = sources[o.item]?.display, display.w > 0, display.h > 0 {
                o.frame = EditGeometry.clampInside(o.frame, display: display, canvas: t.canvas)
            } else {
                o.frame = EditFrame(x: min(max(0, o.frame.x), 0.95), y: min(max(0, o.frame.y), 0.95), w: min(1, max(0.05, o.frame.w)))
            }
            let wantedStart = EditMath.roundHalfUp(o.at * fps)
            let wantedFrames = max(1, EditMath.roundHalfUp((o.out - o.`in`) * fps))
            let start = max(previousEnd, max(0, wantedStart))
            var frames = wantedFrames
            if start + frames > total { frames = total - start }
            guard frames >= minFrames else { continue }
            if start != wantedStart { o.at = Double(start) / fps }
            if frames != wantedFrames { o.out = o.`in` + Double(frames) / fps }
            previousEnd = start + frames
            kept.append(o)
        }
        t.overlay = kept
        return EditJSON.rounded(t)
    }

    // MARK: pure helpers

    /// New in and out for a trim: inside `0...duration`, `minSpan` apart.
    static func clampTrim(
        in inPoint: Double, out outPoint: Double, minSpan: Double, newIn: Double?, newOut: Double?, duration: Double?
    ) -> (Double, Double) {
        let limit = duration ?? .infinity
        var inP = inPoint, outP = outPoint
        if let newIn, newIn.isFinite {
            inP = min(max(0, newIn), outP - minSpan)
            inP = max(0, inP)
        }
        if let newOut, newOut.isFinite {
            outP = min(max(newOut, inP + minSpan), limit)
            if outP - inP < minSpan { inP = max(0, outP - minSpan) }
        }
        return (inP, outP)
    }

    /// Inside the frame and at least 64 px a side (1 % when the size is not known).
    static func clampCrop(_ c: EditCrop, display: PixelSize?) -> EditCrop {
        var c = c
        let minW = display.map { min(1, 66.0 / Double(max(1, $0.w))) } ?? 0.01
        let minH = display.map { min(1, 66.0 / Double(max(1, $0.h))) } ?? 0.01
        c.w = min(1, max(minW, c.w.isFinite ? c.w : 1))
        c.h = min(1, max(minH, c.h.isFinite ? c.h : 1))
        c.x = min(1 - c.w, max(0, c.x.isFinite ? c.x : 0))
        c.y = min(1 - c.h, max(0, c.y.isFinite ? c.y : 0))
        return c
    }

    // MARK: - Saving

    private static func blocksSave(_ p: EditProblem) -> Bool {
        switch p {
        case .canvas, .empty, .tooManyClips, .tooLong, .range, .overlayOverlap, .overlayPastEnd: return true
        case .sourceMissing, .notVideo, .unsupportedSource, .pastSourceEnd: return false
        }
    }

    private func markChanged() {
        dirty = true
        if case .conflict = saveState { return }                // autosave is stopped until the owner picks a side
        saveState = .unsaved
        scheduleSave()
    }

    private func scheduleSave(after delay: Double = EditSession.saveDelay) {
        saveTask?.cancel()
        saveTask = Task { @MainActor [weak self] in
            guard let self, await self.nap(delay) else { return }
            self.saveTask = nil
            await self.flush()
        }
    }

    /// Sends what is unsaved. One PUT at a time: a second call while one is out is queued behind it.
    func flush() async {
        guard dirty, !isClosed else { return }
        if case .conflict = saveState { return }
        if let running = flushTask {
            // a PUT is out: it sends this change too (flushAgain), and the caller waits for all of it
            flushAgain = true
            await Self.wait(for: running)
            return
        }
        let task = Task { @MainActor in await self.performFlush() }
        flushTask = task
        await Self.wait(for: task)
        if flushTask == task { flushTask = nil }
    }

    /// Waits for `task`; a cancelled waiter cancels it (the close that gave up).
    private static func wait(for task: Task<Void, Never>) async {
        await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
    }

    private func performFlush() async {
        defer { flushTask = nil }
        guard dirty, !isClosed else { return }
        if case .conflict = saveState { return }
        if let blocking = problems.first(where: Self.blocksSave) {
            saveState = .failed(.invalid(blocking))              // the server would refuse it; the next change that clears it saves
            return
        }
        guard let client = editorClient else {
            saveState = .failed(.unavailable)
            scheduleRetry()
            return
        }
        flushing = true
        defer { flushing = false }
        repeat {
            flushAgain = false
            let snapshot = timeline
            let title = pendingTitle
            saveState = .saving
            saveCalls += 1
            do {
                let saved = try await client.saveEditProject(
                    id: project.id, timeline: snapshot, baseRevision: project.revision, title: title)
                retryStep = 0
                retryTask?.cancel()
                retryTask = nil
                adopt(saved)
                if pendingTitle == title { pendingTitle = nil }
                dirty = timeline != snapshot || pendingTitle != nil
                saveState = dirty ? .unsaved : .saved
            } catch {
                if Task.isCancelled {
                    saveState = .unsaved                         // a close that gave up waiting
                    return
                }
                let e = EditError.from(error)
                if case .conflict(let theirs) = e {
                    conflict = theirs
                    saveState = .conflict(theirs)
                    return
                }
                saveState = .failed(e)
                if Self.retryable(e) { scheduleRetry() }
                return
            }
        } while flushAgain && dirty
    }

    /// A failed save worth trying again on its own: no network, the server not answering, or an unknown failure.
    private static func retryable(_ e: EditError) -> Bool {
        if e.isTransient { return true }
        if case .other = e { return true }
        return false
    }

    /// The server's answer to a save: its revision, title and render; the timeline stays this session's.
    private func adopt(_ saved: EditProject) {
        var p = saved
        p.timeline = nil
        if pendingTitle != nil { p.title = project.title }
        if p.render == nil { p.render = project.render }
        project = p
        onProject(p)
    }

    private func scheduleRetry() {
        guard retryTask == nil, !isClosed else { return }
        let delay = Self.retryDelays[min(retryStep, Self.retryDelays.count - 1)]
        retryStep += 1
        retryTask = Task { @MainActor [weak self] in
            guard let self, await self.nap(delay) else { return }
            self.retryTask = nil
            await self.flush()
        }
    }

    /// Try the save again now (the owner tapped "retry").
    public func retrySave() async {
        retryTask?.cancel()
        retryTask = nil
        saveTask?.cancel()
        saveTask = nil
        if case .failed = saveState { dirty = true }
        await flush()
    }

    /// Flushes the autosave for a close: true when the server has the current revision. Gives up after `timeout` seconds.
    func settle(timeout: Double = 3) async -> Bool {
        saveTask?.cancel()
        saveTask = nil
        if dirty {
            // The flush races the timeout; whichever ends first cancels the other (a task group here trips the compiler's
            // region-based isolation checker).
            let flushing = Task { @MainActor in await self.flush() }
            let timer = Task { @MainActor in if await self.nap(timeout) { flushing.cancel() } }
            await flushing.value
            timer.cancel()
        }
        return !dirty && saveState == .saved
    }

    /// The conflict banner: `keepMine` replaces the server's version with this one (a PUT at the server's revision);
    /// otherwise the server's version is loaded and this one stays one undo step away.
    public func resolveConflict(keepMine: Bool) async {
        guard case .conflict(let theirs) = saveState, let client = editorClient else { return }
        if keepMine {
            project.revision = theirs.revision
            if pendingTitle == nil, theirs.title != project.title { pendingTitle = project.title }
            saveState = .unsaved
            dirty = true
            conflict = nil
            await flush()
            return
        }
        do {
            let (fresh, fresh_sources) = try await client.editProject(id: project.id)
            guard let theirTimeline = fresh.timeline else { saveState = .failed(.other("invalid response")); return }
            for (id, source) in fresh_sources { sources[id] = source }
            undoStack.append(timeline)
            redoStack = []
            updateHistoryFlags()
            var p = fresh
            p.timeline = nil
            project = p
            pendingTitle = nil
            conflict = nil
            timeline = normalized(theirTimeline)
            lastKey = nil
            dirty = false
            timing = EditTiming(timeline, sourceDurations: Self.durations(of: sources))
            problems = EditValidation.check(timeline, sources: sources)
            saveState = .saved
            onProject(p)
            scheduleRebuild()
        } catch {
            saveState = .failed(EditError.from(error))
        }
    }

    // MARK: - Render

    /// Saves first, then asks the server to render this revision. Throws what stops it: a problem in the timeline, a failed or
    /// conflicting save, or the server's refusal (`.queueFull`, `.tooLarge`, ...). `notify` follows `features.notify_bridge`.
    public func render() async throws(EditError) -> EditRender {
        if let first = problems.first { throw .invalid(first) }
        guard let client = editorClient else { throw .unavailable }
        saveTask?.cancel()
        saveTask = nil
        if dirty { await flush() }
        switch saveState {
        case .conflict(let theirs): throw .conflict(theirs)
        case .failed(let e): throw e
        case .saved: break
        case .saving, .unsaved: throw .other("unsaved")
        }
        do {
            let r = try await client.renderEdit(id: project.id, revision: project.revision, notify: ctx.capabilities.notifyBridge)
            adoptRender(r)
            startRenderPolling()
            return r
        } catch {
            let e = EditError.from(error)
            if case .conflict(let theirs) = e {
                conflict = theirs
                saveState = .conflict(theirs)
            }
            throw e
        }
    }

    /// The server renamed the project (the list's rename while the editor is open).
    func adoptTitle(_ title: String, revision: Int) {
        project.title = title
        project.revision = max(project.revision, revision)
        pendingTitle = nil
    }

    /// A render of this project changed elsewhere (the queue cancelled it).
    func noteRender(_ r: EditRender) {
        guard r.projectID == project.id, activeRender == nil || activeRender?.id == r.id || r.createdAt >= (activeRender?.createdAt ?? .distantPast) else { return }
        adoptRender(r)
    }

    private func adoptRender(_ r: EditRender) {
        activeRender = r
        project.render = r
        onRender(r)
    }

    /// Reads the render every 3 s while it runs, the editor is open and the app is in front.
    func startRenderPolling() {
        guard renderPoll == nil, let r = activeRender, r.isActive else { return }
        renderPoll = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self, await self.nap(Self.renderPollSeconds) else { break }
                guard let id = self.activeRender?.id, self.activeRender?.isActive == true, let client = self.editorClient else { break }
                guard self.ctx.background.activity.isActive else { continue }        // in the background the queue's polling follows it
                if let fresh = try? await client.editRender(id: id) {
                    self.adoptRender(fresh)
                    if !fresh.isActive { break }
                }
            }
            self?.renderPoll = nil
        }
    }

    // MARK: - The player

    private func nap(_ seconds: Double) async -> Bool {
        do { try await ctx.clock.sleep(seconds: seconds) } catch { return false }
        return !Task.isCancelled
    }

    private func scheduleRebuild(delay: Double = EditSession.rebuildDelay) {
        rebuildTask?.cancel()
        rebuildGeneration += 1
        let generation = rebuildGeneration
        rebuildTask = Task { @MainActor [weak self] in
            guard let self else { return }
            if delay > 0, await !self.nap(delay) { return }
            await self.rebuild(generation: generation)
        }
    }

    /// Fetches the files the timeline names, then builds the composition and gives it to the player.
    private func rebuild(generation: Int) async {
        let snapshot = timeline
        let items = Set(snapshot.main.map(\.item) + snapshot.overlay.map(\.item))
        let running = items.compactMap { startLoad($0) }
        for task in running { await task.value }
        guard generation == rebuildGeneration, !isClosed else { return }

        guard snapshot.main.allSatisfy({ assets[$0.item] != nil }), !snapshot.main.isEmpty else {
            isPlayerReady = false
            playable = nil
            player.replaceCurrentItem(with: nil)
            return
        }
        var playing = snapshot
        playing.overlay = snapshot.overlay.filter { assets[$0.item] != nil }          // an overlay whose file is missing is not drawn
        do {
            let built = try await EditComposition.build(playing, assets: assets)
            guard generation == rebuildGeneration, !isClosed else { return }
            builds += 1
            let wasPlaying = isPlaying
            let item = built.playerItem()
            observeEnd(of: item)
            player.replaceCurrentItem(with: item)
            playable = built
            isPlayerReady = true
            let k = min(playhead, max(0, built.timing.frames - 1))
            playhead = k
            player.seek(to: CMTime(value: Int64(k), timescale: Int32(built.timing.fps)), toleranceBefore: .zero, toleranceAfter: .zero) { _ in }
            if wasPlaying { player.play() }
        } catch {
            guard generation == rebuildGeneration else { return }
            isPlayerReady = false
            playable = nil
            player.replaceCurrentItem(with: nil)
        }
    }

    /// Starts fetching a file unless it is here or on its way; the task finishes when it is decoded or has failed.
    private func startLoad(_ id: String) -> Task<Void, Never>? {
        if assets[id] != nil { return nil }
        if let running = loads[id] { return running }
        guard let source = sources[id], source.available, source.kind != .unsupported, sourceFailures[id] == nil else { return nil }
        loadingSources[id] = 0
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            let poll = Task { @MainActor [weak self] in
                while !Task.isCancelled {
                    guard let self, await self.nap(0.25) else { return }
                    if let p = await self.cache.progress(for: id) { self.loadingSources[id] = p }
                }
            }
            do {
                let asset = try await self.cache.asset(for: source)
                self.assets[id] = asset
            } catch {
                self.sourceFailures[id] = EditError.from(error)
            }
            poll.cancel()
            self.loadingSources[id] = nil
            self.loads[id] = nil
        }
        loads[id] = task
        return task
    }

    /// The file of a clip that could not be fetched: try again.
    public func retrySource(_ id: String) {
        sourceFailures[id] = nil
        scheduleRebuild(delay: 0)
    }

    /// The decoded file of a clip (once it is on the device).
    func asset(_ id: String) -> EditSourceAsset? { assets[id] }

    // MARK: - Closing

    /// Stops everything the session runs: timers, downloads, the player. The store calls it when the editor closes.
    func tearDown() {
        isClosed = true
        saveTask?.cancel(); saveTask = nil
        retryTask?.cancel(); retryTask = nil
        rebuildTask?.cancel(); rebuildTask = nil
        renderPoll?.cancel(); renderPoll = nil
        for task in loads.values { task.cancel() }
        loads = [:]
        player.pause()
        isPlaying = false
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        timeObserver = nil
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = nil
        player.replaceCurrentItem(with: nil)
        Task { [cache] in await cache.cancelAll() }
    }
}
