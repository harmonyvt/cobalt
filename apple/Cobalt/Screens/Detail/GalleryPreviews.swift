#if DEBUG
import CobaltKit
import SwiftUI

// `#Preview`s and launch flags of the gallery detail (CONTRACT-GALLERY 1.18-1.20), over the gallery preview scenarios of
// `AppModel.preview(...)`: the post is pasted into the preview server, saved, listed by the preview library, and its detail is
// opened over the real model (a make, a delete, the switch all run against the preview server). Makes are driven through
// `AppModel.make(_:from:)` before the detail shows, so the made tabs are the files the model stored.

/// The launch flags that put a detail in a state for a screenshot (all debug builds; `-previewDetail N` opens the detail):
///
///     -previewDetailPage N        a gallery's page, by the item's place in the post (0-based)
///     -previewDetailSelect 1,2    `select photos` on, with those items (0-based) ticked
///     -previewDetailMake 1        the combine sheet is up
///     -previewDetailConfirm photo | made     the confirm of a delete (with the page or the shown made file)
///     -previewDetailAuto <what>   presses a button a second and a half after the detail is up, through the same calls the
///                                 buttons make: deletePhoto, deleteMade, deletePicked (the `-previewDetailSelect` ones),
///                                 retry (the missing photo), saveAll, links (copy all links), text (copy text of the page),
///                                 switchOff (the whole post private), webp (make a webp of the page, a video or a gif)
@MainActor
enum GalleryDebug {
    private static let defaults = UserDefaults.standard
    private static var applied = false

    static func apply(to controller: DetailController, item: @MainActor () -> MediaItem, leave: @MainActor () -> Void) async {
        guard !applied else { return }
        let page = defaults.string(forKey: "previewDetailPage").flatMap(Int.init)
        let select = defaults.string(forKey: "previewDetailSelect")
        let make = defaults.bool(forKey: "previewDetailMake")
        let confirm = defaults.string(forKey: "previewDetailConfirm")
        let auto = defaults.string(forKey: "previewDetailAuto")
        let galleryAuto = ["deletePhoto", "deleteMade", "deletePicked", "retry", "saveAll", "links", "text", "switchOff", "webp"]
        let wantsAuto = auto.map(galleryAuto.contains) ?? false
        guard page != nil || select != nil || make || confirm == "photo" || confirm == "made" || wantsAuto else { return }
        applied = true
        try? await Task.sleep(for: .milliseconds(500))
        if let page { controller.pageIndex = page; controller.selectedID = nil }
        if let select {
            controller.selecting = true
            controller.picked = Set(select.split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) })
        }
        if make { controller.showsMakeSheet = true }
        try? await Task.sleep(for: .milliseconds(400))
        if confirm == "photo", let index = controller.pageIndex ?? page { controller.confirm = .deletePhoto(index) }
        if confirm == "made", let id = controller.selectedID { controller.confirm = .deleteMade(id) }
        guard wantsAuto, let auto else { return }
        try? await Task.sleep(for: .milliseconds(1500))
        let now = item()
        let shown = controller.selected(in: now)
        switch auto {
        case "deletePhoto": if let index = controller.currentPage(in: now)?.index { await controller.deletePhotos([index], of: now) }
        case "deleteMade": await controller.deleteMade(shown, of: now)
        case "deletePicked": await controller.deletePhotos(controller.picked.sorted(), of: now)
        case "retry": await controller.retryMissing(now)
        case "saveAll": await controller.saveToPhotos(now.items, of: now)
        case "links": controller.copyAllLinks(now)
        case "text": await controller.copyText(of: shown)
        case "switchOff": await controller.setPostPublic(!controller.isPostPublic(now), for: now)
        case "webp": if controller.makeWebp(ofItem: shown, in: now) { leave() }
        default: break
        }
    }
}

/// What a preview makes from the post before the detail shows.
private enum PreviewMake {
    case webp, mp4, image(GalleryLayout)
}

/// Pastes a gallery into the preview scenario, waits for the save, makes what was asked, then shows its detail.
@MainActor
private struct GalleryDetailScene: View {
    let model: AppModel
    var link = "https://www.instagram.com/p/Ddy0-gpGg5U/"
    var makes: [PreviewMake] = []
    /// The tab to open on: the index into the media's renditions after the makes (items first).
    var tab: Int?
    var preset = DetailPreset()
    @State private var item: MediaItem?

