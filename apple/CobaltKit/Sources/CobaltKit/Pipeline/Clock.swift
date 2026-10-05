import Foundation

/// The pipeline's and the preview client's only source of time, so tests can run the whole state
/// machine on a virtual clock with no real sleeping.
protocol PipelineClock: Sendable {
    func now() -> Date
    func sleep(seconds: Double) async throws
}

struct SystemClock: PipelineClock {
    func now() -> Date { Date() }
    func sleep(seconds: Double) async throws {
        guard seconds > 0 else { return }
        try await Task.sleep(for: .seconds(seconds))
    }
}
