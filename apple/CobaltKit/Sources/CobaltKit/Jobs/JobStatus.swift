import Foundation

// One value for "what is this piece of work doing right now" (apple 03-PHASE3 3.2).
//
// Today eight helpers in the app target translate a pipeline, a server row or a download into words and a bar
// (`ProgressStory`, `JobCardFacts`, `GalleryCardParts`, `HeroProgress`, `OfflineMark`, `OfflineWords`, `SharePrepRow`,
// `QueueRowFacts`). `JobStatus` is the single, pure, unit-tested projection they will all read: it says *what stage* a
// job is in and with *which numbers*, never *which words*. Words stay in the app's `Copy` files, so nothing in this file
// is a sentence a person reads.
//
// Where the projections live: `JobStatusProjection.swift` (from a `Pipeline`, an offline download, a server row, an
// editor render). Where the counts live: `ActivitySummary.swift` (`AppModel.activity`).
//
// Adaptations from the spec's sketch (03-PHASE3 3.2), each because the real types differ:
//  - `RenderPhase` is the wire enum `{fetching, decode, pack, queued}` (Models/Wire.swift). A gallery make's `MakePhase`
//    (`uploading, composing, encoding`) is mapped onto it (uploading -> fetching, composing -> decode, encoding -> pack).
//  - `TransferProgress` is `(bytes, total?)`; the stages carry `bytes`/`total` as optionals instead.
//  - `Stage` gains `awaitingChoice` (a multi-item post waits for the owner to pick: no work is running, nothing failed).
//    The spec's matrix says "10 Stage cases"; its own list has 11. This is the 12th, tested.
//  - Fields added to the spec's struct: `ref` (who owns the work, so actions route back), `sessionID` / `mediaID` (the
//    dedupe key and the way to open the media), `engine` / `fallbackFrom` (what ran, independent of the stage, so a
//    finished download still shows its engine and a fallback callout), `woke` (the run needed a container to wake: the
//    stepper keeps the wake step once it has been shown), `failedStep`, `remote`, `isFocused`, `canDismiss`.

public struct JobStatus: Sendable, Equatable, Identifiable {
    public enum Kind: Sendable, Equatable, CaseIterable {
        case save, gallery, upload, webpRender, editorRender, deviceDownload, photosExport, swarm
    }

    public enum Stage: Sendable, Equatable {
        /// Waiting in a line (the server's, or this device's). `ahead`: the jobs before this one, the running one included
        /// (0 = next); nil when the line cannot say how many ("the server is busy with something not in this list").
        case queued(ahead: Int?)
        /// The server says a container is starting up (`SaveStatus.waking`), never the device's own timer after the server
        /// has spoken. `engine` is the downloader that is starting, when the server names it.
        case waking(engine: SaveEngine?)
        /// A link is being read: the server is working but has no byte counts yet. `fallbackFrom`: the engine that failed
        /// before this one took over (a switch from cobalt to yt-dlp).
        case fetching(engine: SaveEngine?, fallbackFrom: SaveEngine?)
        /// The source is being copied with real byte counts: the server reading a post from its site, or, for kind
        /// `.upload`, this device sending a file (the "source" of an upload is this device).
        case downloading(bytes: Int64?, total: Int64?)
        /// The file is being written to the library (R2).
        case storing(bytes: Int64?, total: Int64?)
        /// A multi-item post saving: `done` of `total` items are safe; `currentBytes` of `currentTotal` is the item in flight.
        case galleryProgress(done: Int, total: Int, currentBytes: Int64?, currentTotal: Int64?)
        /// This device reading the filmstrip of a saved video, for the trim.
        case readingFrames(done: Int, total: Int)
        /// A render or a make on the server: `phase` is what it is on, `done` of `total` frames or seconds.
        case rendering(phase: RenderPhase?, done: Int?, total: Int?)
        /// The library has it; the copy on this device is on its way (or this is a download onto the device).
        case deviceCopy(bytes: Int64?, total: Int64?)
        /// Nothing left to wait for. `cloudSaved` false is plain cobalt (no library). `deviceCopy` says where the copy on
        /// this device stands, apart from the cloud: Cloud ✓ with Device ✓ or Device ⚠.
        case completed(cloudSaved: Bool, deviceCopy: LocalCopyReceipt)
        case failed(failure: PipelineFailure, retryable: Bool)
        /// A multi-item post is saved to look at and waits for the owner's pick. Nothing runs, nothing failed.
        case awaitingChoice
    }

