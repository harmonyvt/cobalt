import Foundation
#if os(iOS)
import BackgroundTasks
#endif

// Keeping a run alive after the owner leaves the app (iOS 26 `BGContinuedProcessingTask`).
//
// What Apple requires, as read from the BackgroundTasks headers of the iOS 27 SDK (the
// framework's API is `API_AVAILABLE(ios(26.0))`, unavailable on the Mac):
//  - the request is made "on behalf of the currently foregrounded app": submit it while the app is
//    in front, in response to the owner's action. This controller submits when a run's work starts
//    (the owner pasted a link, pressed "make webp"), and tries once more when the app resigns
//    active with work in flight and no task yet;
//  - the identifier is `<bundle id>.<context>.*` in `BGTaskSchedulerPermittedIdentifiers` (the
//    wildcard lives ONLY there), and the submitted one is `<bundle id>.<context>.<anything>`. Each
//    concrete identifier must be registered (`register(forTaskWithIdentifier:)`, exempt from "before
//    launch ends") right before it is submitted: a submission with no registration raises an
//    Objective-C exception (`_handleSubmissionWithoutRegistration`, SIGABRT) that Swift `try`
//    cannot catch, and a wildcard registration does not satisfy it (Apple DTS, WWDC25 session 227);
//  - the task must report real progress (`task.progress`): one that looks stalled is expired;
//  - `expirationHandler` is set, and `setTaskCompleted` is called when the work ends;
//  - no entitlement is needed unless the request asks for GPU (it does not). `UIBackgroundModes` is
//    not named for these tasks.
// Not checked on a device (the simulator refuses background tasks, and this sandbox has none): that
// the system accepts a submission made at run start, and how its progress UI sits next to the
// app's own Live Activity.

/// Told by every pipeline when its work starts, moves or ends.
@MainActor
protocol ContinuedWorkSink: AnyObject {
    func pipelineChanged(_ pipeline: Pipeline)
}

// MARK: - The scheduler seam

/// One running continued-processing task, as the controller drives it.
@MainActor
protocol ContinuedTaskHandle: AnyObject {
    func setProgress(completed: Int64, total: Int64)
    func update(title: String, subtitle: String)
    func setExpirationHandler(_ handler: @escaping @MainActor () -> Void)
    func complete(success: Bool)
}

@MainActor
protocol ContinuedTaskScheduler: AnyObject {
    /// False where there is no such thing (the Mac, previews, tests that say so).
    var isAvailable: Bool { get }
    /// Remembers the launch handler for runs whose identifier matches `pattern` (`....run.*`; the
    /// pattern itself is only in Info.plist). The handler gets the task and the identifier it was
    /// submitted with. `submit` registers each concrete identifier with the system and throws, without
    /// submitting, if that fails.
    @discardableResult
    func register(pattern: String, launch: @escaping @MainActor (any ContinuedTaskHandle, String) -> Void) -> Bool
    func submit(identifier: String, title: String, subtitle: String) throws
    func cancel(identifier: String)
}

// MARK: - Progress and words

/// What the system shows for the task. The numbers are the pipeline's own: bytes of the save,
/// frames of the render, the original's download.
@MainActor
enum ContinuedProgress {
    static let total: Int64 = 1000

