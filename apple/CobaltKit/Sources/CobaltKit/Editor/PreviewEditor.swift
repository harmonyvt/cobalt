import CoreGraphics
import Foundation
import Synchronization

// The editor in previews and tests (apple/CONTRACT-EDITOR.md 3.8): a server with `features.editor` and two projects, "beach day
// edit" and "cat compilation". Saves check the revision and the timeline as the real routes do (31.12); a render moves through its
// states on the client's clock, about 20 s long (times `timeScale`).

enum PreviewEditorIDs {
    static let pier = "PrEvIeWedSrc0001"
    static let surf = "PrEvIeWedSrc0002"
    static let sunset = "PrEvIeWedSrc0003"
    static let friends = "PrEvIeWedSrc0004"
    static let dance = "PrEvIeWedSrc0005"
    static let photo = "PrEvIeWedSrc0006"
    static let beach = "PrEvIeWedPrj0001"
    static let cats = "PrEvIeWedPrj0002"
    static let catsRender = "PrEvIeWedRnd0001"
    /// The render a `.editorRendering` server is already making.
    static let liveRender = "PrEvIeWedRnd0002"
}

extension PreviewScenario {
    /// The preview server has `features.editor`.
    var hasEditor: Bool {
        switch self {
        case .happy, .renditions, .editorEmpty, .editorRendering, .editorRenderFails, .editorConflict, .editorFail: return true
        default: return false
        }
    }
}

extension PreviewData {
    /// The six library files the preview projects name, by id.
    static func editorSources() -> [String: EditSource] {
        func poster(_ id: String) -> URL { mediaBase.appendingPathComponent("\(id).jpg") }
        let list = [
            EditSource(id: PreviewEditorIDs.pier, name: "pier.mp4", kind: .video, contentType: "video/mp4", width: 1280, height: 720,
                       duration: 12, bytes: 9_400_000, posterURL: poster(PreviewEditorIDs.pier)),
            EditSource(id: PreviewEditorIDs.surf, name: "surf.mp4", kind: .video, contentType: "video/mp4", width: 1280, height: 720,
                       duration: 10, bytes: 7_800_000, posterURL: poster(PreviewEditorIDs.surf)),
            EditSource(id: PreviewEditorIDs.sunset, name: "sunset.mov", kind: .video, contentType: "video/quicktime", width: 1920,
                       height: 1080, duration: 5.5, bytes: 6_100_000, posterURL: poster(PreviewEditorIDs.sunset)),
            EditSource(id: PreviewEditorIDs.friends, name: "friends.mp4", kind: .video, contentType: "video/mp4", width: 1080,
                       height: 1920, duration: 4, bytes: 5_200_000, posterURL: poster(PreviewEditorIDs.friends)),
            EditSource(id: PreviewEditorIDs.dance, name: "dance.gif", kind: .gif, contentType: "image/gif", width: 480, height: 360,
                       duration: 1.2, bytes: 640_000, posterURL: poster(PreviewEditorIDs.dance)),
            EditSource(id: PreviewEditorIDs.photo, name: "harbour.png", kind: .photo, contentType: "image/png", width: 1600,
                       height: 1200, bytes: 2_100_000, posterURL: poster(PreviewEditorIDs.photo)),
        ]
        return Dictionary(uniqueKeysWithValues: list.map { ($0.id, $0) })
    }

    /// "beach day edit": 9:16, 1080p, 30; pier 0-12, surf 2-8.75 at 1.5x, sunset with a 9:16 crop, friends; dance.gif at 3 s for 3 s.
    static func editorBeachTimeline() -> EditTimeline {
        let crop = EditCrop.centred(.story, display: CGSize(width: 1920, height: 1080))
        return EditTimeline(
            canvas: EditCanvas(shape: .story, resolution: .p1080, fps: 30),
            main: [
                EditClip(id: "cPier0001", item: PreviewEditorIDs.pier, in: 0, out: 12),
                EditClip(id: "cSurf0001", item: PreviewEditorIDs.surf, in: 2, out: 8.75, speed: 1.5),
                EditClip(id: "cSunset01", item: PreviewEditorIDs.sunset, in: 0, out: 5.5, crop: crop),
                EditClip(id: "cFrnd0001", item: PreviewEditorIDs.friends, in: 0, out: 4),
            ],
            overlay: [
                EditOverlay(id: "cDance001", item: PreviewEditorIDs.dance, at: 3, in: 0, out: 3,
                            frame: EditFrame(x: 0.6, y: 0.05, w: 0.35), opacity: 1, volume: 1, muted: true),
            ])
    }