    /// Where the copy on this device stands (apple 02-PHASE2 2.2.4), apart from the cloud copy.
    public enum LocalCopyReceipt: Sendable, Equatable {
        /// "keep videos on device" is off, or this kind has no device copy.
        case notNeeded
        case savedOnDevice
        case inProgress
        /// It did not arrive: an `error.app.*` / `http.*` code.
        case failed(code: String?)
    }

    /// Who owns the work: where an action on this status goes (`ActivityModel.perform`).
    public enum Ref: Sendable, Equatable, Hashable {
        /// A job of `JobQueue` (its `Job.ID`, the run id of its pipeline).
        case pipeline(UUID)
        /// An `OfflineDownloads` row, by its queue key.
        case download(key: String)
        /// A row of the server's line (`GET /queue`), by `QueueItem.id` ("server:...").
        case server(id: String)
        /// A render of the video editor, by its id.
        case editRender(id: String)
        /// A job that finished and left the queue (`FinishedWork.id`).
        case finished(UUID)
        /// The photos album adding saves.
        case photosAlbum
    }

    /// Work the server runs for someone else: another device of this key, or the share sheet.
    public struct Remote: Sendable, Equatable {
        /// The name of the key that sent it ("iphone", "mac"); nil for a key the server cannot name.
        public var keyName: String?
        public var fromShare: Bool
        public init(keyName: String? = nil, fromShare: Bool = false) {
            self.keyName = keyName
            self.fromShare = fromShare
        }
    }

    /// Which of the sheet's three groups a status sits in.
    public enum Bucket: Sendable, Equatable { case running, attention, settled }

    /// Stable across refreshes: "job:<uuid>", "download:<key>", "server:...", "edit:<id>", "finished:<uuid>", "photos"
    /// (the same ids `UnifiedQueue` gives its rows).
    public let id: String
    public let ref: Ref
    public let kind: Kind
    /// What the owner (or the link) calls it: the typed title, else `service · ref`, else the file's name. Empty when
    /// nothing names it (a foreign server row with no link): the app words it. Never a sentence.
    public let title: String
    /// The site a link save reads from ("x.com"); nil for files and downloads.
    public let sourceHost: String?
    /// The studio session this work belongs to: the dedupe key across pipelines, downloads and server rows.
    public let sessionID: String?
    /// The server's own id of the render or make this status stands for (`renderJobID`, `makeJobID`; a server row's `job`): the
    /// second dedupe key, for a render a server row names by job and not by session.
    public let serverJobID: String?
    /// The stored media it landed as (or will land as), when this device has it: opens the detail. For an editor render that
    /// finished it is `post:<library item id>` (what `QueueDestination.media` takes).
    public let mediaID: String?
    public let stage: Stage
    /// 0...1 for the current stage; nil = indeterminate.
    public let fraction: Double?
    public let startedAt: Date
    public let updatedAt: Date
    /// The downloader that runs (or ran) a save; nil when the server has not said.
    public let engine: SaveEngine?
    /// The engine that failed before `engine` took over.
    public let fallbackFrom: SaveEngine?
    /// The run needed a container to wake at some point: keeps the stepper's wake step visible after the wake is over.
    public let woke: Bool
    /// For a failure: the step it happened in (nil = the kind's default, see `JobStep`).
    public let failedStep: JobStep.ID?
    /// Nil for this device's own work.
    public let remote: Remote?
    /// The job the focus screen shows.
    public let isFocused: Bool
    public let canFocus: Bool
    public let canCancel: Bool
    public let canRetry: Bool
    /// "dismiss" applies: a failed or finished job, a failed download, a multi-item post nobody picked.
    public let canDismiss: Bool

    public init(
        id: String, ref: Ref, kind: Kind, title: String = "", sourceHost: String? = nil, sessionID: String? = nil,
        serverJobID: String? = nil, mediaID: String? = nil, stage: Stage, fraction: Double? = nil, startedAt: Date, updatedAt: Date,
        engine: SaveEngine? = nil, fallbackFrom: SaveEngine? = nil, woke: Bool = false, failedStep: JobStep.ID? = nil,
        remote: Remote? = nil, isFocused: Bool = false, canFocus: Bool = false, canCancel: Bool = false,
        canRetry: Bool = false, canDismiss: Bool = false
    ) {
        self.id = id
        self.ref = ref
        self.kind = kind
        self.title = title
        self.sourceHost = sourceHost
        self.sessionID = sessionID
        self.serverJobID = serverJobID
        self.mediaID = mediaID
        self.stage = stage
        self.fraction = fraction.map { min(1, max(0, $0)) }
        self.startedAt = startedAt
        self.updatedAt = updatedAt
        self.engine = engine
        self.fallbackFrom = fallbackFrom
        self.woke = woke
        self.failedStep = failedStep
        self.remote = remote
        self.isFocused = isFocused
        self.canFocus = canFocus
        self.canCancel = canCancel
        self.canRetry = canRetry
        self.canDismiss = canDismiss
    }

