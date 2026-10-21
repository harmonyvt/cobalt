import CobaltKit
import SwiftUI

/// The buttons under a gallery's or a photo's hero (CONTRACT-GALLERY 1.19-1.20), on every tab: EXACTLY ONE prominent button
/// (`copy photo link` when the file is public, `share` when it is private, `try photo 7 again` on a page that was never
/// saved), then the secondary row (share, save to photos, make a webp of a video item), then the state of whatever
/// ran. In `select photos` the row becomes `3 selected` with share, to photos and delete. What does not apply is not shown.
struct GalleryActions: View {
    let c: DetailContext
    var leave: () -> Void = {}

    @Environment(\.shell) private var shell
    @Environment(\.hapticsEnabled) private var haptics
    /// File URLs for the system sheet. Empty means nothing is presented.
    @State private var filesToShare: [URL] = []

    private var controller: DetailController { c.controller }
    private var item: MediaItem { c.item }
    private var r: Rendition { c.rendition }
    private var model: AppModel { c.model }

    enum Primary: Equatable { case copyLink, share, savePhotos, tryAgain(Int) }
    enum Choice: Hashable { case share, savePhotos, makeWebp }

    // MARK: the plan

    /// A share button is shown when this device already has the file, or the library row can be downloaded.
    /// A public link on its own is not enough: the sheet only receives a file URL (`localFileURLs`).
    private var canShare: Bool {
        if let url = r.local?.fileURL, url.isFileURL, FileManager.default.fileExists(atPath: url.path) { return true }
        return r.file != nil
    }
    private var canSave: Bool { RenditionPhotos.canSave(r) }
    private var placement: PhotosPlacement { controller.placement(of: r, in: item) }

    private var linkTitle: String {
        switch r.kind {
        case .item(_, let type):
            switch type {
            case .photo: return Copy.Gallery.copyPhotoLink
            case .gif: return DetailWords.copyGifLink
            case .video: return Copy.Media.copyVideoLink
            }
        case .slideshow(_, let format): return format == .webp ? Copy.Media.copyWebpLink : Copy.Media.copyVideoLink
        case .galleryImage: return DetailWords.copyImageLink
        case .crop: return Copy.Gallery.copyPhotoLink
        case .webp: return Copy.Media.copyWebpLink
        case .video: return r.isStillPicture ? Copy.Gallery.copyPhotoLink : Copy.Media.copyVideoLink
        }
    }

    var plan: (primary: Primary?, secondary: [Choice]) {
        if let missing = c.missingIndex { return (.tryAgain(missing), []) }
        var primary: Primary?
        if r.publicURL != nil {
            primary = .copyLink
        } else if canShare {
            primary = .share
        } else if canSave {
            primary = .savePhotos
        }
        var secondary: [Choice] = []
        if canShare, primary != .share { secondary.append(.share) }
        if canSave, primary != .savePhotos { secondary.append(.savePhotos) }
        if r.isItem, controller.canMakeWebp(ofItem: r, in: item) { secondary.append(.makeWebp) }
        return (primary, secondary)
    }

    // MARK: body

