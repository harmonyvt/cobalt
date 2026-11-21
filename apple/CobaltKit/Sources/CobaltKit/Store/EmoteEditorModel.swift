import Foundation
import Observation

/// Everything the owner can set in the emote editor (APP-API-CONTRACT 71): one value, so undo and redo are copies of it and
/// "did anything change since the last draft" is `==`.
public struct EmoteSettings: Sendable, Equatable {
    /// The box to keep (fractions of the picture); nil = the whole picture.
    public var crop: ImageCropRect?
    public var stretch = EmoteStretch.identity
    public var format = EmoteFormat.webp
    /// Auto keeps the file under the cap with the server's ladder; off holds `quality`.
    public var autoQuality = true
    public var quality = 70
    /// The longest side in px (32...1000).
    public var size = EmoteLimits.defaultSize
    public var fps = EmoteLimits.defaultFps
    /// A video's moment, in seconds.
    public var start = 0.0
    public var end = EmoteLimits.defaultMoment
    public var bounce = false
    /// A png's still, seconds into a video (nil = the moment's start).
    public var frame: Double?

    public init() {}
}

/// One of the four live ticks (71.4): shape, pixels, frames, bytes.
public struct EmoteCheck: Sendable, Equatable, Identifiable {
    public enum Kind: String, Sendable { case shape, pixels, frames, bytes }
    public enum Tone: Sendable { case ok, warn, bad, unknown }

    public var id: Kind { kind }
    public var kind: Kind
    public var tone: Tone
    /// What is measured: "3:2", "512 x 341", "48", "1.8 MB"; nil while unknown.
    public var value: String?
    /// The limit, as the mockup writes it: "1:32 - 3:1", "<= 1000 px".
    public var limit: String
}

/// The emote editor's state (APP-API-CONTRACT 71, apple/CONTRACT.md "emote editor"): the settings, the draft the server last
/// made, and the remake loop. Every settled change (`delay` after the last one, 0.4 s) calls `make` with `replace` = the draft
/// before; a newer change cancels one still running; the last good draft stays shown; a refusal shows inline (`error`) and
/// does not clear it. A shape outside 1:32..3:1 is never sent: `blocker` says so at once.
@MainActor @Observable
public final class EmoteEditorModel {
    public enum Tab: String, Sendable, CaseIterable, Identifiable {
        case crop, squash, format, compress, frames
        public var id: String { rawValue }
    }

    public enum Blocker: Sendable, Equatable {
        /// The stretched crop is outside 1:32..3:1.
        case shape
        /// A video moment is not 0.2 to 10 seconds.
        case moment
    }

    public let source: EmoteSource
    public private(set) var settings = EmoteSettings()
    /// "linked": a squash on one side moves the other the same way.
    public var linked = false
    public var tab: Tab = .crop

    /// The last good draft, and the settings it was made with.
    public private(set) var draft: EmoteDraft?
    public private(set) var draftSettings: EmoteSettings?
    /// The draft's bytes (what the preview draws), once read.
    public private(set) var draftData: Data?
    /// A file on disk for the share sheet.
    public private(set) var shareURL: URL?
    /// Changes whenever a new draft's bytes arrive (a view restarts its player on it).
    public private(set) var draftRevision = 0
    /// A remake is running (the seam glows).
    public private(set) var remaking = false
    /// The last remake's refusal; nil after a good one.
    public private(set) var error: SevenTvError?
    /// The source picture's size in px when the file did not say (the view reads it from the decoded picture).
    public private(set) var sourceWidth: Int?
    public private(set) var sourceHeight: Int?
    /// A video's length in seconds (the library's, else what the view read).
    public private(set) var videoDuration: Double?
    public private(set) var canUndo = false
    public private(set) var canRedo = false
    /// Counts up whenever a draft lands or a remake fails: the haptics.
    public private(set) var landed = 0
    public private(set) var failed = 0

