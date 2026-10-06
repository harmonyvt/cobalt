import CobaltKit
import SwiftUI

/// The detail's `more` menu (CONTRACT-MEDIA 1.10, CONTRACT-LIBRARY2 decision 5, CONTRACT-OFFLINE decision 11), in the
/// contract's order: rename (first, on every width), open in library (from the orbit,
/// when the library has the post), show in finder / show in files, keep everything offline (only while some of
/// the media is offline and the rest can be fetched), remove from this iphone, delete this webp (webp tab only), delete everything
/// (destructive, last, only when the media has something on the server and a way to delete it).
struct DetailMenu: View {
    let controller: DetailController
    let item: MediaItem
    let rendition: Rendition
    var openInLibrary: () -> Void
    /// Opens the rename alert; the same item sits in the detail's title menu.
    var rename: () -> Void = {}

    private var model: AppModel { controller.model }

    /// From the orbit, when the library has the post: the library tab, on this media.
    private var showsOpenInLibrary: Bool {
        model.capabilities.library && item.post != nil && model.selectedTab != .library
    }

    /// Some of the media is kept offline and the rest can still be fetched (nothing runs for it right now).
    private var showsKeepEverything: Bool {
        guard model.store.canKeep, model.offlineState(of: item).offline == .some else { return false }
        let plan = OfflinePlan(item: item, model: model)
        return plan.canKeep && !plan.active
    }

    // MARK: a gallery's and a photo's entries (CONTRACT-GALLERY 1.19)

    private var page: GalleryPage? { controller.currentPage(in: item) }
    private var liveRendition: Rendition? { page?.rendition }

    /// After `rename` and `open in library`: make from this post…, select photos, save all to photos, copy all links (on the
    /// pager); save to photos and share (on a made file). `crop…` and `repost frame…` arrive with lane A7.
    @ViewBuilder
    private func galleryItems(deleting: Bool) -> some View {
        if item.detailShape == .gallery {
            Button(Copy.Gallery.makeFromThisPost, systemImage: Symbol.Gallery.make) { controller.showsMakeSheet = true }
                .disabled(deleting || controller.makeAvailability(item) != .ready)
        }
        if page != nil {
            if item.detailShape == .gallery, item.items.count >= 2 {
                Button(Copy.Gallery.selectPhotos, systemImage: Symbol.Gallery.selectPhotos) {
                    withAnimation(Motion.rows) { controller.beginSelecting(with: page.flatMap { $0.rendition == nil ? nil : $0.index }) }
                }
                .disabled(deleting)
            }
            if !item.items.isEmpty {
                Button(DetailWords.saveAllTitle, systemImage: Symbol.Gallery.saveToPhotos) {
                    Task { await controller.saveToPhotos(item.items, of: item) }
                }
                .disabled(deleting || controller.batchPhotos == .working)
            }
            if item.detailShape == .gallery {
                Button(Copy.Gallery.copyAllLinks, systemImage: Symbol.Gallery.copyLinks) { controller.copyAllLinks(item) }
            }
            // TODO(A7): `crop…` and `repost frame…` (Screens/Tools) go here, after copy all links.
        } else if rendition.isMade || rendition.isWebp {
            if RenditionPhotos.canSave(rendition), controller.placement(of: rendition, in: item) == .none {
                Button(GalleryActions.saveTitle(done: false), systemImage: GalleryActions.saveSymbol) {
                    Task { await controller.savePhotos(rendition, in: item) }
                }
            }
            if let url = shareURL(rendition) {
                ShareLink(item: url) { Label(Copy.Media.share, systemImage: Symbol.Media.share) }
            }
        }
    }

    /// The deletes of the shown page or file: `delete this photo` (not the last one), `delete this file` (a made file).
    @ViewBuilder
    private func galleryDeletes(deleting: Bool) -> some View {
        if let page, let r = page.rendition, item.items.count >= 2 {
            Button(Copy.Gallery.deletePhoto, systemImage: Symbol.Media.deleteWebp, role: .destructive) {
                controller.confirm = .deletePhoto(page.index)
            }
            .disabled(deleting)
            .accessibilityLabel("\(Copy.Gallery.deletePhoto): \(r.itemLabel ?? "")")
        } else if page == nil, rendition.isMade {
            Button(Copy.Gallery.deleteFile, systemImage: Symbol.Media.deleteWebp, role: .destructive) {
                controller.confirm = .deleteMade(rendition.id)
            }
            .disabled(deleting)
        }
    }

    private func shareURL(_ r: Rendition) -> URL? {
        if let url = r.local?.fileURL, FileManager.default.fileExists(atPath: url.path) { return url }
        return r.publicURL
    }