    var body: some View {
        let locked = controller.isDeleting
        VStack(spacing: 12) {
            if controller.selecting, c.page != nil {
                GallerySelectionBar(c: c, share: share)
            } else {
                let plan = plan
                GlassEffectContainer(spacing: 0) {
                    VStack(spacing: 8) {
                        if let missing = c.missingIndex { missingNote(missing) }
                        if let primary = plan.primary { primaryButton(primary) }
                        if !plan.secondary.isEmpty { secondaryRow(plan.secondary) }
                    }
                }
                .disabled(locked)
            }
            DetailStatus(controller: controller, item: item, leave: leave)
        }
        .haptic(.success, trigger: controller.copiedID, enabled: haptics) { $0 != nil }
        .haptic(.success, trigger: controller.flash, enabled: haptics) { $0 != nil }
        .haptic(.error, trigger: controller.notice, enabled: haptics) { $0 != nil }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .contain)
        .background { GalleryFileShare(fileURLs: $filesToShare) }
    }

    /// Copies files onto this device if they are not here, then presents the system sheet. A second tap while that
    /// is running does nothing. An empty list is a notice, not a sheet.
    private func share(_ renditions: [Rendition]) {
        Task { await presentShare(renditions) }
    }

    private func presentShare(_ renditions: [Rendition]) async {
        guard !controller.preparingShare else { return }
        controller.preparingShare = true
        let urls = await controller.localFileURLs(for: renditions)
        controller.preparingShare = false
        guard !urls.isEmpty else { return }
        filesToShare = urls
    }

    // MARK: a page that was never saved

    private func missingNote(_ index: Int) -> some View {
        let name = Copy.Gallery.itemLabel(.photo, index: index)
        return Text(Copy.Gallery.notFetched(name, kept: item.items.count))
            .font(Font.cobalt(12, .regular, relativeTo: .caption))
            .foregroundStyle(CobaltColor.errorText)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity)
    }

    // MARK: primary

    @ViewBuilder
    private func primaryButton(_ choice: Primary) -> some View {
        switch choice {
        case .copyLink:
            let done = controller.copiedID == r.id
            DetailPrimary(
                title: done ? Copy.Media.copied : linkTitle, symbol: Symbol.Media.copyLink, doneSymbol: Symbol.Media.copied, done: done
            ) { if let url = r.publicURL { controller.copy(url, for: r.id) } }
        case .share:
            DetailPrimary(
                title: Copy.Media.share, symbol: Symbol.Media.share, working: controller.preparingShare
            ) { share([r]) }
        case .savePhotos:
            savePrimary
        case .tryAgain(let index):
            let name = Copy.Gallery.itemLabel(.photo, index: index)
            let working = controller.retrying.contains(index)
            DetailPrimary(
                title: working ? DetailWords.fetching(name) : Copy.Gallery.tryItemAgain(name), symbol: Symbol.Media.retry,
                working: working
            ) { Task { await controller.retryMissing(item) } }
        }
    }

    /// "save to photos" as the one prominent button (a private file this device cannot share): once the file is in the
    /// owner's photos it says where, and stops being a button.
    @ViewBuilder
    private var savePrimary: some View {
        let state = controller.photos[r.id] ?? .idle
        switch placement {
        case .inAlbum:
            DetailPrimary(title: Copy.Sync.inAlbum, symbol: Symbol.Sync.inPhotos, doneSymbol: Symbol.Sync.inPhotos, done: true, inert: true) {}
        case .inLibrary:
            DetailPrimary(title: Copy.Sync.inLibrary, symbol: Symbol.Sync.inPhotos, doneSymbol: Symbol.Sync.inPhotos, done: true, inert: true) {}
        case .none:
            DetailPrimary(
                title: Self.saveTitle(done: state == .done), symbol: Self.saveSymbol, doneSymbol: Symbol.checkmark,
                done: state == .done, working: state == .working
            ) { Task { await controller.savePhotos(r, in: item) } }
        }
    }

    static func saveTitle(done: Bool) -> String {
        #if os(macOS)
        return done ? Copy.saved : Copy.saveAs
        #else
        return done ? Copy.savedPhotos : Copy.Media.savePhotos
        #endif
    }

    static var saveSymbol: String {
        #if os(macOS)
        return Symbol.saveAs
        #else
        return Symbol.Media.savePhotos
        #endif
    }

    // MARK: secondary

    private func secondaryRow(_ items: [Choice]) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) { ForEach(items, id: \.self) { secondary($0, .stacked) } }
            VStack(spacing: 8) {
                ForEach(Array(stride(from: 0, to: items.count, by: 2)), id: \.self) { i in
                    HStack(spacing: 8) {
                        ForEach(Array(items[i..<min(i + 2, items.count)]), id: \.self) { secondary($0, .stacked) }
                    }
                }
            }
            VStack(spacing: 8) { ForEach(items, id: \.self) { secondary($0, .inline) } }
        }
    }

    @ViewBuilder
    private func secondary(_ choice: Choice, _ layout: DetailChoiceLayout) -> some View {
        switch choice {
        case .share:
            DetailChoiceButton(
                title: Copy.Media.share, symbol: Symbol.Media.share, working: controller.preparingShare, layout: layout
            ) { share([r]) }
        case .savePhotos:
            let state = controller.photos[r.id] ?? .idle
            switch placement {
            case .inAlbum:
                DetailChoiceButton(title: Copy.Sync.inAlbum, symbol: Symbol.Sync.inPhotos, inert: true, layout: layout) {}
            case .inLibrary:
                DetailChoiceButton(title: Copy.Sync.inLibrary, symbol: Symbol.Sync.inPhotos, inert: true, layout: layout) {}
            case .none:
                DetailChoiceButton(
                    title: Self.saveTitle(done: state == .done), symbol: state == .done ? Symbol.checkmark : Self.saveSymbol,
                    working: state == .working, layout: layout
                ) { Task { await controller.savePhotos(r, in: item) } }
            }
        case .makeWebp:
            DetailChoiceButton(title: Copy.Gallery.makeAWebp, symbol: Symbol.Media.makeWebp, layout: layout) {
                if controller.makeWebp(ofItem: r, in: item) { leave() }
            }
        }
    }
}

