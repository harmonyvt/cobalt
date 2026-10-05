import CobaltKit
import SwiftUI

/// The one detail screen app-wide (CONTRACT-MEDIA 1.8): the orbit, the library (phone, iPad, Mac), the
/// inspector and the debug hooks all open it, over a `MediaItem`. One media is one screen; its renditions are
/// tabs above the hero (`video`, `webp 1`, `webp 2`...), each with its own meta and actions, exactly one
/// prominent button per tab, a `more` menu with the three ways to get rid of things, and the offline copy of
/// the selected file. Wide windows (iPad regular, a Mac sheet from 700 pt) go two columns.
///
/// The screen keeps itself current: it reads its media from the store and the library on every change, so a
/// webp made elsewhere appears as a tab and a delete shows what is left. The snapshot it was opened with only
/// stands in while the media is being removed.
struct MediaDetail: View {
    let model: AppModel
    private let localID: String?
    private let postID: String?
    /// False in `#Preview`s that hand over a media the model does not hold: the snapshot is the media.
    private let live: Bool

    @State private var lastShown: MediaItem
    @State private var controller: DetailController
    @State private var width: CGFloat = 0
    @State private var gone = false
    @Environment(\.dismiss) private var dismiss
    @Environment(\.shell) private var shell
    @Environment(\.dynamicTypeSize) private var typeSize

    /// The tabbed detail's entry point (CONTRACT-MEDIA 4.2): one media, opening on the rendition `initial` names
    /// (`Rendition.ID`; nil = the face).
    init(model: AppModel, item: MediaItem, initial: Rendition.ID? = nil) {
        self.init(model: model, item: item, initial: initial, live: true)
    }

    /// The old entry: a stored record opens its media, on that record's tab. Kept so the call sites that
    /// still hold a `StoredVideo` (the orbit's planet tap) compile unchanged.
    init(model: AppModel, video: StoredVideo) {
        let local = model.store.media(containing: video.id)
            ?? StoredMedia(
                id: video.mediaID, original: video.kind == .original ? video : nil,
                webps: video.kind == .webp ? [video] : [])
        let item = local.map { model.mediaItem(for: $0) } ?? MediaItem(
            id: video.mediaID, local: nil, post: nil, service: nil, ref: nil, link: video.link,
            renditions: [Rendition(id: video.id, kind: video.kind == .webp ? .webp(number: 1) : .video, local: video,
                                   createdAt: video.createdAt)])
        self.init(model: model, item: item, initial: video.id, live: true)
    }

    fileprivate init(model: AppModel, item: MediaItem, initial: Rendition.ID?, live: Bool, preset: DetailPreset? = nil) {
        self.model = model
        self.localID = item.local?.id
        self.postID = item.post?.id
        self.live = live
        _lastShown = State(initialValue: item)
        let controller = DetailController(model: model)
        controller.selectedID = initial
        preset?.apply(to: controller)
        _controller = State(initialValue: controller)
    }

    /// The library post this video belongs to (same session or same link), if the library has it.
    static func post(for video: StoredVideo, in library: LibraryModel) -> LibraryPost? {
        library.posts.first {
            ($0.session?.id != nil && $0.session?.id == video.sessionID) || ($0.link != nil && $0.link == video.link)
        }
    }

    // MARK: the media, as it is now

    /// The media from the store and the library as they are now; nil once nothing of it is left.
    private var resolved: MediaItem? {
        guard live else { return lastShown }
        let post = postID.flatMap { id in model.library.posts.first { $0.id == id } }
        let local = localID.flatMap { model.store.media(id: $0) }
        if let post {
            return model.mediaItem(for: post, preferring: local)
        }
        return local.map { model.mediaItem(for: $0) }
    }

    private func title(_ item: MediaItem) -> String {
        if item.service != nil {
            let (service, ref) = Copy.libraryPostTitle(service: item.service, ref: item.ref)
            return ref.map { "\(service) · \($0)" } ?? service
        }
        return item.local?.title ?? item.post?.title ?? Copy.libraryPostTitle(service: nil, ref: nil).0
    }

    // MARK: body

