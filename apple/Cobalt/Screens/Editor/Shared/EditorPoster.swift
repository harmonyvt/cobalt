import SwiftUI

/// A library file's poster, filling its frame, over a flat colour that stands in until it loads (and for good when the server
/// sent none). Decoded off the main thread through the library's picture loader (memory and disk cache).
///
/// Shared: the bin's tiles, the shelf's covers, the timeline's filmstrips and the crop view all use it.
struct EditorPoster: View {
    let url: URL?
    var fallback: Color = CobaltColor.elevated
    var maxPixel: Int = 320
    @State private var image: ImageBox?

    var body: some View {
        fallback
            .overlay {
                if let image {
                    Image(decorative: image.image, scale: 1)
                        .resizable()
                        .scaledToFill()
                        .transition(.opacity)
                }
            }
            .clipped()
            .animation(.easeOut(duration: 0.2), value: image != nil)
            .task(id: url) {
                guard let url else {
                    image = nil
                    return
                }
                let source: LibraryPictureSource = url.isFileURL ? .file(url) : .image(url)
                image = await LibraryPictureLoader.shared.picture(source, maxPixel: maxPixel)
            }
    }
}