    /// 0...1 for one pipeline's work. Phases without counts (fetching, a render that sends none)
    /// creep towards a ceiling so the task never looks stalled.
    static func fraction(of p: Pipeline, now: Date) -> Double {
        func ratio(_ t: TransferProgress) -> Double {
            guard let total = t.total, total > 0 else { return 0 }
            return min(1, max(0, Double(t.bytes) / Double(total)))
        }
        func creep(from start: Date, ceiling: Double, over seconds: Double) -> Double {
            let t = max(0, now.timeIntervalSince(start))
            return ceiling * (1 - exp(-t / seconds))
        }
        switch p.state {
        case .idle, .picker, .image: return p.keepProgress.map { 0.1 + 0.85 * ratio($0) } ?? 0
        case .fetching(let since, _): return creep(from: since, ceiling: 0.12, over: 20)
        case .uploading(let t): return 0.4 * ratio(t)
        case .saving(let bytes, let total, let since):
            if let bytes, let total, total > 0 { return 0.12 + 0.5 * min(1, Double(bytes) / Double(total)) }
            return 0.12 + creep(from: since, ceiling: 0.35, over: 30)
        case .reading(let developed, let of):
            let share = of > 0 ? Double(developed) / Double(of) : 0
            if let k = p.keepProgress { return 0.62 + 0.15 * share + 0.2 * ratio(k) }
            return 0.62 + 0.33 * share
        case .ready, .done, .savedLocally:
            // finished, except for a download that is still arriving
            if let k = p.keepProgress { return 0.1 + 0.85 * ratio(k) }
            return 1
        case .rendering(let progress):
            switch progress {
            case .decoding(let done, let total): return 0.06 + 0.74 * (total > 0 ? min(1, Double(done) / Double(total)) : 0)
            case .packing(let since): return 0.8 + creep(from: since, ceiling: 0.17, over: 8)
            case .working(let since): return creep(from: since, ceiling: 0.5, over: 40)
            }
        case .failed: return 1
        }
    }

    static func title(of p: Pipeline) -> String {
        if case .rendering = p.state { return "making your webp" }
        if p.photos == .working { return "adding to photos" }
        if case .ready = p.state, p.keepRequest != nil { return "keeping a copy on this device" }
        return "saving your video"
    }

    static func subtitle(of p: Pipeline) -> String { p.notifyLabel }
}

// MARK: - The controller

@MainActor
final class ContinuedProcessing: ContinuedWorkSink {
    /// `<bundle id>.run.*` in `BGTaskSchedulerPermittedIdentifiers` (Info.plist, project.yml).
    static let identifierPrefix = "com.capybaraharmony.cobalt.run."
    static let identifierPattern = identifierPrefix + "*"

    private enum Phase {
        case idle
        case requested(identifier: String)
        case running(handle: any ContinuedTaskHandle, identifier: String)
    }

    private let ctx: PipelineContext
    private let scheduler: any ContinuedTaskScheduler
    private let home: @MainActor () -> Pipeline
    private let makeIdentifier: @MainActor () -> String

    private var phase: Phase = .idle
    /// The pipelines whose work made this spell (busy now, or until the spell ends), for the outcome.
    private var spell: [Pipeline] = []
    /// A task was already asked for in this spell (a refused or expired one is not asked for again
    /// from the background, where the system would refuse it).
    private var requestedInSpell = false
    /// What this spell actually did, so the end says the right thing (a publish of a finished webp is
    /// not "your webp is ready").
    private var sawSave = false
    private var sawRender = false
    private var lastFraction: Double = 0
    private var registered = false
    var isRegistered: Bool { registered }

    /// The last submission that failed, for the owner's log and tests.
    private(set) var lastSubmitError: (any Error)?
    /// Submissions made, expirations seen, in order: tests read these.
    private(set) var submissions: [String] = []
    private(set) var expirations = 0

    init(
        context: PipelineContext, scheduler: any ContinuedTaskScheduler, home: @escaping @MainActor () -> Pipeline,
        makeIdentifier: @escaping @MainActor () -> String = { ContinuedProcessing.identifierPrefix + UUID().uuidString.prefix(8).lowercased() }
    ) {
        self.ctx = context
        self.scheduler = scheduler
        self.home = home
        self.makeIdentifier = makeIdentifier
    }

    var isRunning: Bool { if case .running = phase { return true } else { return false } }
    var hasRequest: Bool { if case .idle = phase { return false } else { return true } }

    /// Once, at launch.
    func register() {
        guard !registered, scheduler.isAvailable else { return }
        registered = scheduler.register(pattern: Self.identifierPattern) { [weak self] handle, identifier in
            self?.launched(handle, identifier: identifier)
        }
    }

    // MARK: Which runs are in flight

    /// Runs with work the owner would lose to a suspended process: a save, a render, an upload,
    /// frames being read, the original arriving, a publish, "save to photos".
    private func busyPipelines() -> [Pipeline] {
        ([home()] + ctx.background.runs).filter(Self.isBusy)
    }

