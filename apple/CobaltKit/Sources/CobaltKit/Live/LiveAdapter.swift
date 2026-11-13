import Foundation

/// The part of ActivityKit `LiveActivityManager` uses, as a seam: the real adapter (`ActivityKitJobAdapter.saves()`,
/// `JobActivity.swift`) is iOS only, tests (and the Mac) use a fake, so the manager's logic runs under `swift test` on
/// macOS. Every activity is a job activity (`CobaltJobActivityAttributes`, CONTRACT-JOBLIVE.md 5) of kind save, upload,
/// make or many.
@MainActor
protocol LiveActivityAdapter: AnyObject, Sendable {
    /// Live Activities are allowed (`ActivityAuthorizationInfo().areActivitiesEnabled`).
    var isAvailable: Bool { get }
    /// The job activities of saves, uploads, makes and the busy period.
    var activities: [any JobActivityHandle] { get }
    /// Activities of the old type (`CobaltActivityAttributes`) still on screen from an older build: ended, never written.
    var oldActivities: [any OldLiveActivity] { get }
    func request(_ job: JobLiveJob, staleDate: Date, push: Bool) throws -> any JobActivityHandle
    /// The job type's `pushToStartTokenUpdates`, lowercase hex.
    func startTokens() -> AsyncStream<String>
    /// The job type's `pushToStartToken` right now.
    var currentStartToken: String? { get }
    /// The job type's `activityUpdates`: activities the system (a push-to-start) created, of the kinds above.
    func newActivities() -> AsyncStream<any JobActivityHandle>
}

extension Data {
    var liveHex: String { map { String(format: "%02x", $0) }.joined() }
}

extension LiveRunAttributes {
    /// What `PUT /live/runs/<run>` needs for a run the server push-started (an instant share, an agent job), whose activity
    /// carries only the job's attributes. The server already holds the run and keeps its own attributes; these only have to
    /// pass its checks. The source line ("twitch · KindStupidClip") is split back into service and ref as best it can be.
    init(pushStarted a: JobLiveAttributes, run: UUID) {
        let upload = a.kind == "upload"
        let parts = a.title.components(separatedBy: " · ")
        let service = upload ? "file" : parts.count > 1 ? parts[0] : a.title
        let ref = upload ? a.title : parts.count > 1 ? parts.dropFirst().joined(separator: " · ") : ""
        self.init(
            run: run, input: upload ? "file" : "link", service: JobText.prefix(service, 120), ref: JobText.prefix(ref, 120),
            origin: "share")
    }
}
