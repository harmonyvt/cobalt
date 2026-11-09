import CobaltKit
import SwiftUI

// The item page's part of post frames (APP-API-CONTRACT 52.6, the mockup's section 2): "from the post" (the details kept for
// the video, looked up when the page opens if the server has none yet) and the framed copies made from it (the library's
// `made_from`, plus the ones still rendering). The "post frame" button itself sits in the secondary row (`DetailActions`).

/// "from the post" and "framed copies", under the video's buttons.
struct PostFrameDetailSection: View {
    let controller: DetailController
    let item: MediaItem

    private var model: AppModel { controller.model }
    private var itemID: String? { model.postFrameSource(item) }

    var body: some View {
        if let itemID {
            Section {
                PostFrameSummary(model: model, itemID: itemID)
                PostFrameCopies(model: model, itemID: itemID)
            } header: {
                Text(Copy.PostFrame.fromThePost).font(CobaltType.caption).textCase(nil)
            }
            .task(id: itemID) { await model.postFrames.loadIfNeeded(itemID: itemID) }
        }
    }
}

/// The details in two or three lines: who, when, what they wrote, the counts. While they are looked up, or when the post is
/// gone, the line says so.
private struct PostFrameSummary: View {
    let model: AppModel
    let itemID: String

    var body: some View {
        if let d = model.postFrames.state(for: itemID)?.details, d.found {
            HStack(alignment: .top, spacing: 10) {
                PostAvatar(name: d.displayName ?? d.host ?? "?", data: model.postFrames.avatars[itemID], size: 30)
                    .accessibilityHidden(true)
                PostFrameSummaryWords(details: d)
            }
            .padding(.vertical, 2)
            .accessibilityElement(children: .combine)
        } else {
            PostFrameDetailsLine(model: model, itemID: itemID)
        }
    }
}

private struct PostFrameSummaryWords: View {
    let details: PostDetails

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(Copy.PostFrame.whoLine(details))
                .font(CobaltType.bodyMedium)
                .foregroundStyle(CobaltColor.text)
                .lineLimit(1)
            if let words = details.text ?? details.title {
                Text(words)
                    .font(CobaltType.caption)
                    .foregroundStyle(CobaltColor.text)
                    .lineLimit(3)
            }
            if let counts = Copy.PostFrame.countsLine(details.counts) {
                Text(counts)
                    .font(CobaltType.captionSmall)
                    .foregroundStyle(CobaltColor.caption)
                    .monospacedDigit()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// "framed copies": the ones rendering (with their progress), then the ones in the library, newest first (at most 6).
private struct PostFrameCopies: View {
    let model: AppModel
    let itemID: String

    var body: some View {
        let running = model.postFrameRenders(of: itemID)
        let copies = Array(model.framedCopies(of: itemID).prefix(6))
        if !running.isEmpty || !copies.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text(Copy.PostFrame.framedCopies)
                    .font(CobaltType.captionSmall)
                    .foregroundStyle(CobaltColor.caption)
                ForEach(running) { render in
                    PostFrameRenderRow(render: render)
                }
                ForEach(copies) { post in
                    PostFrameCopyRow(post: post, style: model.framedCopyStyle(post))
                }
            }
            .padding(.vertical, 2)
            .motion(Motion.rows, value: running.map(\.id) + copies.map(\.id))
        }
    }
}

/// A framed copy on its way: its title and `rendering 42%`.
private struct PostFrameRenderRow: View {
    let render: EditRender

    private var line: String {
        switch render.status {
        case .queued: return Copy.PostFrame.queuedLine
        case .error, .cancelled: return Copy.PostFrame.renderFailed
        default: return Copy.PostFrame.rendering(Int(((render.progress ?? 0) * 100).rounded()))
        }
    }

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 6, style: .continuous).fill(CobaltColor.elevated)
                if render.status == .error {
                    Image(systemName: Symbol.PostFrame.gone).foregroundStyle(CobaltColor.errorText)
                } else {
                    ProgressView(value: min(1, max(0, render.progress ?? 0))).progressViewStyle(.circular).controlSize(.small)
                }
            }
            .frame(width: 44, height: 44)
            VStack(alignment: .leading, spacing: 2) {
                Text(render.title).font(CobaltType.caption).foregroundStyle(CobaltColor.text).lineLimit(1)
                Text(line)
                    .font(CobaltType.captionSmall)
                    .foregroundStyle(render.status == .error ? CobaltColor.errorText : CobaltColor.caption)
                    .monospacedDigit()
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// A framed copy in the library: its still, its title and `x · nov 9`.
private struct PostFrameCopyRow: View {
    let post: LibraryPost
    let style: PostFrameStyle?

    private var poster: URL? { post.posterURL ?? post.files.first?.posterURL }

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 6, style: .continuous).fill(CobaltColor.elevated)
                if let poster { RemoteStill(poster: RemotePoster(url: poster, isVideo: false), maxPixel: 120) }
            }
            .frame(width: 44, height: 44)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(post.customTitle ?? post.title ?? Copy.PostFrame.postFrame)
                    .font(CobaltType.caption).foregroundStyle(CobaltColor.text).lineLimit(1)
                Text(Copy.PostFrame.copyLine(style: style, created: post.createdAt))
                    .font(CobaltType.captionSmall).foregroundStyle(CobaltColor.caption)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - presenting the sheet

/// The item page's "post frame" sheet, open while `DetailController.postFrameTarget` is set.
private struct PostFrameSheetPresenter: ViewModifier {
    let controller: DetailController
    let model: AppModel

    private var target: Binding<PostFrameTarget?> {
        Binding(get: { controller.postFrameTarget }, set: { controller.postFrameTarget = $0 })
    }

    func body(content: Content) -> some View {
        content.sheet(item: target) { current in
            PostFrameSheet(model: model, target: current)
                .cobaltRoot(model: model)
        }
    }
}

extension View {
    func postFrameSheet(controller: DetailController, model: AppModel) -> some View {
        modifier(PostFrameSheetPresenter(controller: controller, model: model))
    }
}
