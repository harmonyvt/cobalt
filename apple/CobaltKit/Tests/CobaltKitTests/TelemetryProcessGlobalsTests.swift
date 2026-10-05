import Foundation
import Synchronization
import Testing
#if canImport(MetricKit)
import MetricKit
#endif
@testable import CobaltKit

/// Everything that touches process-wide telemetry state: the installed runtime (`Telemetry.install`) and the
/// process's one uncaught-exception handler (`NSSetUncaughtExceptionHandler`). Swift Testing runs suites in
/// parallel inside one process, so tests that swap either must share one serialized suite, or two of them
/// chain the handler to itself (a stack overflow: SIGBUS on a guard page) and read each other's runtime.
@Suite("telemetry process globals", .serialized)
struct TelemetryProcessGlobalsTests {
    private func runtime(_ dir: URL, _ process: TelemetryProcess = .app) -> TelemetryRuntime {
        TelemetryRuntime(directory: dir, process: process, mirrorToOSLog: false)
    }

    @Test func startedFacadeWritesAndUnstartedOneDoesNothing() throws {
        let dir = try makeTempDirectory()
        let runtime = TelemetryRuntime(directory: dir, process: .app, mirrorToOSLog: false)
        let previous = Telemetry.install(runtime)
        defer { Telemetry.install(previous) }
        let marker = "facade-\(UUID().uuidString.prefix(6))"
        Telemetry.log(.info, .ui, marker, data: ["x": 1])
        Telemetry.flush()
        #expect(runtime.log.readAll().contains { $0.e.msg == marker })
        Telemetry.install(nil)
        Telemetry.log(.info, .ui, "dropped-\(marker)")
        Telemetry.flush()
        #expect(!runtime.log.readAll().contains { $0.e.msg.hasPrefix("dropped-") })
    }

    // MARK: off the main actor

    /// The system calls MetricKit's delegate and the uncaught-exception handler on threads of its own. In
    /// Swift 6 a callback written in a main-actor context traps on entry there (the 1.2 upload crash), so
    /// these run from a global queue: a wrong isolation would crash this test process.
    @Test func theSubscriberAndTheExceptionHandlerRunOnABackgroundQueue() async throws {
        let dir = try makeTempDirectory()
        let rt = runtime(dir)
        let previousRuntime = Telemetry.install(rt)
        let previousHandler = NSGetUncaughtExceptionHandler()
        NSSetUncaughtExceptionHandler(nil)                          // nothing to chain to in the test process
        let told = LockedBox(0)
        let previousCallback = Telemetry.crashIngested
        Telemetry.crashIngested = { @Sendable in told.withLock { $0 += 1 } }
        defer {
            Telemetry.crashIngested = previousCallback
            NSSetUncaughtExceptionHandler(previousHandler)
            Telemetry.install(previousRuntime)
        }
        rt.installExceptionBreadcrumb()
        let handler = try #require(NSGetUncaughtExceptionHandler())
        let payload = TelemetryCrashTests().fakeCrashPayload(depth: 5, marker: "BackgroundQueue")

        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            DispatchQueue.global(qos: .utility).async {
                handler(NSException(name: NSExceptionName("TelemetryTestException"), reason: "thrown on a global queue", userInfo: nil))
                #if canImport(MetricKit)
                MetricKitSubscriber(runtime: rt).didReceive([MXDiagnosticPayload]())
                #endif
                rt.ingest(payload, kind: .crash, at: TelemetryLog.nowMillis())      // what the subscriber does per diagnostic
                done.resume()
            }
        }
        let events = rt.log.readAll()
        #expect(events.contains { $0.e.msg == "uncaught exception" && $0.e.data["name"] == .string("TelemetryTestException") })
        #expect(rt.crashes.count == 1)
        #expect(told.withLock { $0 } == 1)                           // the app was told, from that same queue
    }

    /// An exception raised while the telemetry queue itself is writing must not wait on that queue.
    @Test func theExceptionHandlerReturnsWhenItFiresOnTheLogsOwnQueue() throws {
        let dir = try makeTempDirectory()
        let rt = runtime(dir)
        let previousRuntime = Telemetry.install(rt)
        let previousHandler = NSGetUncaughtExceptionHandler()
        NSSetUncaughtExceptionHandler(nil)
        defer {
            NSSetUncaughtExceptionHandler(previousHandler)
            Telemetry.install(previousRuntime)
        }
        rt.installExceptionBreadcrumb()
        let handler = try #require(NSGetUncaughtExceptionHandler())
        rt.log.runOnQueue {
            handler(NSException(name: NSExceptionName("InsideTheQueue"), reason: "raised on the telemetry queue", userInfo: nil))
            rt.log.flush()                                           // also a no-op here
        }
        #expect(rt.log.readAll().contains { $0.e.msg == "uncaught exception" && $0.e.data["name"] == .string("InsideTheQueue") })
    }

    /// Installing twice without clearing the handler in between (a second `armCrashCapture`, or a parallel
    /// test) used to record our own handler as "the previous one", and the first exception then called itself
    /// until the stack ran out.
    @Test func installingTheBreadcrumbTwiceDoesNotChainTheHandlerToItself() throws {
        let dir = try makeTempDirectory()
        let rt = runtime(dir)
        let previousRuntime = Telemetry.install(rt)
        let previousHandler = NSGetUncaughtExceptionHandler()
        NSSetUncaughtExceptionHandler(nil)
        defer {
            NSSetUncaughtExceptionHandler(previousHandler)
            Telemetry.install(previousRuntime)
        }
        rt.installExceptionBreadcrumb()
        let first = try #require(NSGetUncaughtExceptionHandler())
        rt.installExceptionBreadcrumb()
        rt.installExceptionBreadcrumb()
        let handler = try #require(NSGetUncaughtExceptionHandler())
        #expect(unsafeBitCast(handler, to: UnsafeRawPointer.self) == unsafeBitCast(first, to: UnsafeRawPointer.self))
        handler(NSException(name: NSExceptionName("Twice"), reason: "installed three times", userInfo: nil))
        #expect(rt.log.readAll().filter { $0.e.msg == "uncaught exception" }.count == 1)
    }

    /// A handler that was there first (another SDK's) still runs, once, after ours.
    @Test func theHandlerThatWasThereFirstStillRunsOnce() throws {
        let dir = try makeTempDirectory()
        let rt = runtime(dir)
        let previousRuntime = Telemetry.install(rt)
        let previousHandler = NSGetUncaughtExceptionHandler()
        defer {
            NSSetUncaughtExceptionHandler(previousHandler)
            Telemetry.install(previousRuntime)
        }
        NSSetUncaughtExceptionHandler { _ in Self.chained.withLock { $0 += 1 } }
        Self.chained.withLock { $0 = 0 }
        rt.installExceptionBreadcrumb()
        rt.installExceptionBreadcrumb()
        let handler = try #require(NSGetUncaughtExceptionHandler())
        handler(NSException(name: NSExceptionName("Chained"), reason: "to the earlier handler", userInfo: nil))
        #expect(Self.chained.withLock { $0 } == 1)
    }

    private static let chained = Mutex(0)
}
