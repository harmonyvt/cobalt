#if DEBUG
import CobaltKit
import Foundation
import os

/// Evidence that the scene-level hooks (`.task`, `.onOpenURL`, `.onChange(of: scenePhase)`, the
/// notification-tap path) run. Debug builds only, and only with `-debugHooks 1`:
///
///   -debugHooks 1            log every hook to the `com.capybaraharmony.cobalt` / `hooks` category
///   -debugSeedJob <uuid>     put a failed job with that id in the job store, so
///                            `cobalt-apple://job/<uuid>` has something to open
///   -debugSeedVideo <path>   store a copy of that video file as the newest entry (an offline copy to remove)
///   -debugNotifyTap <url>    from `App.init` (before any window), deliver <url> the way a tap on a
///                            notification whose userInfo["url"] is <url> does
///   -previewDetail N         open the Nth media's detail over the shell (`DetailDebug`, below, has the
///                            flags that drive its states for screenshots)
///
/// Read them back with `log show --last 1m --info --predicate 'subsystem == "com.capybaraharmony.cobalt"'`
/// (macOS) or the same through `xcrun simctl spawn <device>` (iOS simulator).
@MainActor
enum DebugHooks {
    private static let logger = Logger(subsystem: "com.capybaraharmony.cobalt", category: "hooks")
    static let enabled = UserDefaults.standard.bool(forKey: "debugHooks")

    static func log(_ message: String) {
        guard enabled else { return }
        logger.notice("[hooks] \(message, privacy: .public)")
    }

    /// What the model looks like after a link was handed to it.
    static func describe(_ model: AppModel) -> String {
        "tab=\(model.selectedTab.rawValue) pipeline=\(String(describing: model.pipeline.state).prefix(60))"
    }

    /// Launch-time flags: the seeded job, then the simulated notification tap.
    static func runIfRequested(_ model: AppModel) {
        log("App.init")
        seedJobIfRequested(model)
        seedVideoIfRequested(model)
        PreviewClip.runIfRequested(model)
        DetailDebug.seedFilesIfRequested(model)
        if enabled, let raw = UserDefaults.standard.string(forKey: "debugNotifyTap"), let url = URL(string: raw) {
            log("simulated notification tap \(raw)")
            LinkInbox.shared.deliver(url)
        }
    }

