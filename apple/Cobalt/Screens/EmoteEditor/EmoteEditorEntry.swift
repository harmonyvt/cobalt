import CobaltKit
import SwiftUI

// The ways into the emote editor (APP-API-CONTRACT 71.4): "make an emote" on a post's page (the icon of the actions' secondary
// row) and in its `more` menu and the library's context menu, for a picture, gif, webp or video; and the 7tv upload page's
// "make an emote" (pick a picture, then the editor). Presented like the picture crop sheet: full screen on iPhone and iPad, a
// sheet (the editor's own window size) on the Mac.

/// Presents the editor on `target`.
struct EmoteEditorPresenter: ViewModifier {
    let model: AppModel
    @Binding var target: EmoteEditorTarget?

    func body(content: Content) -> some View {
        #if os(iOS)
        content.fullScreenCover(item: $target) { picked in
            EmoteEditorScreen(model: model, target: picked) { target = nil }
        }
        #else
        content.sheet(item: $target) { picked in
            EmoteEditorScreen(model: model, target: picked) { target = nil }
        }
        #endif
    }
}

extension AppModel {
    /// The editor target for a rendition of a post, when the server makes emotes and the file is one it takes.
    @MainActor
    func emoteTarget(rendition: Rendition?, title: String?) -> EmoteEditorTarget? {
        guard canMakeEmotes, let rendition else { return nil }
        return EmoteEditorTarget(rendition: rendition, title: title)
    }

    /// The editor target for a library post: its first picture or video an emote can be made from.
    @MainActor
    func emoteTarget(item: MediaItem) -> EmoteEditorTarget? {
        guard canMakeEmotes else { return nil }
        let candidates = item.items + (item.video.map { [$0] } ?? [])
        for rendition in candidates {
            if let target = EmoteEditorTarget(rendition: rendition, title: item.titleText) { return target }
        }
        return nil
    }
}

/// The secondary-row icon of a post's page; nothing when the file cannot be made into an emote here.
struct EmoteEditorIcon: View {
    let model: AppModel
    let rendition: Rendition
    let title: String?

    @State private var target: EmoteEditorTarget?

    var body: some View {
        if let made = model.emoteTarget(rendition: rendition, title: title) {
            DetailChoiceButton(title: Copy.EmoteEditor.makeAnEmote, symbol: Symbol.EmoteEditor.make) { target = made }
                .modifier(EmoteEditorPresenter(model: model, target: $target))
        }
    }
}