    /// Seconds to wait after the last change before a remake.
    @ObservationIgnored public var delay: Double
    @ObservationIgnored private let client: any SevenTvClient
    @ObservationIgnored private let sleeper: @Sendable (Double) async throws -> Void
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var settled = EmoteSettings()
    @ObservationIgnored private var undoStack: [EmoteSettings] = []
    @ObservationIgnored private var redoStack: [EmoteSettings] = []
    @ObservationIgnored private var shareFolder: URL?

    public init(
        source: EmoteSource, client: any SevenTvClient, delay: Double = 0.4,
        sleep: @escaping @Sendable (Double) async throws -> Void = { try await Task.sleep(for: .seconds($0)) }
    ) {
        self.source = source
        self.client = client
        self.delay = delay
        self.sleeper = sleep
        sourceWidth = source.width
        sourceHeight = source.height
        if source.isVideo {
            videoDuration = source.duration
            if let d = source.duration { settings.end = min(EmoteLimits.defaultMoment, d) }
        }
        settled = settings
    }

    // MARK: reading

    public var hasFrames: Bool { source.hasFrames }
    /// The tabs this source has (frames only for a video or an animated picture).
    public var tabs: [Tab] { Tab.allCases.filter { $0 != .frames || hasFrames } }

    /// The picture's size in px, when known.
    public var sourcePixels: (width: Int, height: Int)? {
        guard let w = sourceWidth, let h = sourceHeight else { return nil }
        return (w, h)
    }

    /// The crop box, then the stretch, in px; nil while the picture's size is unknown.
    public var stretchedPixels: (width: Double, height: Double)? {
        EmoteLimits.stretchedPixels(width: sourceWidth, height: sourceHeight, crop: settings.crop, stretch: settings.stretch)
    }

    /// What the server makes of the settings in px (the draft's own size once one is current).
    public var outputPixels: (width: Int, height: Int)? {
        if isCurrent, let draft { return (draft.width, draft.height) }
        return stretchedPixels.map { EmoteLimits.outputPixels(stretched: $0, size: settings.size) }
    }

    /// The shape of the stretched crop as "3:2".
    public var shapeLabel: String? {
        stretchedPixels.map { EmoteLimits.ratioLabel(width: $0.width, height: $0.height) }
    }

    public var blocker: Blocker? {
        if let s = stretchedPixels, !EmoteLimits.shapeFits(width: s.width, height: s.height) { return .shape }
        if source.isVideo {
            let length = settings.end - settings.start
            if length < EmoteLimits.momentRange.lowerBound - 1e-6 || length > EmoteLimits.momentRange.upperBound + 1e-6 { return .moment }
        }
        return nil
    }

    /// The draft was made with the settings now on screen.
    public var isCurrent: Bool { draft != nil && draftSettings == settings }

    /// The draft is fit to upload or save: current, nothing running, no refusal, and under the cap.
    public var canUseDraft: Bool {
        guard let draft, isCurrent, !remaking, error == nil, blocker == nil else { return false }
        return draft.bytes <= EmoteLimits.capBytes
    }

    /// The four ticks (shape, pixels, frames, bytes). Before a draft exists frames and bytes are estimates or unknown.
    public var checks: [EmoteCheck] {
        [shapeCheck, pixelsCheck, framesCheck, bytesCheck]
    }

    private var shapeCheck: EmoteCheck {
        let limit = "1:32 - 3:1"
        guard let s = stretchedPixels else { return EmoteCheck(kind: .shape, tone: .unknown, value: nil, limit: limit) }
        let ok = EmoteLimits.shapeFits(width: s.width, height: s.height)
        return EmoteCheck(
            kind: .shape, tone: ok ? .ok : .bad, value: EmoteLimits.ratioLabel(width: s.width, height: s.height), limit: limit)
    }

    private var pixelsCheck: EmoteCheck {
        let limit = "<= \(EmoteLimits.maxSide) px"
        guard let out = outputPixels else { return EmoteCheck(kind: .pixels, tone: .unknown, value: nil, limit: limit) }
        let ok = max(out.width, out.height) <= EmoteLimits.maxSide
        return EmoteCheck(kind: .pixels, tone: ok ? .ok : .bad, value: "\(out.width) x \(out.height)", limit: limit)
    }

