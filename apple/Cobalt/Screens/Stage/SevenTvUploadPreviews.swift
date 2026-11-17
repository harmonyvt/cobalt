#if DEBUG
import CobaltKit
import SwiftUI

// `#Preview`s of "upload to 7tv" (APP-API-CONTRACT 57.9) on the preview server (`PreviewSevenTv.swift`): the form, the form
// with a set picked, a big webp the server shrinks (57.10: the size row and a "sent as" line after), an avif over the cap, a
// picture too tall for 7TV, a refused file, and a real run (processing, then done after one 5 s poll).

/// Loads the account the way the detail page does, makes the sheet's model, and (with `run`) uploads at once.
private struct LoadedUpload: View {
    let model: AppModel
    var fileID = "f_preview_capy_webp"
    var bytes: Int64? = 412_000
    var contentType: String? = "image/webp"
    var width: Int?
    var height: Int?
    var addToSet = false
    var run = false

    @State private var upload: SevenTvUploadModel?

    var body: some View {
        Group {
            if let upload {
                SevenTvUploadSheet(upload: upload)
            } else {
                Color.clear
            }
        }
        .task {
            await model.sevenTv.load()
            let made = model.sevenTv.uploader(
                fileID: fileID, bytes: bytes, title: "capy dance party.webp", contentType: contentType, width: width, height: height)
            if addToSet {
                made.addToSet = true
                await made.prepareSets()
            }
            upload = made
            if run { await made.upload() }
        }
    }
}

#Preview("7tv upload · form", traits: .fixedLayout(width: 390, height: 640)) {
    PreviewHost(.happy, tab: .stage) { model in
        LoadedUpload(model: model)
    }
}
#Preview("7tv upload · into a set, dark", traits: .fixedLayout(width: 390, height: 720)) {
    PreviewHost(.happy, tab: .stage) { model in
        LoadedUpload(model: model, addToSet: true)
    }
    .preferredColorScheme(.dark)
}
#Preview("7tv upload · big, shrunk to fit", traits: .fixedLayout(width: 390, height: 640)) {
    PreviewHost(.happy, tab: .stage) { model in
        LoadedUpload(model: model, fileID: "f_preview_big_webp", bytes: 9_400_000, width: 1_600, height: 1_600)
    }
}
#Preview("7tv upload · big, shrunk, sent", traits: .fixedLayout(width: 390, height: 520)) {
    PreviewHost(.happy, tab: .stage) { model in
        LoadedUpload(model: model, fileID: "f_preview_big_webp", bytes: 9_400_000, run: true)
    }
}
#Preview("7tv upload · avif too big", traits: .fixedLayout(width: 390, height: 640)) {
    PreviewHost(.happy, tab: .stage) { model in
        LoadedUpload(model: model, bytes: 9_400_000, contentType: "image/avif")
    }
}
#Preview("7tv upload · too tall, needs a crop", traits: .fixedLayout(width: 390, height: 640)) {
    PreviewHost(.happy, tab: .stage) { model in
        LoadedUpload(model: model, fileID: "f_preview_tall_webp", width: 100, height: 3_600)
    }
}
#Preview("7tv upload · refused file", traits: .fixedLayout(width: 390, height: 640)) {
    PreviewHost(.happy, tab: .stage) { model in
        LoadedUpload(model: model, fileID: "f_preview_video", run: true)
    }
}
#Preview("7tv upload · processing, then done", traits: .fixedLayout(width: 390, height: 520)) {
    PreviewHost(.happy, tab: .stage) { model in
        LoadedUpload(model: model, addToSet: true, run: true)
    }
}
#Preview("7tv upload · AX3 text", traits: .fixedLayout(width: 390, height: 1000)) {
    PreviewHost(.happy, tab: .stage) { model in
        LoadedUpload(model: model, addToSet: true)
    }
    .dynamicTypeSize(.accessibility3)
}
#Preview("7tv upload · mac", traits: .fixedLayout(width: 460, height: 600)) {
    PreviewHost(.happy, tab: .stage) { model in
        LoadedUpload(model: model)
    }
}
#endif