// MARK: - select photos

/// `select photos` is on (the `more` menu): `3 selected` and `done`, then share, to photos, delete for the ticked ones. A tap
/// on a tile of the strip (or the big photo) ticks it.
struct GallerySelectionBar: View {
    let c: DetailContext
    /// Shares the ticked files. A chosen photo may still need a download, so this is not gated on a URL.
    let share: ([Rendition]) -> Void

    private var controller: DetailController { c.controller }
    private var chosen: [Rendition] { controller.pickedRenditions(in: c.item) }
    @Environment(\.hapticsEnabled) private var haptics

    var body: some View {
        let chosen = chosen
        let none = chosen.isEmpty
        let all = !c.item.items.isEmpty && chosen.count == c.item.items.filter { $0.itemIndex != nil }.count
        VStack(spacing: 10) {
            HStack {
                Text(DetailWords.selected(chosen.count))
                    .font(Font.cobalt(13, .medium, relativeTo: .footnote))
                    .contentTransition(.numericText())
                Spacer()
                Button(all ? DetailWords.selectNone : DetailWords.selectAll) {
                    withAnimation(Motion.rows) { controller.toggleAll(in: c.item) }
                }
                .buttonStyle(.cobaltSecondary(fullWidth: false, compact: true))
                Button(DetailWords.doneSelecting) { withAnimation(Motion.rows) { controller.endSelecting() } }
                    .buttonStyle(.cobaltSecondary(fullWidth: false, compact: true))
            }
            GlassEffectContainer(spacing: 0) {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) { buttons(chosen, .stacked) }
                    VStack(spacing: 8) { buttons(chosen, .inline) }
                }
            }
            .disabled(none || controller.isDeleting)
        }
        .accessibilityElement(children: .contain)
        .haptic(.selection, trigger: chosen.count, enabled: haptics)
    }

    @ViewBuilder
    private func buttons(_ chosen: [Rendition], _ layout: DetailChoiceLayout) -> some View {
        DetailChoiceButton(
            title: Copy.Media.share, symbol: Symbol.Media.share, working: controller.preparingShare, layout: layout
        ) { share(chosen) }
        DetailChoiceButton(
            title: DetailWords.toPhotos, symbol: GalleryActions.saveSymbol, working: controller.batchPhotos == .working,
            layout: layout
        ) { Task { await controller.saveToPhotos(chosen, of: c.item) } }
        DetailChoiceButton(title: DetailWords.deleteN(chosen.count), symbol: Symbol.Media.deleteWebp, layout: layout) {
            let indices = chosen.compactMap(\.itemIndex).sorted()
            controller.confirm = indices.count == 1 ? .deletePhoto(indices[0]) : .deletePhotos(indices)
        }
    }
}

// MARK: - make from this post

/// The row that opens the combine sheet (CONTRACT-GALLERY 1.15): a slideshow webp, a slideshow mp4 or a gallery image from the
/// post's photos. Disabled with the reason under it when the server cannot make them, the post has expired, or it has too few
/// items. The sheet itself is lane A2's (`Screens/Combine`).
struct GalleryMakeRow: View {
    let controller: DetailController
    let item: MediaItem

    var body: some View {
        let availability = controller.makeAvailability(item)
        Section {
            Button {
                controller.showsMakeSheet = true
            } label: {
                Label(DetailWords.makeFromPost, systemImage: Symbol.Gallery.make)
            }
            .disabled(availability != .ready || controller.isDeleting)
        } footer: {
            Text(footnote(availability))
                .font(CobaltType.captionSmall)
                .foregroundStyle(availability == .ready ? Color.secondary : CobaltColor.errorText)
        }
        .font(CobaltType.body)
    }

    private func footnote(_ a: DetailController.MakeAvailability) -> String {
        switch a {
        case .ready: return DetailWords.makeSubtitle
        case .serverCant: return Copy.Gallery.serverCantMake
        case .expired: return DetailWords.makeExpired
        case .needsTwo: return DetailWords.makeNeedsTwo
        }
    }
}
