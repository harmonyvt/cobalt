import Foundation
import Observation

// The editor's list and its open project (apple/CONTRACT-EDITOR.md 3.6): the projects, this key's recent renders, and the one
// `EditSession` that is open. `AppModel.editor`.

/// What `create(from:)` could not put on the timeline.
public struct EditLeftOut: Sendable, Equatable {
    public var photosAndGifs: Int
    public var notOnServer: Int

    public init(photosAndGifs: Int = 0, notOnServer: Int = 0) {
        self.photosAndGifs = photosAndGifs
        self.notOnServer = notOnServer
    }

    /// Nothing was left out.
    public var isEmpty: Bool { photosAndGifs == 0 && notOnServer == 0 }
}

@MainActor @Observable
public final class EditorStore {
    public enum ListState: Equatable, Sendable { case idle, loading, loaded, failed(EditError) }

    /// Summaries, newest updated first.
    public private(set) var projects: [EditProject] = []
    public private(set) var listState: ListState = .idle
    /// This key's recent renders (the list's, plus the ones this device started or watched).
    public private(set) var renders: [EditRender] = []
    /// The open project; the presenters show the editor while this is non-nil.
    public var session: EditSession?

    @ObservationIgnored private let ctx: PipelineContext
    @ObservationIgnored private let cache: EditSourceCache
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var opening = false
    @ObservationIgnored private var refreshing = false
    /// Every batch of renders merged (the Live Activities of renders, `EditLiveManager.observe`); wired by `AppModel`.
    @ObservationIgnored var onRenders: (@MainActor ([EditRender]) -> Void)?

    static let maxTitleCodePoints = 60
    static let rendersLimit = 20

    init(context: PipelineContext, directory: URL? = nil) {
        self.ctx = context
        let dir = directory
            ?? (context.isPreview
                ? FileManager.default.temporaryDirectory.appendingPathComponent("capystore-editor-preview", isDirectory: true)
                : EditSourceCache.defaultDirectory)
        var provider: (@Sendable @MainActor (String) async -> URL?)? = nil
        if context.isPreview {
            provider = { @Sendable @MainActor id in await PreviewEditorMedia.shared.url(forFile: id) }
        }
        self.cache = EditSourceCache(
            directory: dir, client: { context.client }, provider: provider)
    }

    private var editorClient: (any EditorClient)? { ctx.client as? any EditorClient }

    /// `capabilities.editor` and a client that speaks the routes.
    public var isAvailable: Bool { ctx.capabilities.editor && editorClient != nil }

    // MARK: the list

    /// `GET /edits`, then `GET /edits/renders?limit=20`. A failure keeps what was loaded; the renders are best effort.
    public func refresh() async {
        guard isAvailable, let client = editorClient, !refreshing else { return }
        refreshing = true
        defer { refreshing = false }
        let started = generation
        if listState != .loaded { listState = .loading }
        do {
            let list = try await client.editProjects()
            guard started == generation else { return }
            projects = Self.newestFirst(list)
            listState = .loaded
        } catch {
            guard started == generation else { return }
            listState = .failed(EditError.from(error))
            return
        }
        if let fresh = try? await client.editRenders(limit: Self.rendersLimit), started == generation {
            mergeRenders(fresh)
        }
    }

    static func newestFirst(_ list: [EditProject]) -> [EditProject] {
        list.sorted { $0.updatedAt != $1.updatedAt ? $0.updatedAt > $1.updatedAt : $0.id < $1.id }
    }

    /// The render with this id, from the newest copy this device knows.
    public func render(_ id: String) -> EditRender? { renders.first { $0.id == id } }