    var body: some View {
        Group {
            if let item {
                NavigationStack {
                    MediaDetail(
                        live: model, item: item,
                        initial: tab.flatMap { latest(item).renditions.indices.contains($0) ? latest(item).renditions[$0].id : nil },
                        preset: preset)
                }
            } else {
                ProgressView().controlSize(.large)
            }
        }
        .task { await prepare() }
    }

    private func latest(_ item: MediaItem) -> MediaItem {
        model.store.media.first.map { model.mediaItem(for: $0) } ?? item
    }

    private func prepare() async {
        guard item == nil else { return }
        model.pipeline.start(pastedText: link)
        for _ in 0..<300 {
            try? await Task.sleep(for: .milliseconds(100))
            if model.pipeline.galleryRun?.phase == .saved { break }
        }
        try? await Task.sleep(for: .milliseconds(500))
        await model.library.refresh()
        guard var current = model.store.media.first.map({ model.mediaItem(for: $0) }) else { return }
        for make in makes {
            let items = current.items.compactMap(\.itemIndex)
            let wanted: GalleryMake
            switch make {
            case .webp: wanted = .slideshow(.standard(.webp, items: items, settings: model.settings))
            case .mp4: wanted = .slideshow(.standard(.mp4, items: items, settings: model.settings))
            case .image(let layout): wanted = .image(GalleryImagePlan(items: items, layout: layout))
            }
            let before = current.made.count
            try? await model.make(wanted, from: current)
            for _ in 0..<300 {
                try? await Task.sleep(for: .milliseconds(100))
                await model.library.refresh()
                if let next = model.store.media.first.map({ model.mediaItem(for: $0) }), next.made.count > before { current = next; break }
            }
        }
        item = current
    }
}

@MainActor
private func scene(
    _ scenario: PreviewScenario, link: String = "https://www.instagram.com/p/Ddy0-gpGg5U/", makes: [PreviewMake] = [], tab: Int? = nil,
    preset: DetailPreset = DetailPreset()
) -> some View {
    PreviewHost(scenario) { model in GalleryDetailScene(model: model, link: link, makes: makes, tab: tab, preset: preset) }
}

private let xLink = "https://x.com/ilokineedsleep/status/2106850389551374806"
private let oneLink = "https://x.com/ilokineedsleep/status/2106850389551374807"
private let mixLink = "https://www.instagram.com/p/DdMix1xedPo/"

#Preview("gallery detail · instagram, 10 photos") {
    scene(.galleryInstagram)
}
#Preview("gallery detail · photo 7 never saved") {
    scene(.galleryPartial, preset: DetailPreset(page: 6))
}
#Preview("gallery detail · x, 4 photos") {
    scene(.galleryX, link: xLink)
}
#Preview("gallery detail · mixed, the video item") {
    scene(.galleryMixed, link: mixLink, preset: DetailPreset(page: 2))
}
#Preview("gallery detail · one photo") {
    scene(.galleryOne, link: oneLink)
}
#Preview("gallery detail · select photos, 3 ticked") {
    scene(.galleryInstagram, preset: DetailPreset(selecting: [1, 3, 4]))
}
#Preview("gallery detail · slideshow webp tab") {
    scene(.galleryInstagram, makes: [.webp], tab: 10)
}
#Preview("gallery detail · gallery image tab (3 across)") {
    scene(.galleryInstagram, makes: [.image(.grid3)], tab: 10)
}
#Preview("gallery detail · three made tabs, chips") {
    scene(.galleryInstagram, makes: [.webp, .mp4, .image(.strip)], tab: 10)
}
#Preview("gallery detail · confirm delete photo 4") {
    scene(.galleryInstagram, preset: DetailPreset(confirm: .deletePhoto(3), page: 3))
}
#Preview("gallery detail · server cannot make") {
    scene(.galleryNoMake)
}
#Preview("gallery detail · wide", traits: .fixedLayout(width: 1100, height: 760)) {
    scene(.galleryInstagram)
}
#Preview("gallery detail · dark") {
    scene(.galleryInstagram).preferredColorScheme(.dark)
}
#Preview("gallery detail · AX5 type") {
    scene(.galleryInstagram).dynamicTypeSize(.accessibility5)
}
#endif