    static func isBusy(_ p: Pipeline) -> Bool {
        switch p.state {
        case .fetching, .uploading, .saving, .reading, .rendering: return true
        default: break
        }
        return p.keepRequest != nil || p.hosting == .working || p.photos == .working
    }

    // MARK: Events

    func pipelineChanged(_ pipeline: Pipeline) {
        reconcile()
    }

    /// The scene is about to leave the screen: tell the server to speak for runs in flight (the
    /// task may be refused or may expire), and ask for a task if none was.
    func appResigned() {
        let busy = busyPipelines()
        guard !busy.isEmpty else { return }
        registerServerNotify(for: busy)
        if case .idle = phase, !requestedInSpell { request(for: busy) }
    }

    /// The owner is back: the server need not speak for what they are watching.
    func appBecameActive() {
        ctx.notify.cancelAll(source: .background, client: ctx.client)
    }

    private func reconcile() {
        let busy = busyPipelines()
        if busy.isEmpty {
            endSpell()
            return
        }
        for p in busy where !spell.contains(where: { $0 === p }) { spell.append(p) }
        for p in busy {
            switch p.state {
            case .fetching, .uploading, .saving, .reading: sawSave = true
            case .rendering: sawRender = true
            default: break
            }
        }
        if case .idle = phase, !requestedInSpell, ctx.background.activity.isActive { request(for: busy) }
        pushProgress(busy)
    }

    // MARK: The task

    private func request(for busy: [Pipeline]) {
        guard scheduler.isAvailable, let lead = busy.first else { return }
        requestedInSpell = true
        let identifier = makeIdentifier()
        do {
            try scheduler.submit(
                identifier: identifier, title: ContinuedProgress.title(of: lead), subtitle: ContinuedProgress.subtitle(of: lead))
            submissions.append(identifier)
            phase = .requested(identifier: identifier)
            lastSubmitError = nil
        } catch {
            lastSubmitError = error                // the Simulator, an unsigned build, background refresh off: the opt-in covers it
        }
    }

    private func launched(_ handle: any ContinuedTaskHandle, identifier: String) {
        // A second task while one runs (it should not happen): the new one ends at once.
        if case .running = phase { handle.complete(success: true); return }
        phase = .running(handle: handle, identifier: identifier)
        handle.setExpirationHandler { [weak self] in self?.expired() }
        lastFraction = 0
        let busy = busyPipelines()
        guard !busy.isEmpty else { endSpell(); return }       // the work ended before the system got to us
        if let lead = busy.first { handle.update(title: ContinuedProgress.title(of: lead), subtitle: ContinuedProgress.subtitle(of: lead)) }
        pushProgress(busy)
    }

    private func pushProgress(_ busy: [Pipeline]) {
        guard case .running(let handle, _) = phase, !busy.isEmpty else { return }
        let now = ctx.clock.now()
        let mean = busy.map { ContinuedProgress.fraction(of: $0, now: now) }.reduce(0, +) / Double(busy.count)
        // never backwards, and only when it moved: the system watches for a stalled task
        let next = max(lastFraction, min(0.99, mean))
        guard next - lastFraction >= 0.002 || lastFraction == 0 else { return }
        lastFraction = next
        handle.setProgress(completed: Int64((next * Double(ContinuedProgress.total)).rounded()), total: ContinuedProgress.total)
        if let lead = busy.first { handle.update(title: ContinuedProgress.title(of: lead), subtitle: ContinuedProgress.subtitle(of: lead)) }
    }

    /// The system is taking the time back. The server speaks for the run from here on (the opt-in
    /// was registered when the app left; again now in case that was skipped).
    private func expired() {
        guard case .running(let handle, _) = phase else { return }
        expirations += 1
        handle.complete(success: false)
        phase = .idle
        let busy = busyPipelines()
        if !busy.isEmpty, !ctx.background.activity.isActive { registerServerNotify(for: busy) }
    }

    // MARK: The end

