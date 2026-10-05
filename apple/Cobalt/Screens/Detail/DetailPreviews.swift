#if DEBUG
import CobaltKit
import SwiftUI

/// The media of the `.renditions` scenario cut to a size, for the previews: the instagram `Dd7P496wolG` media with
/// its video and up to five webps (the preview data has three; more are copies a few minutes later), the
/// webp-only media, or the plain save of `.plainCobalt`. The library's post is joined and cut to match, so the
/// previews show the same merged `MediaItem` the app builds.
@MainActor
enum DetailPreviewItems {
    static func showcase(_ model: AppModel, webps count: Int, video: Bool = true) -> MediaItem {
        let base = model.store.media.first { $0.webps.count >= 3 && $0.original != nil } ?? model.store.media[0]
        var webps = base.webps
        var n = 0
        while webps.count < count, let last = webps.last {
            n += 1
            var more = last
            more.id = "preview-extra-webp-\(n)"
            more.createdAt = last.createdAt.addingTimeInterval(180)
            more.remoteURL = last.remoteURL?.deletingLastPathComponent().appendingPathComponent("PrEvIeW0\(20 + n).webp")
            webps.append(more)
        }
        webps = Array(webps.prefix(count))
        let local = StoredMedia(id: base.id, original: video ? base.original : nil, webps: webps)!
        var post = model.library.posts.first { MediaItem.joins(base, $0) }
        let urls = Set(webps.compactMap(\.remoteURL))
        let kept = (post?.files ?? []).filter { file in
            switch file.role {
            case .webp: return file.url.map(urls.contains) ?? false
            case .privateCopy, .hostedLink: return video
            }
        }
        post?.files = kept
        let joined = kept.isEmpty ? nil : post
        return MediaItem.merge(local: local, post: joined)!
    }

    /// The media that has only a webp on this device (the original was not kept).
    static func webpOnly(_ model: AppModel) -> MediaItem {
        let local = model.store.media.first { $0.original == nil } ?? model.store.media[0]
        return model.mediaItem(for: local)
    }

    /// The first plain save (no studio, no webps).
    static func plain(_ model: AppModel) -> MediaItem {
        model.mediaItem(for: model.store.media.first { $0.webps.isEmpty } ?? model.store.media[0])
    }
}

/// One detail in a navigation stack over `AppModel.preview`.
@MainActor
private func detailPreview(
    _ scenario: PreviewScenario = .renditions,
    item: @escaping @MainActor (AppModel) -> MediaItem,
    tab: Int? = nil,
    preset: (@MainActor (MediaItem) -> DetailPreset)? = nil
) -> some View {
    PreviewHost(scenario) { model in
        let media = item(model)
        NavigationStack {
            MediaDetail(
                preview: model, item: media, initial: tab.flatMap { media.renditions.indices.contains($0) ? media.renditions[$0].id : nil },
                preset: preset?(media))
        }
    }
}

#Preview("detail · 1 rendition (webp only)") {
    detailPreview(item: { DetailPreviewItems.webpOnly($0) })
}
#Preview("detail · 2 renditions") {
    detailPreview(item: { DetailPreviewItems.showcase($0, webps: 1) })
}
#Preview("detail · 4 renditions, segmented") {
    detailPreview(item: { DetailPreviewItems.showcase($0, webps: 3) })
}
#Preview("detail · 4 renditions, webp 2 (cropped 1:1)") {
    detailPreview(item: { DetailPreviewItems.showcase($0, webps: 3) }, tab: 2)
}
#Preview("detail · 6 renditions, chip row") {
    detailPreview(item: { DetailPreviewItems.showcase($0, webps: 5) }, tab: 5)
}
#Preview("detail · evicted webp") {
    detailPreview(item: { DetailPreviewItems.showcase($0, webps: 3) }, tab: 1)
}
#Preview("detail · plain cobalt") {
    detailPreview(.plainCobalt, item: { DetailPreviewItems.plain($0) })
}
#Preview("detail · photos: in your cobalt album") {
    detailPreview(item: { DetailPreviewItems.showcase($0, webps: 3) }, tab: 1) { _ in
        DetailPreset(placement: .inAlbum)
    }
}
#Preview("detail · photos: in your photos, plain cobalt") {
    detailPreview(.plainCobalt, item: { DetailPreviewItems.plain($0) }) { _ in
        DetailPreset(placement: .inLibrary)
    }
}
#Preview("detail · wide, two columns", traits: .fixedLayout(width: 1100, height: 760)) {
    detailPreview(item: { DetailPreviewItems.showcase($0, webps: 3) }, tab: 2)
}
#Preview("detail · wide, six tabs, video", traits: .fixedLayout(width: 1100, height: 760)) {
    detailPreview(item: { DetailPreviewItems.showcase($0, webps: 5) }, tab: 0)
}
#Preview("detail · AX5 type") {
    detailPreview(item: { DetailPreviewItems.showcase($0, webps: 3) }, tab: 2)
        .dynamicTypeSize(.accessibility5)
}
#Preview("detail · dark") {
    detailPreview(item: { DetailPreviewItems.showcase($0, webps: 3) }, tab: 2)
        .preferredColorScheme(.dark)
}

// MARK: - getting rid of things

#Preview("detail · confirm delete this webp") {
    detailPreview(item: { DetailPreviewItems.showcase($0, webps: 3) }, tab: 2) { media in
        DetailPreset(confirm: .deleteWebp(media.renditions[2].id))
    }
}
#Preview("detail · delete webp failed") {
    detailPreview(item: { DetailPreviewItems.showcase($0, webps: 3) }, tab: 2) { media in
        DetailPreset(phase: .failed, retry: .deleteWebp(media.renditions[2].id))
    }
}
#Preview("detail · confirm delete everything (route b)") {
    detailPreview(.renditions, item: { DetailPreviewItems.showcase($0, webps: 3) }) { _ in
        DetailPreset(confirm: .deleteEverything)
    }
}
#Preview("detail · confirm delete everything (fallback a)") {
    detailPreview(.renditionsLegacy, item: { DetailPreviewItems.showcase($0, webps: 3) }) { _ in
        DetailPreset(confirm: .deleteEverything)
    }
}
#Preview("detail · deleting") {
    detailPreview(item: { DetailPreviewItems.showcase($0, webps: 3) }) { _ in
        DetailPreset(phase: .deleting, retry: .deleteEverything)
    }
}
#Preview("detail · partial, try again") {
    detailPreview(item: { DetailPreviewItems.showcase($0, webps: 3) }) { _ in
        DetailPreset(phase: .partial(remaining: 1), retry: .deleteEverything)
    }
}
#Preview("detail · busy, delete everything disabled") {
    detailPreview(item: { DetailPreviewItems.showcase($0, webps: 3) }) { _ in
        DetailPreset(busy: true)
    }
}
#endif
