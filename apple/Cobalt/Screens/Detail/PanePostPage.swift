import CobaltKit
import SwiftUI

// The post in the screen pane (apple/CONTRACT-PANE.md section 5: library, home and chat open `.post(id)`). The same media
// as `MediaDetail` (one media, its renditions as tabs, the same controller and the same actions), drawn as a `PanePage`:
// the media is the hero, the tabs and four big buttons are the controls, the meta line and the rest of the actions are
// the body, and the details and the link settings are the shelf. `MediaDetail` stays what the phone pushes and the
// sheets (a Mac sheet, a chat card) open; this is what beside-the-tab opens.

extension AppModel {
    /// The media a pane `.post(id)` / `.peek(id)` names, from just its id. Accepts a library post id (what a library row
    /// carries), `MediaItem.id`'s `post:<id>` form, and the id of a media only this device holds. A hidden post resolves
    /// only while the library holds the album's posts (it drops them when the album locks).
    func paneMedia(id: String) -> MediaItem? {
        let key = id.hasPrefix("post:") ? String(id.dropFirst(5)) : id
        if let post = library.post(id: key) ?? library.hiddenPost(id: key) { return mediaItem(for: post) }
        if let local = store.media(id: id) { return mediaItem(for: local) }
        return nil
    }
}

// MARK: - the page, from an id

/// `.post(id)`: waits for the post when the library has not loaded it yet (a chat result, a link's file), asks the
/// library to find it, and says so when it is not there.
struct PanePostPage: View {
    let id: String
    let model: AppModel
    let pane: Pane

    @State private var first: MediaItem?
    @State private var missing = false

    var body: some View {
        let now = model.paneMedia(id: id)
        Group {
            if let item = now ?? first {
                PanePostContent(id: id, model: model, pane: pane, first: item)
            } else if missing {
                PaneGonePage()
            } else {
                PaneLoadingPage()
            }
        }
        .onChange(of: now, initial: true) { _, found in
            if let found { first = found; missing = false }
        }
        .task(id: id) {
            guard model.paneMedia(id: id) == nil else { return }
            if model.library.posts.isEmpty, model.capabilities.library { await model.library.refresh() }
            if model.paneMedia(id: id) == nil, id.hasPrefix("post:") || model.store.media(id: id) == nil {
                _ = await model.library.locate(postID: id.hasPrefix("post:") ? String(id.dropFirst(5)) : id)
            }
            if model.paneMedia(id: id) == nil { missing = true }
        }
    }
}

// MARK: - the content

struct PanePostContent: View {
    let id: String
    let model: AppModel
    let pane: Pane