    /// "cat compilation": 16:9, 720p, 60; six clips, 21 s.
    static func editorCatsTimeline() -> EditTimeline {
        EditTimeline(
            canvas: EditCanvas(shape: .wide, resolution: .p720, fps: 60),
            main: [
                EditClip(id: "cCat00001", item: PreviewEditorIDs.pier, in: 0, out: 4),
                EditClip(id: "cCat00002", item: PreviewEditorIDs.surf, in: 0, out: 3),
                EditClip(id: "cCat00003", item: PreviewEditorIDs.sunset, in: 0, out: 5),
                EditClip(id: "cCat00004", item: PreviewEditorIDs.friends, in: 0, out: 4),
                EditClip(id: "cCat00005", item: PreviewEditorIDs.pier, in: 4, out: 8, speed: 2),
                EditClip(id: "cCat00006", item: PreviewEditorIDs.surf, in: 3, out: 6),
            ])
    }
}

final class PreviewEditorState: Sendable {
    /// A render the preview server is making: its state is derived from the clock.
    struct Running: Sendable {
        var id: String
        var projectID: String
        var revision: Int
        var title: String
        var secondsTotal: Double
        var createdAt: Date
        var fails: Bool
        var cancelledAt: Date?
    }

    /// How long a render takes, before `timeScale`.
    static let renderSeconds = 20.0
    /// The share of the render at which `.editorRenderFails` fails: progress 0.6.
    static let failAt = 0.2 + 0.7 * ((0.6 - 0.1) / 0.85)

    private struct State {
        var projects: [String: EditProject] = [:]       // summaries (no timeline)
        var timelines: [String: EditTimeline] = [:]
        var sources: [String: EditSource] = [:]
        var finished: [String: EditRender] = [:]        // seeded renders that are over
        var running: [String: Running] = [:]
        var renderOrder: [String] = []
        var calls: [String] = []
        var saves: [(String, Int)] = []                 // project id, base revision
        var listFails = false
        var conflictOnce = false
        var failSaves = 0
        var failWith: EditError = .offline
        var counter = 0
    }

    private let state = Mutex(State())

    var calls: [String] { state.withLock { $0.calls } }
    func record(_ call: String) { state.withLock { $0.calls.append(call) } }
    var saveCount: Int { state.withLock { $0.saves.count } }

    /// A library file the preview server now knows (a cutout made in the editor), so saves that name it pass.
    func addSource(_ source: EditSource) { state.withLock { $0.sources[source.id] = source } }
    func source(_ id: String) -> EditSource? { state.withLock { $0.sources[id] } }

    /// The stored timeline of a project (tests read what a save sent).
    func timeline(of id: String) -> EditTimeline? { state.withLock { $0.timelines[id] } }
    func project(_ id: String) -> EditProject? { state.withLock { $0.projects[id] } }

    /// Tests: the next `n` saves fail with `error` (default: no network) before the server looks at them.
    func failNextSaves(_ n: Int, with error: EditError = .offline) {
        state.withLock { s in
            s.failSaves = n
            s.failWith = error
        }
    }

    // MARK: seed

