import Foundation
import Synchronization
#if canImport(MetricKit)
import MetricKit
#endif

/// The one call every process makes to leave a trace:
///
///     Telemetry.log(.info, .pipeline, "state ready", data: ["bytes": .bytes(n)])
///
/// Cheap (the file is written later, on a utility queue), safe from any thread or actor, mirrored to
/// `os.Logger` (subsystem `com.capybaraharmony.cobalt`). Until a process calls `start(process:)` (previews,
/// tests) it does nothing at all.
public enum Telemetry {
    private static let installed = Mutex<TelemetryRuntime?>(nil)

    static var runtime: TelemetryRuntime? { installed.withLock { $0 } }

    public static func log(_ level: TelemetryLevel, _ cat: TelemetryCategory, _ msg: String, data: [String: TelemetryValue] = [:]) {
        runtime?.log.log(level, cat, msg, data: data)
    }

    /// Blocks until everything logged so far is on disk (a background transition). Never blocks when
    /// called from the log's own queue.
    public static func flush() { runtime?.log.flush() }

    /// Writes the event before returning (the uncaught-exception breadcrumb).
    static func logNow(_ level: TelemetryLevel, _ cat: TelemetryCategory, _ msg: String, data: [String: TelemetryValue] = [:]) {
        runtime?.log.logNow(level, cat, msg, data: data)
    }

    /// Called once, as early as the process can: opens the shared buffer. The app also arms crash capture
    /// (MetricKit, the unclean-exit check, the uncaught-exception breadcrumb); the share extension and the
    /// widgets only buffer, the app uploads. A second call changes nothing.
    public static func start(process: TelemetryProcess) {
        let created: TelemetryRuntime? = installed.withLock { slot in
            if slot != nil { return nil }
            let runtime = TelemetryRuntime(directory: AppGroup.directory("Telemetry"), process: process)
            slot = runtime
            return runtime
        }
        guard let runtime = created else { return }
        runtime.log.log(.info, .app, "\(process.rawValue) started", data: runtime.launchData)
        if process == .app { runtime.armCrashCapture() }
    }

    /// Swaps the runtime (tests only). Returns what was installed before.
    @discardableResult
    static func install(_ runtime: TelemetryRuntime?) -> TelemetryRuntime? {
        installed.withLock { slot in
            defer { slot = runtime }
            return slot
        }
    }

    /// Set by the app: told when a new crash record lands, so it can upload soon. Called on whatever queue
    /// MetricKit used, so it must be `@Sendable` and never assume the main actor.
    nonisolated(unsafe) static var crashIngested: (@Sendable () -> Void)?
}

/// The buffer, the crash records and the files around them, for one process.
final class TelemetryRuntime: Sendable {
    let directory: URL
    let log: TelemetryLog
    let crashes: CrashStore

    init(directory: URL, process: TelemetryProcess, limits: TelemetryLog.Limits = .init(), mirrorToOSLog: Bool = true) {
        self.directory = directory
        self.log = TelemetryLog(directory: directory, process: process, limits: limits, mirrorToOSLog: mirrorToOSLog)
        self.crashes = CrashStore(directory: directory.appendingPathComponent("crashes", isDirectory: true))
    }

    var uploadStateURL: URL { directory.appendingPathComponent("upload-state.json") }

    var launchData: [String: TelemetryValue] {
        let info = TelemetryAppInfo.current(process: log.process)
        return [
            "version": .string(info.version), "build": .string(info.build), "os": .string(info.os),
            "device": .string(info.device), "run": .string(log.runTag),
        ]
    }

    // MARK: - Unclean exit

    /// The app is on screen: from here until it goes to the background (or terminates) a death is a crash.
    func markRunning() {
        let info = TelemetryAppInfo.current(process: .app)
        UncleanExit.write(
            RunMarker(run: log.runTag, startedAt: TelemetryLog.nowMillis(), version: info.version, build: info.build, os: info.os),
            in: directory)
    }

    func markClean() { UncleanExit.clear(in: directory) }

