import Foundation
import Synchronization
import Testing
#if canImport(MetricKit)
import MetricKit
#endif
@testable import CobaltKit

/// Crash capture: the unclean-exit marker, and MetricKit diagnostics passed through untouched.
@Suite("telemetry crashes")
struct TelemetryCrashTests {
    private func runtime(_ dir: URL, _ process: TelemetryProcess = .app) -> TelemetryRuntime {
        TelemetryRuntime(directory: dir, process: process, mirrorToOSLog: false)
    }

    // MARK: unclean exit

    @Test func aMarkerLeftBehindBecomesAnUncleanExitWithTheLastHundredEvents() throws {
        let dir = try makeTempDirectory()
        let before = runtime(dir)                                    // the session that dies
        for n in 0..<150 { before.log.log(.info, .pipeline, "step \(n)") }
        before.markRunning()
        before.log.flush()
        // no markClean(): the process was killed

        let after = runtime(dir)                                     // the next launch
        after.log.log(.info, .app, "new session event")
        let record = try #require(after.collectUncleanExit())
        #expect(record.kind == .uncleanExit)
        #expect(record.events.count == TelemetryLimits.crashEvents)
        #expect(record.events.first?.msg == "step 50")
        #expect(record.events.last?.msg == "step 149")               // the new session's own events are not in it
        #expect(record.summary.contains("without going to the background"))
        #expect(record.hasPayload == false)

        let pending = after.crashes.pending()
        #expect(pending.count == 1)
        #expect(pending.first?.payload == nil)
        // reported once: the marker is gone
        #expect(after.collectUncleanExit() == nil)
        #expect(after.crashes.count == 1)
    }

    @Test func aCleanBackgroundLeavesNothing() throws {
        let dir = try makeTempDirectory()
        let before = runtime(dir)
        before.markRunning()
        before.markClean()
        let after = runtime(dir)
        #expect(after.collectUncleanExit() == nil)
        #expect(after.crashes.count == 0)
    }

    @Test func goingActiveAgainAfterABackgroundArmsItAgain() throws {
        let dir = try makeTempDirectory()
        let a = runtime(dir)
        a.markRunning()
        a.markClean()
        a.markRunning()                                              // back in the foreground, then killed
        #expect(runtime(dir).collectUncleanExit() != nil)
    }

    @Test func noMarkerBeforeTheFirstActivation() throws {
        let dir = try makeTempDirectory()
        _ = runtime(dir)                                             // launched in the background: never became active
        #expect(runtime(dir).collectUncleanExit() == nil)
    }

    // MARK: MetricKit passthrough