    func seed(_ scenario: PreviewScenario, now: Date, timeScale: Double) {
        state.withLock { s in
            s.sources = PreviewData.editorSources()
            s.listFails = scenario == .editorFail
            s.conflictOnce = scenario == .editorConflict
            if scenario == .editorEmpty || scenario == .editorFail { return }
            let beach = PreviewData.editorBeachTimeline()
            let cats = PreviewData.editorCatsTimeline()
            let day = 86_400.0
            s.projects[PreviewEditorIDs.beach] = Self.summary(
                id: PreviewEditorIDs.beach, title: "beach day edit", revision: 4, timeline: beach,
                created: now.addingTimeInterval(-3 * day), updated: now.addingTimeInterval(-2 * 3_600))
            s.timelines[PreviewEditorIDs.beach] = beach
            s.projects[PreviewEditorIDs.cats] = Self.summary(
                id: PreviewEditorIDs.cats, title: "cat compilation", revision: 7, timeline: cats,
                created: now.addingTimeInterval(-9 * day), updated: now.addingTimeInterval(-1 * day))
            s.timelines[PreviewEditorIDs.cats] = cats
            let seconds = EditTiming(cats).seconds
            s.finished[PreviewEditorIDs.catsRender] = EditRender(
                id: PreviewEditorIDs.catsRender, projectID: PreviewEditorIDs.cats, revision: 7, title: "cat compilation",
                status: .done, progress: 1, secondsDone: seconds, secondsTotal: seconds, itemID: "PrEvIeWedItm0001",
                posterURL: PreviewData.mediaBase.appendingPathComponent("PrEvIeWedItm0001.jpg"), bytes: 8_400_000, width: 1280,
                height: 720, duration: seconds, createdAt: now.addingTimeInterval(-1 * day), startedAt: now.addingTimeInterval(-1 * day + 2),
                finishedAt: now.addingTimeInterval(-1 * day + 22))
            s.renderOrder.append(PreviewEditorIDs.catsRender)
            if scenario == .editorRendering {
                let secondsTotal = EditTiming(beach).seconds
                s.running[PreviewEditorIDs.liveRender] = Running(
                    id: PreviewEditorIDs.liveRender, projectID: PreviewEditorIDs.beach, revision: 4, title: "beach day edit",
                    secondsTotal: secondsTotal, createdAt: now, fails: false, cancelledAt: nil)
                s.renderOrder.append(PreviewEditorIDs.liveRender)
            }
        }
    }

    private static func summary(
        id: String, title: String, revision: Int, timeline: EditTimeline, created: Date, updated: Date
    ) -> EditProject {
        EditProject(
            id: id, title: title, revision: revision, timeline: nil, canvas: timeline.canvas,
            duration: EditTiming(timeline).seconds, clipCount: timeline.main.count,
            coverURL: PreviewData.mediaBase.appendingPathComponent("\(timeline.main[0].item).jpg"), createdAt: created, updatedAt: updated)
    }

    // MARK: renders

    /// The render as it is at `now`.
    static func view(_ r: Running, now: Date, timeScale: Double, scenario: PreviewScenario) -> EditRender {
        let total = renderSeconds * max(0.01, timeScale)
        let t = max(0, now.timeIntervalSince(r.createdAt)) / total
        var out = EditRender(id: r.id, projectID: r.projectID, revision: r.revision, title: r.title, status: .queued,
                             secondsTotal: r.secondsTotal, createdAt: r.createdAt)
        let started = r.createdAt.addingTimeInterval(0.05 * total)
        if let cancelled = r.cancelledAt, now >= cancelled {
            out.status = .cancelled
            out.cancelRequested = true
            out.finishedAt = cancelled
            return out
        }
        if r.fails, t >= failAt {
            out.status = .error
            out.error = "error.edit.render_failed"
            out.progress = 0.6
            out.startedAt = started
            out.finishedAt = r.createdAt.addingTimeInterval(failAt * total)
            return out
        }
        switch t {
        case ..<0.05:
            out.status = .queued
            out.queueAhead = 0
        case ..<0.2:
            out.status = .preparing
            out.progress = 0.1 * ((t - 0.05) / 0.15)
            out.startedAt = started
        case ..<0.9:
            let f = (t - 0.2) / 0.7
            out.status = .rendering
            out.progress = 0.1 + 0.85 * f
            out.secondsDone = f * r.secondsTotal
            out.startedAt = started
        case ..<1:
            out.status = .finishing
            out.progress = 0.95
            out.secondsDone = r.secondsTotal
            out.startedAt = started
        default:
            out.status = .done
            out.progress = 1
            out.secondsDone = r.secondsTotal
            out.startedAt = started
            out.finishedAt = r.createdAt.addingTimeInterval(total)
            out.itemID = "PrEvIeWedItm" + String(r.id.suffix(4))
            out.posterURL = PreviewData.mediaBase.appendingPathComponent("\(out.itemID ?? "x").jpg")
            out.bytes = 6_200_000
            out.duration = r.secondsTotal
        }
        return out
    }

