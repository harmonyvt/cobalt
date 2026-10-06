import Foundation
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// The logic of the Shortcuts actions (CONTRACT-PARALLEL.md section 15), behind plain Swift so `swift test` runs it on
/// the preview server. `Cobalt/Intents/` holds the thin `AppIntent` structs that call these.
///
/// **One entry point.** Every action that creates work calls `JobQueue.add(_:via: .shortcut, options:)` and then
/// `accepted(_:timeout:)` (15.2.2): the jobs are ordinary jobs (tray, Live summary, relaunch, cancel), never focused.
/// Read-only actions call the client. A render for "Make webp" is not a job: renders exist only for the focused job
/// (5.3), so it talks to the server directly and waits for its own result (`ShortcutActions+Webp.swift`).
@MainActor
public final class ShortcutActions {
    let model: AppModel
    var ctx: PipelineContext { model.ctx }
    var queue: JobQueue { model.queue }
    private let clipboard: any ShortcutClipboard
    private var lastCapabilityCheck: Date?

    /// Capabilities older than this are read again before an action runs (15.3 step 1).
    public static let capabilityMaxAge: TimeInterval = 600
    /// ... and that read gets this long.
    public static let capabilityTimeout: Double = 5
    /// How long an action waits for the server to take the links (15.3 step 4).
    public static let acceptTimeout: Double = 20
    /// An upload's bytes go up inside the action, so it waits as long as the server's line may (the longest a job can
    /// be held anyway).
    public static let uploadAcceptTimeout: Double = 1_800
    public static let maxLinks = 20
    /// The tray (CONTRACT-PARALLEL 5.8: "open cobalt" shows it, never a focus).
    public static let jobsURL = URL(string: "cobalt-apple://jobs")!

    public init(model: AppModel, clipboard: (any ShortcutClipboard)? = nil) {
        self.model = model
        self.clipboard = clipboard ?? SystemShortcutClipboard()
    }

    /// What an action does once the server has the work (15.2.5, 15.3 steps 6 and 7).
    public enum FollowUp: Sendable, Equatable {
        /// Return at once. With the app not active, one `PUT /studio/line/notify` leaves the rest to Hark.
        case leave
        /// The caller waits for the result itself (`waitUntilSaved`): nothing is registered.
        case wait
        /// The caller brings cobalt forward and shows the tray: nothing is registered.
        case open
    }

    // MARK: - Ready?

    /// 15.3 step 1: a server and key, capabilities no older than 10 minutes, a server that answers and accepts the key.
    /// Nothing is queued before this passes. Returns whether the server keeps the line (`features.line`).
    public func prepare() async throws -> ShortcutReadiness {
        // The key is read from the keychain now (after-first-unlock), not from what the model saw at launch.
        guard ctx.settings.apiKey() != nil else { throw ShortcutError.notSignedIn }
        let age = lastCapabilityCheck.map { ctx.clock.now().timeIntervalSince($0) }
        if age == nil || age! > Self.capabilityMaxAge || ctx.capabilities.kind == .unreachable {
            let fresh = await fetchCapabilities()
            guard let fresh, fresh.kind != .unreachable, fresh.kind != .notCobalt else { throw ShortcutError.serverUnreachable }
            model.apply(fresh)
            lastCapabilityCheck = ctx.clock.now()
        }
        let caps = ctx.capabilities
        switch caps.key {
        case .invalid: throw ShortcutError.keyRefused
        case .missing: throw ShortcutError.notSignedIn
        case .valid, .unknown: break
        }
        // Plain cobalt keeps no sessions: nothing a Shortcut could follow or hand back.
        if caps.kind == .plainCobalt { throw ShortcutError.failed(.unsupported) }
        return ShortcutReadiness(hasLine: caps.line, lineMax: caps.limits.lineMax)
    }

