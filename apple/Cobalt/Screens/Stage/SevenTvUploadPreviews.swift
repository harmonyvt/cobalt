#if DEBUG
import CobaltKit
import SwiftUI

// `#Preview`s of "upload to 7tv" (APP-API-CONTRACT 57.9) on the preview server (`PreviewSevenTv.swift`): the form, the form
// with a set picked, a file over 7TV's cap, a refused file, and a real run (processing, then done after one 5 s poll).

/// Loads the account the way the detail page does, makes the sheet's model, and (with `run`) uploads at once.
private struct LoadedUpload: View {
    let model: AppModel
    var fileID = "f_preview_capy_webp"
    var bytes: Int64? = 412_000
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
            let made = model.sevenTv.uploader(fileID: fileID, bytes: bytes, title: "capy dance party.webp")
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
#Preview("7tv upload · too big", traits: .fixedLayout(width: 390, height: 640)) {
    PreviewHost(.happy, tab: .stage) { model in
        LoadedUpload(model: model, bytes: 9_400_000)
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
