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
/// - The player is rebuilt (`EditComposition`) 150 ms after the timeline settles, and keeps the playhead. During a drag or
///   slider run it waits for `endGesture()` (or 0.6 s of quiet), so the item is not swapped mid-gesture.
@MainActor @Observable
public final class EditSession {
    public enum Tool: String, CaseIterable, Sendable { case select, blade, crop }
    public enum SaveState: Equatable, Sendable {
        case saved, saving, unsaved, failed(EditError), conflict(EditProject)
        /// The project on the server is a version 2 timeline this save cannot write back. Shown as "update needed".
        case needsUpdate
    }
    public enum Selection: Equatable, Sendable { case none, main(String), overlay(String) }     // clip ids

    // MARK: state

    public private(set) var project: EditProject
    /// Always rounded and normalized (31.2).
    public private(set) var timeline: EditTimeline
    public private(set) var sources: [String: EditSource]
    public private(set) var timing: EditTiming
    /// What the server would refuse (or render with a problem); `[]` = ready to render.
    public private(set) var problems: [EditProblem]
    /// Layers the owner locked on this device. Never written to the project.
    public private(set) var lockedTracks: Set<Int> = []
    /// The overlay whose effects menu replaces the Mac inspector. The phone uses its own sheet.
    public var effectsFor: String?
    /// Greenscreen the canvas is previewing, before Apply. Not saved.
    public var effectDraft: EditEffectDraft?
    /// "fx" on a clip whose file a cut or Bria replaced. A greenscreen shows from its `key` alone.
    public private(set) var effectMarks: [String: EditEffectKind] = [:]
    /// The line on the effects card while a cut or a background-removal job is running.
    public var effectStatus: String?
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
    /// The composition the player plays; nil until one has been built.
    public private(set) var playable: EditPlayable?
    /// True once an item reports `.readyToPlay` (kept while a rebuilt item loads); false before the first one and when the
    /// current item has failed. A rebuild that throws keeps the last ready item, so play still works.
    public private(set) var isPlayerReady = false
    /// True when the newest build threw, or the current item's status is `.failed`. The last good picture stays up when there is one.
    public private(set) var previewFailed = false
    /// The line on the canvas while `previewFailed` (a short reason, never a path).
    public private(set) var previewFailure: String?
    /// Clip id -> why that clip was left out of the picture or drawn as a gap. The rest of the preview still plays.
    public private(set) var previewIssues: [String: String] = [:]
    public private(set) var canUndo = false
    public private(set) var canRedo = false
    /// Why the last lane edit was refused (`all 64 lanes are in use`, a locked lane, an older server). Nil after a success.
    public private(set) var laneRefusal: String?
    /// Clip ids the preview skipped because their file could not be read. The last good frame stays up; the chip names these.
    public private(set) var previewSkips: [String] = []

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
    /// A keyed edit (a drag or slider run) changed the timeline and its rebuild waits for `endGesture`.
    @ObservationIgnored private var gestureRebuildPending = false
    @ObservationIgnored private var assets: [String: EditSourceAsset] = [:]
    @ObservationIgnored private var loads: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var seekInFlight = false
    @ObservationIgnored private var pendingSeekFrame: Int?
    @ObservationIgnored private var endObserver: (any NSObjectProtocol)?
    @ObservationIgnored private var statusObservation: NSKeyValueObservation?
    /// The newest build threw and the previous item is still in the player. Its `.readyToPlay` must not clear `previewFailed`.
    @ObservationIgnored private var previewHold = false
    /// Pins on the source cache for the files this session is playing. Released in `tearDown`.
    @ObservationIgnored private let cacheOwner = UUID()
    @ObservationIgnored private var renderPoll: Task<Void, Never>?
    @ObservationIgnored private(set) var builds = 0

    // pitch in the preview (31.16): pre-shifted copies of clips' sound, made by the cache after the edits settle
    @ObservationIgnored private(set) var pitchCopies: [EditPitchKey: URL] = [:]
    @ObservationIgnored private var pitchTasks: [EditPitchKey: Task<Void, Never>] = [:]
    @ObservationIgnored private var pitchFailures: Set<EditPitchKey> = []
    @ObservationIgnored private var pitchDebounce: Task<Void, Never>?

    public static let saveDelay: Double = 1
    public static let rebuildDelay: Double = 0.15
    public static let retryDelays: [Double] = [2, 5, 10, 30]
    public static let renderPollSeconds: Double = 3
    public static let undoLimit = 100
    static let coalesceWindow: TimeInterval = 0.6
    /// Quiet time after the last rebuild before a shifted copy of a clip's sound is made (a slider drag makes one, not twenty).
    public static let pitchDelay: Double = 0.3
    static let minSeconds = 0.1

    init(
        project: EditProject, timeline: EditTimeline, sources: [String: EditSource], context: PipelineContext,
        cache: EditSourceCache, onProject: @escaping @MainActor (EditProject) -> Void,
        onRender: @escaping @MainActor (EditRender) -> Void
    ) {
        let rounded = EditLanes.materialize(EditJSON.rounded(timeline))
        self.project = project
        self.timeline = rounded
        self.sources = sources
        self.timing = EditTiming(rounded, sourceDurations: Self.durations(of: sources))
        self.problems = EditValidation.check(
            rounded, sources: sources,
            maxClips: max(1, context.capabilities.limits.editMaxClips),
            maxOverlayTracks: max(1, context.capabilities.limits.editOverlayTracks))
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
        chaseSeek(to: clamped)
    }

