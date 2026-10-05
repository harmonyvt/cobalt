import Foundation
import Synchronization
@testable import CobaltKit

/// Virtual time for the pipeline and `PreviewClient`: `sleep` parks until the driver advances to
/// its wake time, so a 5 s render takes milliseconds and no test sleeps for real on the clock.
final class VirtualClock: PipelineClock, Sendable {
    private struct Sleeper {
        var id: UInt64
        var wake: Double
        var continuation: CheckedContinuation<Void, Error>
    }

    private struct State {
        var now: Double = 0
        var nextID: UInt64 = 0
        var sleepers: [Sleeper] = []
        var registrations = 0
    }

    private let state = Mutex(State())
    let epoch = Date(timeIntervalSince1970: 1_800_000_000)

    func now() -> Date { epoch.addingTimeInterval(state.withLock { $0.now }) }
    var elapsed: Double { state.withLock { $0.now } }
    var registrations: Int { state.withLock { $0.registrations } }
    var pending: Int { state.withLock { $0.sleepers.count } }

    func sleep(seconds: Double) async throws {
        guard seconds > 0 else { return }
        let id = state.withLock { s -> UInt64 in s.nextID += 1; return s.nextID }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                state.withLock { s in
                    s.sleepers.append(Sleeper(id: id, wake: s.now + seconds, continuation: continuation))
                    s.registrations += 1
                }
                if Task.isCancelled { cancel(id) }
            }
        } onCancel: {
            cancel(id)
        }
    }

    private func cancel(_ id: UInt64) {
        let sleeper = state.withLock { s -> Sleeper? in
            guard let i = s.sleepers.firstIndex(where: { $0.id == id }) else { return nil }
            return s.sleepers.remove(at: i)
        }
        sleeper?.continuation.resume(throwing: CancellationError())
    }

    /// Moves time forward without waking anybody (what a real server does between two calls).
    func jump(by seconds: Double) { state.withLock { $0.now += seconds } }

    /// Wakes the earliest sleeper (ties in registration order). False when nobody sleeps.
    @discardableResult
    func advance() -> Bool {
        let sleeper = state.withLock { s -> Sleeper? in
            guard let i = s.sleepers.indices.min(by: {
                (s.sleepers[$0].wake, s.sleepers[$0].id) < (s.sleepers[$1].wake, s.sleepers[$1].id)
            }) else { return nil }
            let sl = s.sleepers.remove(at: i)
            s.now = max(s.now, sl.wake)
            return sl
        }
        sleeper?.continuation.resume()
        return sleeper != nil
    }
}

/// A preview app model on a virtual clock, plus the driver that runs time forward.
@MainActor
struct Harness {
    let clock = VirtualClock()
    let app: AppModel
    let scenario: PreviewScenario

    init(_ scenario: PreviewScenario, timeScale: Double = 1) {
        self.scenario = scenario
        self.app = AppModel.makePreview(scenario, timeScale: timeScale, clock: clock)
        // The sheet's countdown is on by default (CONTRACT-SYNC.md): tests of other behaviour drive
        // virtual time far past 5 s, so only the countdown's own tests turn it on.
        self.app.ctx.settings.autoContinue = false
    }

    var pipeline: Pipeline { app.pipeline }
    var ctx: PipelineContext { app.ctx }
    var clipboard: MemoryClipboard { ctx.clipboard as! MemoryClipboard }
    var log: [PipelineState] { pipeline.stateLog }
    var kinds: [String] { Harness.collapse(log.map(Harness.kind)) }

    /// Waits (in real milliseconds) until no new sleeper has registered for a few ticks, i.e. every
    /// task that could run has run and is parked on the virtual clock again.
    func settle() async {
        var last = clock.registrations
        var stable = 0
        while stable < 4 {
            try? await Task.sleep(for: .milliseconds(1))
            let r = clock.registrations
            if r == last { stable += 1 } else { stable = 0; last = r }
        }
    }

    /// Runs virtual time forward until `condition` holds (or 300 virtual seconds pass).
    func drive(until condition: @MainActor () -> Bool, maxVirtualSeconds: Double = 300) async {
        var idle = 0
        while !condition() && clock.elapsed < maxVirtualSeconds {
            await settle()
            if condition() { return }
            if clock.advance() { idle = 0 } else {
                idle += 1
                if idle > 30 { return }
                try? await Task.sleep(for: .milliseconds(5))
            }
        }
    }

    func isTerminalOrReady() -> Bool {
        switch pipeline.state {
        case .ready, .failed, .done, .savedLocally, .image, .picker: return true
        default: return false
        }
    }

    func driveToSettled() async { await drive { self.isTerminalOrReady() } }

    // MARK: describing states

    static func kind(_ s: PipelineState) -> String {
        switch s {
        case .idle: return "idle"
        case .fetching(_, let waking): return waking ? "fetching(waking)" : "fetching"
        case .uploading: return "uploading"
        case .saving(let bytes, _, _): return bytes == nil ? "saving(degraded)" : "saving"
        case .reading: return "reading"
        case .picker: return "picker"
        case .image: return "image"
        case .ready: return "ready"
        case .rendering(.working): return "rendering.working"
        case .rendering(.decoding): return "rendering.decoding"
        case .rendering(.packing): return "rendering.packing"
        case .done: return "done"
        case .savedLocally: return "savedLocally"
        case .failed(let f): return "failed(\(f))"
        }
    }

    static func collapse(_ items: [String]) -> [String] {
        var out: [String] = []
        for i in items where out.last != i { out.append(i) }
        return out
    }
}

/// True when `needle` appears in `haystack` in order (not necessarily adjacent).
func isSubsequence(_ needle: [String], of haystack: [String]) -> Bool {
    var i = 0
    for item in haystack where i < needle.count && item == needle[i] { i += 1 }
    return i == needle.count
}

func makeTempFile(_ name: String, bytes: Int = 1_000) throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cobaltkit-tests-\(UUID().uuidString.prefix(8))", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let url = dir.appendingPathComponent(name)
    try Data(repeating: 7, count: bytes).write(to: url)
    return url
}

func makeTempDirectory() throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cobaltkit-tests-\(UUID().uuidString.prefix(8))", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}
