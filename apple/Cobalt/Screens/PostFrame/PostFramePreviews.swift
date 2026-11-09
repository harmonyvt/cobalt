#if DEBUG
import CobaltKit
import SwiftUI

// Post frames against the preview server (`PreviewPostFrame.swift`): the X post of the library's kitchen timer loop, the
// Instagram reel whose post is gone, the editor's sheet on a preview project's clip, and every card light and dark.

private enum PostFramePreviewTargets {
    /// `kitchen timer loop`: an X post (found, verified, counts).
    static let x = PostFrameTarget(
        itemID: "PrEvIeWitem000006", mode: .item, link: URL(string: "https://x.com/i/status/2105435404002562056"),
        poster: nil, width: 480, height: 568, duration: 5.46)
    /// The second Instagram reel: its post is gone (`found` false).
    static let goneReel = PostFrameTarget(
        itemID: "PrEvIeWitem000004", mode: .item, link: URL(string: "https://www.instagram.com/reel/Dd7P496wolG/"),
        poster: URL(string: "https://media.capybaraharmony.com/PrEvIeWp22.jpg"), width: 720, height: 1280, duration: 14.77)
    /// The editor's "post" tool on the pier clip, trimmed to 2...9 s.
    static let editor = PostFrameTarget(
        itemID: "PrEvIeWedSrc0001", mode: .editor(from: 2, to: 9), link: nil, poster: nil, width: 1920, height: 1080,
        duration: 12)
}

#Preview("post frame · item, x") {
    PreviewHost(.happy, tab: .library) { model in
        Color.clear.sheet(isPresented: .constant(true)) {
            PostFrameSheet(model: model, target: PostFramePreviewTargets.x).cobaltRoot(model: model)
        }
    }
}

#Preview("post frame · item, post gone") {
    PreviewHost(.happy, tab: .library) { model in
        Color.clear.sheet(isPresented: .constant(true)) {
            PostFrameSheet(model: model, target: PostFramePreviewTargets.goneReel).cobaltRoot(model: model)
        }
    }
}

#Preview("post frame · editor") {
    PreviewHost(.happy, tab: .library) { model in
        Color.clear.sheet(isPresented: .constant(true)) {
            PostFrameSheet(model: model, target: PostFramePreviewTargets.editor).cobaltRoot(model: model)
        }
    }
}

#Preview("post frame · every card") {
    PostFrameCardGallery()
}

/// The five styles, light and dark, with invented details.
private struct PostFrameCardGallery: View {
    private let now = Date()

    private func content(_ style: PostFrameStyle, _ theme: PostFrameTheme) -> PostCardContent {
        let link: String
        switch style {
        case .x: link = "https://x.com/mochibytes/status/1"
        case .instagram: link = "https://www.instagram.com/reel/AbCdEf/"
        case .twitch: link = "https://clips.twitch.tv/SomeClip"
        case .youtube: link = "https://www.youtube.com/watch?v=abc"
        case .generic: link = "https://vimeo.com/123"
        }
        let details = PostDetails(
            link: link, site: style, found: true, name: "mochi", handle: "@mochibytes",
            text: "the cat learned to open the fridge and now we live in fear", title: "the fridge incident",
            channel: "mochi", game: "Just Chatting", siteName: style == .generic ? "vimeo" : nil,
            postedAt: now.addingTimeInterval(-86_400), counts: PostCounts(likes: 18_000, reposts: 2_100, replies: 312, views: 402_000,
                                                                         comments: 381, subscribers: 1_200_000),
            verified: true)
        return PostCardContent(
            details: details, style: style, theme: theme, show: .all, videoAspect: 16 / 9, poster: nil, duration: 12, avatar: nil)
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                ForEach(PostFrameStyle.allCases, id: \.self) { style in
                    HStack(alignment: .top, spacing: 16) {
                        PostFramePreview(content: content(style, .light), canvas: .fit, maxWidth: 300, maxHeight: 420)
                        PostFramePreview(content: content(style, .dark), canvas: .fit, maxWidth: 300, maxHeight: 420)
                    }
                }
                PostFramePreview(content: content(.x, .dark), canvas: .portrait, maxWidth: 220, maxHeight: 390)
            }
            .padding()
        }
        .background(Color(hex: 0x0e0e11))
    }
}
#endif