    /// Nothing is in flight any more: the task ends, and a finished run that the owner is not
    /// looking at is announced here (a webp that was ready is `Notifications.Kind.webpReady`).
    private func endSpell() {
        defer {
            spell = []
            requestedInSpell = false
            sawSave = false
            sawRender = false
            lastFraction = 0
        }
        guard !spell.isEmpty else { return }
        let outcome = Self.outcome(of: spell, sawSave: sawSave, sawRender: sawRender)
        switch phase {
        case .running(let handle, _):
            handle.complete(success: outcome.kind != .failed)
        case .requested(let identifier):
            scheduler.cancel(identifier: identifier)       // the work ended before the system started the task
        case .idle:
            break
        }
        phase = .idle
        let wasInBackground = !ctx.background.activity.isActive
        // The server's opt-in is moot once the app has said it itself (or the owner is watching).
        let sessions = spell.compactMap(\.sessionID)
        for sid in sessions { ctx.queueCancelNotify(session: sid) }
        guard wasInBackground, let kind = outcome.notification, let notifier = ctx.notifier else { return }
        let id = outcome.jobID
        Task { await notifier.post(kind, jobID: id) }
    }

    struct Outcome: Equatable {
        enum Kind: Equatable { case webp, saved, failed, none }
        var kind: Kind
        var jobID: UUID
        var notification: Notifications.Kind? {
            switch kind {
            case .webp: return .webpReady
            case .saved: return .saved
            case .failed: return .failed
            case .none: return nil
            }
        }
    }

    /// What the owner should hear about a spell that ended: a webp beats a save beats nothing; a
    /// failure is said when nothing else came out of it.
    static func outcome(of pipelines: [Pipeline], sawSave: Bool, sawRender: Bool) -> Outcome {
        if sawRender, let p = pipelines.first(where: { if case .done = $0.state { return true } else { return false } }) {
            return Outcome(kind: .webp, jobID: p.liveRunID)
        }
        if sawSave, let p = pipelines.first(where: {
            switch $0.state {
            case .ready, .savedLocally: return true
            default: return false
            }
        }) {
            return Outcome(kind: .saved, jobID: p.liveRunID)
        }
        if let p = pipelines.first(where: { if case .failed = $0.state { return true } else { return false } }) {
            return Outcome(kind: .failed, jobID: p.liveRunID)
        }
        return Outcome(kind: .none, jobID: pipelines.first?.liveRunID ?? UUID())
    }

    // MARK: The server's voice (no APNs)

    private func registerServerNotify(for busy: [Pipeline]) {
        guard ctx.capabilities.notifyBridge else { return }
        for p in busy {
            guard let sid = p.sessionID, let optIn = p.notifyOptIn, !ctx.notify.isRegistered(sid) else { continue }
            ctx.queueNotify(session: sid, optIn, source: .background)
        }
    }
}

// MARK: - Registering each concrete identifier

/// What the OS scheduler offers, one concrete identifier at a time.
@MainActor
protocol BackgroundTaskBacking: AnyObject {
    /// False when the system refused the registration (an identifier not in Info.plist, one already
    /// registered, or registration closed).
    func register(identifier: String, launch: @escaping @MainActor (any ContinuedTaskHandle, String) -> Void) -> Bool
    func submit(identifier: String, title: String, subtitle: String) throws
    func cancel(identifier: String)
}

enum ContinuedSchedulingError: Error, Equatable {
    case notRegistered(identifier: String)
    case noLaunchHandler
}

/// The wildcard (`....run.*`) is an Info.plist permission, not something to register: BGTaskScheduler
/// matches a submission to a registration by the concrete identifier, and raises an exception that
/// Swift cannot catch when there is none. So the launch closure is kept, each unique identifier is
/// registered right before it is submitted, and a refused registration throws instead of submitting.
@MainActor
final class ConcreteRegistrationScheduler: ContinuedTaskScheduler {
    private let backing: any BackgroundTaskBacking
    private var launch: (@MainActor (any ContinuedTaskHandle, String) -> Void)?
    private(set) var registeredIdentifiers: [String] = []
    var isAvailable: Bool { true }