    /// Frames of the draft, else for a video the moment at the frame rate; unknown for a picture before its first draft.
    public var frameCount: Int? {
        if isCurrent, let draft { return draft.frames }
        if settings.format == .png { return 1 }
        if source.isVideo {
            return EmoteLimits.estimatedFrames(seconds: settings.end - settings.start, fps: settings.fps, bounce: settings.bounce)
        }
        return draft?.frames
    }

    private var framesCheck: EmoteCheck {
        let limit = "<= \(EmoteLimits.maxFrames)"
        guard let n = frameCount else { return EmoteCheck(kind: .frames, tone: .unknown, value: nil, limit: limit) }
        return EmoteCheck(kind: .frames, tone: n <= EmoteLimits.maxFrames ? .ok : .bad, value: "\(n)", limit: limit)
    }

    private var bytesCheck: EmoteCheck {
        let limit = "<= 7 MB"
        guard let draft else { return EmoteCheck(kind: .bytes, tone: .unknown, value: nil, limit: limit) }
        let tone: EmoteCheck.Tone = draft.bytes > EmoteLimits.capBytes ? .bad : (draft.overCap || !isCurrent ? .warn : .ok)
        return EmoteCheck(kind: .bytes, tone: tone, value: Self.megabytes(draft.bytes), limit: limit)
    }

    /// "1.8 MB", "412 kB".
    public static func megabytes(_ bytes: Int64) -> String {
        if bytes >= 1_000_000 { return String(format: "%.1f MB", Double(bytes) / 1_000_000) }
        return "\(max(1, Int((Double(bytes) / 1000).rounded()))) kB"
    }

    /// 0...1: the draft's weight against the cap (the meter's fill).
    public var meterFraction: Double {
        guard let draft else { return 0 }
        return min(1, Double(draft.bytes) / Double(EmoteLimits.capBytes))
    }

    /// The body `make` sends for the settings now.
    public func request(replace: String? = nil) -> EmoteMakeRequest {
        let s = settings
        let png = s.format == .png
        var r = EmoteMakeRequest(fileID: source.fileID, crop: s.crop, stretch: s.stretch.isNone ? nil : s.stretch, size: s.size, format: s.format)
        if !png, !s.autoQuality { r.quality = s.quality }
        if hasFrames, !png { r.fps = s.fps; r.bounce = s.bounce }
        if source.isVideo {
            r.start = s.start
            r.end = s.end
            if png { r.frame = s.frame ?? s.start }
        }
        r.replace = replace
        return r
    }

    // MARK: changing it

    /// Any change: applied at once (the preview moves on the device), the remake follows `delay` after the last one.
    public func edit(_ change: (inout EmoteSettings) -> Void) {
        var next = settings
        change(&next)
        apply(next)
    }

    private func apply(_ next: EmoteSettings) {
        guard next != settings else { return }
        settings = next
        schedule(after: delay)
    }

    public func setCrop(_ rect: ImageCropRect?) {
        let box = rect.map(\.clamped).flatMap { $0.isWhole ? nil : $0 }
        edit { $0.crop = box }
    }

    /// The wide way. When linked the tall way follows by the same factor (kept inside the range).
    public func setStretchW(_ value: Double) {
        let w = Self.clampStretch(value)
        edit { s in
            let factor = s.stretch.w > 0 ? w / s.stretch.w : 1
            s.stretch.w = w
            if linked { s.stretch.h = Self.clampStretch(s.stretch.h * factor) }
        }
    }

    public func setStretchH(_ value: Double) {
        let h = Self.clampStretch(value)
        edit { s in
            let factor = s.stretch.h > 0 ? h / s.stretch.h : 1
            s.stretch.h = h
            if linked { s.stretch.w = Self.clampStretch(s.stretch.w * factor) }
        }
    }

    static func clampStretch(_ v: Double) -> Double { EmoteStretch(w: v, h: v).clamped.w }

