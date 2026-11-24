import Foundation
import Observation

/// What the System Health Inspector shows (apple 03-PHASE3 3.4.2, the "system" segment of the activity sheet): whether the API
/// edge answers and how fast, which containers were last seen warm or waking, and the edits the library sync is holding. The
/// library sync's own status, the offline storage and the OBS stage are read straight from `LibraryModel.syncStatus`,
/// `OfflineStore.usage` and `StageStore.stage` by the sheet; those already observe themselves.
///
/// **Nothing here polls.** The edge is timed when the sheet opens and on "retry now" (`checkEdge`); the containers are sampled
/// from the activity list while the pill or the sheet is on screen (`sample`), never asked; the pending edits are read from the
/// outbox when the sheet opens and again when the sync's status moves (`refreshPendingEdits`). A reading says when it was taken:
/// "last observed", not "live".
@MainActor @Observable
public final class SystemHealth {
    // MARK: API edge

    /// One timing of the edge: the server's `capabilities()` call, the one the app makes at launch.
    public struct EdgeReading: Sendable, Equatable {
        /// What the server answered: `.unreachable` is the network (or the server) not answering; `.notCobalt` something that
        /// is not a cobalt server.
        public let kind: ServerKind
        /// Round trip in milliseconds (at least 1), measured around the call. Meaningful when the server answered.
        public let rttMilliseconds: Int
        public let at: Date

        public init(kind: ServerKind, rttMilliseconds: Int, at: Date) {
            self.kind = kind
            self.rttMilliseconds = max(1, rttMilliseconds)
            self.at = at
        }

        /// The server answered with something (even a server that is not cobalt).
        public var reachable: Bool { kind != .unreachable }
    }

    /// The last timing, nil before the first (the sheet times one when it opens).
    public private(set) var edge: EdgeReading?
    /// A timing is in flight.
    public private(set) var isCheckingEdge = false

    // MARK: Containers

    public enum ContainerName: String, Sendable, CaseIterable, Equatable {
        /// The cobalt downloader container.
        case cobalt
        /// The yt-dlp box.
        case ytdlp
        /// The editor's renderer.
        case editRenderer
    }

    public enum ContainerState: Sendable, Equatable {
        /// Nothing seen yet (or what was seen has ended without a sign either way).
        case unknown
        case warm
        case waking
    }

    /// What was last seen of one container. `observedAt` is nil while nothing has ever been seen.
    public struct ContainerReading: Sendable, Equatable, Identifiable {
        public let name: ContainerName
        public let state: ContainerState
        public let observedAt: Date?
        public var id: ContainerName { name }

        public init(name: ContainerName, state: ContainerState = .unknown, observedAt: Date? = nil) {
            self.name = name
            self.state = state
            self.observedAt = observedAt
        }
    }

    /// One reading per container, in `ContainerName.allCases` order.
    public private(set) var containers: [ContainerReading] = ContainerName.allCases.map { ContainerReading(name: $0) }

    /// A container is starting up right now, as far as the activity list says. Row 5 of the pill.
    public var isWaking: Bool { containers.contains { $0.state == .waking } }

    // MARK: Library sync

    /// The edits waiting in the sync outbox, oldest first. Empty while the sync engine is off.
    public private(set) var pendingEdits: [PendingSyncEdit] = []

    // MARK: -

    @ObservationIgnored let ctx: PipelineContext
    /// Tests and previews: what times the edge, in place of the context's client.
    @ObservationIgnored var probe: (@MainActor () async -> Capabilities)?
    @ObservationIgnored private var edgeTask: Task<Void, Never>?

    init(context: PipelineContext) {
        self.ctx = context
    }

    // MARK: Edge

    /// Times a `capabilities()` call: the server's own front door. One at a time; a call while one is in flight waits for it.
    public func checkEdge() async {
        if let edgeTask {
            await edgeTask.value
            return
        }
        isCheckingEdge = true
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            let clock = ContinuousClock()
            let start = clock.now
            let caps: Capabilities
            if let probe = self.probe { caps = await probe() } else { caps = await self.ctx.client.capabilities() }
            let elapsed = clock.now - start
            let ms = Int((Double(elapsed.components.seconds) * 1000 + Double(elapsed.components.attoseconds) / 1e15).rounded())
            self.edge = EdgeReading(kind: caps.kind, rttMilliseconds: ms, at: self.ctx.clock.now())
            self.isCheckingEdge = false
            self.edgeTask = nil
        }
        edgeTask = task
        await task.value
    }

    // MARK: Containers

    /// Reads what the activity list says about the containers and keeps it (`observe`). Call it when the list changes while the pill
    /// or the sheet is on screen; a call with nothing new changes nothing.
    public func sample(_ items: [JobStatus], now: Date) {
        let next = Self.observe(items, previous: containers, now: now)
        if next != containers { containers = next }
    }

    /// The pure part of `sample`: a waking stage is `.waking`; a stage that runs on a container is `.warm`; a container that was
    /// waking and that nothing says is waking any more falls back to `.unknown` unless something says warm; one nothing mentions
    /// keeps its last reading and its time.
    nonisolated static func observe(_ items: [JobStatus], previous: [ContainerReading], now: Date) -> [ContainerReading] {
        var waking: Set<ContainerName> = []
        var warm: Set<ContainerName> = []
        for item in items where item.isActive {
            if case .waking(let engine) = item.stage {
                waking.insert(container(for: engine))
                continue
            }
            switch item.kind {
            case .editorRender, .swarm:
                if case .rendering = item.stage { warm.insert(.editRenderer) }
            case .save, .gallery, .upload, .webpRender:
                switch item.stage {
                case .fetching, .downloading, .storing, .galleryProgress, .rendering:
                    warm.insert(container(for: item.engine))
                default: break
                }
            case .deviceDownload, .photosExport:
                break
            }
        }
        return ContainerName.allCases.map { name in
            let old = previous.first { $0.name == name } ?? ContainerReading(name: name)
            if waking.contains(name) {
                return old.state == .waking ? old : ContainerReading(name: name, state: .waking, observedAt: now)
            }
            if warm.contains(name) {
                return old.state == .warm ? old : ContainerReading(name: name, state: .warm, observedAt: now)
            }
            if old.state == .waking { return ContainerReading(name: name, state: .unknown, observedAt: old.observedAt) }
            return old
        }
    }

    /// The server names the downloader that is starting; without a name it is the cobalt container (the only one that reported
    /// waking before the engines were named).
    nonisolated private static func container(for engine: SaveEngine?) -> ContainerName {
        engine == .ytdlp ? .ytdlp : .cobalt
    }

    // MARK: Library sync

    /// Reads the outbox through the library's sync engine. Empty (and cheap) while the engine is off.
    public func refreshPendingEdits(from library: LibraryModel) async {
        let edits = await library.sync?.pendingEdits() ?? []
        if edits != pendingEdits { pendingEdits = edits }
    }
}
