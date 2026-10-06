import Foundation

/// A Live sink that understands several jobs at once (CONTRACT-PARALLEL.md section 6: one activity for the busy
/// period). `LiveActivityManager` conforms in wave 2 (L2); until it does, `LiveRouter` keeps today's single-run
/// behaviour for it.
@MainActor
protocol JobLiveSink: LiveSink {
    /// After every add, settle, focus change, cancel and line move.
    func jobsChanged(_ queue: JobQueue)
}

/// Sits between the pipelines and the real `LiveSink` (`PipelineContext.live`). The manager of wave 1 knows one
/// visible run plus the runs `detach()` handed over, so a second pipeline reporting to it would end the first one's
/// activity. The router therefore mutes the pipelines of jobs the owner never focused (batch jobs report nothing) and
/// forwards everything for a sink that conforms to `JobLiveSink`.
@MainActor
final class LiveRouter: LiveSink {
    var sink: (any LiveSink)?
    private var muted: Set<ObjectIdentifier> = []

    /// The sink hears every pipeline and the queue's own changes.
    var hearsEveryJob: Bool { sink is any JobLiveSink }

    func mute(_ p: Pipeline) { muted.insert(ObjectIdentifier(p)) }
    func unmute(_ p: Pipeline) { muted.remove(ObjectIdentifier(p)) }
    func isMuted(_ p: Pipeline) -> Bool { !hearsEveryJob && muted.contains(ObjectIdentifier(p)) }

    func jobsChanged(_ queue: JobQueue) { (sink as? any JobLiveSink)?.jobsChanged(queue) }

    func runBegan(_ pipeline: Pipeline) { if !isMuted(pipeline) { sink?.runBegan(pipeline) } }
    func stateChanged(_ pipeline: Pipeline) { if !isMuted(pipeline) { sink?.stateChanged(pipeline) } }
    func sessionChanged(_ pipeline: Pipeline) { if !isMuted(pipeline) { sink?.sessionChanged(pipeline) } }
    func runDetached(from old: Pipeline, to background: Pipeline) {
        // a muted run never had an activity: what carries it on (a finished job's keep download) has none either
        if isMuted(old) { mute(background); return }
        sink?.runDetached(from: old, to: background)
    }
    func detachedSettled(_ background: Pipeline) {
        if muted.contains(ObjectIdentifier(background)) { unmute(background); return }
        sink?.detachedSettled(background)
    }
}