    var body: some View {
        let deleting = controller.isDeleting
        let busy = controller.isBusy(item)
        Menu {
            Button(Copy.Library2.rename, systemImage: Symbol.Library.rename, action: rename)
                .disabled(deleting)
            if showsOpenInLibrary {
                Button(Copy.Media.openInLibrary, systemImage: Symbol.Media.openInLibrary, action: openInLibrary)
            }
            if item.detailShape != .classic { galleryItems(deleting: deleting) }
            ShowInFinderButton(model: model, videos: rendition.local.map { [$0] } ?? [])
            ShowInFilesButton(model: model, item: item)
            if showsKeepEverything {
                Button(Copy.Offline.keepEverything, systemImage: Symbol.keepOffline) { model.keepOffline(item) }
            }
            if item.local != nil {
                Button(Copy.Media.removeMedia, systemImage: Symbol.Media.removeFromDevice) { controller.confirm = .removeMedia }
                    .disabled(deleting)
            }
            if item.detailShape != .classic { galleryDeletes(deleting: deleting) }
            if rendition.isWebp {
                if rendition.deletableName != nil {
                    Button(Copy.Media.deleteWebp, systemImage: Symbol.Media.deleteWebp, role: .destructive) {
                        controller.confirm = .deleteWebp(rendition.id)
                    }
                    .disabled(deleting)
                } else if rendition.local != nil {
                    Button(Copy.Media.removeWebp, systemImage: Symbol.Media.removeFromDevice) {
                        controller.confirm = .removeWebp(rendition.id)
                    }
                    .disabled(deleting)
                }
            }
            if controller.canDeleteEverything(item) {
                Button(Copy.Media.deleteEverything, systemImage: Symbol.Media.deleteEverything, role: .destructive) {
                    controller.confirm = .deleteEverything
                }
                .disabled(deleting || busy)
            }
        } label: {
            Label(Copy.Media.more, systemImage: Symbol.Media.more)
        }
        .accessibilityLabel(Copy.Media.more)
    }
}

/// The confirm of each way to get rid of something, one `confirmationDialog` whose words follow the question
/// (CONTRACT-MEDIA 1.12): the destructive button names the act, the cancel says `keep`.
struct DetailDialogs: ViewModifier {
    let controller: DetailController
    let item: MediaItem
    let confirmed: (DetailController.Confirm) -> Void

    private var presented: Binding<Bool> {
        Binding(get: { controller.confirm != nil }, set: { if !$0 { controller.confirm = nil } })
    }

    func body(content: Content) -> some View {
        content.confirmationDialog(
            title(controller.confirm), isPresented: presented, titleVisibility: .visible, presenting: controller.confirm
        ) { ask in
            Button(button(ask), role: .destructive) { confirmed(ask) }
            Button(Copy.Media.keep, role: .cancel) {}
        } message: { ask in
            Text(message(ask))
        }
    }

    private func title(_ ask: DetailController.Confirm?) -> String {
        switch ask {
        case .deleteWebp: return Copy.Media.deleteWebpTitle
        case .removeWebp: return Copy.Media.removeWebpTitle
        case .removeMedia: return Copy.Media.removeMediaTitle
        case .deleteEverything: return Copy.Media.deleteEverythingTitle
        case .deletePhoto(let index): return Copy.Gallery.deletePhotoTitle(index + 1)
        case .deletePhotos(let indices): return DetailWords.deletePhotosTitle(indices.count)
        case .deleteMade: return DetailWords.deleteMadeTitle
        case nil: return ""
        }
    }

    private func button(_ ask: DetailController.Confirm) -> String {
        switch ask {
        case .deleteWebp, .deletePhoto, .deletePhotos, .deleteMade: return Copy.Media.delete
        case .removeWebp, .removeMedia: return Copy.Media.remove
        case .deleteEverything: return Copy.Media.deleteEverything
        }
    }

    private func message(_ ask: DetailController.Confirm) -> String {
        switch ask {
        case .deleteWebp: return Copy.Media.deleteWebpMessage
        case .removeWebp: return Copy.Media.removeWebpMessage
        case .removeMedia:
            return item.detailShape == .classic
                ? Copy.Media.removeMediaMessage(webps: item.webpCount)
                : DetailWords.removeGalleryMessage(items: max(1, item.items.count), made: item.made.count)
        case .deleteEverything: return Self.everythingMessage(controller: controller, item: item)
        case .deletePhoto, .deletePhotos: return Copy.Gallery.deletePhotoMessage
        case .deleteMade: return DetailWords.deleteMadeMessage
        }
    }

    /// (b) with the post route: what exists, for everyone. (a) on an older server: only the webps.
    static func everythingMessage(controller: DetailController, item: MediaItem) -> String {
        if item.detailShape != .classic, controller.usesPostRoute(item) {
            return DetailWords.deleteEverythingMessage(items: max(1, item.items.count), made: item.made.count)
        }
        if controller.usesPostRoute(item) {
            let video = item.video
            let hosted = video?.hosted != nil || video?.publicURL != nil
            return Copy.Media.deleteEverythingMessage(video: video != nil, hosted: hosted, webps: item.webpCount)
        }
        return Copy.Media.deleteEverythingFallbackMessage(webps: controller.deletableWebps(item))
    }
}

extension View {
    func detailDialogs(controller: DetailController, item: MediaItem, confirmed: @escaping (DetailController.Confirm) -> Void) -> some View {
        modifier(DetailDialogs(controller: controller, item: item, confirmed: confirmed))
    }
}