    @State private var lastShown: MediaItem
    @State private var controller: DetailController
    @State private var gone = false
    @State private var renaming = false
    @State private var managing = false
    @State private var subtitles = SubtitleSession()
    /// File URLs for the system share sheet (empty: nothing is presented).
    @State private var filesToShare: [URL] = []
    @Environment(\.paneShape) private var shape
    @Environment(\.shell) private var shell
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.paneItem) private var paneItem

    private let localID: String?
    private let postID: String?
    private let fromAlbum: Bool

    init(id: String, model: AppModel, pane: Pane, first item: MediaItem) {
        self.id = id
        self.model = model
        self.pane = pane
        localID = item.local?.id
        postID = item.post?.id
        fromAlbum = item.post?.hidden == true
        _lastShown = State(initialValue: item)
        let controller = DetailController(model: model)
        controller.selectedID = nil
        _controller = State(initialValue: controller)
    }

    // MARK: the media, as it is now

    /// The media from the store and the library as they are now; nil once nothing of it is left.
    private var resolved: MediaItem? {
        let post = postID.flatMap { key in model.library.post(id: key) ?? (fromAlbum ? model.library.hiddenPost(id: key) : nil) }
        let local = localID.flatMap { model.store.media(id: $0) }
        if let post {
            if let local { return MediaItem.merge(local: local, post: post) ?? model.mediaItem(for: post) }
            return model.mediaItem(for: post)
        }
        return local.map { model.mediaItem(for: $0) }
    }

    /// The video's player and playhead, kept by the pane while it holds this post: the page is built anew for each shape
    /// (sheet, cover, column, tall, wide), and the clip must not start over each time. Nil where the pane does not hold the
    /// post (a preview): the hero keeps its own then.
    private var heroKept: HeroKept? {
        let item = paneItem ?? .post(id)
        guard pane.holds(item) else { return nil }
        return pane.keepAlive("player", for: item) { HeroKept() }
    }

    private func subtitlesShown(_ item: MediaItem, _ selected: Rendition) -> Bool {
        model.capabilities.transcripts && item.post != nil && item.detailShape == .classic && selected.kind == .video
    }

    // MARK: body

    var body: some View {
        let current = resolved
        let item = current ?? lastShown
        let selected = controller.selected(in: item)
        let context = DetailContext(
            controller: controller, item: item, rendition: selected,
            selection: Binding(
                get: { controller.tabID(in: item) },
                set: { tab in withAnimation(Motion.card) { controller.selectTab(tab, in: item) } }),
            leave: { pane.close() })
        Group {
            if gone {
                PaneGonePage(message: Copy.Media.deleted)
            } else if shape == .bar {
                bar(item)
            } else {
                page(context)
            }
        }
        .environment(\.subtitles, subtitlesShown(item, selected) ? subtitles : nil)
        .environment(\.heroKept, heroKept)
        // a hidden post is not in the app switcher's snapshot (the library's own cover does not reach the pane)
        .hiddenCover(whenHidden: fromAlbum || model.isHiddenPost(item))
        .background { GalleryFileShare(fileURLs: $filesToShare) }
        .detailDialogs(controller: controller, item: item) { ask in run(ask, item) }
        .makeSheet(controller: controller, item: item, model: model)
        .postFrameSheet(controller: controller, model: model)
        .renameAlert(item: item, isPresented: $renaming, model: model) { controller.notice = $0 }
        .navigationDestination(isPresented: $managing) {
            PostSettingsPage(id: id, model: model, controller: controller, fallback: lastShown)
        }
        .onChange(of: current) { old, now in
            if let now { lastShown = now }
            if let old, let now, now.detailShape == .classic, now.webpCount > old.webpCount { controller.selectedID = now.face.id }
            if let old, let now, now.detailShape != .classic,
               let fresh = now.made.last(where: { r in !old.renditions.contains { $0.id == r.id } }) {
                controller.selectedID = fresh.id
            }
        }
        .onChange(of: current == nil) { _, vanished in
            if vanished { finishGone() }
        }
        .task(id: postID) {
            guard let postID, model.capabilities.transcripts else { return }
            await subtitles.load(model.library, postKey: postID)
        }
        .onChange(of: model.library.pendingMoment, initial: true) { takeMoment() }
        .task {
            if model.library.posts.isEmpty, model.capabilities.library { await model.library.refresh() }
        }
    }

    // MARK: the page

    private func page(_ c: DetailContext) -> some View {
        let item = c.item
        let actions = PostActions(c: c, share: share, leave: { pane.close() }, shellMakeWebp: { shell.makeWebp($0) })
        let all = actions.all
        let grid = Array(all.prefix(PaneActionGrid.limit))
        return PanePage(
            title: item.titleText, subtitle: subtitle(item), actions: headerActions(item), more: moreActions(c, extra: Array(all.dropFirst(PaneActionGrid.limit)))
        ) {
            hero(c)
        } controls: {
            controls(c, grid: grid)
        } body: {
            detailBody(c)
        } shelf: {
            PaneCard(Copy.PostPane.detailsCard) { details(c) }
            PaneCard(Copy.PostPane.linkCard) { linkCard(c) }
        }
    }

    // MARK: hero

    @ViewBuilder
    private func hero(_ c: DetailContext) -> some View {
        switch shape {
        case .tall:
            DetailHero(c: c, maxHeight: typeSize.isAccessibilitySize ? 200 : 340)
        case .wide:
            DetailHero(c: c, maxHeight: 520)
        case .split, .bar:
            DetailHero(c: c, maxHeight: 700)
        }
    }

    // MARK: controls

    @ViewBuilder
    private func controls(_ c: DetailContext, grid: [PaneAction]) -> some View {
        VStack(spacing: 12) {
            RenditionTabs(item: c.item, selection: c.selection, maxSegments: 4)
            SubtitleStrip()
            if controller.selecting, c.page != nil {
                GallerySelectionBar(c: c, share: share)
            } else if !grid.isEmpty {
                PaneActionGrid(grid)
                    .disabled(controller.isDeleting)
            }
            DetailStatus(controller: controller, item: c.item, leave: { pane.close() })
        }
        .motion(Motion.card, value: c.rendition.id)
    }

    // MARK: body

    @ViewBuilder
    private func detailBody(_ c: DetailContext) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            DetailInfo(
                item: c.item, rendition: c.rendition, missing: c.missingIndex,
                shareLink: c.model.capabilities.shareLink(for:))
            IconRow(alignment: .leading) {
                DetailMenu(
                    controller: controller, item: c.item, rendition: c.rendition,
                    openInLibrary: { openInLibrary(c.item) }, askAbout: { askAbout(c.item) }, rename: { renaming = true },
                    paneDrawsEssentials: true)
                    .buttonStyle(.cobaltIcon())
                SevenTvUploadIcon(model: model, file: c.rendition.file, title: c.item.titleText)
                EmoteEditorIcon(model: model, rendition: c.rendition, title: c.item.titleText)
            }
            .padding(.horizontal, 16)
        }
    }

    private func details(_ c: DetailContext) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let missing = c.missingIndex {
                MissingInfo(item: c.item, index: missing)
            } else {
                ForEach(DetailMeta.rows(c.rendition, in: c.item), id: \.label) { row in
                    LabeledContent(row.label) { Text(row.value).monospacedDigit() }
                        .font(CobaltType.body)
                }
            }
        }
    }

    private func linkCard(_ c: DetailContext) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(linkSummary(c))
                .font(CobaltType.caption)
                .foregroundStyle(CobaltColor.caption)
                .fixedSize(horizontal: false, vertical: true)
            Button { managing = true } label: {
                Label(Copy.PostPane.manage, systemImage: Symbol.Media.more)
            }
            .buttonStyle(.cobaltSecondary(fullWidth: false))
        }
    }

    private func linkSummary(_ c: DetailContext) -> String {
        guard c.missingIndex == nil else { return Copy.PostPane.notSaved }
        switch model.fileLink(of: c.rendition) {
        case .off: return Copy.PrivateLinks.offDetail
        case .public: return Copy.PrivateLinks.publicDetail
        case .private: return Copy.PrivateLinks.privateDetail
        }
    }

    // MARK: title row and the header's menu

    private func subtitle(_ item: MediaItem) -> String {
        let face = item.face
        var parts: [String] = []
        parts.append(item.detailShape == .gallery ? Copy.Gallery.photosTab(item.galleryTotal) : kindWord(item))
        if item.detailShape != .gallery, let length = face.duration ?? item.post?.duration, length > 0 { parts.append(Format.seconds(length)) }
        if let service = item.service, !service.isEmpty { parts.append(service) }
        return parts.joined(separator: " · ")
    }

    private func kindWord(_ item: MediaItem) -> String { item.kind.rawValue }

    private func headerActions(_ item: MediaItem) -> [PaneAction] {
        var list = [PaneAction(Copy.Library2.rename, systemImage: Symbol.Library.rename, disabled: controller.isDeleting) { renaming = true }]
        if model.capabilities.chat, item.post != nil, !model.isHiddenPost(item) {
            list.append(PaneAction(Copy.Chat.askAbout, systemImage: Symbol.chatAsk, needsServer: true) { askAbout(item) })
        }
        return list
    }

    private func moreActions(_ c: DetailContext, extra: [PaneAction]) -> [PaneAction] {
        var list = extra
        let item = c.item
        if model.capabilities.library, item.post != nil, model.selectedTab != .library {
            list.append(PaneAction(Copy.Media.openInLibrary, systemImage: Symbol.Media.openInLibrary) { openInLibrary(item) })
        }
        if controller.canDeleteEverything(item) {
            list.append(PaneAction(
                Copy.Media.deleteEverything, systemImage: Symbol.Media.deleteEverything, role: .destructive,
                disabled: controller.isDeleting || controller.isBusy(item)
            ) { controller.confirm = .deleteEverything })
        }
        return list
    }

    // MARK: the bar

    /// A post whose chat job is running, as the bar: its picture, its title, one control.
    @ViewBuilder
    private func bar(_ item: MediaItem) -> some View {
        PanePage(title: item.titleText, subtitle: subtitle(item)) {
            FacePicture(item: item, maxPixel: 160, showsGlyph: false)
        } controls: {
            EmptyView()
        }
    }

    // MARK: actions

    /// Copies the files onto this device if they are not here, then presents the system sheet.
    private func share(_ renditions: [Rendition]) {
        Task {
            guard !controller.preparingShare else { return }
            controller.preparingShare = true
            let urls = await controller.localFileURLs(for: renditions)
            controller.preparingShare = false
            guard !urls.isEmpty else { return }
            filesToShare = urls
        }
    }

    private func run(_ ask: DetailController.Confirm, _ item: MediaItem) {
        Task {
            switch ask {
            case .deleteWebp(let id), .removeWebp(let id):
                guard let r = item.rendition(id: id) else { return }
                if case .deleteWebp = ask { await controller.deleteWebp(r, of: item, onServer: true) }
                else { await controller.deleteWebp(r, of: item, onServer: false) }
            case .deletePhoto(let index):
                await controller.deletePhotos([index], of: item)
            case .deletePhotos(let indices):
                await controller.deletePhotos(indices, of: item)
            case .deleteMade(let id):
                guard let r = item.rendition(id: id) else { return }
                await controller.deleteMade(r, of: item)
            case .removeMedia:
                if await controller.removeFromDevice(item) {
                    if resolved == nil { finishGone() } else { pane.close() }
                }
            case .deleteEverything:
                if case .popWithStatus(let message) = await controller.deleteEverything(item) {
                    shell.showStatus(message)
                    pane.close()
                }
            }
        }
    }

    /// Nothing of the media is left: the page says `deleted.` and the pane's close is the way out.
    private func finishGone() {
        guard !gone else { return }
        gone = true
        if let status = controller.exitStatus { shell.showStatus(status) }
    }

    private func askAbout(_ item: MediaItem) {
        guard let post = item.post else { return }
        Task {
            do {
                try await model.askAbout([post])
                pane.close()
            } catch {
                shell.showStatus(Copy.Chat.message(for: error))
            }
        }
    }

    private func openInLibrary(_ item: MediaItem) {
        guard let post = item.post else { return }
        // on one narrow screen the pane is a sheet over the tab: it goes, or the library would light the post behind it
        if pane.placement == .compact { pane.close() }
        model.library.expandedPostID = post.id
        model.selectedTab = .library
    }

    /// A search's "said at" for this post: play from there, subtitles on.
    private func takeMoment() {
        guard let moment = model.library.pendingMoment, moment.postKey == postID else { return }
        model.library.pendingMoment = nil
        subtitles.start(at: moment.seconds)
    }
}

