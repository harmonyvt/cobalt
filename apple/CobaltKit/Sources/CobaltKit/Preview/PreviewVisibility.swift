import Foundation
import Synchronization

/// How the preview server of `AppModel.previewVisibility(_:)` behaves (CONTRACT-VISIBILITY.md): a server with
/// `features.visibility` whose `PATCH …/visibility` works, fails on its first call per file, or always fails; or
/// (`.off`) one that does not have the feature at all.
public enum VisibilityPreviewMode: Sendable, Equatable { case off, working, failsOnce, failing }

/// What the preview "server" remembers about the switches made so far: each file's state, the link it was given
/// (kept when switched off, so the same link comes back), and every call.
final class PreviewVisibilityState: Sendable {
    private struct State {
        var visibility: [String: Visibility] = [:]
        var urls: [String: URL] = [:]
        var calls: [String] = []                     // "<file id> on|off", in order
        var saves: [String] = []                     // "create public" / "create -" / "upload public" / "upload -"
    }

    private let state = Mutex(State())

    var calls: [String] { state.withLock { $0.calls } }
    /// What each save asked for: `public` when the call carried `public: true`, `-` when it sent nothing.
    var saves: [String] { state.withLock { $0.saves } }

    func recordSave(_ what: String, public makePublic: Bool?) {
        state.withLock { $0.saves.append("\(what) \(makePublic == true ? "public" : "-")") }
    }

    /// Records a call and returns how many came in for `id` so far (this one included).
    func recordCall(_ id: String, public makePublic: Bool) -> Int {
        state.withLock { s in
            s.calls.append("\(id) \(makePublic ? "on" : "off")")
            return s.calls.filter { $0.hasPrefix("\(id) ") }.count
        }
    }

    /// The link a file is public at: the one it had, else one made for it (stable from then on).
    private static func link(for file: LibraryFile) -> URL {
        file.url ?? file.mediaName.map { PreviewData.mediaBase.appendingPathComponent($0) }
            ?? PreviewData.mediaBase.appendingPathComponent("PrEvIeWv\(file.id.suffix(6)).mp4")
    }

    /// `file`, as the "server" has it now.
    func applying(to file: LibraryFile) -> LibraryFile {
        state.withLock { s in
            var out = file
            if let known = s.urls[file.id], out.url == nil { out.url = known }
            guard let v = s.visibility[file.id] else { return out }
            out.wireVisibility = v
            out.url = v == .public ? (s.urls[file.id] ?? Self.link(for: file)) : nil
            return out
        }
    }

    /// Switches `file` and returns it as it now is.
    func set(_ file: LibraryFile, public makePublic: Bool) -> LibraryFile {
        state.withLock { s in
            var out = file
            let link = s.urls[file.id] ?? Self.link(for: file)
            s.urls[file.id] = link
            s.visibility[file.id] = makePublic ? .public : .private
            out.wireVisibility = makePublic ? .public : .private
            out.url = makePublic ? link : nil
            return out
        }
    }
}

extension PreviewData {
    /// `libraryPage` as `GET /library?v=2` lists it: one file per rendition, no separate hosted copy. The first
    /// post's video and the x post's video are public (their links are the old hosted copies'); the other
    /// originals are private; every webp is public but `PrEvIeWitem000013`, switched private (no link, a lock).
    /// Every file says it can be switched.
    static func libraryPageV2(now: Date) -> LibraryPage {
        var page = libraryPage(now: now)
        let publicVideoLinks: [String: String] = [
            "Dd55fEyN1Yy": "https://media.capybaraharmony.com/PrEvIeW011.mp4",
            "2105435404002562056": "https://media.capybaraharmony.com/PrEvIeW012.mp4",
        ]
        page.posts = page.posts.map { post in
            var p = post
            var files: [LibraryFile] = []
            let host = post.files.first { $0.source == .host }
            for original in post.files where original.source != .host {
                var f = original
                f.canToggleVisibility = true
                if f.role == .privateCopy {
                    let link = host?.url ?? publicVideoLinks[post.id].flatMap(URL.init(string:))
                    f.wireVisibility = link == nil ? .private : .public
                    f.url = link
                    if f.posterURL == nil { f.posterURL = host?.posterURL }
                } else if f.id == "PrEvIeWitem000013" {
                    f.wireVisibility = .private
                    f.url = nil                                   // its name stays: `media_name` is the public name
                } else {
                    f.wireVisibility = .public
                }
                files.append(f)
            }
            p.files = files
            p.visibility = files.first { $0.role == .privateCopy }?.visibility ?? .public
            return p
        }
        return page
    }
}

extension AppModel {
    /// Every screen of the public/private switch previews against this: `libraryPage` listed as `v=2` (one file per
    /// rendition, a private webp, public and private videos), a server with `features.visibility` and
    /// `public_default`, and a switch that works, fails once per file, or always fails.
    public static func previewVisibility(_ mode: VisibilityPreviewMode = .working) -> AppModel {
        makePreviewVisibility(mode, timeScale: 1, clock: SystemClock())
    }

    static func makePreviewVisibility(_ mode: VisibilityPreviewMode, timeScale: Double, clock: any PipelineClock) -> AppModel {
        let ctx = PipelineContext.preview(.renditions, timeScale: timeScale, clock: clock)
        let client = PreviewClient(scenario: .renditions, timeScale: timeScale, clock: clock, visibility: mode)
        ctx.client = client
        var caps = ctx.capabilities
        caps.visibility = mode != .off
        caps.publicDefault = mode != .off
        ctx.capabilities = caps
        let page = mode == .off ? PreviewData.libraryPage(now: clock.now()) : PreviewData.libraryPageV2(now: clock.now())
        return AppModel(
            context: ctx, library: LibraryModel(context: ctx, seed: page),
            photosSync: PhotosSync.preview(.init(access: .album, enabled: false)),
            makeClient: { _ in client })
    }
}