    /// `-debugSeedVideo <path>`: stores a copy of that video file as the newest entry, so the media
    /// detail has an offline copy to remove. (On the Mac the path must be inside the app's sandbox.)
    private static func seedVideoIfRequested(_ model: AppModel) {
        guard enabled, let path = UserDefaults.standard.string(forKey: "debugSeedVideo") else { return }
        guard let info = try? JSONDecoder().decode(MediaInfo.self, from: Data(#"{"name":"debug clip","isImage":false}"#.utf8)) else { return }
        Task {
            do {
                let stored = try await model.store.add(
                    file: URL(fileURLWithPath: path), kind: .original, media: info, sessionID: nil, link: nil,
                    remoteURL: nil, move: false, keep: false)
                log("seeded video \(stored.id) file=\(stored.fileURL != nil)")
            } catch {
                log("seeding video failed: \(error)")
            }
        }
    }

    private static func seedJobIfRequested(_ model: AppModel) {
        guard enabled, let raw = UserDefaults.standard.string(forKey: "debugSeedJob"), let id = UUID(uuidString: raw) else { return }
        // SharedJob has no public memberwise init; it is Codable, so build it from JSON.
        let json = """
        {"id":"\(id.uuidString)","origin":"app","stage":{"failed":{"code":"error.api.fetch.fail"}},\
        "wantsTrim":false,"pickedUp":false,"updatedAt":\(Date().timeIntervalSinceReferenceDate)}
        """
        do {
            model.jobs.upsert(try JSONDecoder().decode(SharedJob.self, from: Data(json.utf8)))
        } catch {
            log("seeding job failed: \(error)")
            return
        }
        log("seeded job \(id)")
    }
}

/// The media detail's launch flags (simulator evidence, debug builds only). The detail itself is opened by
/// `-previewDetail N` (AppShell) or `-previewOpenFirst YES` (the orbit); these set what it shows:
///
///   -debugDetailFiles 0,1,2,3   give those renditions of the `.renditions` media a file on disk: 0 is the video,
///                               1... its webps oldest to newest (needs `-previewClip` and `-previewWebp`);
///                               the rest stay evicted
///   -debugDetailFilesOthers 1   also fill every other media (plain saves with the clip, the webp-only one with the webp)
///   -previewDetailTab I         open on the Ith tab
///   -previewDetailConfirm K     ask a confirm at once: webp | removeWebp | remove | everything
///   -previewDetailPhase K       a delete in a state: deleting | failed | partial | busy
///   -previewDetailKeep N        keep only the first N renditions (1 and 2); shown as given, not live
///   -previewDetailExtra N       add N webps (copies of the last) so the tabs reach 5 and 6; shown as given, not live
///   -previewDetailAX5 1         the detail at accessibility5 text (the shell clamps the app at accessibility2)
///   -previewDetailAuto everything   run `delete everything` through the model after a moment (the real call over the
///                               preview client: partial first on `.renditions`), then "try again" 3 s later
///                               `-previewDetailAuto makeWebp`: press "another webp" (pops the detail into the focus)
///   -previewDetailBusy 1        this media's own run is "in progress": delete everything is disabled
///   -previewDetailFailDelete 1  every delete answers "couldn't delete that" (the preview client's deletes succeed)
///   -previewPlacement K         album | library: the "save to photos" button's placed states (shared with the focus)
///
/// Only the first detail that opens takes the confirm and the phase; the others open plain.
@MainActor
enum DetailDebug {
    private static let defaults = UserDefaults.standard
    private static var applied = false

    static var forceBusy: Bool { defaults.bool(forKey: "previewDetailBusy") }
    static var failDeletes: Bool { defaults.bool(forKey: "previewDetailFailDelete") }

    static var placement: PhotosPlacement? {
        switch defaults.string(forKey: "previewPlacement") {
        case "album": return .inAlbum
        case "library": return .inLibrary
        default: return nil
        }
    }

    static var ax5: Bool { defaults.bool(forKey: "previewDetailAX5") }

    /// `-previewDetailExtra N`: the media with N more webps, copies of its newest; `-previewDetailKeep N` keeps only
    /// the first N renditions (1 and 2 renditions). Nil without either flag.
    static func padded(_ item: MediaItem) -> MediaItem? {
        if let keep = defaults.string(forKey: "previewDetailKeep").flatMap(Int.init), keep > 0 {
            var cut = item
            cut.renditions = Array(item.renditions.prefix(keep))
            return cut
        }
        guard let extra = defaults.string(forKey: "previewDetailExtra").flatMap(Int.init), extra > 0, let last = item.webps.last else { return nil }
        var out = item
        for i in 1...extra {
            var r = last
            r.id = "pad-\(i)"
            r.kind = .webp(number: item.webpCount + i)
            r.createdAt = last.createdAt.addingTimeInterval(Double(i) * 120)
            r.publicURL = last.publicURL?.deletingLastPathComponent().appendingPathComponent("PrEvIeW02\(i).webp")
            r.file = nil
            r.deletableName = nil
            out.renditions.append(r)
        }
        return out
    }

    static var tab: Int? { defaults.string(forKey: "previewDetailTab").flatMap(Int.init) }

    /// The tab a debug-opened detail starts on.
    static func initial(_ item: MediaItem) -> Rendition.ID? {
        guard let tab, item.renditions.indices.contains(tab) else { return nil }
        return item.renditions[tab].id
    }

    /// The confirm and the phase the flags ask for, once, a moment after the first detail is up.
    static func apply(
        to controller: DetailController, item: MediaItem, perform: @MainActor (DetailController.Effect) -> Void
    ) async {
        guard defaults.string(forKey: "previewDetailConfirm") != nil || defaults.string(forKey: "previewDetailPhase") != nil
                || defaults.string(forKey: "previewDetailAuto") != nil
        else { return }
        try? await Task.sleep(for: .milliseconds(700))
        let selected = controller.selected(in: item)
        switch defaults.string(forKey: "previewDetailConfirm") {
        case "webp": controller.confirm = .deleteWebp(selected.id)
        case "removeWebp": controller.confirm = .removeWebp(selected.id)
        case "remove": controller.confirm = .removeMedia
        case "everything": controller.confirm = .deleteEverything
        default: break
        }
        switch defaults.string(forKey: "previewDetailPhase") {
        case "deleting": controller.phase = .deleting
        case "failed": controller.phase = .failed; controller.retry = .deleteEverything
        case "partial": controller.phase = .partial(remaining: 1); controller.retry = .deleteEverything
        case "busy": controller.phase = .busy
        default: break
        }
        if defaults.string(forKey: "previewDetailAuto") == "makeWebp", !applied {
            applied = true
            try? await Task.sleep(for: .milliseconds(1200))
            perform(.makeWebp)
        }
        if defaults.string(forKey: "previewDetailAuto") == "everything", !applied {
            applied = true
            try? await Task.sleep(for: .milliseconds(800))
            perform(await controller.deleteEverything(item))
            if case .partial = controller.phase {
                try? await Task.sleep(for: .seconds(3))
                perform(await controller.tryAgain(item))
            }
        }
    }

    /// `-debugDetailFiles`: real pictures in the seeded renditions, so the hero and the tabs show motion.
    static func seedFilesIfRequested(_ model: AppModel) {
        guard let raw = defaults.string(forKey: "debugDetailFiles"), let clip = PreviewClip.url else { return }
        let webp = PreviewClip.webpURL ?? clip
        let indexes = Set(raw.split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) })
        let others = defaults.bool(forKey: "debugDetailFilesOthers")
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(400))
            for media in model.store.media {
                let isShowcase = media.webps.count >= 3
                for (i, record) in media.renditions.enumerated() {
                    let wanted = isShowcase ? indexes.contains(i) : others
                    guard wanted, record.fileURL == nil else { continue }
                    _ = try? await model.store.attach(file: record.kind == .webp ? webp : clip, to: record.id, move: false, keep: false)
                }
            }
            DebugHooks.log("detail files attached \(indexes.sorted())")
        }
    }
}
#endif