// MARK: - the big buttons

/// What the post page's big buttons are: the choices `DetailActions` and `GalleryActions` plan (the one prominent button,
/// then the secondary row), as `PaneAction`s. The first four are the grid; the rest go to the header's `more`.
@MainActor
struct PostActions {
    let c: DetailContext
    let share: ([Rendition]) -> Void
    let leave: () -> Void
    let shellMakeWebp: (MediaItem) -> Void

    private var controller: DetailController { c.controller }
    private var item: MediaItem { c.item }
    private var r: Rendition { c.rendition }
    private var model: AppModel { c.model }

    var all: [PaneAction] { c.isGalleryLike ? gallery : classic }

    // MARK: a video and its webps

    private var classic: [PaneAction] {
        let a = DetailActions(controller: controller, item: item, rendition: r)
        let plan = a.plan
        var out: [PaneAction] = []
        for choice in ([plan.primary].compactMap { $0 } + plan.secondary) {
            if let action = classicAction(choice, a, primary: choice == plan.primary) { out.append(action) }
        }
        return out
    }

    private func classicAction(_ choice: DetailActions.Choice, _ a: DetailActions, primary: Bool) -> PaneAction? {
        let copied = controller.copiedID == r.id
        let form = copied ? (controller.copiedForm ?? .share) : nil
        switch choice {
        case .copyWebpLink:
            guard let url = r.publicURL else { return nil }
            let paired = model.capabilities.hasLinkPair(url)
            return PaneAction(
                copied && form != .direct ? Copy.Media.copied : (paired ? Copy.LinkPair.copyShareLink : Copy.Media.copyWebpLink),
                systemImage: copied ? Symbol.Media.copied : Symbol.Media.copyLink, id: "copy-webp"
            ) { controller.copy(url, for: r.id) }
        case .copyVideoLink:
            guard let url = a.videoLink else { return nil }
            let paired = model.capabilities.hasLinkPair(url)
            return PaneAction(
                copied && form != .direct ? Copy.Media.copied : (paired ? Copy.LinkPair.copyShareLink : Copy.Media.copyVideoLink),
                systemImage: copied && form != .direct ? Symbol.Media.copied : Symbol.Media.copyLink, id: "copy-video"
            ) { controller.copy(url, for: r.id) }
        case .copyVideoDirect:
            guard let url = a.videoLink else { return nil }
            return PaneAction(
                copied && form == .direct ? Copy.Media.copied : Copy.LinkPair.copyDirectLink,
                systemImage: copied && form == .direct ? Symbol.Media.copied : Symbol.LinkPair.direct, id: "copy-direct"
            ) { controller.copy(url, for: r.id, form: .direct) }
        case .makeWebp, .anotherWebp:
            let title = choice == .anotherWebp && !primary ? Copy.Media.anotherWebp
                : (item.webpCount > 0 ? Copy.Media.makeAnotherWebp : Copy.Media.makeAWebp)
            return PaneAction(title, systemImage: Symbol.Media.makeWebp, needsServer: true, id: "make-webp") {
                shellMakeWebp(item)
                leave()
            }
        case .savePhotos:
            return savePhotosAction(inItem: false)
        case .share:
            return PaneAction(Copy.Media.share, systemImage: Symbol.Media.share, id: "share") { share([r]) }
        case .publicShare:
            return PaneAction(Copy.Media.publicShare, systemImage: Symbol.Media.publicShare, needsServer: true, id: "public-share") {
                Task { await controller.publicShare(r) }
            }
        case .postFrame:
            guard let target = a.postFrameTarget else { return nil }
            return PaneAction(Copy.PostFrame.postFrame, systemImage: Symbol.PostFrame.frame, needsServer: true, id: "post-frame") {
                controller.postFrameTarget = target
            }
        }
    }