    /// A diagnostic as MetricKit writes it (shape from `MXCrashDiagnostic.jsonRepresentation()`): the call
    /// stack tree nests one frame inside the next, as deep as the crashed stack was.
    private func fakeCrashPayload(depth: Int, marker: String = "Cobalt") -> Data {
        var frames = #"{"binaryName":"\#(marker)","address":4294967296}"#
        for _ in 0..<depth { frames = #"{"binaryName":"\#(marker)","subFrames":[\#(frames)]}"# }
        let json = #"{"diagnosticMetaData":{"exceptionType":1,"signal":11,"exceptionCode":1,"terminationReason":"Namespace SIGNAL, Code 11","appBuildVersion":"3"},"callStackTree":{"callStacks":[{"threadAttributed":true,"callStackRootFrames":[\#(frames)]}],"callStackPerThread":false}}"#
        return Data(json.utf8)
    }

    @Test func aDiagnosticPayloadIsStoredAndSentByteForByte() throws {
        let dir = try makeTempDirectory()
        let rt = runtime(dir)
        rt.log.log(.info, .pipeline, "before the crash")
        let payload = fakeCrashPayload(depth: 40)
        let ts = TelemetryLog.nowMillis() + 5
        #expect(DiagnosticIngest.ingest(payload, kind: .crash, at: ts, into: rt.crashes, log: rt.log))

        let stored = try #require(rt.crashes.pending().first)
        #expect(stored.payload == payload)                           // untouched on disk
        #expect(stored.record.kind == .crash)
        #expect(stored.record.ts == ts)
        #expect(stored.record.summary.contains("signal 11"))
        #expect(stored.record.summary.contains("exception type 1"))
        #expect(stored.record.events.contains { $0.msg == "before the crash" })

        let info = TelemetryAppInfo(version: "1.2", build: "3", platform: "ios", os: "iOS 26.0", device: "iPhone17,1", process: .app)
        let batch = TelemetryBatch(process: .app, events: [], crashes: [stored])
        let body = try TelemetryBody.encode(batch: batch, app: info, install: "install-1")
        #expect(body.range(of: payload) != nil)                      // spliced in verbatim
        let object = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        let crash = try #require((object["crashes"] as? [[String: Any]])?.first)
        #expect(crash["kind"] as? String == "crash")
        #expect((crash["payload"] as? [String: Any])?["callStackTree"] != nil)
        #expect((crash["events"] as? [[String: Any]])?.isEmpty == false)
    }

    @Test func aStackTooDeepForAnyJSONParserStillGoesThrough() throws {
        let dir = try makeTempDirectory()
        let rt = runtime(dir)
        let payload = fakeCrashPayload(depth: 3_000)                 // a stack overflow: far past a parser's depth limit
        #expect(DiagnosticIngest.ingest(payload, kind: .crash, at: 1, into: rt.crashes, log: rt.log))
        let stored = try #require(rt.crashes.pending().first)
        #expect(stored.payload == payload)
        let info = TelemetryAppInfo(version: "1", build: "1", platform: "ios", os: "iOS 26", device: "x", process: .app)
        let body = try TelemetryBody.encode(batch: TelemetryBatch(process: .app, events: [], crashes: [stored]), app: info, install: "i")
        #expect(body.range(of: payload) != nil)
    }

    @Test func theSameDiagnosticTwiceIsOneRecordAndStaysGoneOnceSent() throws {
        let dir = try makeTempDirectory()
        let rt = runtime(dir)
        let payload = fakeCrashPayload(depth: 2)
        #expect(DiagnosticIngest.ingest(payload, kind: .crash, at: 10, into: rt.crashes, log: rt.log))
        #expect(!DiagnosticIngest.ingest(payload, kind: .crash, at: 10, into: rt.crashes, log: rt.log))
        #expect(rt.crashes.count == 1)
        let id = try #require(rt.crashes.pending().first?.record.id)
        rt.crashes.remove([id])
        #expect(rt.crashes.count == 0)
        #expect(!DiagnosticIngest.ingest(payload, kind: .crash, at: 10, into: rt.crashes, log: rt.log))   // MetricKit re-delivered it
        #expect(rt.crashes.count == 0)
    }

    @Test func everyKindGetsASummary() {
        let hang = Data(#"{"diagnosticMetaData":{"hangDuration":"5.2 sec"}}"#.utf8)
        let cpu = Data(#"{"diagnosticMetaData":{"totalCPUTime":"92 sec","totalSampledTime":"180 sec"}}"#.utf8)
        let disk = Data(#"{"diagnosticMetaData":{"writesCaused":"1.1 GB"}}"#.utf8)
        #expect(DiagnosticIngest.summary(of: hang, kind: .hang).contains("5.2 sec"))
        #expect(DiagnosticIngest.summary(of: cpu, kind: .cpu).contains("92 sec"))
        #expect(DiagnosticIngest.summary(of: disk, kind: .disk).contains("1.1 GB"))
        #expect(DiagnosticIngest.summary(of: Data("not json".utf8), kind: .crash) == "crash")
        #expect(DiagnosticIngest.summary(of: Data(), kind: .launch) == "launch")
    }

    @Test func aPayloadThatIsNotJSONIsSentAsNull() throws {
        let dir = try makeTempDirectory()
        let rt = runtime(dir)
        #expect(DiagnosticIngest.ingest(Data("garbage".utf8), kind: .hang, at: 1, into: rt.crashes, log: rt.log))
        let stored = try #require(rt.crashes.pending().first)
        #expect(stored.payload == nil)
        let info = TelemetryAppInfo(version: "1", build: "1", platform: "ios", os: "iOS 26", device: "x", process: .app)
        let body = try TelemetryBody.encode(batch: TelemetryBatch(process: .app, events: [], crashes: [stored]), app: info, install: "i")
        let object = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        let crash = try #require((object["crashes"] as? [[String: Any]])?.first)
        #expect(crash["payload"] is NSNull)
    }

    @Test func theStoreKeepsAtMostThirtyRecords() throws {
        let dir = try makeTempDirectory()
        let store = CrashStore(directory: dir)
        for n in 0..<(CrashStore.maxRecords + 5) {
            store.add(CrashRecord(id: "r\(n)", ts: Int64(n), kind: .hang, summary: "h", events: [], hasPayload: false), payload: nil)
        }
        let all = store.pending()
        #expect(all.count == CrashStore.maxRecords)
        #expect(all.first?.record.id == "r5")                        // the oldest went
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
        let payload = fakeCrashPayload(depth: 5, marker: "BackgroundQueue")

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
}