    var body: some View {
        let item = resolved ?? lastShown
        let selected = controller.selected(in: item)
        let context = DetailContext(
            controller: controller, item: item, rendition: selected,
            selection: Binding(
                get: { selected.id },
                set: { id in withAnimation(Motion.card) { controller.select(id) } }),
            leave: { dismiss() })
        Group {
            if gone {
                Text(Copy.Media.deleted)
                    .font(CobaltType.body).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if width >= DetailWidth.wide, !typeSize.isAccessibilitySize {
                WideDetail(c: context, maxSegments: width >= DetailWidth.sixTabs + 300 ? 6 : 4)
            } else {
                CompactDetail(c: context, maxSegments: width >= DetailWidth.sixTabs ? 6 : 4)
            }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .navigationTitle(title(item))
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            if !gone {
                ToolbarItem(placement: .primaryAction) {
                    DetailMenu(controller: controller, item: item, rendition: selected) { openInLibrary(item) }
                }
            }
        }
        .detailDialogs(controller: controller, item: item) { ask in run(ask, item) }
        .background { tabShortcuts(item) }
        .onChange(of: resolved) { old, now in
            if let now { lastShown = now }
            // a webp that arrived (made here or on another device) takes the selection, like a new tab
            if let old, let now, now.webpCount > old.webpCount { controller.selectedID = now.face.id }
        }
        .onChange(of: resolved == nil) { _, vanished in
            if vanished { finishGone() }
        }
        .task {
            if live, model.library.posts.isEmpty, model.capabilities.library { await model.library.refresh() }
        }
        #if DEBUG
        .task {
            await DetailDebug.apply(to: controller, item: lastShown) { effect in
                switch effect {
                case .popWithStatus(let message):
                    shell.showStatus(message)
                    dismiss()
                case .makeWebp:
                    DebugHooks.log("detail debug: makeWebp then dismiss")
                    shell.makeWebp(lastShown)
                    dismiss()
                case .none:
                    break
                }
            }
        }
        #endif
    }

    // MARK: actions

    private func run(_ ask: DetailController.Confirm, _ item: MediaItem) {
        Task {
            switch ask {
            case .deleteWebp(let id), .removeWebp(let id):
                guard let r = item.rendition(id: id) else { return }
                if case .deleteWebp = ask { await controller.deleteWebp(r, of: item, onServer: true) }
                else { await controller.deleteWebp(r, of: item, onServer: false) }
            case .removeMedia:
                if await controller.removeFromDevice(item) {
                    if resolved == nil { finishGone() } else { dismiss() }
                }
            case .deleteEverything:
                if case .popWithStatus(let message) = await controller.deleteEverything(item) {
                    shell.showStatus(message)
                    dismiss()
                }
            }
        }
    }

    /// Nothing of the media is left: the screen underneath says `deleted.` (when it was deleted) and this pops.
    private func finishGone() {
        guard live, !gone else { return }
        gone = true
        if let status = controller.exitStatus { shell.showStatus(status) }
        dismiss()
    }

    private func openInLibrary(_ item: MediaItem) {
        guard let post = item.post else { return }
        model.library.expandedPostID = post.id
        model.selectedTab = .library
        dismiss()
    }

    /// ⌘1…⌘9 pick a tab (an iPad keyboard, the Mac).
    @ViewBuilder
    private func tabShortcuts(_ item: MediaItem) -> some View {
        if item.renditions.count >= 2 {
            VStack {
                ForEach(Array(item.renditions.prefix(9).enumerated()), id: \.element.id) { index, r in
                    Button(r.tabName(of: item)) { withAnimation(Motion.card) { controller.select(r.id) } }
                        .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: .command)
                }
            }
            .frame(width: 0, height: 0)
            .opacity(0)
            .accessibilityHidden(true)
        }
    }
}

extension AppModel {
    /// The post's media, joined with `local` when the caller already holds it (it joins the same way
    /// `mediaItem(for: post)` does, and a screen that opened on a local media keeps it).
    fileprivate func mediaItem(for post: LibraryPost, preferring local: StoredMedia?) -> MediaItem {
        if let local { return MediaItem.merge(local: local, post: post) ?? mediaItem(for: post) }
        return mediaItem(for: post)
    }
}

/// A starting state for a `#Preview` (a confirm already asked, a delete in a state), applied to the
/// controller before the first frame. Debug builds only use it, from `DetailPreviews.swift`.
struct DetailPreset {
    var confirm: DetailController.Confirm?
    var phase: DetailController.Phase = .idle
    var retry: DetailController.Confirm?
    var notice: String?
    var copiedID: String?
    var busy = false
    var failsDeletes = false
    var placement: PhotosPlacement?

    @MainActor func apply(to controller: DetailController) {
        controller.confirm = confirm
        controller.phase = phase
        controller.retry = retry
        controller.notice = notice
        controller.copiedID = copiedID
        controller.previewBusy = busy
        controller.previewFailsDeletes = failsDeletes
        controller.previewPlacement = placement
    }
}

#if DEBUG
extension MediaDetail {
    /// Previews: a media the model does not necessarily hold (a hand-built set of renditions), shown as given.
    init(preview model: AppModel, item: MediaItem, initial: Rendition.ID? = nil, preset: DetailPreset? = nil) {
        self.init(model: model, item: item, initial: initial, live: false, preset: preset)
    }
}
#endif