    // MARK: - What the stage means for counting

    /// Work is going on or waiting for its turn: counts in `ActivitySummary.activeCount`. A finished job whose device copy
    /// is still arriving is active too.
    public var isActive: Bool { stage.isActive }

    /// A failed job, or a finished one whose device copy did not arrive: counts in `ActivitySummary.attentionCount`.
    public var needsAttention: Bool { stage.needsAttention }

    public var bucket: Bucket {
        if needsAttention { return .attention }
        return isActive ? .running : .settled
    }

    /// The keys another source's status may share with this one: its session and its server job. Ids are the third.
    var dedupeKeys: [String] {
        var keys: [String] = []
        if let sessionID { keys.append("sid:\(sessionID)") }
        if let serverJobID { keys.append("srvjob:\(serverJobID)") }
        return keys
    }

    /// The ordered steps of the one stepper every surface draws (`WorkCard`, the activity sheet, the share sheet, the island).
    public var steps: [JobStep] { JobStep.steps(for: self) }

    /// The step the stage is in (what the compact surfaces name).
    public var currentStep: JobStep.ID { JobStep.current(for: self) }
}

extension JobStatus.Stage {
    public var isActive: Bool {
        switch self {
        case .queued, .waking, .fetching, .downloading, .storing, .galleryProgress, .readingFrames, .rendering, .deviceCopy:
            return true
        case .completed(_, let receipt):
            return receipt == .inProgress
        case .failed, .awaitingChoice:
            return false
        }
    }

    public var needsAttention: Bool {
        switch self {
        case .failed: return true
        case .completed(_, .failed): return true
        default: return false
        }
    }

    /// The stage is waiting for a turn, not working.
    public var isWaiting: Bool {
        if case .queued = self { return true }
        return false
    }
}

// MARK: - The canonical stepper

/// One step of the stepper. The five canonical steps, in order: `queued` (accepted, waiting for a turn), `wake` (a container
/// starting up: shown only while it is, or once it has been, so a warm save has four), `source` (the download from the
/// site, with its engine and a fallback callout), `store` (the library write, or the render), `device` (the copy on this
/// device: Cloud ✓ apart from Device ✓ or ⚠).
public struct JobStep: Sendable, Equatable, Identifiable {
    public enum ID: String, Sendable, CaseIterable, Comparable {
        case queued, wake, source, store, device

        var rank: Int { Self.allCases.firstIndex(of: self) ?? 0 }
        public static func < (a: ID, b: ID) -> Bool { a.rank < b.rank }
    }

    public enum State: Sendable, Equatable { case done, active, warning, pending, failed }

    /// The numbers a step can show. Only ever the real ones.
    public enum Detail: Sendable, Equatable {
        case none
        case queue(ahead: Int?)
        case wake(engine: SaveEngine?)
        /// `fallbackFrom` set = "switched from cobalt to yt-dlp".
        case source(engine: SaveEngine?, fallbackFrom: SaveEngine?, bytes: Int64?, total: Int64?)
        case items(done: Int, total: Int, currentBytes: Int64?, currentTotal: Int64?)
        case frames(done: Int, total: Int)
        case bytes(Int64?, of: Int64?)
        case render(phase: RenderPhase?, done: Int?, total: Int?)
        case failure(PipelineFailure)
        case receipt(JobStatus.LocalCopyReceipt)
    }

    public let id: ID
    public let state: State
    public let detail: Detail
    /// 0...1 on the active step; nil elsewhere and when the number is not known.
    public let fraction: Double?

    public init(id: ID, state: State, detail: Detail = .none, fraction: Double? = nil) {
        self.id = id
        self.state = state
        self.detail = detail
        self.fraction = fraction
    }