    // MARK: a gallery and a photo

    private var gallery: [PaneAction] {
        let a = GalleryActions(c: c)
        let plan = a.plan
        var out: [PaneAction] = []
        if let primary = plan.primary, let action = galleryPrimary(primary) { out.append(action) }
        for choice in plan.secondary {
            if let action = gallerySecondary(choice) { out.append(action) }
        }
        return out
    }

    private func galleryPrimary(_ choice: GalleryActions.Primary) -> PaneAction? {
        switch choice {
        case .copyLink:
            guard let url = r.publicURL else { return nil }
            let done = controller.copiedID == r.id
            return PaneAction(
                done ? Copy.Media.copied : Copy.Gallery.copyPhotoLink,
                systemImage: done ? Symbol.Media.copied : Symbol.Media.copyLink, id: "copy-link"
            ) { controller.copy(url, for: r.id) }
        case .share:
            return PaneAction(Copy.Media.share, systemImage: Symbol.Media.share, disabled: controller.preparingShare, id: "share") { share([r]) }
        case .savePhotos:
            return savePhotosAction(inItem: true)
        case .tryAgain(let index):
            let name = Copy.Gallery.itemLabel(.photo, index: index)
            return PaneAction(
                Copy.Gallery.tryItemAgain(name), systemImage: Symbol.Media.retry,
                needsServer: true, disabled: controller.retrying.contains(index), id: "try-again"
            ) { Task { await controller.retryMissing(item) } }
        }
    }

