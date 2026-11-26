import CobaltKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

// Find a library picture's booru post (APP-API-CONTRACT 72.11): the picture goes to iqdb.org from the device, the posts it
// names come back from Danbooru, and the server keeps the general ones. A match of 90% or more is linked straight away (the
// post's link becomes the Danbooru page, and the artist goes into its details); otherwise the owner picks one, or none.

/// "booru" on a picture's detail page: the button that opens the search.
struct BooruFindSection: View {
    let model: AppModel
    let item: MediaItem
    let rendition: Rendition
    @State private var shown = false

    /// The file the server links by: this picture's own row, else the post's first file.
    private var fileID: String? { rendition.file?.id ?? item.post?.files.first?.id }

    static func applies(model: AppModel, item: MediaItem, rendition: Rendition) -> Bool {
        guard model.capabilities.booru, item.post != nil else { return false }
        if case .item(_, let type) = rendition.kind { return type == .photo }
        return rendition.file?.contentType?.lowercased().hasPrefix("image/") == true
    }

    var body: some View {
        if let fileID {
            Section {
                Button { shown = true } label: {
                    Label(isLinked ? Copy.BooruFind.findAgain : Copy.BooruFind.find, systemImage: Symbol.Booru.search)
                }
                if isLinked, let link = item.post?.link {
                    Link(destination: link) { Label(Copy.BooruFind.linkedTo(link), systemImage: Symbol.Booru.open) }
                        .font(CobaltType.caption)
                }
            } header: {
                Text(Copy.BooruFind.header).font(CobaltType.caption).textCase(nil)
            }
            .sheet(isPresented: $shown) {
                BooruFindSheet(model: model, fileID: fileID, rendition: rendition)
            }
        }
    }

    private var isLinked: Bool { item.post?.link?.host == "danbooru.donmai.us" }
}

struct BooruFindSheet: View {
    let model: AppModel
    let fileID: String
    let rendition: Rendition
    @Environment(\.dismiss) private var dismiss

    private enum Phase: Equatable {
        case reading
        case searching
        case found([BooruMatch])
        case linking(Int)
        case linked(BooruMatch)
        case failed(String)
    }