    /// The steps a kind has, in order (before the wake step is decided).
    static func applicable(_ kind: JobStatus.Kind) -> [ID] {
        switch kind {
        case .save, .upload, .gallery: return [.queued, .wake, .source, .store, .device]
        case .webpRender: return [.queued, .wake, .store, .device]
        case .editorRender, .swarm: return [.queued, .wake, .store]
        case .deviceDownload, .photosExport: return [.queued, .device]
        }
    }

    /// The step a failure lands in when nothing says otherwise.
    static func defaultFailure(_ kind: JobStatus.Kind) -> ID {
        switch kind {
        case .save, .upload, .gallery: return .source
        case .webpRender, .editorRender, .swarm: return .store
        case .deviceDownload, .photosExport: return .device
        }
    }

    /// The step a stage is in.
    static func current(for s: JobStatus) -> ID {
        switch s.stage {
        case .queued, .awaitingChoice: return .queued
        case .waking: return .wake
        case .fetching, .downloading, .galleryProgress: return .source
        case .storing, .rendering: return .store
        case .readingFrames, .deviceCopy, .completed: return .device
        case .failed: return s.failedStep ?? defaultFailure(s.kind)
        }
    }

    static func steps(for s: JobStatus) -> [JobStep] {
        var ids = applicable(s.kind)
        let waking: Bool = { if case .waking = s.stage { return true } else { return false } }()
        if !(s.woke || waking) { ids.removeAll { $0 == .wake } }
        if case .completed(false, _) = s.stage { ids.removeAll { $0 == .store } }   // plain cobalt: no library to write to
        // the step the stage is in, or the nearest one after it that this kind has
        let wanted = current(for: s)
        let current = ids.first { $0 >= wanted } ?? ids.last ?? .queued
        let device = deviceReceipt(s.stage)
        return ids.map { id in
            if case .awaitingChoice = s.stage { return JobStep(id: id, state: id == .queued ? .done : .pending) }
            if case .completed = s.stage, id != .device { return JobStep(id: id, state: .done, detail: detail(id, s, active: false)) }
            if id < current { return JobStep(id: id, state: .done, detail: detail(id, s, active: false)) }
            if id > current { return JobStep(id: id, state: .pending) }
            return JobStep(id: id, state: activeState(s, device: device), detail: detail(id, s, active: true), fraction: activeFraction(s))
        }
    }

    private static func deviceReceipt(_ stage: JobStatus.Stage) -> JobStatus.LocalCopyReceipt? {
        if case .completed(_, let receipt) = stage { return receipt }
        return nil
    }

    private static func activeState(_ s: JobStatus, device: JobStatus.LocalCopyReceipt?) -> State {
        switch s.stage {
        case .failed: return .failed
        case .completed:
            switch device ?? .notNeeded {
            case .notNeeded, .savedOnDevice: return .done
            case .inProgress: return .active
            case .failed: return .warning          // Cloud ✓, Device ⚠
            }
        default: return .active
        }
    }

    private static func activeFraction(_ s: JobStatus) -> Double? {
        s.stage.isActive ? s.fraction : nil
    }

    private static func detail(_ id: ID, _ s: JobStatus, active: Bool) -> Detail {
        if active, case .failed(let f, _) = s.stage { return .failure(f) }
        switch id {
        case .queued:
            if case .queued(let ahead) = s.stage { return .queue(ahead: ahead) }
            return .none
        case .wake:
            if case .waking(let engine) = s.stage { return .wake(engine: engine) }
            return .wake(engine: s.engine)
        case .source:
            switch s.stage {
            case .galleryProgress(let done, let total, let b, let t):
                return .items(done: done, total: total, currentBytes: b, currentTotal: t)
            case .downloading(let b, let t):
                return .source(engine: s.engine, fallbackFrom: s.fallbackFrom, bytes: b, total: t)
            default:
                // done, fetching or waiting: the engine and the switch still show
                guard s.engine != nil || s.fallbackFrom != nil else { return .none }
                return .source(engine: s.engine, fallbackFrom: s.fallbackFrom, bytes: nil, total: nil)
            }
        case .store:
            switch s.stage {
            case .storing(let b, let t): return .bytes(b, of: t)
            case .rendering(let p, let d, let t): return .render(phase: p, done: d, total: t)
            default: return .none
            }
        case .device:
            switch s.stage {
            case .readingFrames(let d, let t): return .frames(done: d, total: t)
            case .deviceCopy(let b, let t): return .bytes(b, of: t)
            case .completed(_, let receipt): return .receipt(receipt)
            default: return .none
            }
        }
    }
}
