import CobaltKit
import SwiftUI

/// What the detail's hero borrows its poster from when the media has none on this device: the face's public
/// animated webp (its first frame) or the hosted mp4 (a frame from the start), both from the server's public
/// media bucket. Private-only media have neither, and keep their placeholder. (The library's tiles have their
/// own chain, `FacePicture`; this one stays for `RenditionHero`.)
struct RemotePoster: Equatable, Sendable {
    let url: URL
    let isVideo: Bool

    init(url: URL, isVideo: Bool) {
        self.url = url
        self.isVideo = isVideo
    }

    var source: LibraryPictureSource { isVideo ? .videoFrame(url) : .image(url) }
}

/// A poster from the network, filling its frame. Blank until decoded, and blank when it cannot be. Decoded off
/// the main thread at thumbnail size through the library's picture loader (memory and disk cache).
struct RemoteStill: View {
    let poster: RemotePoster
    var maxPixel: Int = 360
    @State private var image: ImageBox?

    var body: some View {
        Color.clear
            .overlay {
                if let image {
                    Image(decorative: image.image, scale: 1).resizable().scaledToFill().transition(.opacity)
                }
            }
            .clipped()
            .animation(.easeOut(duration: 0.25), value: image != nil)
            .task(id: poster) { image = await LibraryPictureLoader.shared.picture(poster.source, maxPixel: maxPixel) }
    }
}
