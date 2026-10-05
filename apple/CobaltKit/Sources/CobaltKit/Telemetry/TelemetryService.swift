import Foundation
import Observation
import Synchronization

/// The app's side of telemetry: the app lifecycle in the log, the unclean-exit marker, and the uploads
/// (at launch and server refresh, on becoming active, on going to the background). Owned by `AppModel`;
/// nil there in previews and tests.
@MainActor @Observable
public final class TelemetryService {
    @ObservationIgnored let runtime: TelemetryRuntime
    @ObservationIgnored let uploader: TelemetryUploader
    @ObservationIgnored private let settings: Settings
    @ObservationIgnored private let capabilities: @MainActor () -> Capabilities
    @ObservationIgnored private let makeTransport: @MainActor (URL, String) -> any TelemetryTransport
    @ObservationIgnored private var observers: [any NSObjectProtocol] = []

    init(
        runtime: TelemetryRuntime, settings: Settings,
        capabilities: @escaping @MainActor () -> Capabilities,
        makeTransport: @escaping @MainActor (URL, String) -> any TelemetryTransport = { HTTPTelemetryTransport(baseURL: $0, apiKey: $1) },
        app: TelemetryAppInfo = .current(process: .app),
        install: @escaping @Sendable () -> String = { TelemetryInstall.id() }
    ) {
        self.runtime = runtime
        self.settings = settings
        self.capabilities = capabilities
        self.makeTransport = makeTransport
        // the uploader asks the service (on the main actor) whether it may send, at the moment it does
        let box = GateBox()
        self.uploader = TelemetryUploader(
            log: runtime.log, crashes: runtime.crashes, stateURL: runtime.uploadStateURL,
            app: { app }, install: install, gate: { await box.ask() })
        box.set { [weak self] in await self?.currentGate() ?? .disabled }
    }

    /// Lets the uploader be built before `self` is whole.
    private final class GateBox: Sendable {
        private let ask_ = Mutex<(@Sendable () async -> TelemetryGate)?>(nil)
        func set(_ f: @escaping @Sendable () async -> TelemetryGate) { ask_.withLock { $0 = f } }
        func ask() async -> TelemetryGate {
            let f = ask_.withLock { $0 }
            return await f?() ?? .disabled
        }
    }

    /// The real app's service, once `Telemetry.start(process: .app)` has run.
    static func live(settings: Settings, capabilities: @escaping @MainActor () -> Capabilities) -> TelemetryService? {
        guard let runtime = Telemetry.runtime else { return nil }
        let service = TelemetryService(runtime: runtime, settings: settings, capabilities: capabilities)
        Telemetry.crashIngested = { @Sendable [weak service] in Task { @MainActor in service?.uploadSoon() } }
        service.observeLifecycle()
        return service
    }

    // MARK: - Uploading

    /// Whether, and where, an upload may go right now.
    func currentGate() -> TelemetryGate {
        guard settings.sendTelemetry else { return .disabled }
        guard capabilities().telemetry else { return .unsupported }
        guard let key = settings.apiKey() else { return .noKey }
        return .allowed(transport: makeTransport(settings.serverURL, key), secrets: [key])
    }

    /// Best effort and quiet: a pass over what is pending, if the owner allows it and the server takes it.
    public func uploadSoon() {
        Task { _ = await uploader.upload() }
    }

    /// Settings' "send logs now": ignores the backoff, never the toggle or the server's capability.
    public func sendNow() async -> TelemetrySendResult {
        Telemetry.log(.info, .app, "send logs now")
        return await uploader.upload(force: true)
    }

    /// Events and crash records waiting to go.
    public func pendingCounts() async -> (events: Int, crashes: Int) { await uploader.pendingCounts() }

    // MARK: - Lifecycle

    /// The app's own notifications, by name (CobaltKit builds into extensions, where there is no
    /// application object): active → mark running and upload; background → mark clean, flush, upload
    /// under a grace period; terminate → mark clean; memory warning → note how much is left.
    func observeLifecycle() {
        let center = NotificationCenter.default
        func watch(_ name: String, _ body: @escaping @MainActor (TelemetryService) -> Void) {
            observers.append(center.addObserver(forName: Notification.Name(name), object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { if let self { body(self) } }
            })
        }
        #if os(iOS)
        watch("UIApplicationDidBecomeActiveNotification") { $0.becameActive() }
        watch("UIApplicationDidEnterBackgroundNotification") { $0.enteredBackground() }
        watch("UIApplicationWillTerminateNotification") { $0.terminating() }
        watch("UIApplicationDidReceiveMemoryWarningNotification") { $0.memoryWarning() }
        #else
        watch("NSApplicationDidBecomeActiveNotification") { $0.becameActive() }
        watch("NSApplicationDidResignActiveNotification") { $0.enteredBackground() }
        watch("NSApplicationWillTerminateNotification") { $0.terminating() }
        #endif
    }

    func becameActive() {
        runtime.markRunning()
        Telemetry.log(.info, .app, "app active", data: Telemetry.memoryData())
        uploadSoon()
    }

    func enteredBackground() {
        Telemetry.log(.info, .app, "app background", data: Telemetry.memoryData())
        #if os(iOS)
        // iOS: this is where "running" ends. The Mac keeps running behind other apps, so only a
        // terminate clears it there.
        runtime.markClean()
        #endif
        Telemetry.flush()
        uploadWithGrace()
    }

    func terminating() {
        Telemetry.log(.info, .app, "app terminate")
        Telemetry.flush()
        runtime.markClean()
    }

    func memoryWarning() {
        Telemetry.log(.warn, .app, "memory warning", data: Telemetry.memoryData())
    }

    /// Keeps the process alive until `done` is signalled or the system's deadline. Nonisolated on purpose:
    /// the system runs the block on a thread of its own, and a block written inside a main-actor type
    /// would be inferred main-actor and trap there.
    nonisolated private static func holdProcess(until done: DispatchSemaphore) {
        #if os(iOS)
        ProcessInfo.processInfo.performExpiringActivity(withReason: "cobalt telemetry") { @Sendable expired in
            // the first call holds the process up until the upload ends or the system's deadline (the second call)
            if expired { done.signal() } else { done.wait() }
        }
        #endif
    }

    /// One upload pass that the system lets finish after the app has left the screen.
    private func uploadWithGrace() {
        #if os(iOS)
        let done = DispatchSemaphore(value: 0)
        Self.holdProcess(until: done)
        Task {
            _ = await uploader.upload()
            done.signal()
        }
        #else
        uploadSoon()
        #endif
    }

}
