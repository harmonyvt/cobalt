import Foundation

/// At most `limit` holders at once; the rest wait first in first out, silently, in whatever step they are in
/// (CONTRACT-PARALLEL.md 3.2, "Concurrency caps").
@MainActor
final class ConcurrencyGate {
    private struct Waiter {
        var token: Int
        var continuation: CheckedContinuation<Void, Error>
    }

    let limit: Int
    private(set) var inUse = 0
    private var waiters: [Waiter] = []
    private var counter = 0

    init(limit: Int) { self.limit = limit }

    var waiting: Int { waiters.count }

    func acquire() async throws {
        try Task.checkCancellation()
        if inUse < limit, waiters.isEmpty {
            inUse += 1
            return
        }
        counter += 1
        let mine = counter
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                waiters.append(Waiter(token: mine, continuation: continuation))
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancelWaiter(mine) }
        }
    }

    /// A slot is handed straight to the first waiter; otherwise it is free again.
    func release() {
        if !waiters.isEmpty {
            waiters.removeFirst().continuation.resume()
        } else {
            inUse = max(0, inUse - 1)
        }
    }

    func withSlot<T>(_ body: @MainActor () async throws -> T) async throws -> T {
        try await acquire()
        defer { release() }
        return try await body()
    }

    private func cancelWaiter(_ token: Int) {
        guard let i = waiters.firstIndex(where: { $0.token == token }) else { return }
        waiters.remove(at: i).continuation.resume(throwing: CancellationError())
    }
}

/// The caps of one app: 3 link checks, 2 uploads, 2 frame reads at once. Keep downloads belong to the system's
/// background session; the server's own line (`line_max`) bounds what is sent to it.
@MainActor
final class JobGates {
    /// Creates sent to the server's line one at a time, in the order the jobs were added, so first in line is first
    /// pasted (a create is a round trip of well under a second; the polls are not behind it).
    let create = ConcurrencyGate(limit: 1)
    let check = ConcurrencyGate(limit: 3)
    let upload = ConcurrencyGate(limit: 2)
    let frames = ConcurrencyGate(limit: 2)
}