    public enum Preset: String, Sendable, CaseIterable, Identifiable {
        case squish, tall, wide, reset
        public var id: String { rawValue }
    }

    /// squish (72 % tall), tall (72 % wide), wide 3:1 (the stretched crop made 3:1 by widening), reset.
    public func apply(_ preset: Preset) {
        switch preset {
        case .squish: edit { $0.stretch = EmoteStretch(w: 1, h: 0.72) }
        case .tall: edit { $0.stretch = EmoteStretch(w: 0.72, h: 1) }
        case .reset: edit { $0.stretch = .identity }
        case .wide:
            let box = settings.crop?.clamped ?? .whole
            if let w = sourceWidth, let h = sourceHeight {
                let cropRatio = (Double(w) * box.w) / (Double(h) * box.h)
                edit { $0.stretch = EmoteStretch(w: Self.clampStretch(EmoteLimits.maxAspect / cropRatio), h: 1) }
            } else {
                edit { $0.stretch = EmoteStretch(w: 2, h: 1) }
            }
        }
    }

    /// The picture's own size, read from the decoded picture when the library did not say.
    public func useSourceSize(width: Int, height: Int, duration: Double? = nil) {
        if sourceWidth == nil || sourceHeight == nil, width > 0, height > 0 {
            sourceWidth = width
            sourceHeight = height
        }
        if source.isVideo, let duration, duration > 0 {
            videoDuration = duration
            if settings.end > duration {
                edit { $0.end = duration; $0.start = min($0.start, max(0, duration - EmoteLimits.momentRange.lowerBound)) }
            }
        }
    }

    /// The moment, kept 0.2 to 10 s long and inside the clip.
    public func setMoment(start: Double, end: Double) {
        let length = videoDuration ?? .infinity
        var s = max(0, start)
        var e = max(s + EmoteLimits.momentRange.lowerBound, end)
        if e - s > EmoteLimits.momentRange.upperBound { e = s + EmoteLimits.momentRange.upperBound }
        if e > length { e = length; s = max(0, min(s, e - EmoteLimits.momentRange.lowerBound)) }
        edit { $0.start = s; $0.end = e }
    }

    /// Moves the moment keeping its length (the amber window dragged).
    public func slideMoment(to start: Double) {
        let length = settings.end - settings.start
        let limit = max(0, (videoDuration ?? .infinity) - length)
        let s = min(max(0, start), limit)
        edit { $0.start = s; $0.end = s + length }
    }

    // MARK: undo

    public func undo() {
        guard let previous = undoStack.popLast() else { return }
        redoStack.append(settings)
        settings = previous
        settled = previous
        refreshStacks()
        schedule(after: 0)
    }