    /// One exact seek in flight; a scrub's newer targets wait, and only the latest is sent when it lands.
    private func chaseSeek(to frame: Int) {
        if seekInFlight {
            pendingSeekFrame = frame
            return
        }
        seekInFlight = true
        let time = CMTime(value: Int64(frame), timescale: Int32(timing.fps))
        player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            Task { @MainActor [weak self] in self?.seekLanded() }
        }
    }

    private func seekLanded() {
        seekInFlight = false
        guard let next = pendingSeekFrame else { return }
        pendingSeekFrame = nil
        guard !isClosed, player.currentItem != nil else { return }
        chaseSeek(to: min(next, max(0, timing.frames - 1)))
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

    /// Follows the item's status: ready only at `.readyToPlay`, `previewFailed` at `.failed`. `token` drops stale callbacks.
    /// A rebuild that kept the previous item sets `previewHold`, so this item becoming ready does not clear that failure.
    private func observeStatus(of item: AVPlayerItem) {
        statusObservation?.invalidate()
        let token = builds
        statusObservation = item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
            let status = item.status
            // the reason is a short string: `Error` is not sent across the hop, and its description can carry a path
            let failed = status == .failed ? EditPreviewFailure.reason(item.error ?? EditError.other("player")) : nil
            let logged = status == .failed ? Telemetry.errorData(item.error ?? EditError.other("player")) : nil
            Task { @MainActor [weak self] in self?.itemStatus(status, reason: failed, log: logged, token: token) }
        }
    }

    private func itemStatus(_ status: AVPlayerItem.Status, reason: String?, log: [String: TelemetryValue]?, token: Int) {
        guard token == builds, !isClosed else { return }
        switch status {
        case .readyToPlay:
            isPlayerReady = true
            if !previewHold {
                previewFailed = false
                previewFailure = nil
            }
        case .failed:
            previewHold = false
            isPlayerReady = false
            previewFailed = true
            previewFailure = reason ?? EditPreviewFailure.couldntUpdate
            var data = log ?? [:]
            data["reason"] = .string(previewFailure ?? EditPreviewFailure.couldntUpdate)
            data["where"] = "player"
            Telemetry.log(.error, .ui, "edit preview failed", data: data)
        default: break   // still loading: keep the last item's state
        }
    }

    private func reachedEnd() {
        isPlaying = false
        playhead = max(0, timing.frames - 1)
    }

    // MARK: - Main track

    /// Videos only (a gif or photo goes on the overlay); `nil` = the end. A clip is its whole file, speed 1 (31.2.1).
    ///
    /// A video whose length the library does not know (an upload: the server keeps none) is fetched and measured first: its
    /// download shows in `loadingSources`, and the clips go in when it is read, in the order given, at `index` as it is then.
    /// A file that cannot be fetched is not added (`sourceFailures` says why; adding it again tries again). A clip is never
    /// made with no length.
    public func add(_ files: [EditSource], at index: Int?) {
        let videos = files.filter { $0.kind == .video && $0.available }.map { self.withMeasured($0) }
        guard !videos.isEmpty else { return }
        let unknown = videos.filter { $0.duration == nil }
        guard !unknown.isEmpty else {
            insertClips(videos, at: index)
            return
        }
        let running = unknown.compactMap { measureLoad($0) }
        Task { @MainActor [weak self] in
            for task in running { await task.value }
            guard let self, !self.isClosed else { return }
            self.insertClips(videos.map { self.withMeasured($0) }, at: index)
        }
    }

    private func insertClips(_ files: [EditSource], at index: Int?) {
        let videos = files.filter { ($0.duration ?? 0) >= Self.minSeconds }
        guard !videos.isEmpty else { return }
        for file in videos { sources[file.id] = file }
        var firstID: String?
        commit(key: nil) { t in
            var at = min(max(0, index ?? t.main.count), t.main.count)
            for file in videos {
                guard t.main.count + t.overlay.count < self.clipLimit + 1 else { break }       // one past: the problem shows
                guard let duration = file.duration else { continue }
                let clip = EditClip.added(item: file.id, duration: duration)
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

    /// Splits the clip under the playhead. A selected clip that contains the playhead wins; otherwise the lane 0 clip.
    public func splitAtPlayhead() {
        let selected: String? = switch selection {
        case .main(let id), .overlay(let id): id
        case .none: nil
        }
        if let selected, contains(selected, frame: playhead) {
            split(clip: selected, atFrame: playhead)
            return
        }
        if timeline.version >= 2,
           let row = timing.laneClips.first(where: { row in
               timeline.clips.first(where: { $0.id == row.id })?.lane == 0 && playhead >= row.start && playhead < row.start + row.frames
           }) {
            split(clip: row.id, atFrame: playhead)
            return
        }
        guard let (index, _) = timing.clip(atFrame: playhead) else { return }
        split(clip: timeline.main[index].id, atFrame: playhead)
    }

    /// The clip the playhead is inside. `preferring` is used when that clip contains the playhead.
    func clipUnderPlayhead(preferring selection: Selection) -> String? {
        let preferred: String? = switch selection {
        case .main(let id), .overlay(let id): id
        case .none: nil
        }
        if let preferred, contains(preferred, frame: playhead) { return preferred }
        if timeline.version >= 2 {
            return EditLanes.drawOrder(timeline).reversed().compactMap { index -> String? in
                let clip = timeline.clips[index]
                guard !clip.hidden, contains(clip.id, frame: playhead) else { return nil }
                return clip.id
            }.first
        }
        return nil
    }

    private func contains(_ id: String, frame: Int) -> Bool {
        if timeline.version >= 2, let row = timing.laneClips.first(where: { $0.id == id }) {
            return frame >= row.start && frame < row.start + row.frames
        }
        if let index = timeline.main.firstIndex(where: { $0.id == id }), index < timing.main.count {
            let row = timing.main[index]
            return frame >= row.start && frame < row.start + row.frames
        }
        if let index = timeline.overlay.firstIndex(where: { $0.id == id }), index < timing.overlay.count {
            let row = timing.overlay[index]
            return frame >= row.start && frame < row.start + row.frames
        }
        return false
    }

    /// Splits at output frame `k`. Nothing happens when `k` is on the clip's edge or a half would be under 0.1 s.
    public func split(clip id: String, atFrame k: Int) {
        if timeline.version >= 2, timeline.clips.contains(where: { $0.id == id }) {
            applyLane(EditLanes.split(timeline, id: id, atFrame: k, newID: EditID.mint()))
            return
        }
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
        case .main(let id):
            if timeline.version >= 2 {
                applyLane(EditLanes.delete(timeline, id: id, closeLane0: true, locked: lockedLanes), clampForV1: true)
            } else {
                commit(key: nil) { $0.main.removeAll { $0.id == id } }
            }
        case .overlay(let id):
            if timeline.version >= 2 {
                applyLane(EditLanes.delete(timeline, id: id, closeLane0: true, locked: lockedLanes), clampForV1: true)
                effectMarks[id] = nil
                return
            }
            if let track = timeline.overlay.first(where: { $0.id == id })?.track, lockedTracks.contains(track) { return }
            commit(key: nil) { $0.overlay.removeAll { $0.id == id } }
            effectMarks[id] = nil
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

    /// Semitones (31.16): clamped to -12...12 and rounded to 0.5; 0 = unchanged. One undo step per drag (key `pitch:<id>`).
    /// Does nothing when the server does not know pitch (`capabilities.limits.editPitch` false): the control is hidden then, and
    /// a save never sends a pitch to such a server either (see `performFlush`).
    public func setPitch(_ semitones: Double, clip id: String) {
        guard ctx.capabilities.limits.editPitch else { return }
        editClip(id, key: "pitch:\(id)") { clip, _ in clip.pitch = Self.clampPitch(semitones) }
    }

    // MARK: - Overlay

    /// The overlay layers this server takes (`limits.edit_overlay_tracks`). 1 when the key is absent: that server refuses
    /// `track`. A server that sends 64 is 64. The old 8 is only `EditValidation.maxOverlayTracks`, for a check with no limit.
    public var overlayTrackLimit: Int {
        max(1, ctx.capabilities.limits.editOverlayTracks)
    }

    /// Main + overlay clips this server takes (`limits.edit_max_clips`). 50 when the key is absent.
    public var clipLimit: Int {
        max(1, ctx.capabilities.limits.editMaxClips)
    }

    /// The server stores `hidden: true`. When it does not, hide stays on the device and a version 1 save leaves the key out.
    public var sendsHidden: Bool { ctx.capabilities.limits.editOverlayHidden }

    /// This server stores a version 2 timeline (`limits.edit_timeline_version` >= 2). Otherwise a save is still version 1,
    /// and a lane move version 1 cannot represent is refused.
    public var savesTimelineV2: Bool { ctx.capabilities.limits.editTimelineVersion >= 2 }

    /// Overlay-track locks, as lane numbers. Lane 0 is the main row and is not one of those locks.
    var lockedLanes: Set<Int> { Set(lockedTracks.map { $0 + 1 }) }

    func sourceKinds() -> [String: String?] {
        var kinds: [String: String?] = [:]
        for (id, source) in sources {
            switch source.kind {
            case .video: kinds[id] = "video"
            case .gif: kinds[id] = "gif"
            case .photo: kinds[id] = "photo"
            case .unsupported: break
            }
        }
        return kinds
    }

    /// A version 1 server can store `next` only when the conversion drops nothing.
    func allowsSave(_ next: EditTimeline) -> Bool {
        if savesTimelineV2 || next.version < 2 { return true }
        if case .ok = EditLanes.v2ToV1(next, kinds: sourceKinds()) { return true }
        return false
    }

    /// A video overlay hiding the whole picture at the playhead: full frame, opaque, no greenscreen. Nil when the preview
    /// already marked that clip broken, or while its effects are open.
    public var coveringOverlayID: String? {
        EditPreviewCover.id(
            in: timeline, timing: timing, at: playhead,
            display: { id in
                if let asset = self.assets[id], asset.display.w > 0, asset.display.h > 0 { return asset.display }
                return self.sources[id]?.display
            },
            isVideo: { self.sources[$0]?.kind == .video },
            blocked: { self.previewIssues[$0] != nil || self.effectsFor == $0 })
    }

    /// More than about 8 videos share one moment. The preview is drawn smaller and a note says the render is fine.
    public var previewCrowded: Bool {
        EditOverlap.peak(in: timeline, timing: timing, video: { sources[$0.item]?.kind == .video }) > EditOverlap.comfortableVideos
    }

    public func showsEffect(_ overlay: EditOverlay) -> Bool {
        overlay.hasKey || effectMarks[overlay.id] != nil
    }

    public func isTrackLocked(_ track: Int) -> Bool { lockedTracks.contains(track) }

    public func setTrackLocked(_ track: Int, _ locked: Bool) {
        if locked { lockedTracks.insert(track) } else { lockedTracks.remove(track) }
    }

    /// Hide or show every overlay on a layer. Sent only when `sendsHidden` is true.
    public func setLayerHidden(_ track: Int, _ hidden: Bool) {
        commit(key: nil) { t in
            for i in t.overlay.indices where t.overlay[i].track == track {
                t.overlay[i].hidden = hidden
            }
        }
    }

    /// A layer is hidden when it has overlays and every one of them is hidden.
    public func layerHidden(_ track: Int) -> Bool {
        let rows = timeline.overlay.filter { $0.track == track }
        return !rows.isEmpty && rows.allSatisfy(\.hidden)
    }

    public func openEffects(_ id: String) {
        guard timeline.overlay.contains(where: { $0.id == id }) else { return }
        effectsFor = id
    }

    /// Closes the effects menu and drops the unsaved preview.
    public func closeEffects() {
        effectsFor = nil
        effectDraft = nil
        effectStatus = nil
        scheduleRebuild()
    }

    /// The live preview. Not an edit: Apply is what writes the timeline.
    public func setEffectDraft(_ draft: EditEffectDraft?) {
        effectDraft = draft
        scheduleRebuild(delay: 0.12)
    }

    /// Greenscreen: writes `key` (and background, and the edit's output). The list of effects maps to those fields.
    public func applyGreenscreen(id: String, key: EditChromaKey, background: EditOverlayBackground?, output: EditKeyedOutput?) {
        guard let key = key.normalized() else { return }
        commit(key: nil) { t in
            guard let i = t.overlay.firstIndex(where: { $0.id == id }) else { return }
            t.overlay[i].key = key
            t.overlay[i].background = background
            t.output = output?.stored
        }
        effectMarks[id] = .greenscreen
        effectDraft = nil
        effectStatus = nil
    }

    /// Person or subject: an alpha .mov uploaded as `role = alt`. Depth returns the stub message and changes nothing.
    /// Nil means it landed; a string is the line to show (an old server that refuses the upload, a clip with no subject).
    public func applyCut(id: String, kind: EditCutKind, soften: Double) async -> String? {
        if kind == .depthCut {
            return "depth cutout needs depth anything v2 small (\(EditDepthModel.approximateMegabytes) mb). it isn't in this build. person and subject work on this device."
        }
        guard let overlay = timeline.overlay.first(where: { $0.id == id }),
              let source = sources[overlay.item], source.kind == .video else { return "that isn't a video" }
        effectStatus = "cutting out…"
        do {
            let asset = try await cache.asset(for: source)
            guard case .video(let av, _, _) = asset else { effectStatus = nil; return "that isn't a video" }
            let movie = try await EditMaskExport.movie(
                source: av.url, kind: kind, start: overlay.`in`, end: overlay.out, soften: soften)
            guard let client = ctx.client as? any CobaltClient else { effectStatus = nil; return "you're offline · try again" }
            let spec = try JSONSerialization.data(withJSONObject: ["kind": kind.rawValue])
            let uploaded = try await client.uploadMade(
                item: overlay.item, role: .alt, file: movie, contentType: "video/quicktime",
                name: "\(kind.rawValue).mov", spec: spec, progress: { _ in })
            await cache.register(local: movie, for: uploaded.file.id)
            let made = EditSource(
                id: uploaded.file.id, name: uploaded.file.name, kind: .video,
                contentType: uploaded.file.contentType ?? "video/quicktime",
                width: uploaded.file.width, height: uploaded.file.height,
                duration: uploaded.file.duration ?? (overlay.out - overlay.`in`),
                bytes: uploaded.file.bytes, posterURL: uploaded.file.posterURL)
            sources[made.id] = made
            commit(key: nil) { t in
                guard let i = t.overlay.firstIndex(where: { $0.id == id }) else { return }
                t.overlay[i].item = made.id
                t.overlay[i].key = nil
            }
            effectMarks[id] = kind.effect
            effectDraft = nil
            effectStatus = nil
            _ = startLoad(made.id)
            return nil
        } catch let e as EditMaskError {
            effectStatus = nil
            switch e {
            case .depthUnavailable:
                return "depth cutout needs depth anything v2 small (\(EditDepthModel.approximateMegabytes) mb). it isn't in this build."
            case .tooLong: return "that clip is over 60s · trim it first"
            case .empty: return "nothing was left · try another method"
            case .noVideo: return "that isn't a video"
            case .failed: return "couldn't cut that out · try again"
            }
        } catch let e as CobaltError {
            effectStatus = nil
            if case .api(let code, let status) = e, status == 400 || code.contains("bad_request") {
                return "this server can't store that cut yet"
            }
            if case .network = e { return "you're offline · try again" }
            return "couldn't upload the cut · try again"
        } catch {
            effectStatus = nil
            return "couldn't cut that out · try again"
        }
    }

    /// The section 67 quote, or nil when this server has no remove-background route.
    public func backgroundQuote(for id: String) async -> RmbgQuote? {
        guard let item = timeline.overlay.first(where: { $0.id == id })?.item,
              let client = ctx.client as? any RmbgClient else { return nil }
        return try? await client.rmbgQuote(of: item)
    }

    /// Bria (section 67). Shows the quote's price on the card, then polls the job. The result is a ProRes alternate.
    /// Nil means the overlay now points at it.
    public func removeVideoBackground(id: String, spill: Double) async -> String? {
        guard let overlay = timeline.overlay.first(where: { $0.id == id }),
              let source = sources[overlay.item], source.kind == .video else { return "that isn't a video" }
        guard let client = ctx.client as? any RmbgClient else {
            return "this server can't remove a video background yet"
        }
        effectStatus = "checking the price…"
        do {
            let quote = try await client.rmbgQuote(of: source.id)
            if quote.tooLong {
                effectStatus = nil
                return "that clip is over \(Int(quote.maxSeconds))s"
            }
            effectStatus = "removing the background · \(Self.priceLine(quote))"
            let started = try await client.rmbgStart(of: source.id, spill: min(1, max(0, spill)))
            var job = started
            for _ in 0..<90 {
                if job.state == .success, let item = job.itemID {
                    let made = EditSource(
                        id: item, name: "background removed.mov", kind: .video, contentType: "video/quicktime",
                        duration: job.seconds ?? quote.seconds)
                    sources[made.id] = made
                    commit(key: nil) { t in
                        guard let i = t.overlay.firstIndex(where: { $0.id == id }) else { return }
                        t.overlay[i].item = made.id
                        t.overlay[i].key = nil
                    }
                    effectMarks[id] = .removeBackground
                    effectDraft = nil
                    effectStatus = nil
                    _ = startLoad(made.id)
                    return nil
                }
                if job.state == .error {
                    effectStatus = nil
                    return "couldn't remove the background · try again"
                }
                try await Task.sleep(for: .seconds(2))
                guard !isClosed else { return nil }
                job = try await client.rmbgStatus(of: source.id, job: started.id)
                effectStatus = "removing the background · \(Self.priceLine(quote))"
            }
            effectStatus = nil
            return "that's still running · it'll show up in your library"
        } catch let e as RmbgError {
            effectStatus = nil
            switch e {
            case .tooLong: return "that clip is over 60s"
            case .notVideo: return "that isn't a video"
            case .off: return "this server can't remove a video background yet"
            case .offline: return "you're offline · try again"
            case .notFound: return "that video is gone from your library"
            default: return "couldn't remove the background · try again"
            }
        } catch {
            effectStatus = nil
            return "couldn't remove the background · try again"
        }
    }

    private func problems(of t: EditTimeline) -> [EditProblem] {
        EditValidation.check(t, sources: sources, maxClips: clipLimit, maxOverlayTracks: overlayTrackLimit)
    }

    /// Puts a video, gif or photo (a webp, an emote, a cutout) over the main track at frame `k` (nil = the playhead), on layer
    /// `track` (nil = the lowest layer with room there). Refuses (false) when `k` is inside another overlay of that layer (of
    /// every layer, when `track` is nil) or less than 0.1 s of room is left; a longer one is cut at the next overlay of its
    /// layer.
    ///
    /// A video whose length is not known is fetched and measured first (as `add`): true means it goes on once it is read (at
    /// that frame, if there is still room then).
    @discardableResult
    public func addOverlay(_ file: EditSource, atFrame k: Int?, track: Int? = nil) -> Bool {
        let known = withMeasured(file)
        guard let spot = overlayRoom(for: known, atFrame: k, track: track) else { return false }
        let start = spot.start
        if known.kind == .video, known.duration == nil {
            guard let task = measureLoad(known) else { return false }
            Task { @MainActor [weak self] in
                await task.value
                guard let self, !self.isClosed else { return }
                let measured = self.withMeasured(known)
                guard (measured.duration ?? 0) >= Self.minSeconds else { return }
                _ = self.placeOverlay(measured, atFrame: start, track: track)
            }
            return true
        }
        return placeOverlay(known, atFrame: start, track: spot.track)
    }

    /// Where an overlay put at `k` (nil = the playhead) on layer `track` (nil = the lowest one with room) would start, the frames
    /// it has and its layer; nil when it cannot go there.
    func overlayRoom(for file: EditSource, atFrame k: Int?, track: Int? = nil) -> (start: Int, room: Int, track: Int)? {
        guard file.available, file.kind != .unsupported, timeline.main.count + timeline.overlay.count < clipLimit,
              timing.frames > 0 else { return nil }
        let start = min(max(0, k ?? playhead), timing.frames - 1)
        let layers = track.map { [$0] } ?? Array(0..<overlayTrackLimit)
        for layer in layers where (0..<overlayTrackLimit).contains(layer) {
            var room = timing.frames - start
            var blocked = false
            for (j, o) in timing.overlay.enumerated() where j < timeline.overlay.count && timeline.overlay[j].track == layer {
                if start >= o.start, start < o.start + o.frames { blocked = true; break }
                if o.start > start { room = min(room, o.start - start) }
            }
            if !blocked, room >= Self.minFrames(fps: timing.fps) { return (start, room, layer) }
        }
        return nil
    }

    private func placeOverlay(_ file: EditSource, atFrame k: Int, track: Int?) -> Bool {
        guard let spot = overlayRoom(for: file, atFrame: k, track: track) else { return false }
        let start = spot.start, room = spot.room
        sources[file.id] = file
        var overlay = EditOverlay.added(
            item: file.id, kind: file.kind, duration: file.duration, at: timing.time(ofFrame: start),
            remaining: Double(room) / Double(timing.fps))
        overlay.track = spot.track
        if let display = file.display {
            overlay.frame = EditGeometry.clampInside(overlay.frame, display: display, canvas: timeline.canvas)
        }
        let id = overlay.id
        commit(key: nil) { $0.overlay.append(overlay) }
        selection = .overlay(id)
        return true
    }

    /// The free stretch around frame `anchor` on layer `track`, leaving out overlay `i`: from the end of the overlay before it
    /// (one that covers `anchor` counts as before) to the start of the next one (or the end of the timeline).
    static func layerGap(_ t: EditTimeline, timing: EditTiming, excluding i: Int, track: Int, anchor: Int) -> (from: Int, to: Int) {
        var from = 0, to = timing.frames
        for (j, o) in timing.overlay.enumerated() where j != i && j < t.overlay.count && t.overlay[j].track == track {
            if o.start <= anchor { from = max(from, o.start + o.frames) } else { to = min(to, o.start) }
        }
        return (from, to)
    }

    /// Moves the overlay's start to output frame `k` (and to layer `track`, nil = its own), between the overlays next to it on
    /// that layer and the end. On its own layer it never jumps over a neighbour; on another layer it goes in the gap at `k`.
    /// False when it does not fit there (nothing changes).
    @discardableResult
    public func moveOverlay(id: String, toFrame k: Int, track: Int? = nil) -> Bool {
        if let current = timeline.overlay.first(where: { $0.id == id })?.track, lockedTracks.contains(current) { return false }
        if let track, lockedTracks.contains(track) { return false }
        if let track, !(0..<overlayTrackLimit).contains(track) { return false }
        var moved = false
        commit(key: "move:\(id)") { t in
            guard let i = t.overlay.firstIndex(where: { $0.id == id }) else { return }
            let timing = EditTiming(t)
            guard i < timing.overlay.count else { return }
            let me = timing.overlay[i]
            let layer = track ?? t.overlay[i].track
            let anchor = layer == t.overlay[i].track ? me.start : min(max(0, k), max(0, timing.frames - 1))
            let gap = Self.layerGap(t, timing: timing, excluding: i, track: layer, anchor: anchor)
            let latest = gap.to - me.frames
            guard latest >= gap.from else { return }
            let start = min(max(k, gap.from), latest)
            // one write: on a version 2 timeline `overlay` is a view sorted by time, so after a write to `at` the index can
            // name another overlay and a second write to `track` would move that one
            var placed = t.overlay[i]
            placed.at = Double(start) / Double(timing.fps)
            placed.track = layer
            t.overlay[i] = placed
            moved = true
        }
        return moved
    }

    /// Swaps the picture an overlay shows (its cutout, 39.3): the same place, width, time and layer; the height follows the new
    /// picture. Only a gif or photo overlay, and only for a gif or photo.
    public func setOverlayItem(id: String, _ file: EditSource) {
        guard file.kind == .photo || file.kind == .gif else { return }
        sources[file.id] = file
        commit(key: nil) { t in
            guard let i = t.overlay.firstIndex(where: { $0.id == id }),
                  let kind = self.sources[t.overlay[i].item]?.kind, kind == .photo || kind == .gif else { return }
            t.overlay[i].item = file.id
            if let display = file.display {
                t.overlay[i].frame = EditGeometry.clampInside(t.overlay[i].frame, display: display, canvas: t.canvas)
            }
        }
    }

    /// Puts the overlay on layer `track` at the same time. False when that layer is busy then.
    @discardableResult
    public func setOverlayTrack(id: String, _ track: Int) -> Bool {
        guard let i = timeline.overlay.firstIndex(where: { $0.id == id }), i < timing.overlay.count else { return false }
        if lockedTracks.contains(timeline.overlay[i].track) || lockedTracks.contains(track) { return false }
        if timeline.overlay[i].track == track { return true }
        let me = timing.overlay[i]
        let gap = Self.layerGap(timeline, timing: timing, excluding: i, track: track, anchor: me.start)
        guard gap.from <= me.start, gap.to >= me.start + me.frames else { return false }
        return moveOverlay(id: id, toFrame: me.start, track: track)
    }

    /// How long it stays up, 0.1 s to the room it has (the next overlay, the end, the file's own length for a video).
    public func setOverlayLength(id: String, seconds: Double) {
        if let track = timeline.overlay.first(where: { $0.id == id })?.track, lockedTracks.contains(track) { return }
        commit(key: "length:\(id)") { t in
            guard let i = t.overlay.firstIndex(where: { $0.id == id }) else { return }
            let timing = EditTiming(t)
            guard i < timing.overlay.count else { return }
            let me = timing.overlay[i]
            let nextStart = Self.layerGap(t, timing: timing, excluding: i, track: t.overlay[i].track, anchor: me.start).to
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
        if let track = timeline.overlay.first(where: { $0.id == id })?.track, lockedTracks.contains(track) { return }
        commit(key: "otrim:\(id)") { t in
            guard let i = t.overlay.firstIndex(where: { $0.id == id }), self.sources[t.overlay[i].item]?.kind == .video else { return }
            let timing = EditTiming(t)
            guard i < timing.overlay.count else { return }
            let me = timing.overlay[i]
            let nextStart = Self.layerGap(t, timing: timing, excluding: i, track: t.overlay[i].track, anchor: me.start).to
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

    /// An overlay's pitch, as `setPitch` (key `opitch:<id>`). A gif or photo has no sound: the value is kept and ignored.
    public func setOverlayPitch(_ semitones: Double, overlay id: String) {
        guard ctx.capabilities.limits.editPitch else { return }
        editOverlay(id, key: "opitch:\(id)") { $0.pitch = Self.clampPitch(semitones) }
    }

    // MARK: - Cutouts (APP-API-CONTRACT 39.3)

    /// The server takes cutouts (`features.cutout`) and the client can send them.
    public var canCutout: Bool { ctx.capabilities.cutout && ctx.client is any CutoutClient }

    /// The server can make a cutout itself (`features.cutout_auto`): the way when the picture cannot be read on the device.
    public func canServerCutout(mode: CutoutMode) -> Bool { canCutout && ctx.capabilities.cutoutAuto }

    /// The picture of a library file (a photo, or the first frame of a gif or animated webp), for the cutout sheet.
    public func picture(for source: EditSource) async throws -> CGImage {
        switch try await cache.asset(for: source) {
        case .photo(let image, _): return image
        case .gif(let frames, _, _):
            guard let first = frames.first else { throw CutoutError.failed }
            return first
        case .video: throw CutoutError.notImage
        }
    }

    /// Makes the cutout of `source` (a new private PNG in the library) and, with `place`, puts it over the main track at the
    /// playhead on the lowest free layer. Made on the device first (Vision for `auto`, the flood fill for white and colour) and
    /// uploaded; when the device cannot (the picture is not here, Vision finds no subject) and the server can
    /// (`features.cutout_auto`), the server makes it. A white or colour cutout with nothing left throws `.empty` at once.
    /// `replacing`: an overlay that shows `source` now shows the cutout instead (nothing new is placed).
    @discardableResult
    public func makeCutout(
        of source: EditSource, options: CutoutMaker.Options, place: Bool = true, replacing overlayID: String? = nil
    ) async throws -> EditSource {
        guard ctx.capabilities.cutout, let client = ctx.client as? any CutoutClient else { throw CutoutError.off }
        var png: Data?
        do {
            let picture = CutoutBox(try await picture(for: source))
            png = try await Task.detached(priority: .userInitiated) {
                let image = try CutoutMaker.make(picture.image, options)
                guard let data = CutoutMaker.png(image) else { throw CutoutError.failed }
                return data
            }.value
        } catch let e as CutoutError where e == .empty && options.mode != .auto {
            throw e
        } catch {
            png = nil
        }
        let result: CutoutResult
        if let png {
            result = try await client.uploadCutout(of: source.id, png: png, mode: options.mode, title: nil)
        } else if ctx.capabilities.cutoutAuto {
            let spec = CutoutSpec(
                mode: options.mode, color: options.mode == .color ? CutoutMaker.hex(options.key) : nil,
                tolerance: options.tolerance, edgesOnly: options.edgesOnly, soften: options.soften, trim: options.trim)
            result = try await client.makeCutout(of: source.id, spec: spec)
        } else {
            throw CutoutError.failed
        }
        var made = result.source
        made.posterURL = nil
        sources[made.id] = made
        if isClosed { return made }
        if let overlayID, timeline.overlay.contains(where: { $0.id == overlayID }) {
            setOverlayItem(id: overlayID, made)
        } else if place {
            addOverlay(made, atFrame: nil)
        }
        return made
    }

    // MARK: - Cropping pictures (APP-API-CONTRACT 44, apple/CONTRACT-EDITOR.md 13)

    /// The server takes crops (`features.image_crop`) and the client can send them.
    public var canCropImage: Bool { ctx.capabilities.imageCrop && ctx.client is any ImageCropClient }

    /// The server can make the crop of `source` itself: the way when the picture cannot be read or made on the device.
    public func canServerCrop(_ source: EditSource, cutout: Bool) -> Bool {
        canCropImage && ctx.capabilities.canServerCropImage(contentType: source.contentType, cutout: cutout)
    }

    /// Makes the crop of `source` (a new private PNG in the library) from `picture` (the stored picture at full size, from
    /// `picture(for:)`; nil asks the server) and, with `place`, puts it over the main track at the playhead on the lowest
    /// free layer. `replacing`: an overlay that shows `source` now shows the crop instead (same place, width, time and layer;
    /// nothing new is placed).
    @discardableResult
    public func makeImageCrop(
        of source: EditSource, picture: CGImage?, spec: ImageCropSpec, place: Bool = true, replacing overlayID: String? = nil
    ) async throws -> EditSource {
        guard canCropImage, let client = ctx.client as? any ImageCropClient else { throw ImageCropError.off }
        let result = try await ImageCropRun.make(
            of: source.id, picture: picture, spec: spec, client: client, server: canServerCrop(source, cutout: spec.cutout))
        var made = result.source
        made.posterURL = nil
        sources[made.id] = made
        if isClosed { return made }
        if let overlayID, timeline.overlay.contains(where: { $0.id == overlayID }) {
            setOverlayItem(id: overlayID, made)
        } else if place {
            addOverlay(made, atFrame: nil)
        }
        return made
    }

    // MARK: - Lanes (section 69)

    /// Moves a clip to `toLane` at `at` seconds. Leaving lane 0 closes the hole unless `keepGap`. Landing on another clip
    /// opens a new lane directly above the target. One undo step. False, and `laneRefusal`, when it cannot.
    @discardableResult
    public func moveClip(id: String, toLane: Int, at: Double, keepGap: Bool = false) -> Bool {
        applyLane(EditLanes.moveClip(timeline, id: id, toLane: toLane, at: at, keepGap: keepGap, locked: lockedLanes))
    }

    /// Opens a new lane directly above `lane` and puts the clip there, whether or not `lane` was free.
    @discardableResult
    public func moveClipToNewLane(id: String, above lane: Int, at: Double, keepGap: Bool = false) -> Bool {
        applyLane(EditLanes.moveToNewLane(timeline, id: id, above: lane, at: at, keepGap: keepGap, locked: lockedLanes))
    }

    /// Shifts every clip above `lane` up by one. The new lane is empty.
    @discardableResult
    public func insertLaneAbove(_ lane: Int) -> Bool {
        applyLane(EditLanes.insertLane(above: lane, in: timeline))
    }

    /// A copy of the clip just after it, on the same lane, or on a new lane above when that spot is taken.
    @discardableResult
    public func duplicateClip(id: String) -> Bool {
        applyLane(EditLanes.duplicate(timeline, id: id, newID: EditID.mint(), locked: lockedLanes))
    }

    /// Hides or shows one clip on any lane. A hidden clip still occupies its lane.
    public func setClipHidden(id: String, _ hidden: Bool) {
        _ = applyLane(EditLanes.setHidden(timeline, id: id, hidden: hidden))
    }

    /// One lane up (`by` +1, drawn later) or down. A taken spot is refused.
    @discardableResult
    public func moveClipLayer(id: String, by delta: Int) -> Bool {
        applyLane(EditLanes.moveLayer(timeline, id: id, by: delta, locked: lockedLanes))
    }

    /// `clampForV1`: a delete. On an older server the overlays are cut at the end of lane 0 first, as `commit` does and
    /// as version 1 always did, so a delete that leaves an overlay running past the end (or nothing on lane 0) goes through
    /// instead of being refused. Moves are checked as they are.
    @discardableResult
    private func applyLane(_ change: EditLaneChange, key: String? = nil, clampForV1: Bool = false) -> Bool {
        switch change {
        case .done(let success):
            let checked = clampForV1 && !savesTimelineV2 ? normalized(success.timeline, clampOverlays: true) : success.timeline
            // the last clip deleted: as version 1 that is an empty main track, which `problems` keeps from saving (`.empty`)
            guard allowsSave(checked) || (clampForV1 && checked.clips.isEmpty) else {
                laneRefusal = EditLanes.needsServerMessage
                return false
            }
            laneRefusal = nil
            guard success.timeline != timeline else { return true }
            if let lane = success.insertedAbove { shiftLocks(above: lane) }
            commit(key: key) { $0 = success.timeline }
            return true
        case .refused(let message):
            laneRefusal = message
            return false
        }
    }

    /// A new lane was opened above `lane`, so a lock on a higher overlay track moves up with that track.
    private func shiftLocks(above lane: Int) {
        lockedTracks = Set(lockedTracks.map { track in
            track + 1 > lane ? track + 1 : track
        })
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
    /// A rebuild held back during the run is scheduled now (the usual 150 ms debounce, so a burst of nudges is one rebuild).
    public func endGesture() {
        lastKey = nil
        if gestureRebuildPending {
            gestureRebuildPending = false
            scheduleRebuild()
        }
    }

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
        timeline = normalized(t, clampOverlays: !savesTimelineV2)
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
        let clamp = !savesTimelineV2
        change(&t)
        t = normalized(t, clampOverlays: clamp)
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
        afterChange(inGesture: key != nil)
    }

    /// `inGesture`: a drag or slider run; the player is rebuilt when it ends (`endGesture`), or after `coalesceWindow` of
    /// quiet if no end comes, not on every tick.
    private func afterChange(inGesture: Bool = false) {
        timing = EditTiming(timeline, sourceDurations: Self.durations(of: sources))
        problems = problems(of: timeline)
        switch selection {
        case .none: break
        case .main(let id): if !timeline.main.contains(where: { $0.id == id }) { selection = .none }
        case .overlay(let id): if !timeline.overlay.contains(where: { $0.id == id }) { selection = .none }
        }
        if playhead > max(0, timing.frames - 1) { playhead = max(0, timing.frames - 1) }
        markChanged()
        if inGesture {
            gestureRebuildPending = true
            scheduleRebuild(delay: Self.coalesceWindow)
        } else {
            gestureRebuildPending = false
            scheduleRebuild()
        }
    }

    /// The probed length of every video file, for the end-of-source clamp the renderer applies.
    static func durations(of sources: [String: EditSource]) -> [String: Double] {
        var out: [String: Double] = [:]
        for (id, source) in sources where source.kind == .video && source.available {
            if let d = source.duration, d > 0 { out[id] = d }
        }
        return out
    }

    /// `file` with the length and size this session has measured for it filled in where it has none.
    private func withMeasured(_ file: EditSource) -> EditSource { Self.keepingMeasured(file, sources[file.id]) }

    /// `fresh` (the server's or the library's copy of a file) with `known`'s length and size where `fresh` has none: the server
    /// keeps no length for an upload, and the session learns it when the file is decoded.
    static func keepingMeasured(_ fresh: EditSource, _ known: EditSource?) -> EditSource {
        guard let known, known.id == fresh.id else { return fresh }
        var s = fresh
        if s.duration == nil { s.duration = known.duration }
        if s.display == nil, let d = known.display {
            s.width = d.w
            s.height = d.h
        }
        return s
    }

    /// Fills in what the server did not know of a file (an upload has no length or size) from its decoded copy, then times and
    /// checks the timeline again with it: the bin, add, the overlay, trim limits and the end-of-source clamp see real numbers.
    private func learn(_ id: String, display: PixelSize, duration: Double?) {
        guard var s = sources[id] else { return }
        var changed = false
        if s.display == nil, display.w > 0, display.h > 0 {
            s.width = display.w
            s.height = display.h
            changed = true
        }
        if s.duration == nil, s.kind == .video, let duration, duration.isFinite, duration > 0 {
            s.duration = duration
            changed = true
        }
        guard changed else { return }
        sources[id] = s
        timing = EditTiming(timeline, sourceDurations: Self.durations(of: sources))
        problems = problems(of: timeline)
        if playhead > max(0, timing.frames - 1) { playhead = max(0, timing.frames - 1) }
    }

    /// Fetches and decodes a file that is not on the timeline yet, to measure it: the source joins `sources` (with what is
    /// already known of it) and an earlier failure is forgotten (adding it again is the retry). Nil: nothing to wait for.
    private func measureLoad(_ file: EditSource) -> Task<Void, Never>? {
        sources[file.id] = withMeasured(file)
        sourceFailures[file.id] = nil
        return startLoad(file.id)
    }

    static func minFrames(fps: Int) -> Int { max(1, Int((Self.minSeconds * Double(fps) - 1e-9).rounded(.up))) }

    /// "$0.0225/s · $0.0900" for the effects card. The price is the quote's, which section 67 fixes at $0.0225 a second.
    private static func priceLine(_ quote: RmbgQuote) -> String {
        String(format: "$%.4f/s · $%.4f", quote.usdPerSecond, quote.estimateUSD)
    }

    /// Rounded, and with the overlays made safe: sorted by start (ties keep their order), on a known layer, inside the canvas,
    /// never overlapping another of their layer (in frames), inside the main track. An overlay with under 0.1 s of room is dropped.
    ///
    /// A server that stores version 2 does not pull clips back inside lane 0: a gap stays black and a higher lane may run past
    /// lane 0. `clampOverlays` is that older rule, used while the save is still version 1.
    private func normalized(_ input: EditTimeline, clampOverlays: Bool) -> EditTimeline {
        var t = EditJSON.rounded(input)
        guard clampOverlays else { return t }
        let fps = Double(max(1, t.canvas.fps))
        let total = t.version >= 2 ? EditLanes.lane0EndFrame(t) : EditTiming(t).frames
        let minFrames = Self.minFrames(fps: t.canvas.fps)
        t.overlay = t.overlay.enumerated()
            .sorted { $0.element.at != $1.element.at ? $0.element.at < $1.element.at : $0.offset < $1.offset }
            .map(\.element)
        var kept: [EditOverlay] = []
        let layerLimit = overlayTrackLimit
        var previousEnd: [Int: Int] = [:]
        for var o in t.overlay {
            o.track = min(max(0, o.track), layerLimit - 1)
            if let display = sources[o.item]?.display, display.w > 0, display.h > 0 {
                o.frame = EditGeometry.clampInside(o.frame, display: display, canvas: t.canvas)
            } else {
                o.frame = EditFrame(x: min(max(0, o.frame.x), 0.95), y: min(max(0, o.frame.y), 0.95), w: min(1, max(0.05, o.frame.w)))
            }
            let wantedStart = EditMath.roundHalfUp(o.at * fps)
            let wantedFrames = max(1, EditMath.roundHalfUp((o.out - o.`in`) * fps))
            let start = max(previousEnd[o.track] ?? 0, max(0, wantedStart))
            var frames = wantedFrames
            if start + frames > total { frames = total - start }
            guard frames >= minFrames else { continue }
            if start != wantedStart { o.at = Double(start) / fps }
            if frames != wantedFrames { o.out = o.`in` + Double(frames) / fps }
            previousEnd[o.track] = start + frames
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

    /// -12...12, then the nearest 0.5 (31.16); not a number = 0.
    static func clampPitch(_ p: Double) -> Double {
        EditJSON.pitch(min(EditJSON.pitchRange.upperBound, max(EditJSON.pitchRange.lowerBound, p.isFinite ? p : 0)))
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
        if case .needsUpdate = saveState { return }
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
            // Version 2 is sent only when the server says `edit_timeline_version` >= 2. Otherwise the save is the version 1
            // document, and a timeline that cannot be one is "update needed" rather than a partial write.
            var sent = snapshot
            if savesTimelineV2 {
                if sent.version < 2, case .ok(let v2) = EditLanes.v1ToV2(sent) { sent = v2 }
            } else if sent.version >= 2 {
                guard case .ok(let v1) = EditLanes.v2ToV1(sent, kinds: sourceKinds()) else {
                    saveState = .needsUpdate
                    return
                }
                sent = v1
            }
            // a server that does not know pitch refuses the key: it gets the timeline with every pitch at 0 (left out).
            // one that does not advertise `hidden` must not be sent the key either (it would refuse the save). A version 2
            // document includes both keys (section 69), so they are stripped only from a version 1 save.
            if !ctx.capabilities.limits.editPitch { sent = EditJSON.withoutPitch(sent) }
            if sent.version < 2, !sendsHidden { sent = EditJSON.withoutHidden(sent) }
            let title = pendingTitle
            saveState = .saving
            saveCalls += 1
            do {
                let saved = try await client.saveEditProject(
                    id: project.id, timeline: sent, baseRevision: project.revision, title: title)
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
                if case .needsTimelineV2 = e {
                    saveState = .needsUpdate
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
            for (id, source) in fresh_sources { sources[id] = Self.keepingMeasured(source, sources[id]) }
            undoStack.append(timeline)
            redoStack = []
            updateHistoryFlags()
            var p = fresh
            p.timeline = nil
            project = p
            pendingTitle = nil
            conflict = nil
            timeline = normalized(EditLanes.materialize(theirTimeline), clampOverlays: !savesTimelineV2)
            lastKey = nil
            dirty = false
            timing = EditTiming(timeline, sourceDurations: Self.durations(of: sources))
            problems = problems(of: timeline)
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
        case .needsUpdate: throw .needsTimelineV2(path: "", title: project.title, projectID: project.id)
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
            self.gestureRebuildPending = false
            await self.rebuild(generation: generation)
        }
    }

    /// Fetches the files the timeline names, then builds the composition and gives it to the player.
    private func rebuild(generation: Int) async {
        let snapshot = timeline
        let items = Set(snapshot.main.map(\.item) + snapshot.overlay.map(\.item))
        await preflight(items)
        let running = items.compactMap { startLoad($0) }
        for task in running { await task.value }
        guard generation == rebuildGeneration, !isClosed else { return }

        // a missing file is a gap or a left-out clip with its reason (`previewIssues`), never a blank preview
        let empty = snapshot.version < 2 ? snapshot.main.isEmpty : snapshot.clips.isEmpty
        guard !empty else {
            previewIssues = [:]
            previewSkips = []
            failPreview(EditPreviewFailure.nothingToPlay, keepPicture: false)
            return
        }
        var playing = snapshot
        if snapshot.version < 2 {
            playing.overlay = snapshot.overlay.filter { !$0.hidden }
        }
        if let draft = effectDraft, draft.kind == .greenscreen {
            if playing.version >= 2, let i = playing.clips.firstIndex(where: { $0.id == draft.overlayID }) {
                playing.clips[i].key = draft.key.normalized()
                playing.clips[i].background = draft.background
            } else if let i = playing.overlay.firstIndex(where: { $0.id == draft.overlayID }) {
                playing.overlay[i].key = draft.key.normalized()
                playing.overlay[i].background = draft.background
            }
        }
        // clips with a pitch play their shifted copy once it is made, the source's sound until then
        let wanted = pitchKeys(playing)
        let ready = pitchCopies.filter { wanted.contains($0.key) }
        schedulePitchCopies(wanted.subtracting(ready.keys))
        do {
            let hints = EditPreviewHints(
                maskOverlayID: effectDraft?.showMask == true ? effectDraft?.overlayID : nil,
                splitOverlayID: effectDraft?.split == true ? effectDraft?.overlayID : nil)
            let built = try await EditComposition.build(playing, assets: assets, shifted: ready, preview: hints)
            guard generation == rebuildGeneration, !isClosed else { return }
            builds += 1
            let wasPlaying = isPlaying
            let item = built.playerItem()
            observeEnd(of: item)
            // keep the last item's readiness while the new one loads (no flicker on every edit); its status decides
            previewHold = false
            previewFailed = false
            previewFailure = nil
            let nextIssues = Dictionary(built.issues.map { ($0.clipID, $0.reason) }, uniquingKeysWith: { first, _ in first })
            for issue in built.issues where previewIssues[issue.clipID] != issue.reason {
                Telemetry.log(.warn, .ui, "edit preview left a clip out", data: [
                    "lane": .string(issue.lane.rawValue), "reason": .string(issue.reason),
                ])
            }
            previewIssues = nextIssues
            observeStatus(of: item)
            player.replaceCurrentItem(with: item)
            playable = built
            previewSkips = built.skippedClipIDs
            let k = min(playhead, max(0, built.timing.frames - 1))
            playhead = k
            pendingSeekFrame = nil                                                        // this seek goes to the playhead
            player.seek(to: CMTime(value: Int64(k), timescale: Int32(built.timing.fps)), toleranceBefore: .zero, toleranceAfter: .zero) { _ in }
            if wasPlaying { player.play() }
        } catch {
            guard generation == rebuildGeneration else { return }
            let reason = EditPreviewFailure.reason(error)
            // the last picture stays, and play stays usable while that item is still ready
            failPreview(reason, keepPicture: player.currentItem != nil && playable != nil)
            var data = Telemetry.errorData(error)
            data["reason"] = .string(reason)
            data["where"] = "build"
            Telemetry.log(.error, .ui, "edit preview failed", data: data)
        }
    }

    /// Off the main thread (apple/ARCHITECTURE.md rule 1): a stat can stall on a busy disk.
    @concurrent
    nonisolated static func fileIsReadable(_ url: URL) async -> Bool {
        FileManager.default.isReadableFile(atPath: url.path)
    }

    /// A file the session already holds must still be on disk. One that is gone is dropped so `startLoad` fetches it again,
    /// and every file that is still here is pinned before the next download's trim.
    private func preflight(_ ids: Set<String>) async {
        for id in ids {
            guard let asset = assets[id] else { continue }
            let readable: Bool
            switch asset {
            case .video(let av, _, _):
                readable = await Self.fileIsReadable(av.url)
            case .gif, .photo:
                readable = await cache.isReadable(id)
            }
            if readable {
                if case .video(let av, _, _) = asset {
                    await cache.pin(owner: cacheOwner, file: av.url)
                }
                await cache.pin(owner: cacheOwner, id: id)
                await cache.touch(id)
            } else {
                assets[id] = nil
                sourceFailures[id] = nil
                await cache.invalidate(id)
            }
        }
    }

    /// `keepPicture`: the player already has an item, so this failure leaves it (and its frame) where it is.
    private func failPreview(_ reason: String, keepPicture: Bool) {
        previewFailure = reason
        previewFailed = true
        if keepPicture {
            previewHold = true
            return
        }
        previewHold = false
        statusObservation?.invalidate()
        statusObservation = nil
        isPlayerReady = false
        playable = nil
        player.replaceCurrentItem(with: nil)
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
                var length: Double?
                if source.kind == .video, source.duration == nil { length = await self.cache.length(of: id) }
                self.assets[id] = asset
                if case .video(let av, _, _) = asset {
                    await self.cache.pin(owner: self.cacheOwner, file: av.url)
                }
                await self.cache.pin(owner: self.cacheOwner, id: id)
                self.learn(id, display: asset.display, duration: length)
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

    // MARK: pitch copies (31.16)

    /// The copies a timeline needs: every audible clip and video overlay with a pitch whose file is here and has sound.
    func pitchKeys(_ t: EditTimeline) -> Set<EditPitchKey> {
        var keys = Set<EditPitchKey>()
        if t.version >= 2 {
            for clip in t.clips where !clip.muted && !clip.hidden {
                guard let key = EditPitchKey(lane: clip), case .video(_, _, let hasAudio)? = assets[clip.item], hasAudio else { continue }
                keys.insert(key)
            }
            return keys
        }
        for clip in t.main where !clip.muted {
            guard let key = EditPitchKey(clip: clip), case .video(_, _, let hasAudio)? = assets[clip.item], hasAudio else { continue }
            keys.insert(key)
        }
        for o in t.overlay where !o.muted {
            guard let key = EditPitchKey(overlay: o), case .video(_, _, let hasAudio)? = assets[o.item], hasAudio else { continue }
            keys.insert(key)
        }
        return keys
    }

    /// Starts making the missing copies after `pitchDelay` of quiet (each rebuild restarts the wait). A copy that failed is not
    /// tried again in this session: that clip plays unshifted.
    private func schedulePitchCopies(_ missing: Set<EditPitchKey>) {
        pitchDebounce?.cancel()
        pitchDebounce = nil
        let todo = missing.filter { pitchTasks[$0] == nil && !pitchFailures.contains($0) }
        guard !todo.isEmpty, !isClosed else { return }
        pitchDebounce = Task { @MainActor [weak self] in
            guard let self, await self.nap(Self.pitchDelay), !self.isClosed else { return }
            self.pitchDebounce = nil
            for key in todo { self.startPitchCopy(key) }
        }
    }

    /// One copy, made by the cache off the main actor; when it is ready and the timeline still wants it, the player is rebuilt.
    private func startPitchCopy(_ key: EditPitchKey) {
        guard pitchTasks[key] == nil, pitchCopies[key] == nil, let source = sources[key.item] else { return }
        let cache = self.cache
        pitchTasks[key] = Task { @MainActor [weak self] in
            do {
                let url = try await cache.shiftedAudio(for: source, key: key)
                guard let self else { return }
                self.pitchTasks[key] = nil
                guard !self.isClosed else { return }
                self.pitchCopies[key] = url
                if self.pitchKeys(self.timeline).contains(key) { self.scheduleRebuild(delay: 0) }
            } catch {
                guard let self else { return }
                self.pitchTasks[key] = nil
                if !Task.isCancelled, !self.isClosed { self.pitchFailures.insert(key) }
            }
        }
    }

    /// The file of a clip that could not be fetched: try again.
    public func retrySource(_ id: String) {
        sourceFailures[id] = nil
        scheduleRebuild(delay: 0)
    }

    /// The decoded file of a clip (once it is on the device).
    func asset(_ id: String) -> EditSourceAsset? { assets[id] }

    /// The on-device file for a library video, once the preview has decoded it. Nil until then, and for a
    /// gif or a photo. `assets` is not observed: a view refreshes from `playable` or the download state.
    public func localVideoURL(for itemID: String) -> URL? {
        guard case .video(let asset, _, _) = assets[itemID] else { return nil }
        return asset.url
    }

    // MARK: - Closing

    /// Stops everything the session runs: timers, downloads, the player. The store calls it when the editor closes.
    func tearDown() {
        isClosed = true
        statusObservation?.invalidate(); statusObservation = nil
        saveTask?.cancel(); saveTask = nil
        retryTask?.cancel(); retryTask = nil
        rebuildTask?.cancel(); rebuildTask = nil
        renderPoll?.cancel(); renderPoll = nil
        for task in loads.values { task.cancel() }
        loads = [:]
        pitchDebounce?.cancel(); pitchDebounce = nil
        for task in pitchTasks.values { task.cancel() }
        pitchTasks = [:]
        player.pause()
        isPlaying = false
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        timeObserver = nil
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = nil
        player.replaceCurrentItem(with: nil)
        let owner = cacheOwner
        Task { [cache] in
            await cache.unpinOwner(owner)
            await cache.cancelAll()
        }
    }
}

/// Carries a decoded picture to the cutout's background task.
private final class CutoutBox: @unchecked Sendable {
    let image: CGImage
    init(_ image: CGImage) { self.image = image }
}