    /// `GET /capabilities`, capped at 5 seconds; nil when it did not answer in time.
    private func fetchCapabilities() async -> Capabilities? {
        let client = ctx.client
        let clock = ctx.clock
        return await withTaskGroup(of: Capabilities?.self) { group in
            group.addTask { await client.capabilities() }
            group.addTask {
                try? await clock.sleep(seconds: Self.capabilityTimeout)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    // MARK: - Links

    /// 15.3 step 3: every input through `LinkInfo.allLinks(in:)`, folded across inputs, at most 20. No input at all
    /// (Siri's "save my copied link", an empty field) reads the clipboard; input with no link in it is `noLink`.
    func resolveLinks(_ texts: [String]) throws -> [URL] {
        var inputs = texts.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        if inputs.isEmpty, let copied = clipboard.text(), !copied.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            inputs = [copied]
        }
        var found: [URL] = []
        var seen = Set<String>()
        outer: for text in inputs {
            for url in LinkInfo.allLinks(in: text, limit: Self.maxLinks) where seen.insert(url.absoluteString).inserted {
                found.append(url)
                if found.count >= Self.maxLinks { break outer }
            }
        }
        guard !found.isEmpty else { throw ShortcutError.noLink }
        return found
    }

    // MARK: - Save links

    /// "Save links" (15.3 steps 1 to 5). Hands the links to the server's line and returns what it answered; the wait
    /// (`waitUntilSaved`) and "open cobalt" are the caller's, told through `then`.
    ///
    /// - `allowDeviceLine`: the server has no line; the caller has already asked to continue in the foreground and was
    ///   not refused, so a job may wait in this device's line.
    /// - Throws the first failure when every link failed; some failing is `outcome.failures`.
    public func saveLinks(
        _ texts: [String], title: String? = nil, visibility: ShortcutVisibility = .appDefault,
        then: FollowUp = .leave, allowDeviceLine: Bool = false
    ) async throws -> ShortcutSaveOutcome {
        let began = ctx.clock.now()
        let ready: ShortcutReadiness
        let links: [URL]
        do {
            ready = try await prepare()
            if !ready.hasLine && !allowDeviceLine { throw ShortcutError.oldServer }
            links = try resolveLinks(texts)
        } catch {
            logRun(action: "save", inputs: texts.count, accepted: 0, failed: 0, began: began, outcome: "refused")
            throw error
        }
        let options = JobOptions(title: links.count == 1 ? title.flatMap(MediaTitle.clean) : nil, makePublic: visibility.makePublic)
        let jobs = queue.add(links.map(JobInput.link), via: .shortcut, options: options)
        let entries = zip(jobs, links).map { Entry(job: $0, label: Self.label(for: $1), link: $1, fileName: nil, title: options.title) }
        let outcome = await collect(entries, timeout: Self.acceptTimeout, lineMax: ready.lineMax)
        return try await conclude(outcome, action: "save", then: then, began: began)
    }

    // MARK: - Upload files

    /// "Upload files" (15.4): the bytes are copied into the app's inbox first (the system's temporary file may go as
    /// soon as the action returns), then each file is an upload job. Waits until the server has them (the upload
    /// itself), reporting bytes sent through `progress`.
    public func uploadFiles(
        _ files: [ShortcutFile], title: String? = nil, visibility: ShortcutVisibility = .appDefault,
        then: FollowUp = .leave, allowDeviceLine: Bool = false, cancel: ShortcutCancel = ShortcutCancel(),
        progress: ShortcutProgress? = nil
    ) async throws -> ShortcutSaveOutcome {
        let began = ctx.clock.now()
        let ready: ShortcutReadiness
        let staged: [(file: URL, name: String, bytes: Int64)]
        do {
            ready = try await prepare()
            if !ready.hasLine && !allowDeviceLine { throw ShortcutError.oldServer }
            guard !files.isEmpty else { throw ShortcutError.noFile }
            let caps = ctx.capabilities
            guard caps.studio, caps.upload else { throw ShortcutError.failed(.unsupported) }
            // The size is known before a byte is copied or sent (the server refuses above the limit anyway).
            let limit = caps.limits.maxUploadBytes
            for file in files {
                let bytes = Self.size(of: file)
                if limit > 0, bytes > limit { throw ShortcutError.fileTooLarge(limit: limit) }
            }
            staged = try await stage(files)
        } catch {
            logRun(action: "upload", inputs: files.count, accepted: 0, failed: 0, began: began, outcome: "refused")
            throw error
        }
        let options = JobOptions(title: staged.count == 1 ? title.flatMap(MediaTitle.clean) : nil, makePublic: visibility.makePublic)
        let jobs = queue.add(staged.map { JobInput.file($0.file, photosAssetID: nil) }, via: .shortcut, options: options)
        let entries = zip(jobs, staged).map {
            Entry(job: $0, label: $1.name, link: nil, fileName: $1.name, title: options.title)
        }
        let total = staged.reduce(Int64(0)) { $0 + $1.bytes }
        var sampler: Task<Void, Never>?
        if let progress {
            progress(0, total)
            let sizes = zip(jobs, staged.map(\.bytes)).map { ($0, $1) }
            sampler = Task { @MainActor [weak self] in
                while !Task.isCancelled, let self {
                    var sent: Int64 = 0
                    for (job, bytes) in sizes {
                        switch job.pipeline.state {
                        case .uploading(let p): sent += min(p.bytes, bytes)
                        case .idle, .failed, .fetching: break
                        default: sent += bytes                          // the bytes are on the server: saving, reading, ready
                        }
                    }
                    progress(min(sent, total), total)
                    try? await self.ctx.clock.sleep(seconds: 0.25)
                }
            }
        }
        // The stop button (or the task's cancellation) while the bytes go up: nothing is saved yet, so what has not
        // reached the server is cancelled, and what has (its turn came) finishes there and is announced (15.6).
        let jobIDs = jobs.map(\.id)
        let outcome = await withTaskCancellationHandler {
            await collect(entries, timeout: Self.uploadAcceptTimeout, lineMax: ready.lineMax)
        } onCancel: {
            cancel.cancel()
            Task { @MainActor in await self.stopJobs(jobIDs) }
        }
        sampler?.cancel()
        if cancel.isCancelled || Task.isCancelled {
            logRun(action: "upload", inputs: files.count, accepted: 0, failed: 0, began: began, outcome: "cancelled")
            throw CancellationError()
        }
        progress?(total, total)
        return try await conclude(outcome, action: "upload", then: then, began: began)
    }

    // MARK: - After the hand-over

    struct Entry {
        var job: Job
        var label: String
        var link: URL?
        var fileName: String?
        var title: String?
    }

    /// Waits (at most `timeout`) until every job has a server session or failed, and turns the answers into saves.
    func collect(_ entries: [Entry], timeout: Double, lineMax: Int) async -> ShortcutSaveOutcome {
        var seen = Set<UUID>()
        let ids = entries.map(\.job.id).filter { seen.insert($0).inserted }
        let answers = await queue.accepted(ids, timeout: timeout)
        var outcome = ShortcutSaveOutcome(saves: [], failures: [], total: entries.count)
        for entry in entries {
            let id = entry.job.id
            switch answers[id] ?? .stillLocal {
            case .onServer(let session, let postKey, let queued, _):
                // An image upload has no session: both ids are the item id, and nothing is left to follow.
                let isImage = entry.fileName != nil && session == postKey
                outcome.saves.append(save(entry, id: postKey, state: isImage ? .saved : (queued ? .queued : .saving)))
                outcome.jobIDs.append(id)
                outcome.sessions.append(isImage ? nil : session)
            case .failed(let failure):
                outcome.failures.append(ShortcutFailure(label: entry.label, error: .from(failure, lineMax: lineMax)))
            case .stillLocal:
                // Not answered in time: the job goes on in the app for as long as the system lets it, and the ledger
                // sends it again on the next launch (3.5). Nothing a Shortcut can look up yet.
                outcome.saves.append(save(entry, id: id.uuidString, state: .queued))
                outcome.jobIDs.append(id)
                outcome.sessions.append(nil)
            }
        }
        return outcome
    }

    private func save(_ entry: Entry, id: String, state: ShortcutSaveState) -> ShortcutSave {
        let service = entry.link.flatMap(LinkInfo.init)?.service
        let title: String
        if let custom = entry.title.flatMap(MediaTitle.clean) {
            title = custom
        } else if let name = entry.fileName {
            title = MediaTitle.stripExtension(name)
        } else {
            title = entry.label
        }
        return ShortcutSave(
            id: id, title: title, link: entry.link, service: service, state: state, created: entry.job.addedAt,
            hasVideo: entry.fileName.map { !Self.isImage(name: $0) } ?? true)
    }

    /// 15.3 step 5, and the registration of 15.2.5: all failed → the first failure's words; some failed → the outcome
    /// says which; work left on the server with the app away → one summary from Hark.
    private func conclude(_ outcome: ShortcutSaveOutcome, action: String, then: FollowUp, began: Date) async throws -> ShortcutSaveOutcome {
        if outcome.saves.isEmpty, let first = outcome.failures.first {
            logRun(action: action, inputs: outcome.total, accepted: 0, failed: outcome.failures.count, began: began, outcome: "failed")
            throw first.error
        }
        if then == .leave { await leaveToHark(outcome) }
        logRun(
            action: action, inputs: outcome.total, accepted: outcome.saves.count, failed: outcome.failures.count, began: began,
            outcome: outcome.failures.isEmpty ? "ok" : "partial", then: then)
        return outcome
    }

    /// 15.2.5: the action returns with work left on the server and cobalt is not the active app, so one
    /// `PUT /studio/line/notify` makes the server send one Hark message when all of it is done (17.8). Nothing is sent
    /// while cobalt is on screen (the owner sees it) or when there is nothing on the server.
    public func leaveToHark(_ outcome: ShortcutSaveOutcome) async {
        guard !ctx.background.activity.isActive, outcome.sessions.contains(where: { $0 != nil }) else { return }
        await registerLineNotify(watching: outcome.sessions.compactMap { $0 }.count)
    }

    /// The summary opt-in, awaited (the process may be suspended the moment the action returns). On a server without a
    /// line each session gets its own opt-in, as `appLeft()` does.
    func registerLineNotify(watching: Int) async {
        if queue.lineMode == .server {
            guard let task = ctx.queueLineNotify() else { return }
            let seen = await task.value
            Telemetry.log(.info, .pipeline, "line notify", data: ["watching": .int(seen), "via": "shortcut"])
        } else {
            queue.appLeft()
        }
    }

    /// "Open cobalt" (15.3 step 7): the caller has brought the app forward; this shows the tray (never a focus).
    public func openTray() {
        model.open(Self.jobsURL)
    }

    // MARK: - Files

    /// Copies each file into the inbox (coordinated, off the main thread). The pipeline sees a file already under the
    /// inbox and does not copy it again; the ledger records this copy, so a relaunch can still send it.
    private func stage(_ files: [ShortcutFile]) async throws -> [(file: URL, name: String, bytes: Int64)] {
        var out: [(URL, String, Int64)] = []
        for file in files {
            let name = SafeFileName.clean(file.name, fallback: "file")
            let destination = ctx.store.inboxURL(for: name)
            let source = file.source
            do {
                let bytes = try await Task.detached(priority: .userInitiated) { try Self.copy(source, to: destination) }.value
                out.append((destination, destination.lastPathComponent, bytes))
            } catch {
                for staged in out { try? FileManager.default.removeItem(at: staged.0) }
                throw ShortcutError.failed(.server(code: "error.app.file_unreadable"))
            }
        }
        return out
    }

    nonisolated private static func copy(_ source: ShortcutFile.Source, to destination: URL) throws -> Int64 {
        let fm = FileManager.default
        try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        switch source {
        case .data(let data):
            try data.write(to: destination, options: .atomic)
            return Int64(data.count)
        case .url(let url):
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            var coordinationError: NSError?
            var copyError: Error?
            NSFileCoordinator(filePresenter: nil).coordinate(readingItemAt: url, options: .withoutChanges, error: &coordinationError) { readable in
                do {
                    if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
                    try fm.copyItem(at: readable, to: destination)
                } catch {
                    copyError = error
                }
            }
            if let error = coordinationError ?? copyError { throw error }
            return ((try? fm.attributesOfItem(atPath: destination.path)[.size]) as? NSNumber)?.int64Value ?? 0
        }
    }

    nonisolated static func size(of file: ShortcutFile) -> Int64 {
        switch file.source {
        case .data(let data): return Int64(data.count)
        case .url(let url):
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            return ((try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? NSNumber)?.int64Value ?? 0
        }
    }

    nonisolated static func isImage(name: String) -> Bool {
        let type = MIME.type(forFileName: name)
        return type.hasPrefix("image/") && type != "image/gif"
    }

    private static func label(for link: URL) -> String {
        guard let info = LinkInfo(link) else { return link.absoluteString }
        return "\(info.service) · \(info.ref)"
    }

    // MARK: - Telemetry

    /// `shortcut run` (CONTRACT-PARALLEL 8): counts and services only, never a link, title or file name.
    func logRun(
        action: String, inputs: Int, accepted: Int, failed: Int, began: Date, outcome: String, then: FollowUp? = nil,
        waited: Bool = false
    ) {
        let now = ctx.clock.now()
        let mode = ctx.background.activity.isActive ? "foreground" : "background"
        Telemetry.log(.info, .pipeline, "shortcut run", data: [
            "action": .string(action), "inputs": .int(inputs), "accepted": .int(accepted), "failed": .int(failed),
            "mode": .string(mode), "waitedMs": .int(Int(now.timeIntervalSince(began) * 1000)), "outcome": .string(outcome),
            "waits": .bool(waited || then == .wait),
            "concurrent": .int(queue.live.count), "line": .string(queue.lineMode == .server ? "server" : "device"),
        ])
    }
}

/// The system pasteboard, for an action started with no input ("Save my copied link with cobalt").
@MainActor
public struct SystemShortcutClipboard: ShortcutClipboard {
    public init() {}

    public func text() -> String? {
        #if canImport(UIKit)
        return UIPasteboard.general.string ?? UIPasteboard.general.url?.absoluteString
        #elseif canImport(AppKit)
        return NSPasteboard.general.string(forType: .string)
        #else
        return nil
        #endif
    }
}
