#if DEBUG
import CobaltKit
import SwiftUI

// `#Preview`s of the chat tab on the preview server: four sample threads (one with code steps and shown files, one with a
// step that failed and recovered, one with a deleted file, one that ends in a 95-post collage), none yet, and a listing that fails; a finished thread, a reply
// streaming in, a failed reply, the composer with a file attached, and the Mac's width. The thumbnails are network pictures,
// so they stay blank in a preview.

private let sampleThread = "PrEvIeWchat00001"
private let deletedPostThread = "PrEvIeWchat00003"
/// The fourth sample thread ends in a collage of 95 posts (message 132), served 30 at a time.
private let collageThread = "PrEvIeWchat00004"
private let collageMessage = "132"
/// The `.chatConfirm` scenario's thread: the chat asks before deleting three timer clips.
private let confirmThread = "PrEvIeWchat00005"

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
#Preview("thread · collage", traits: .fixedLayout(width: 390, height: 844)) {
    PreviewHost(.happy, tab: .chat) { model in ThreadPreview(model: model, threadID: collageThread) }
}
#Preview("thread · collage, dark", traits: .fixedLayout(width: 390, height: 844)) {
    PreviewHost(.happy, tab: .chat) { model in ThreadPreview(model: model, threadID: collageThread) }
        .preferredColorScheme(.dark)
}
#Preview("thread · collage, two pages in", traits: .fixedLayout(width: 390, height: 844)) {
    PreviewHost(.happy, tab: .chat) { model in
        ThreadPreview(model: model, threadID: collageThread) { model in
            await model.chat.loadCollage(threadID: collageThread, messageID: collageMessage)
            await model.chat.loadMoreCollage(threadID: collageThread, messageID: collageMessage)
        }
    }
}
#Preview("thread · collage, iPad width", traits: .fixedLayout(width: 820, height: 1000)) {
    PreviewHost(.happy, tab: .chat) { model in ThreadPreview(model: model, threadID: collageThread, tier: .regular) }
}
#Preview("thread · collage, mac width", traits: .fixedLayout(width: 1000, height: 760)) {
    PreviewHost(.happy, tab: .chat) { model in ThreadPreview(model: model, threadID: collageThread, tier: .regular) }
}
#Preview("thread · collage streaming in", traits: .fixedLayout(width: 390, height: 844)) {
    PreviewHost(.happy, tab: .chat) { model in
        ThreadPreview(model: model, threadID: collageThread) { model in
            try? await model.chat.send(text: "and the kittens", in: collageThread)
        }
    }
}
#Preview("thread · confirm card", traits: .fixedLayout(width: 390, height: 844)) {
    PreviewHost(.chatConfirm, tab: .chat) { model in ThreadPreview(model: model, threadID: confirmThread) }
}
#Preview("thread · confirm card, dark", traits: .fixedLayout(width: 390, height: 844)) {
    PreviewHost(.chatConfirm, tab: .chat) { model in ThreadPreview(model: model, threadID: confirmThread) }
        .preferredColorScheme(.dark)
}
#Preview("thread · confirm card answered", traits: .fixedLayout(width: 390, height: 844)) {
    PreviewHost(.chatConfirm, tab: .chat) { model in
        ThreadPreview(model: model, threadID: confirmThread) { model in
            guard let card = model.chat.content(of: confirmThread)?.messages.last?.confirm else { return }
            try? await model.chat.answer(card, yes: true, in: confirmThread)
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