    private static func renders(_ s: State, now: Date, timeScale: Double, scenario: PreviewScenario) -> [EditRender] {
        s.renderOrder.compactMap { id -> EditRender? in
            if let r = s.finished[id] { return r }
            return s.running[id].map { view($0, now: now, timeScale: timeScale, scenario: scenario) }
        }
    }

    func renders(now: Date, timeScale: Double, scenario: PreviewScenario) -> [EditRender] {
        state.withLock { Self.renders($0, now: now, timeScale: timeScale, scenario: scenario) }
    }

    func render(_ id: String, now: Date, timeScale: Double, scenario: PreviewScenario) -> EditRender? {
        state.withLock { s in
            if let r = s.finished[id] { return r }
            return s.running[id].map { Self.view($0, now: now, timeScale: timeScale, scenario: scenario) }
        }
    }

    /// The file of a render that finished during this run, as a private library post (3.8: "then a new private library item
    /// appears"). The seeded "cat compilation" render is not one: the preview library stays the page the library tests know.
    func libraryPosts(now: Date, timeScale: Double, scenario: PreviewScenario) -> [LibraryPost] {
        let fresh = state.withLock { s in
            s.renderOrder.compactMap { id in s.running[id].map { Self.view($0, now: now, timeScale: timeScale, scenario: scenario) } }
        }
        return fresh.compactMap { r in
            guard r.status == .done, let item = r.itemID else { return nil }
            let name = "\(r.title).mp4"
            let file = LibraryFile(
                id: item, kind: .private, source: .saved, name: name, url: nil, contentType: "video/mp4", bytes: r.bytes,
                width: r.width, height: r.height, duration: r.duration, createdAt: r.finishedAt ?? r.createdAt, mediaName: nil,
                deletable: true, posterURL: r.posterURL)
            return LibraryPost(
                id: item, service: "upload", link: nil, title: name, duration: r.duration, width: r.width, height: r.height,
                createdAt: r.finishedAt ?? r.createdAt, session: nil, files: [file], customTitle: nil, posterURL: r.posterURL)
        }
    }

    // MARK: routes

    func list(now: Date, timeScale: Double, scenario: PreviewScenario) throws -> [EditProject] {
        try state.withLock { s in
            if s.listFails { throw EditError.unavailable }
            return s.projects.values.map { Self.withRender($0, in: s, now: now, timeScale: timeScale, scenario: scenario) }
        }
    }

    private static func withRender(_ p: EditProject, in s: State, now: Date, timeScale: Double, scenario: PreviewScenario) -> EditProject {
        var out = p
        out.render = renders(s, now: now, timeScale: timeScale, scenario: scenario)
            .filter { $0.projectID == p.id }.max { $0.createdAt < $1.createdAt }
        return out
    }

    func create(title: String?, timeline: EditTimeline, now: Date) throws -> EditProject {
        try state.withLock { s in
            if s.projects.count >= 200 { throw EditError.tooMany }
            if let problem = EditValidation.check(timeline, sources: s.sources).first(where: Self.refuses) { throw EditError.invalid(problem) }
            s.counter += 1
            let id = "PrEvIeWedNew" + String(format: "%04d", s.counter)
            let rounded = EditJSON.rounded(timeline)
            var p = Self.summary(id: id, title: title ?? "untitled edit", revision: 1, timeline: rounded, created: now, updated: now)
            s.projects[id] = p
            s.timelines[id] = rounded
            p.timeline = rounded
            return p
        }
    }

