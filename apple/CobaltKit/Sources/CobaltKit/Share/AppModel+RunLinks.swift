import Foundation

// Where a run's link lands in the app (CONTRACT-SHARE-QUICK.md section 4): the share sheet's local
// notifications, the Live Activity's tap, and (once the server sends it) the Hark notification's tap.
//
//   cobalt-apple://job/<uuid>                       the run (a SharedJob id, or the home run's id)
//   cobalt-apple://job/<uuid>?session=<sid>[&trim=1] the same, with the run's studio session
//   cobalt-apple://session/<sid>                     a run known only by its session (Hark)
//
// A run whose original is already in the store opens as that media (`requestedMediaID`).
//
// The session matters on a build re-signed without the app group: the app then cannot read the
// share sheet's job record, and follows the run from its session alone.

/// A parsed run link.
struct RunLink: Sendable, Equatable {
    var run: UUID?
    var session: String?
    var trim: Bool

    init?(_ url: URL) {
        guard url.scheme?.lowercased() == "cobalt-apple",
              let parts = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else { return nil }
        let host = url.host(percentEncoded: false)?.lowercased()
        let query = parts.queryItems ?? []
        switch host {
        case "job":
            guard let id = UUID(uuidString: url.lastPathComponent) else { return nil }
            run = id
            session = query.first { $0.name == "session" }?.value.flatMap(RunLink.cleanSession)
        case "session":
            guard let sid = RunLink.cleanSession(url.lastPathComponent) else { return nil }
            run = nil
            session = sid
        default:
            return nil
        }
        trim = query.first { $0.name == "trim" }?.value == "1"
    }

    /// Studio session ids are short URL-safe tokens; anything else is not one.
    static func cleanSession(_ raw: String) -> String? {
        let ok = !raw.isEmpty && raw.count <= 64
            && raw.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_" }
        return ok ? raw : nil
    }
}

extension AppModel {
    /// Opens the run a link names. Returns false when `url` is not a run link (the caller passes it to
    /// `open(_:)`).
    ///
    /// - The run has settled and its original is in the store (a finished save the share sheet handed
    ///   off, the Hark "saved" tap): `requestedMediaID` asks the home screen to open that media.
    /// - The home pipeline already follows the run: the save tab, nothing else (it is on screen).
    /// - The app has the run's job record: `open(_:)` takes it as before (only over a quiet home screen).
    /// - No record, but the link carries the session: the home pipeline follows the session as a
    ///   share-sheet save, when the home screen is quiet. Its Live Activity starts with it.
    @discardableResult
    public func openRunLink(_ url: URL) -> Bool {
        guard let link = RunLink(url) else { return false }
        selectedTab = .save
        let all = jobs.all()
        let byRun = link.run.flatMap { id in all.first { $0.id == id } }
        let bySession = link.session.flatMap { sid in all.filter { $0.sessionID == sid }.max { $0.updatedAt < $1.updatedAt } }
        // A run still on the home screen is left to it; a settled one (idle, failed, finished) whose
        // original is already here is opened as the media itself. "Trim in cobalt" is the owner asking
        // for the trim, which the home pipeline gives, so that stays.
        let following = isFollowing(link)
        let wantsTrim = link.trim || (byRun ?? bySession)?.wantsTrim == true
        if !wantsTrim, !following || isQuietForRunLink,
           let sid = link.session ?? byRun?.sessionID,
           let media = store.media.first(where: { $0.original?.sessionID == sid }) {
            // nothing left to follow: the record goes (as a settled run's does) so the next foreground
            // does not resume it over the media
            if let job = byRun ?? bySession {
                jobs.remove(job.id)
                if !ctx.isPreview { Notifications.clear(jobID: job.id) }
            }
            Telemetry.log(.info, .share, "run link opened media")
            requestedMediaID = media.id
            return true
        }
        if following { return true }
        if let job = byRun ?? bySession {
            open(URL(string: "cobalt-apple://job/\(job.id.uuidString)")!)
            return true
        }
        guard let sid = link.session, isQuietForRunLink else { return true }
        if let id = link.run, ctx.background.owns(job: id) { return true }
        let job = SharedJob(
            id: link.run ?? UUID(), origin: .shareExtension, link: nil, sessionID: sid, media: nil, trim: nil,
            stage: .saving, wantsTrim: link.trim, pickedUp: false, updatedAt: ctx.clock.now())
        Telemetry.log(.info, .share, "run link followed by session", data: ["trim": .bool(link.trim)])
        pipeline.resume(job)
        return true
    }

    /// The home pipeline is on this run now.
    private func isFollowing(_ link: RunLink) -> Bool {
        if case .idle = pipeline.state { return false }
        if let id = link.run, id == pipeline.liveRunID { return true }
        if let sid = link.session, sid == pipeline.sessionID { return true }
        return false
    }

    /// Nothing on the home screen a link may push aside: idle, a failure, or a finished result.
    private var isQuietForRunLink: Bool {
        switch pipeline.state {
        case .idle, .done, .failed, .savedLocally, .image: return true
        default: return false
        }
    }
}

#if DEBUG
// Simulator evidence for the app's half of the quick card (debug builds only; `AppLinks.swift` turns
// `cobalt-apple://debug/...` links into these). The live model keeps its own stores, its Live Activity
// manager and its scene; only the server becomes `PreviewClient`, so a run can be followed with no key.
extension AppModel {
    /// The server becomes `PreviewClient` for `scenario`.
    public func debugUsePreviewServer(_ scenario: PreviewScenario) {
        ctx.client = PreviewClient(scenario: scenario, timeScale: 1, clock: ctx.clock)
        apply(PreviewData.capabilities(for: scenario))
        Telemetry.log(.info, .share, "debug preview server", data: ["scenario": .string(scenario.rawValue)])
    }

    /// The quick card's hand-off as the extension leaves it (a `SharedJob(.saving)` from the share
    /// sheet, the save still running on the server), then the foreground pick-up. Returns the job.
    @discardableResult
    public func debugShareHandoff(link: URL) async -> SharedJob? {
        guard let created = try? await ctx.client.createStudio(link: link) else { return nil }
        let job = SharedJob(
            id: UUID(), origin: .shareExtension, link: link, sessionID: created.id, media: nil, trim: nil,
            stage: .saving, wantsTrim: false, pickedUp: false, updatedAt: ctx.clock.now())
        jobs.upsert(job)
        await pickUpSharedJobs()
        return job
    }

    /// A run link with only a session (no job record: a build without the app group), for a save that
    /// is still running. Returns the link it opened.
    @discardableResult
    public func debugSessionRunLink(link: URL) async -> URL? {
        guard let created = try? await ctx.client.createStudio(link: link) else { return nil }
        let url = URL(string: "cobalt-apple://job/\(UUID().uuidString)?session=\(created.id)")!
        openRunLink(url)
        return url
    }
}
#endif