    init(backing: any BackgroundTaskBacking) { self.backing = backing }

    func register(pattern: String, launch: @escaping @MainActor (any ContinuedTaskHandle, String) -> Void) -> Bool {
        self.launch = launch
        return true
    }

    func submit(identifier: String, title: String, subtitle: String) throws {
        guard let launch else { throw ContinuedSchedulingError.noLaunchHandler }
        guard backing.register(identifier: identifier, launch: launch) else {
            throw ContinuedSchedulingError.notRegistered(identifier: identifier)
        }
        registeredIdentifiers.append(identifier)
        try backing.submit(identifier: identifier, title: title, subtitle: subtitle)
    }

    func cancel(identifier: String) { backing.cancel(identifier: identifier) }
}

// MARK: - Lifecycle and the system scheduler (iOS)

#if os(iOS)
extension ContinuedProcessing {
    /// The app's resign/become-active notifications, by name (CobaltKit builds into extensions,
    /// where UIKit's application does not exist).
    func observeLifecycle() -> [any NSObjectProtocol] {
        let center = NotificationCenter.default
        return [
            center.addObserver(forName: Notification.Name("UIApplicationWillResignActiveNotification"), object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.appResigned() }
            },
            center.addObserver(forName: Notification.Name("UIApplicationDidBecomeActiveNotification"), object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.appBecameActive() }
            },
        ]
    }
}

/// `BGTask` is not `Sendable`; the launch handler hands it to the main actor exactly once.
private final class TaskBox: @unchecked Sendable {
    let task: BGContinuedProcessingTask
    init(_ task: BGContinuedProcessingTask) { self.task = task }
}

@MainActor
private final class SystemContinuedHandle: ContinuedTaskHandle {
    let task: BGContinuedProcessingTask
    init(_ task: BGContinuedProcessingTask) { self.task = task }

    func setProgress(completed: Int64, total: Int64) {
        task.progress.totalUnitCount = total
        task.progress.completedUnitCount = completed
    }

    func update(title: String, subtitle: String) { task.updateTitle(title, subtitle: subtitle) }

    func setExpirationHandler(_ handler: @escaping @MainActor () -> Void) {
        task.expirationHandler = { Task { @MainActor in handler() } }
    }

    func complete(success: Bool) { task.setTaskCompleted(success: success) }
}

/// `BGTaskScheduler` behind `ConcreteRegistrationScheduler`.
@MainActor
private final class SystemBackgroundTasks: BackgroundTaskBacking {
    func register(identifier: String, launch: @escaping @MainActor (any ContinuedTaskHandle, String) -> Void) -> Bool {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: nil) { task in
            guard let continued = task as? BGContinuedProcessingTask else {
                task.setTaskCompleted(success: false)
                return
            }
            let box = TaskBox(continued)
            Task { @MainActor in launch(SystemContinuedHandle(box.task), box.task.identifier) }
        }
    }

    func submit(identifier: String, title: String, subtitle: String) throws {
        let request = BGContinuedProcessingTaskRequest(identifier: identifier, title: title, subtitle: subtitle)
        request.strategy = .queue
        try BGTaskScheduler.shared.submit(request)
    }

    func cancel(identifier: String) {
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: identifier)
    }
}

extension ConcreteRegistrationScheduler {
    /// The real thing: iOS 26 `BGTaskScheduler`.
    static func system() -> ConcreteRegistrationScheduler { ConcreteRegistrationScheduler(backing: SystemBackgroundTasks()) }
}

@MainActor
final class SystemContinuedScheduler: ContinuedTaskScheduler {
    private let inner = ConcreteRegistrationScheduler.system()
    var isAvailable: Bool { true }

    func register(pattern: String, launch: @escaping @MainActor (any ContinuedTaskHandle, String) -> Void) -> Bool {
        inner.register(pattern: pattern, launch: launch)
    }
    func submit(identifier: String, title: String, subtitle: String) throws {
        try inner.submit(identifier: identifier, title: title, subtitle: subtitle)
    }
    func cancel(identifier: String) { inner.cancel(identifier: identifier) }
}
#endif
