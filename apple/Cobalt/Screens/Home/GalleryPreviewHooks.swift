#if DEBUG
import CobaltKit
import Foundation
import Observation

/// `-previewGalleryImages <dir>` (simulator evidence, debug builds only): the preview server "downloads" a 70-byte
/// placeholder for every item, so a gallery's planets and cover would be grey. With a folder of `01.jpg … 10.jpg` given, every
/// placeholder item the store holds is replaced by the picture whose number is the item's (modulo 10), the way
/// `-previewClip` does for a video, so the cover, the planets and the front band's turn show real pictures.
@MainActor @Observable
final class GalleryPreviewGeneration {
    static let shared = GalleryPreviewGeneration()
    var value = 0
}

@MainActor
enum GalleryPreviewImages {
    nonisolated static let directory: URL? = UserDefaults.standard.string(forKey: "previewGalleryImages")
        .flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }

    static func run(_ model: AppModel) async {
        guard let dir = directory else { return }
        let fm = FileManager.default
        var seen: Set<String> = []
        while !Task.isCancelled {
            for video in model.store.videos where video.role == .item && !seen.contains(video.id) {
                guard let file = video.fileURL, let size = (try? fm.attributesOfItem(atPath: file.path)[.size]) as? Int, size > 0 else { continue }
                seen.insert(video.id)
                guard size < 4_096 else { continue }
                let number = ((video.itemIndex ?? 0) % 10) + 1
                let picture = dir.appendingPathComponent(String(format: "%02d.jpg", number))
                try? fm.removeItem(at: file)
                try? fm.copyItem(at: picture, to: file)
                await ImageLoader.shared.evict(file)
                GalleryPreviewGeneration.shared.value += 1
            }
            try? await Task.sleep(for: .milliseconds(40))
        }
    }
}
#endif