    private func gallerySecondary(_ choice: GalleryActions.Choice) -> PaneAction? {
        switch choice {
        case .share:
            return PaneAction(Copy.Media.share, systemImage: Symbol.Media.share, disabled: controller.preparingShare, id: "share") { share([r]) }
        case .savePhotos:
            return savePhotosAction(inItem: true)
        case .makeWebp:
            return PaneAction(Copy.Gallery.makeAWebp, systemImage: Symbol.Media.makeWebp, needsServer: true, id: "make-webp") {
                if controller.makeWebp(ofItem: r, in: item) { leave() }
            }
        case .animatedWebp:
            let done = controller.animating[r.id] == .done
            return PaneAction(
                Copy.Gallery.animatedWebp, systemImage: done ? Symbol.checkmark : Symbol.Gallery.animatedWebp,
                needsServer: true, disabled: controller.animating[r.id] == .working, id: "animated-webp"
            ) { Task { await controller.makeAnimatedWebp(of: r, in: item) } }
        }
    }

    // MARK: shared

    /// `save to photos`: once the file is in the owner's photos it says where and stops being a button.
    private func savePhotosAction(inItem: Bool) -> PaneAction? {
        guard RenditionPhotos.canSave(r) else { return nil }
        let state = controller.photos[r.id] ?? .idle
        switch controller.placement(of: r, in: inItem ? item : nil) {
        case .inAlbum:
            return PaneAction(Copy.Sync.inAlbum, systemImage: Symbol.Sync.inPhotos, disabled: true, id: "photos")  {}
        case .inLibrary:
            return PaneAction(Copy.Sync.inLibrary, systemImage: Symbol.Sync.inPhotos, disabled: true, id: "photos") {}
        case .none:
            return PaneAction(
                GalleryActions.saveTitle(done: state == .done),
                systemImage: state == .done ? Symbol.checkmark : GalleryActions.saveSymbol,
                disabled: state == .working, id: "photos"
            ) { Task { await controller.savePhotos(r, in: inItem ? item : nil) } }
        }
    }
}

