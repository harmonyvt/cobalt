import Foundation
import Testing
@testable import CobaltKit

let linkA = URL(string: "https://www.instagram.com/reel/Dd7P496wolG/")!
let linkB = URL(string: "https://x.com/i/status/2105435404002562056")!
let linkC = URL(string: "https://www.tiktok.com/@cobalt/video/7000000000000000001")!
/// The preview server cannot save this one (a private post): its session ends `error.api.fetch.empty`.
let linkPrivate = URL(string: "https://www.instagram.com/reel/Dd55fEyN1Yy/")!

/// A preview app on a virtual clock whose server holds (or does not hold) a line: the driver of the parallel-work
/// tests (CONTRACT-PARALLEL.md section 13).
@MainActor
struct LineRig {
    let clock = VirtualClock()
    let app: AppModel
    let mode: LinePreviewMode

    init(_ mode: LinePreviewMode, notifyBridge: Bool = false) {
        self.mode = mode
        app = AppModel.makePreviewLine(mode, timeScale: 1, clock: clock)
        app.ctx.settings.autoContinue = false
        app.queue.trayIsShown = true                                 // the tray is what makes jobs alongside visible
        if notifyBridge {
            var caps = app.ctx.capabilities
            caps.notifyBridge = true
            app.apply(caps)
        }
    }

    var queue: JobQueue { app.queue }
    var ctx: PipelineContext { app.ctx }
    var client: PreviewClient { app.ctx.client as! PreviewClient }
    var server: PreviewServer { client.server }
    var calls: [String] { server.lineCalls }

    /// Real milliseconds until nothing new has parked on the virtual clock for a few ticks.
    func settle() async {
        var last = clock.registrations
        var stable = 0
        while stable < 4 {
            try? await Task.sleep(for: .milliseconds(1))
            let r = clock.registrations
            if r == last { stable += 1 } else { stable = 0; last = r }
        }
    }

    /// Runs virtual time forward until `condition` holds (or `maxVirtualSeconds` of it pass).
    func drive(until condition: @MainActor () -> Bool, maxVirtualSeconds: Double = 300) async {
        let start = clock.elapsed
        var idle = 0
        while !condition(), clock.elapsed - start < maxVirtualSeconds {
            await settle()
            if condition() { return }
            if clock.advance() { idle = 0 } else {
                idle += 1
                if idle > 30 { return }
                try? await Task.sleep(for: .milliseconds(5))
            }
        }
    }

    /// Runs virtual time forward by `seconds`, waking every sleeper on the way.
    func run(for seconds: Double) async {
        let target = clock.elapsed + seconds
        await settle()
        while clock.elapsed < target {
            await settle()
            guard clock.advance() else { break }
        }
        await settle()
    }

    func settled(_ job: Job) -> Bool {
        switch job.pipeline.state {
        case .ready, .failed, .done, .savedLocally, .image, .picker: return true
        default: return false
        }
    }

    func allSettled() -> Bool { !queue.jobs.isEmpty && queue.jobs.allSatisfy { settled($0) } }

    func count(_ call: String) -> Int { calls.filter { $0 == call }.count }
}

/// Yields the main actor a few times so tasks that are ready to run have run.
@MainActor
func yieldMain(_ times: Int = 8) async {
    for _ in 0..<times { await Task.yield() }
}