    public func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(settings)
        settings = next
        settled = next
        refreshStacks()
        schedule(after: 0)
    }

    private func refreshStacks() {
        canUndo = !undoStack.isEmpty
        canRedo = !redoStack.isEmpty
    }

    // MARK: the remake loop

    /// Starts the first draft (the editor just opened): no wait.
    public func start() {
        guard draft == nil, task == nil else { return }
        schedule(after: 0)
    }

    /// A remake now, whatever changed ("remake" button, a retry after a refusal).
    public func remakeNow() { schedule(after: 0) }

    private func schedule(after wait: Double) {
        task?.cancel()
        generation += 1
        let mine = generation
        task = Task { [weak self] in
            if wait > 0 {
                do { try await self?.sleeper(wait) } catch { return }
            }
            guard !Task.isCancelled else { return }
            await self?.run(mine)
        }
    }

    private func run(_ mine: Int) async {
        guard mine == generation else { return }
        if blocker != nil {
            // nothing to send: the inline tick says why, and a running remake of older settings is not wanted
            remaking = false
            return
        }
        let sent = settings
        let replace = draft?.draftID
        let body = request(replace: replace)
        remaking = true
        do {
            let answer = try await client.makeEmoteDraft(body)
            guard mine == generation, !Task.isCancelled else {
                // a newer change took over while this one was on its way: the server's copy is not wanted
                Task { [client] in try? await client.deleteEmoteDraft(id: answer.draftID) }
                if mine == generation { remaking = false }
                return
            }
            if settled != sent {
                undoStack.append(settled)
                redoStack.removeAll()
            }
            settled = sent
            refreshStacks()
            draft = answer
            draftSettings = sent
            error = nil
            landed += 1
            await loadData(for: answer, mine: mine)
            if mine == generation { remaking = false }
        } catch {
            guard mine == generation, !Task.isCancelled else { return }
            if error is CancellationError { return }
            self.error = SevenTvError.from(error)
            remaking = false
            failed += 1
        }
    }

    private func loadData(for answer: EmoteDraft, mine: Int) async {
        do {
            let data = try await client.emoteDraftData(id: answer.draftID)
            guard mine == generation, draft?.draftID == answer.draftID else { return }
            draftData = data
            draftRevision += 1
            shareURL = await writeShareFile(data, draft: answer)
        } catch {
            // the draft stands (upload and save work from its id); the picture stays on the last one
            guard mine == generation else { return }
            if SevenTvError.from(error) == .draftNotFound { self.error = .draftNotFound }
        }
    }

    private func writeShareFile(_ data: Data, draft: EmoteDraft) async -> URL? {
        let name = source.suggestedName
        let ext = draft.format.fileExtension
        let old = shareFolder
        let folderName = "cobalt-emote-\(draft.draftID.prefix(8))"
        let url: URL? = await Task.detached(priority: .utility) {
            let fm = FileManager.default
            let folder = fm.temporaryDirectory.appendingPathComponent(folderName, isDirectory: true)
            if let old { try? fm.removeItem(at: old) }
            do {
                try fm.createDirectory(at: folder, withIntermediateDirectories: true)
                let file = folder.appendingPathComponent("\(name).\(ext)")
                try data.write(to: file, options: .atomic)
                return file
            } catch {
                return nil
            }
        }.value
        shareFolder = url?.deletingLastPathComponent()
        return url
    }

    // MARK: actions

    /// "save to library": the current draft as a private library item (71.2). Throws `SevenTvError`.
    @discardableResult
    public func saveToLibrary(title: String? = nil) async throws -> EmoteDraftSaved {
        guard let draft, isCurrent else { throw SevenTvError.draftNotFound }
        do {
            return try await client.saveEmoteDraft(id: draft.draftID, title: title ?? source.suggestedName)
        } catch {
            throw SevenTvError.from(error)
        }
    }

    /// The editor closed: nothing more runs, and the server's draft and the share file are dropped (best effort).
    public func close() {
        task?.cancel()
        task = nil
        generation += 1
        remaking = false
        let id = draft?.draftID
        if let id { Task { [client] in try? await client.deleteEmoteDraft(id: id) } }
        if let folder = shareFolder {
            Task.detached(priority: .utility) {
                try? FileManager.default.removeItem(at: folder)
            }
        }
        shareFolder = nil
    }
}

extension SevenTvStore {
    /// The "upload to 7tv" sheet's model for an editor draft (71.2): the draft goes as it is, named from the post's title.
    public func uploader(draft: EmoteDraft, source: EmoteSource) -> SevenTvUploadModel {
        SevenTvUploadModel(
            fileID: "draft:\(draft.draftID)", bytes: draft.bytes, title: source.title, contentType: draft.contentType,
            fileName: nil, width: draft.width, height: draft.height, draftID: draft.draftID, store: self)
    }
}

extension AppModel {
    /// The server has the emote editor's routes (the 7tv ones, `features.stage`) and the client can send them.
    public var canMakeEmotes: Bool { capabilities.stage && ctx.client is any SevenTvClient }

    /// An editor for `source`; nil when the server or client has no routes for it.
    public func emoteEditor(for source: EmoteSource) -> EmoteEditorModel? {
        guard canMakeEmotes, source.isSupported, let client = ctx.client as? any SevenTvClient else { return nil }
        return EmoteEditorModel(source: source, client: client)
    }
}
