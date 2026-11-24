import Foundation

/// The spec's name for `JobQueue` (apple 03-PHASE3 3.1: "PipelineStore (evolved JobQueue + JobLedger)"). Phase 3 evolves
/// `JobQueue` in place and keeps its type name and public API, so nothing that reads it breaks; code written against the spec's
/// vocabulary can say `PipelineStore`.
///
/// What the store is, after Phase 3 lane (a):
/// - **The one place this device's own work lives.** Every run of the app is a `Job` of `JobQueue.jobs` (focused, alongside, or
///   let go of); `JobLedger` is its persistence adapter (the relaunch ledger) and `SharedJobStore` the cross-process handoff it reads
///   at foreground. Nothing is carried in a hidden pipeline.
/// - **Closing never hides.** `ActivityModel.minimize` and a focus that closes only unfocus. A dismiss or a cancel of a job that
///   still has a render, a publish or the copy onto the device going on is `JobQueue.letGo`: the job leaves the tray, stays in
///   `activity.items` (`rendering` / `deviceCopy`), and retires when that work settles. A job that failed meanwhile comes back.
/// - The busy period's number on the Live Activity is the one count (`LiveActivityManager`, `ActivityModel.activeCount`).
public typealias PipelineStore = JobQueue
