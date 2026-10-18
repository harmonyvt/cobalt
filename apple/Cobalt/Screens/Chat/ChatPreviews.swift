#if DEBUG
import CobaltKit
import SwiftUI

// `#Preview`s of the chat tab on the preview server: three sample threads (one with code steps and shown files, one with a
// step that failed and recovered, one with a deleted file), none yet, and a listing that fails; a finished thread, a reply
// streaming in, a failed reply, the composer with a file attached, and the Mac's width. The thumbnails are network pictures,
// so they stay blank in a preview.

private let sampleThread = "PrEvIeWchat00001"
private let deletedPostThread = "PrEvIeWchat00003"

#Preview("chat · happy", traits: .fixedLayout(width: 390, height: 844)) {
    PreviewHost(.happy, tab: .chat) { model in NavigationStack { ChatScreen(model: model, tier: .compact) } }
}
#Preview("chat · happy, dark", traits: .fixedLayout(width: 390, height: 844)) {
    PreviewHost(.happy, tab: .chat) { model in NavigationStack { ChatScreen(model: model, tier: .compact) } }
        .preferredColorScheme(.dark)
}
#Preview("chat · empty", traits: .fixedLayout(width: 390, height: 844)) {
    PreviewHost(.chatEmpty, tab: .chat) { model in NavigationStack { ChatScreen(model: model, tier: .compact) } }
}
#Preview("chat · listing fails", traits: .fixedLayout(width: 390, height: 844)) {
    PreviewHost(.chatFail, tab: .chat) { model in NavigationStack { ChatScreen(model: model, tier: .compact) } }
}
#Preview("chat · mac width", traits: .fixedLayout(width: 900, height: 700)) {
    PreviewHost(.happy, tab: .chat) { model in NavigationStack { ChatScreen(model: model, tier: .regular) } }
}

/// Runs `prepare` (a send, an attachment) after the screen exists, then shows the thread.
private struct ThreadPreview: View {
    let model: AppModel
    let threadID: String
    var tier: Tier = .compact
    var prepare: (AppModel) async -> Void = { _ in }

    var body: some View {
        NavigationStack { ChatThreadScreen(model: model, threadID: threadID, tier: tier) }
            .task {
                await model.chat.load(threadID)
                await prepare(model)
            }
    }
}

#Preview("thread · finished reply, steps and files", traits: .fixedLayout(width: 390, height: 844)) {
    PreviewHost(.happy, tab: .chat) { model in ThreadPreview(model: model, threadID: sampleThread) }
}
#Preview("thread · dark", traits: .fixedLayout(width: 390, height: 844)) {
    PreviewHost(.happy, tab: .chat) { model in ThreadPreview(model: model, threadID: sampleThread) }
        .preferredColorScheme(.dark)
}
#Preview("thread · a removed file", traits: .fixedLayout(width: 390, height: 844)) {
    PreviewHost(.happy, tab: .chat) { model in ThreadPreview(model: model, threadID: deletedPostThread) }
}
#Preview("thread · reply streaming", traits: .fixedLayout(width: 390, height: 844)) {
    PreviewHost(.happy, tab: .chat) { model in
        ThreadPreview(model: model, threadID: sampleThread) { model in
            try? await model.chat.send(text: "only the videos", in: sampleThread)
        }
    }
}
#Preview("thread · reply failed", traits: .fixedLayout(width: 390, height: 844)) {
    PreviewHost(.chatReplyFails, tab: .chat) { model in
        ThreadPreview(model: model, threadID: sampleThread) { model in
            try? await model.chat.send(text: "only the videos", in: sampleThread)
        }
    }
}
#Preview("thread · composer with a file", traits: .fixedLayout(width: 390, height: 844)) {
    PreviewHost(.happy, tab: .chat) { model in
        ThreadPreview(model: model, threadID: sampleThread) { model in
            let post = model.library.posts[1]
            model.chat.attach([post.id], to: sampleThread)
            model.chat.setDraftText("what is this one about?", for: sampleThread)
        }
    }
}
#Preview("chat · ask about this", traits: .fixedLayout(width: 390, height: 844)) {
    PreviewHost(.happy, tab: .chat) { model in
        NavigationStack { ChatScreen(model: model, tier: .compact) }
            .task { try? await model.askAbout([model.library.posts[0]]) }
    }
}
#Preview("thread · mac width", traits: .fixedLayout(width: 900, height: 700)) {
    PreviewHost(.happy, tab: .chat) { model in ThreadPreview(model: model, threadID: sampleThread, tier: .regular) }
}
#Preview("rename chat · sheet", traits: .fixedLayout(width: 390, height: 400)) {
    PreviewHost(.happy, tab: .chat) { model in
        ChatRenameSheet(model: model, thread: ChatThread(
            id: sampleThread, title: "funny things from yesterday", createdAt: .now, updatedAt: .now))
    }
}
#endif