// MARK: - the link settings, pushed in the pane

/// The sections the page does not draw (who can see it and how, the offline copy, how it sits in the search index): the
/// detail's own, in a form pushed in the pane's stack.
struct PostSettingsPage: View {
    let id: String
    let model: AppModel
    let controller: DetailController
    let fallback: MediaItem

    var body: some View {
        let item = model.paneMedia(id: id) ?? fallback
        let selected = controller.selected(in: item)
        let c = DetailContext(
            controller: controller, item: item, rendition: selected,
            selection: Binding(
                get: { controller.tabID(in: item) },
                set: { tab in controller.selectTab(tab, in: item) }),
            leave: {})
        Form {
            if c.isGalleryLike {
                GalleryVisibilitySection(controller: controller, item: item, rendition: selected)
                if item.detailShape == .gallery { GalleryMakeRow(controller: controller, item: item) }
                if c.missingIndex == nil { OfflineCopySection(model: model, item: item, rendition: selected) }
            } else {
                if model.canChoosePrivateLink(selected) {
                    FileLinkSection(controller: controller, rendition: selected)
                } else if controller.canSwitchVisibility(selected) {
                    VisibilitySection(controller: controller, rendition: selected)
                }
                if selected.kind == .video, model.canPostFrame(item) {
                    PostFrameDetailSection(controller: controller, item: item)
                }
                OfflineCopySection(model: model, item: item, rendition: selected)
            }
            if model.capabilities.search, let post = item.post {
                SearchIndexSection(model: model, postKey: post.id, refreshKey: item.titleText)
            }
            if BooruFindSection.applies(model: model, item: item, rendition: selected) {
                BooruFindSection(model: model, item: item, rendition: selected)
            }
        }
        .formStyle(.grouped)
        .navigationTitle(Copy.PostPane.linkCard)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        #endif
    }
}

// MARK: - previews

#if DEBUG
private struct PostPreview: View {
    var shape: PaneShape = .tall
    var hinge: PaneHinge?
    var scenario: PreviewScenario = .renditions
    /// Nil: the first media on this device.
    var id: String?
    @State private var pane = Pane(route: PaneRoute(item: .post("p"), state: .screen))

    var body: some View {
        PreviewHost(scenario) { model in
            NavigationStack {
                PanePostPage(id: id ?? model.store.media.first?.id ?? "none", model: model, pane: pane)
                    .environment(\.paneShape, shape)
                    .environment(\.paneHinge, hinge)
                    .environment(\.paneHeaderHeight, PaneChrome.headerHeight)
                    .environment(pane)
                    .background(CobaltColor.bg)
            }
        }
    }
}

#Preview("post · tall", traits: .fixedLayout(width: 440, height: 900)) { PostPreview() }
#Preview("post · tall, dark, AX3", traits: .fixedLayout(width: 440, height: 900)) {
    PostPreview().preferredColorScheme(.dark).dynamicTypeSize(.accessibility3)
}
#Preview("post · wide", traits: .fixedLayout(width: 1000, height: 560)) { PostPreview(shape: .wide) }
#Preview("post · split, wide duo", traits: .fixedLayout(width: 1080, height: 800)) {
    PostPreview(shape: .split(.media), hinge: PaneHinge(axis: .vertical, position: 540))
}
#Preview("post · bar", traits: .fixedLayout(width: 402, height: 64)) { PostPreview(shape: .bar) }
#Preview("post · not there", traits: .fixedLayout(width: 440, height: 600)) { PostPreview(id: "no-such-post") }
#endif