    /// Adds renders to `renders`, keeping the fresher copy of each, newest first.
    func mergeRenders(_ incoming: [EditRender]) {
        var byID = Dictionary(renders.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for r in incoming {
            if let mine = byID[r.id], mine.isFresher(than: r) { continue }
            byID[r.id] = r
        }
        renders = byID.values.sorted { $0.createdAt != $1.createdAt ? $0.createdAt > $1.createdAt : $0.id < $1.id }
        onRenders?(incoming)
    }

    // MARK: create

    /// `edit` in the library: the picks' videos in tap order (each post's original video; a gallery's video items in item order),
    /// a new project (31.2.1), then opens it. Returns what was left out.
    public func create(from picks: [MediaItem]) async throws(EditError) -> EditLeftOut {
        guard isAvailable, let client = editorClient else { throw .off }
        var left = EditLeftOut()
        var wanted: [Wanted] = []
        var locals: [(String, URL)] = []

        func take(_ r: Rendition) {
            guard let file = r.file else {
                left.notOnServer += 1
                return
            }
            // uploads (and a few saves) have no length or size on the server: they are measured below, not left out
            let known = [r.duration, r.local?.duration, file.duration].compactMap { $0 }.first(where: { $0.isFinite && $0 > 0 })
            var display: PixelSize?
            if let w = r.width ?? file.width, let h = r.height ?? file.height, w > 0, h > 0 { display = PixelSize(w: w, h: h) }
            let source = EditSource(
                id: file.id, name: file.name, kind: .video, contentType: file.contentType, width: display?.w, height: display?.h,
                duration: known, bytes: file.bytes, posterURL: file.posterURL)
            wanted.append(Wanted(source: source, duration: known, display: display))
            if let url = r.local?.fileURL, r.local?.isOffline == true { locals.append((file.id, url)) }
        }

        for pick in picks {
            if pick.itemCount >= 2 || pick.kind == .gallery {
                for item in pick.items {
                    switch item.itemType {
                    case .video?: take(item)
                    case .photo?, .gif?: left.photosAndGifs += 1
                    case nil: left.notOnServer += 1
                    }
                }
            } else if let video = pick.video, pick.kind != .photo {
                take(video)
            } else if pick.kind == .photo || pick.kind == .webp {
                left.photosAndGifs += 1
            } else {
                left.notOnServer += 1
            }
        }

        // the device's copies first, so a measure reads them instead of downloading
        for (id, url) in locals { await cache.register(local: url, for: id) }
        // every file with no known length is measured at once (each its own task); the results are read in pick order
        let measurer = cache
        let measuring: [Measuring?] = wanted.map { w -> Measuring? in
            guard w.duration == nil else { return nil }
            let source = w.source
            return Measuring { try await measurer.measure(source) }
        }
        var clips: [EditClip] = []
        var first: PixelSize?
        for (w, task) in zip(wanted, measuring) {
            var duration = w.duration
            var display = w.display
            if let task {
                guard let measured = try? await task.value, measured.duration > 0 else {
                    left.notOnServer += 1                     // the file could not be fetched or read
                    continue
                }
                duration = measured.duration
                display = display ?? measured.display
            }
            guard let duration, duration > 0 else {
                left.notOnServer += 1
                continue
            }
            if first == nil, let display { first = display }
            clips.append(EditClip.added(item: w.source.id, duration: EditJSON.time(duration)))
        }
        guard !clips.isEmpty else { throw .invalid(.empty) }
        if clips.count > ctx.capabilities.limits.editMaxClips { throw .invalid(.tooManyClips) }

        let canvas = first.map { EditCanvas.forFirstVideo(width: $0.w, height: $0.h) }
            ?? EditCanvas(shape: .story, resolution: .p1080, fps: 30)
        let timeline = EditTimeline.new(canvas: canvas, main: clips)
        let title = Self.title(for: picks.first)

        let created: EditProject
        do { created = try await client.createEditProject(title: title, timeline: timeline) } catch { throw EditError.from(error) }
        upsert(created)
        try await open(created.id)
        return left
    }

    private typealias Measuring = Task<(duration: Double, display: PixelSize?), any Error>

    /// A video `create(from:)` puts on the timeline: its file, and its length and size when the library knows them.
    private struct Wanted {
        var source: EditSource
        var duration: Double?
        var display: PixelSize?
    }

    /// The project's name: the post's custom title, else its file name without the extension, cut to 60 code points; else
    /// "untitled edit".
    static func title(for pick: MediaItem?) -> String {
        guard let pick else { return "untitled edit" }
        var raw = pick.customTitle
        if raw == nil, let name = pick.fileName {
            let stripped = MediaTitle.stripExtension(name).trimmingCharacters(in: .whitespacesAndNewlines)
            if !stripped.isEmpty { raw = stripped }
        }
        guard let raw, !raw.isEmpty else { return "untitled edit" }
        var scalars = String.UnicodeScalarView()
        for s in raw.unicodeScalars.prefix(maxTitleCodePoints) { scalars.append(s) }
        let cut = String(scalars).trimmingCharacters(in: .whitespacesAndNewlines)
        return cut.isEmpty ? "untitled edit" : cut
    }

    // MARK: open and close

    /// Opens a project: reads it with its files and shows the editor. A project already open is closed first (its autosave
    /// flushed).
    public func open(_ projectID: String) async throws(EditError) {
        guard isAvailable, let client = editorClient else { throw .off }
        if let current = session, current.project.id == projectID { return }
        guard !opening else { return }
        opening = true
        defer { opening = false }
        if session != nil {
            guard await close() else { throw .other("unsaved") }
        }
        let started = generation
        let fetched: (EditProject, [String: EditSource])
        do { fetched = try await client.editProject(id: projectID) } catch { throw EditError.from(error) }
        let project = fetched.0, sources = fetched.1
        guard started == generation else { throw .other("cancelled") }
        guard let timeline = project.timeline else { throw .other("invalid response") }
        var summary = project
        summary.timeline = nil
        upsert(summary)
        if let r = project.render { mergeRenders([r]) }
        session = EditSession(
            project: summary, timeline: timeline, sources: sources, context: ctx, cache: cache,
            onProject: { [weak self] p in self?.upsert(p) },
            onRender: { [weak self] r in self?.mergeRenders([r]) })
    }

    /// Flushes the autosave (3 s at most), then closes the editor. False: unsaved changes remain and the editor stays open
    /// (`closeAnyway()` leaves them).
    public func close() async -> Bool {
        guard let current = session else { return true }
        let saved = await current.settle()
        if case .conflict = current.saveState { return false }
        guard saved else { return false }
        finishClose(current)
        return true
    }

    /// Closes the editor with whatever is unsaved lost ("close anyway").
    public func closeAnyway() {
        if let current = session { finishClose(current) }
    }

    private func finishClose(_ current: EditSession) {
        if let r = current.activeRender { mergeRenders([r]) }
        current.tearDown()
        session = nil
    }

    // MARK: projects

    public func rename(_ projectID: String, to title: String) async throws(EditError) {
        guard let client = editorClient else { throw .off }
        let clean = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { throw .other("title") }
        let updated: EditProject
        do { updated = try await client.renameEditProject(id: projectID, title: String(clean.unicodeScalars.prefix(Self.maxTitleCodePoints))) }
        catch { throw EditError.from(error) }
        upsert(updated)
        if let s = session, s.project.id == projectID { s.adoptTitle(updated.title, revision: updated.revision) }
    }

    public func delete(_ projectID: String) async throws(EditError) {
        guard let client = editorClient else { throw .off }
        do { try await client.deleteEditProject(id: projectID) } catch {
            let e = EditError.from(error)
            if case .notFound = e {} else { throw e }
        }
        projects.removeAll { $0.id == projectID }
        if let s = session, s.project.id == projectID {
            s.tearDown()
            session = nil
        }
    }

    public func cancel(render id: String) async throws(EditError) {
        guard let client = editorClient else { throw .off }
        do {
            let r = try await client.cancelEditRender(id: id)
            mergeRenders([r])
            session?.noteRender(r)
        } catch {
            let e = EditError.from(error)
            if case .finished = e, let fresh = try? await client.editRender(id: id) {
                mergeRenders([fresh])
                session?.noteRender(fresh)
            }
            throw e
        }
    }

    /// Sends the render of a project that is not open (the queue's "try again" opens it instead; this is for the list).
    func upsert(_ project: EditProject) {
        var p = project
        p.timeline = nil
        if let i = projects.firstIndex(where: { $0.id == p.id }) { projects[i] = p } else { projects.append(p) }
        projects = Self.newestFirst(projects)
        if let r = p.render { mergeRenders([r]) }
    }

    // MARK: app events

    /// The capabilities changed (`AppModel.apply`): the editor went away, or came.
    func capabilitiesChanged() {
        if !isAvailable {
            generation += 1
            projects = []
            renders = []
            listState = .idle
            guard let s = session else { return }
            // never lose edits: flush the autosave, then close; a failed flush leaves the editor open
            Task { @MainActor [weak self] in
                let saved = await s.settle()
                guard let self, self.session === s, !self.isAvailable else { return }
                if saved {
                    self.finishClose(s)
                }
            }
        }
    }

    /// The server or key changed: forget everything of the old one.
    func reset() {
        generation += 1
        if let s = session {
            s.tearDown()
            session = nil
        }
        projects = []
        renders = []
        listState = .idle
        Task { [cache] in await cache.cancelAll(); await cache.dropDecoded() }
    }
}