    /// A marker the last session left behind becomes a pending `unclean_exit` record, once.
    @discardableResult
    func collectUncleanExit() -> CrashRecord? {
        guard let marker = UncleanExit.leftover(in: directory) else { return nil }
        let record = UncleanExit.record(for: marker, current: .current(process: .app), log: log)
        crashes.add(record, payload: nil)
        UncleanExit.clear(in: directory)
        log.log(.warn, .app, "previous session ended uncleanly", data: [
            "build": .string(marker.build), "version": .string(marker.version), "events": .int(record.events.count),
        ])
        return record
    }

    // MARK: - Crash capture (the app)

    private static let subscriber = Mutex<AnyObject?>(nil)

    func armCrashCapture() {
        collectUncleanExit()
        installExceptionBreadcrumb()
        #if canImport(MetricKit)
        let subscriber = MetricKitSubscriber(runtime: self)
        Self.subscriber.withLock { $0 = subscriber }
        MXMetricManager.shared.add(subscriber)
        #endif
    }

    /// A diagnostic MetricKit delivered (its JSON, untouched) becomes a pending record.
    func ingest(_ json: Data, kind: CrashKind, at ts: Int64) {
        guard !json.isEmpty else { return }
        if DiagnosticIngest.ingest(json, kind: kind, at: ts, into: crashes, log: log) {
            Telemetry.crashIngested?()
        }
    }

    // MARK: - Uncaught exception

    private static let previousHandler = Mutex<(@convention(c) (NSException) -> Void)?>(nil)

    /// An Objective-C exception is about to take the process down: write what it was, synchronously.
    /// Not a signal handler, so ordinary calls are fine here. Signals are left to MetricKit and the
    /// unclean-exit marker: nothing in a signal handler can safely allocate or take a lock.
    func installExceptionBreadcrumb() {
        Self.previousHandler.withLock { $0 = NSGetUncaughtExceptionHandler() }
        NSSetUncaughtExceptionHandler { exception in
            var data: [String: TelemetryValue] = [
                "name": .string(exception.name.rawValue), "reason": .string(exception.reason ?? ""),
            ]
            for (n, frame) in exception.callStackSymbols.prefix(6).enumerated() { data["frame\(n)"] = .string(frame) }
            Telemetry.logNow(.error, .app, "uncaught exception", data: data)
            TelemetryRuntime.previousHandler.withLock { $0 }?(exception)
        }
    }
}

#if canImport(MetricKit)
/// MetricKit hands over the diagnostics of earlier runs (a day late at worst): crashes, hangs, CPU and
/// disk-write exceptions, slow launches. Each goes into the crash store as its own record with its JSON
/// untouched.
///
/// MetricKit calls `didReceive` on a queue of its own. This class is deliberately not main-actor isolated
/// and touches no main-actor state: it only writes to disk (`TelemetryRuntime` is `Sendable`); the app is
/// told through a `@Sendable` closure that hops to the main actor by itself.
final class MetricKitSubscriber: NSObject, MXMetricManagerSubscriber, @unchecked Sendable {
    private let runtime: TelemetryRuntime

    init(runtime: TelemetryRuntime) {
        self.runtime = runtime
        super.init()
    }

    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        for payload in payloads {
            let ts = Int64((payload.timeStampEnd.timeIntervalSince1970 * 1000).rounded())
            for d in payload.crashDiagnostics ?? [] { runtime.ingest(d.jsonRepresentation(), kind: .crash, at: ts) }
            for d in payload.hangDiagnostics ?? [] { runtime.ingest(d.jsonRepresentation(), kind: .hang, at: ts) }
            for d in payload.cpuExceptionDiagnostics ?? [] { runtime.ingest(d.jsonRepresentation(), kind: .cpu, at: ts) }
            for d in payload.diskWriteExceptionDiagnostics ?? [] { runtime.ingest(d.jsonRepresentation(), kind: .disk, at: ts) }
            #if os(iOS)
            for d in payload.appLaunchDiagnostics ?? [] { runtime.ingest(d.jsonRepresentation(), kind: .launch, at: ts) }
            #endif
        }
    }
}
#endif
