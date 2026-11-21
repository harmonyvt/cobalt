import Foundation
import Synchronization

/// What one engine job leaves behind: the index as it was written (or read), the job's own answer, and the job's place in
/// the engine's order. The store adopts `records` on the main actor only when no later job's snapshot got there first.
struct OfflineIndexSnapshot<Value: Sendable>: Sendable {
    let records: [OfflineStore.Record]
    let value: Value
    let sequence: Int
}

/// The index's own engine (8.17: the main thread is display-only). Every read-modify-write the store starts runs here, off
/// the main thread: the coordinated read, the decode, the change, the storage limit, the encode and the write, and the
/// deletes that follow. One job at a time, in the order the store asked for them: the actor runs on a serial dispatch queue,
/// which is first in, first out, where a default actor may let a higher priority job pass a lower one (a rename typed twice
/// must land in the order it was typed). The share extension still writes the same file; `NSFileCoordinator` inside
/// `OfflineStore.mutate` keeps the two processes apart as before.
///
/// The folder work (`OfflineFolder`, behind `OfflineFolderGate`) writes the index on its own hops and is not routed here:
/// its moves and its index writes are one step to the gate.
actor OfflineIndexEngine {
    private let queue: DispatchSerialQueue
    nonisolated var unownedExecutor: UnownedSerialExecutor { queue.asUnownedSerialExecutor() }
    let root: URL
    /// Counts the jobs that produced a snapshot, so the store can drop a snapshot that resumes after a newer one.
    private var sequence = 0

    /// How often an eviction plan ran on and off the main thread, for the test that holds planning off main. Only ever
    /// counted, never read by the app.
    static let planThreads = Mutex<(onMain: Int, offMain: Int)>((onMain: 0, offMain: 0))

    init(root: URL) {
        self.root = root
        self.queue = DispatchSerialQueue(label: "com.capybaraharmony.cobalt.offline-index", qos: .userInitiated)
    }

    /// No snapshot came out of a write that did not throw: cannot happen (`mutate` runs its body whenever it does not throw),
    /// but a missing value is never invented.
    struct NoResult: Error {}

    /// One coordinated write: `body` changes the index and answers a value; then, when `enforce`, the storage limit is
    /// applied to the result before anything is written, sparing `pinned` and whatever `protecting` names from the answer
    /// (`add` only learns inside the write which record survives). The files the limit took are deleted after the write.
    func write<Value: Sendable>(
        limit: Int64?, enforce: Bool, pinned: Set<String>,
        protecting: @Sendable (Value) -> Set<String>,
        _ body: @Sendable (inout [OfflineStore.Record]) -> Value
    ) throws -> OfflineIndexSnapshot<Value> {
        MainThreadGuard.assertOffMain()
        var outcome: (value: Value, evicted: OfflineStore.Eviction)?
        let root = root
        let merged = try EngineClock.measure("store.write") {
            try OfflineStore.mutate(root: root) { records in
                let value = body(&records)
                var evicted = OfflineStore.Eviction()
                if enforce {
                    evicted = OfflineStore.enforce(&records, limit: limit, protecting: protecting(value).union(pinned))
                }
                outcome = (value, evicted)
            }
        }
        guard let outcome else { throw NoResult() }
        OfflineStore.delete(outcome.evicted, root: root)
        return stamp(merged, outcome.value)
    }

    /// Deletes files, posters and flipbook frames the index no longer names, after the write that stopped naming them.
    func delete(_ plan: OfflineStore.Eviction) {
        guard !plan.isEmpty else { return }
        OfflineStore.delete(plan, root: root)
    }

    /// The index as it is on disk, in line with the writes; nil when it cannot be read (the store keeps what it shows).
    func read() -> OfflineIndexSnapshot<Void>? {
        MainThreadGuard.assertOffMain()
        let root = root
        guard let records = EngineClock.measure("store.read", { try? OfflineStore.readRecordsChecked(root: root) }) else { return nil }
        return stamp(records, ())
    }

    /// The reconcile (`OfflineStore.reconciled`): every file, poster and flipbook frame checked on disk, thousands of stats
    /// for a ~900-entry index, which held the main thread 330-430 ms on each foreground in 8.16.
    func reconcile() -> OfflineIndexSnapshot<Void> {
        MainThreadGuard.assertOffMain()
        let root = root
        let records = EngineClock.measure("store.reconcile") { OfflineStore.reconciled(root: root) }
        return stamp(records, ())
    }

    /// The launch's first load (`OfflineStore.boot()`): the reconcile, then the inbox leftovers of a run that never
    /// finished. Both ran in the store's initializer on the main thread, before the first frame; here they run first in
    /// the engine's line, so every write the app queues after launch re-reads what the reconcile fixed.
    /// `launch.store` is what the owner's phone reports for it, beside `store.reconcile`.
    func boot() -> OfflineIndexSnapshot<Void> {
        MainThreadGuard.assertOffMain()
        let root = root
        let records = EngineClock.measure("launch.store") { () -> [OfflineStore.Record] in
            let records = OfflineStore.reconciled(root: root)
            OfflineStore.purgeInbox(root: root, olderThan: OfflineStore.inboxLifetime)
            return records
        }
        return stamp(records, ())
    }

    /// One pass of the limit over the index as it is on disk. The plan is made from one read; only when it would take
    /// something does the coordinated write run (it re-reads, as every write does, and enforces again on what it read).
    /// Nothing to take: the read itself is the snapshot, with no second read. Nil when the index cannot be read (the store
    /// keeps what it shows rather than showing nothing).
    func enforceLimit(limit: Int64?, pinned: Set<String>) -> OfflineIndexSnapshot<Bool>? {
        let root = root
        guard let planned = OfflineStore.planEviction(root: root, limit: limit, protecting: pinned) else { return nil }
        guard !planned.plan.isEmpty else { return stamp(planned.records, false) }
        return try? write(limit: limit, enforce: true, pinned: pinned, protecting: { _ in [] }) { _ in true }
    }

    private func stamp<Value: Sendable>(_ records: [OfflineStore.Record], _ value: Value) -> OfflineIndexSnapshot<Value> {
        sequence += 1
        return OfflineIndexSnapshot(records: records, value: value, sequence: sequence)
    }
}
