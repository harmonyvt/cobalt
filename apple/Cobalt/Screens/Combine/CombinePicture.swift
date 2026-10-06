import CobaltKit
import SwiftUI

/// One item's picture, from the first source that loads (this device's copy, the server's poster, the picker's thumb), decoded
/// off the main thread at `maxPixel` and cached by the library's loader. No picture yet (or ever) leaves the board's
/// neutral frame with the item's number, so a combine sheet over a post whose thumbs are gone still reads as a row of items.
struct CombinePicture: View {
    let sources: [LibraryPictureSource]
    let maxPixel: Int
    let item: GalleryItem?
    let number: Int
    /// `fill` crops to the frame; `fit` shows the whole picture.
    var fills = true
    var showsNumber = true
    @State private var image: ImageBox?

    init(
        sources: [LibraryPictureSource], maxPixel: Int, item: GalleryItem?, number: Int, fills: Bool = true,
        showsNumber: Bool = true
    ) {
        self.sources = sources
        self.maxPixel = maxPixel
        self.item = item
        self.number = number
        self.fills = fills
        self.showsNumber = showsNumber
        _image = State(initialValue: LibraryPictureCache.shared.first(in: sources, maxPixel: maxPixel))
    }

    private struct LoadKey: Hashable {
        let sources: [LibraryPictureSource]
        let maxPixel: Int
    }

    var body: some View {
        ZStack {
            if let image {
                Image(decorative: image.image, scale: 1)
                    .resizable()
                    .aspectRatio(contentMode: fills ? .fill : .fit)
                    .transition(.opacity)
            } else {
                placeholder
            }
        }
        .animation(.easeOut(duration: 0.2), value: image != nil)
        .task(id: LoadKey(sources: sources, maxPixel: maxPixel)) {
            for source in sources {
                let box = await LibraryPictureLoader.shared.picture(source, maxPixel: maxPixel)
                if Task.isCancelled { return }
                if let box {
                    image = box
                    return
                }
            }
        }
    }

    private var placeholder: some View {
        Rectangle()
            .fill(FrameGradient.fill(FrameGradient.variant(forIndex: number)))
            .overlay {
                if showsNumber {
                    if item?.isPhoto == false {
                        Image(systemName: Symbol.Gallery.video)
                            .font(.system(size: 14, weight: .regular))
                            .foregroundStyle(CobaltColor.badgeInk.opacity(0.7))
                    } else {
                        Text("\(number + 1)")
                            .font(.cobalt(13, .medium, relativeTo: .caption))
                            .foregroundStyle(CobaltColor.badgeInk.opacity(0.7))
                    }
                }
            }
    }
}

/// The aspect (width / height) of an item; a post that has not told its size yet counts as 4:5 (like `MakeEstimate`).
func combineAspect(_ item: GalleryItem?) -> CGFloat {
    guard let size = item?.size else { return 4.0 / 5.0 }
    return size.width / size.height
}