    @State private var phase: Phase = .reading
    @State private var started = Date()

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) { content }
                    .padding(16)
                    .frame(maxWidth: 640)
                    .frame(maxWidth: .infinity)
            }
            .background(CobaltColor.bg)
            .navigationTitle(Copy.BooruFind.title)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    DuoToolbarButton(title: Copy.Booru.done, systemImage: "checkmark") { dismiss() }
                }
                .duoVisibilityPriority(.high)
            }
        }
        .task { await run() }
    }

    @ViewBuilder private var content: some View {
        switch phase {
        case .reading, .searching:
            HStack(spacing: 10) {
                ProgressView()
                VStack(alignment: .leading, spacing: 2) {
                    Text(Copy.BooruFind.searching).font(CobaltType.bodyMedium)
                    TimelineView(.periodic(from: started, by: 1)) { ctx in
                        Text(Copy.BooruFind.waited(Int(ctx.date.timeIntervalSince(started))))
                            .font(CobaltType.captionSmall).foregroundStyle(CobaltColor.caption)
                    }
                }
            }
        case .found(let matches) where matches.isEmpty:
            Text(Copy.BooruFind.none).font(CobaltType.bodyMedium)
            Text(Copy.BooruFind.noneHint).font(CobaltType.caption).foregroundStyle(CobaltColor.caption)
            Button(Copy.Booru.retry) { Task { await run() } }.buttonStyle(.cobaltSecondary(fullWidth: false, compact: true))
        case .found(let matches):
            Text(Copy.BooruFind.pick).font(CobaltType.caption).foregroundStyle(CobaltColor.caption)
            matchList(matches, busy: nil)
        case .linking(let id):
            Text(Copy.BooruFind.linking).font(CobaltType.caption).foregroundStyle(CobaltColor.caption)
            matchList(lastMatches, busy: id)
        case .linked(let m):
            Label(Copy.BooruFind.linked, systemImage: "checkmark.circle.fill")
                .font(CobaltType.bodyMedium).foregroundStyle(CobaltColor.success)
            BooruFindRow(match: m, chosen: true, busy: false) {}
            if lastMatches.count > 1 {
                Text(Copy.BooruFind.wrongOne).font(CobaltType.caption).foregroundStyle(CobaltColor.caption).padding(.top, 8)
                matchList(lastMatches.filter { $0.id != m.id }, busy: nil)
            }
        case .failed(let code):
            Text(Copy.BooruFind.failure(code)).font(CobaltType.bodyMedium).foregroundStyle(CobaltColor.errorText)
            Button(Copy.Booru.retry) { Task { await run() } }.buttonStyle(.cobaltSecondary(fullWidth: false, compact: true))
        }
    }

    @State private var lastMatches: [BooruMatch] = []

    private func matchList(_ matches: [BooruMatch], busy: Int?) -> some View {
        VStack(spacing: 8) {
            ForEach(matches) { m in
                BooruFindRow(match: m, chosen: false, busy: busy == m.id) { Task { await link(m) } }
                    .disabled(busy != nil)
            }
        }
    }

    // MARK: work

    private func run() async {
        started = Date()
        phase = .reading
        guard let jpeg = await Self.jpeg(of: rendition) else {
            phase = .failed("error.booru.no_picture")
            return
        }
        phase = .searching
        do {
            let matches = try await model.booru.find(jpeg: jpeg)
            lastMatches = matches
            // one sure match: linked straight away; the rest stay on screen to change it
            if let best = matches.first, best.isSure, matches.dropFirst().allSatisfy({ !$0.isSure }) {
                await link(best)
            } else {
                phase = .found(matches)
            }
        } catch {
            phase = .failed(Self.code(error))
        }
    }

    private func link(_ m: BooruMatch) async {
        phase = .linking(m.id)
        do {
            _ = try await model.booru.link(item: fileID, match: m)
            phase = .linked(m)
            await model.library.refresh()
        } catch {
            phase = .failed(Self.code(error))
        }
    }

    private static func code(_ error: Error) -> String {
        switch error {
        case CobaltError.api(let code, _): return code
        case CobaltError.network: return "error.network"
        default: return "error.booru.search_failed"
        }
    }

    /// The picture as a JPEG for iqdb (at most 2000 px, well under its 8 MB).
    nonisolated static func jpeg(of rendition: Rendition) async -> Data? {
        let source = await PhotoSource.resolved(rendition)
        guard let box = await PhotoDecoder.load(source, maxPixel: 2000) else { return nil }
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, box.image, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return data as Data
    }
}

/// One match: the preview, its similarity, who drew it and what it shows.
private struct BooruFindRow: View {
    let match: BooruMatch
    let chosen: Bool
    let busy: Bool
    let pick: () -> Void

    var body: some View {
        Button(action: pick) {
            HStack(spacing: 12) {
                AsyncImage(url: match.post.thumbUrl) { phase in
                    if let image = phase.image { image.resizable().scaledToFill() } else { CobaltColor.elevated }
                }
                .frame(width: 64, height: 64)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .mediaMask()
                VStack(alignment: .leading, spacing: 2) {
                    Text(Copy.BooruFind.similarity(match.similarity)).font(CobaltType.bodySemibold)
                    Text(Copy.BooruFind.who(match.post)).font(CobaltType.caption).foregroundStyle(CobaltColor.caption).lineLimit(2)
                }
                Spacer(minLength: 8)
                if busy {
                    ProgressView()
                } else if !chosen {
                    Text(Copy.BooruFind.use).font(CobaltType.caption)
                }
            }
            .padding(10)
            .background(CobaltColor.surface, in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(chosen ? CobaltColor.text : CobaltColor.hairline))
            .contentShape(RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
        .disabled(chosen)
    }
}