    func fetch(_ id: String, now: Date, timeScale: Double, scenario: PreviewScenario) throws -> (EditProject, [String: EditSource]) {
        try state.withLock { s in
            guard let p = s.projects[id], let t = s.timelines[id] else { throw EditError.notFound }
            var out = Self.withRender(p, in: s, now: now, timeScale: timeScale, scenario: scenario)
            out.timeline = t
            let named = Set(t.main.map(\.item) + t.overlay.map(\.item))
            return (out, s.sources.filter { named.contains($0.key) })
        }
    }

    /// The problems the server refuses a PUT for; the rest it only renders with.
    private static func refuses(_ p: EditProblem) -> Bool {
        switch p {
        case .sourceMissing, .notVideo, .unsupportedSource, .pastSourceEnd: return false
        default: return true
        }
    }

    func save(
        id: String, timeline: EditTimeline, baseRevision: Int, title: String?, now: Date, timeScale: Double, scenario: PreviewScenario
    ) throws -> EditProject {
        try state.withLock { s in
            guard var p = s.projects[id], let current = s.timelines[id] else { throw EditError.notFound }
            s.saves.append((id, baseRevision))
            if s.failSaves > 0 {
                s.failSaves -= 1
                throw s.failWith
            }
            if s.conflictOnce {
                s.conflictOnce = false
                p.revision += 1
                p.title = "beach day (iphone)"
                p.updatedAt = now
                s.projects[id] = p
                var theirs = Self.withRender(p, in: s, now: now, timeScale: timeScale, scenario: scenario)
                theirs.timeline = current
                throw EditError.conflict(theirs)
            }
            if baseRevision != p.revision {
                var theirs = Self.withRender(p, in: s, now: now, timeScale: timeScale, scenario: scenario)
                theirs.timeline = current
                throw EditError.conflict(theirs)
            }
            if let problem = EditValidation.check(timeline, sources: s.sources).first(where: Self.refuses) { throw EditError.invalid(problem) }
            let rounded = EditJSON.rounded(timeline)
            p.revision += 1
            p.updatedAt = now
            if let title { p.title = title }
            p.canvas = rounded.canvas
            p.duration = EditTiming(rounded).seconds
            p.clipCount = rounded.main.count
            if let first = rounded.main.first { p.coverURL = PreviewData.mediaBase.appendingPathComponent("\(first.item).jpg") }
            s.projects[id] = p
            s.timelines[id] = rounded
            return Self.withRender(p, in: s, now: now, timeScale: timeScale, scenario: scenario)
        }
    }

    func rename(id: String, title: String, now: Date, timeScale: Double, scenario: PreviewScenario) throws -> EditProject {
        try state.withLock { s in
            guard var p = s.projects[id] else { throw EditError.notFound }
            p.title = title
            p.revision += 1
            p.updatedAt = now
            s.projects[id] = p
            return Self.withRender(p, in: s, now: now, timeScale: timeScale, scenario: scenario)
        }
    }

    func delete(id: String) throws {
        try state.withLock { s in
            guard s.projects.removeValue(forKey: id) != nil else { throw EditError.notFound }
            s.timelines[id] = nil
        }
    }

    func startRender(
        id: String, revision: Int, now: Date, timeScale: Double, scenario: PreviewScenario
    ) throws -> EditRender {
        try state.withLock { s in
            guard let p = s.projects[id], let t = s.timelines[id] else { throw EditError.notFound }
            if revision != p.revision {
                var theirs = Self.withRender(p, in: s, now: now, timeScale: timeScale, scenario: scenario)
                theirs.timeline = t
                throw EditError.conflict(theirs)
            }
            if let problem = EditValidation.check(t, sources: s.sources).first { throw EditError.invalid(problem) }
            let all = Self.renders(s, now: now, timeScale: timeScale, scenario: scenario)
            if let same = all.first(where: { $0.projectID == id && $0.revision == revision && $0.isActive }) { return same }
            let active = all.filter(\.isActive).count
            if active >= 20 { throw EditError.queueFull }
            s.counter += 1
            let rid = "PrEvIeWedRnd" + String(format: "%04d", 100 + s.counter)
            let running = Running(
                id: rid, projectID: id, revision: p.revision, title: p.title, secondsTotal: EditTiming(t).seconds, createdAt: now,
                fails: scenario == .editorRenderFails, cancelledAt: nil)
            s.running[rid] = running
            s.renderOrder.append(rid)
            return Self.view(running, now: now, timeScale: timeScale, scenario: scenario)
        }
    }

    func cancel(id: String, now: Date, timeScale: Double, scenario: PreviewScenario) throws -> EditRender {
        try state.withLock { s in
            if s.finished[id] != nil { throw EditError.finished }
            guard var r = s.running[id] else { throw EditError.notFound }
            let seen = Self.view(r, now: now, timeScale: timeScale, scenario: scenario)
            if seen.status == .cancelled { return seen }
            if seen.isEnded { throw EditError.finished }
            r.cancelledAt = now
            s.running[id] = r
            return Self.view(r, now: now, timeScale: timeScale, scenario: scenario)
        }
    }
}

extension PreviewClient: EditorClient {
    public func editProjects() async throws -> [EditProject] {
        editorState.record("GET /edits")
        return try editorState.list(now: clock.now(), timeScale: timeScale, scenario: scenario)
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    public func createEditProject(title: String?, timeline: EditTimeline) async throws -> EditProject {
        editorState.record("POST /edits")
        return try editorState.create(title: title, timeline: timeline, now: clock.now())
    }

    public func editProject(id: String) async throws -> (EditProject, [String: EditSource]) {
        editorState.record("GET /edits/\(id)")
        return try editorState.fetch(id, now: clock.now(), timeScale: timeScale, scenario: scenario)
    }

    public func saveEditProject(id: String, timeline: EditTimeline, baseRevision: Int, title: String?) async throws -> EditProject {
        editorState.record("PUT /edits/\(id)")
        return try editorState.save(
            id: id, timeline: timeline, baseRevision: baseRevision, title: title, now: clock.now(), timeScale: timeScale,
            scenario: scenario)
    }

    public func renameEditProject(id: String, title: String) async throws -> EditProject {
        editorState.record("PATCH /edits/\(id)")
        return try editorState.rename(id: id, title: title, now: clock.now(), timeScale: timeScale, scenario: scenario)
    }

    public func deleteEditProject(id: String) async throws {
        editorState.record("DELETE /edits/\(id)")
        try editorState.delete(id: id)
    }

    public func renderEdit(id: String, revision: Int, notify: Bool) async throws -> EditRender {
        editorState.record("POST /edits/\(id)/render")
        return try editorState.startRender(id: id, revision: revision, now: clock.now(), timeScale: timeScale, scenario: scenario)
    }

    public func editRenders(limit: Int) async throws -> [EditRender] {
        editorState.record("GET /edits/renders")
        return Array(editorState.renders(now: clock.now(), timeScale: timeScale, scenario: scenario)
            .sorted { $0.createdAt > $1.createdAt }.prefix(limit))
    }

    public func editRender(id: String) async throws -> EditRender {
        editorState.record("GET /edits/renders/\(id)")
        guard let r = editorState.render(id, now: clock.now(), timeScale: timeScale, scenario: scenario) else { throw EditError.notFound }
        return r
    }

    public func cancelEditRender(id: String) async throws -> EditRender {
        editorState.record("DELETE /edits/renders/\(id)")
        return try editorState.cancel(id: id, now: clock.now(), timeScale: timeScale, scenario: scenario)
    }
}

extension AppModel {
    /// A preview model whose server has the editor (`scenario`: `.happy`, `.editorEmpty`, `.editorRendering`,
    /// `.editorRenderFails`, `.editorConflict`, `.editorFail`), with the project `open` already open (its id, or "beach"
    /// and "cats" for the two seeded ones). The screens' previews use it.
    @MainActor
    public static func previewEditor(_ scenario: PreviewScenario = .happy, open: String? = nil) -> AppModel {
        let model = AppModel.preview(scenario)
        if let open {
            let id = open == "beach" ? PreviewEditorIDs.beach : (open == "cats" ? PreviewEditorIDs.cats : open)
            Task { @MainActor in
                await model.editor.refresh()
                try? await model.editor.open(id)
            }
        }
        return model
    }
}
