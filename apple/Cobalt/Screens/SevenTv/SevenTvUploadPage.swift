import CobaltKit
import SwiftUI

// "upload" of the 7tv tab (APP-API-CONTRACT 57.9, mockup `7tv-tab/` upload): the library's animated pictures (webps and gifs,
// newest first; 7TV's own emotes saved into the library are left out) with an "on 7tv" mark once one was uploaded
// (`GET /7tv/uploads` matched by file id); a tap opens the "upload to 7tv" sheet (name, crop, size, set). Then "your emotes on
// 7tv" (57.14, `GET /7tv/owned`): every emote the account owns, newest first, made here or on 7tv.app: its picture (a still),
// "processing on 7tv" while 7TV makes its sizes (read again every 5 s while one is), a "from library" mark on what capystore
// uploaded, private and zero-width marks, and "add to a set…" (the row's button and context menu) over every channel the
// account edits. A tap opens the emote on 7tv.app. When the list cannot be read, the older "your uploads" list stands in.

/// A library picture the upload grid offers.
struct SevenTvLibraryPicture: Identifiable, Equatable {
    let file: LibraryFile
    let title: String?
    var id: String { file.id }

    /// The library's animated pictures: webp and gif files (by content type, else by name), not 7TV emotes saved into the
    /// library, newest first. A webp that is known to be a single frame (a duration of 0) is left out.
    static func all(in posts: [LibraryPost]) -> [SevenTvLibraryPicture] {
        var seen = Set<String>()
        var out: [SevenTvLibraryPicture] = []
        for post in posts where !post.isEmote {
            for file in post.files where isAnimatedPicture(file) && seen.insert(file.id).inserted {
                out.append(SevenTvLibraryPicture(file: file, title: post.customTitle ?? post.title))
            }
        }
        return out.sorted { $0.file.createdAt > $1.file.createdAt }
    }

    static func isAnimatedPicture(_ file: LibraryFile) -> Bool {
        guard file.source != .emote, !file.id.isEmpty else { return false }
        if let duration = file.duration, duration <= 0 { return false }
        if let type = file.contentType?.split(separator: ";").first?.trimmingCharacters(in: .whitespaces).lowercased(), !type.isEmpty {
            return type == "image/webp" || type == "image/gif"
        }
        let ext = file.name.split(separator: ".").last?.lowercased()
        return file.name.contains(".") && (ext == "webp" || ext == "gif")
    }

    /// What the tile says: the post's title, else the file's name without its extension.
    var label: String {
        if let title, !title.trimmingCharacters(in: .whitespaces).isEmpty { return title }
        return MediaTitle.stripExtension(file.name)
    }
}

struct SevenTvUploadPage: View {
    let tab: SevenTvTabController

    @Environment(\.openURL) private var openURL

    private var store: SevenTvStore { tab.store }
    private var library: LibraryModel { tab.model.library }
    private var pictures: [SevenTvLibraryPicture] { SevenTvLibraryPicture.all(in: library.posts) }

    private var columns: [GridItem] { [GridItem(.adaptive(minimum: 92), spacing: 10)] }

    var body: some View {
        let uploaded = store.uploadedFileIDs
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text(store.canUpload ? Copy.SevenTv.uploadIntro : Copy.SevenTv.uploadNeedsLink)
                    .font(CobaltType.captionSmall)
                    .foregroundStyle(CobaltColor.caption)
                    .fixedSize(horizontal: false, vertical: true)
                grid(uploaded: uploaded)
                ownedSection
            }
            .padding(.horizontal, Metrics.gutter)
            .padding(.bottom, 16)
            .frame(maxWidth: Metrics.columnMax, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .refreshable {
            await library.refresh()
            await store.loadUploads()
            await store.loadOwned()
        }
        .task {
            if library.posts.isEmpty { await library.refresh() }
        }
        .task {
            await store.loadUploads()
            await store.watchUploads()
        }
        .task {
            await store.loadOwned()
            await store.watchOwned()
        }
    }

    // MARK: your emotes on 7tv

    private var canAddToSet: Bool { store.channels.contains { $0.can.manageSets } }

    @ViewBuilder
    private var ownedSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(Copy.SevenTv.ownedTitle)
                    .font(CobaltType.bodySemibold)
                    .foregroundStyle(CobaltColor.text)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 6)
                if !store.owned.isEmpty {
                    Text(Copy.SevenTv.ownedCount(store.owned.count, total: store.ownedTotal))
                        .font(CobaltType.captionSmall)
                        .foregroundStyle(CobaltColor.caption)
                        .monospacedDigit()
                        .contentTransition(.numericText())
                }
            }
            .padding(.top, 4)
            ownedBody
        }
    }

    @ViewBuilder
    private var ownedBody: some View {
        if !store.owned.isEmpty {
            LazyVStack(spacing: 6) {
                ForEach(store.owned) { emote in
                    SevenTvOwnedRow(
                        emote: emote, fallbackPicture: emote.fileID.flatMap(libraryPicture),
                        ago: emote.createdAt.map { Copy.SevenTv.ago($0, now: store.now()) }, canAddToSet: canAddToSet,
                        addToSet: { tab.addToSet(emote) }, open: { openURL(emote.pageURL) })
                }
            }
            .motion(Motion.rows, value: store.owned.map(\.id))
        } else {
            switch store.ownedState {
            case .idle, .loading:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(Copy.SevenTv.loading).font(CobaltType.captionSmall).foregroundStyle(CobaltColor.caption)
                }
            case .failed(let error):
                VStack(alignment: .leading, spacing: 8) {
                    Text(Copy.SevenTv.message(for: error))
                        .font(CobaltType.captionSmall)
                        .foregroundStyle(CobaltColor.errorText)
                    Button(Copy.SevenTv.retry, systemImage: Symbol.SevenTv.retry) { Task { await store.loadOwned() } }
                        .buttonStyle(.cobaltSecondary(fullWidth: false, compact: true))
                    if !store.uploads.isEmpty {
                        Text(Copy.SevenTv.yourUploads)
                            .font(CobaltType.captionSmall)
                            .foregroundStyle(CobaltColor.caption)
                            .padding(.top, 4)
                        uploadsList
                    }
                }
            case .loaded:
                Text(Copy.SevenTv.noOwned)
                    .font(CobaltType.captionSmall)
                    .foregroundStyle(CobaltColor.caption)
            }
        }
    }

    @ViewBuilder
    private func grid(uploaded: Set<String>) -> some View {
        let pictures = self.pictures
        if pictures.isEmpty {
            HStack(spacing: 8) {
                if library.isLoading { ProgressView().controlSize(.small) }
                Text(library.isLoading ? Copy.SevenTv.loadingLibrary : Copy.SevenTv.noLibraryPictures)
                    .font(CobaltType.captionSmall)
                    .foregroundStyle(CobaltColor.caption)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } else {
            LazyVGrid(columns: columns, spacing: 10) {
                ForEach(pictures) { picture in
                    SevenTvLibraryTile(picture: picture, onSevenTv: uploaded.contains(picture.file.id)) {
                        tab.startUpload(picture.file, title: picture.title)
                    }
                    .disabled(!store.canUpload)
                }
            }
        }
    }

    @ViewBuilder
    private var uploadsList: some View {
        if store.uploads.isEmpty {
            switch store.uploadsState {
            case .loading, .idle:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(Copy.SevenTv.loading).font(CobaltType.captionSmall).foregroundStyle(CobaltColor.caption)
                }
            case .failed(let error):
                Text(Copy.SevenTv.message(for: error))
                    .font(CobaltType.captionSmall)
                    .foregroundStyle(CobaltColor.errorText)
            case .loaded:
                Text(Copy.SevenTv.noUploads)
                    .font(CobaltType.captionSmall)
                    .foregroundStyle(CobaltColor.caption)
            }
        } else {
            VStack(spacing: 6) {
                ForEach(store.uploads) { upload in
                    SevenTvUploadRow(
                        upload: upload, state: store.state(of: upload), info: store.uploadInfo[upload.emoteID],
                        fallbackPicture: libraryPicture(upload.fileID), setName: setName(upload.setID),
                        ago: upload.createdAt.map { Copy.SevenTv.ago($0, now: store.now()) }
                    ) {
                        openURL(upload.pageURL)
                    }
                }
            }
            .motion(Motion.rows, value: store.uploads.map(\.id))
        }
    }

    /// The library file's own picture, while 7TV has none yet.
    private func libraryPicture(_ fileID: String) -> URL? {
        for post in library.posts {
            if let file = post.files.first(where: { $0.id == fileID }) { return file.url }
        }
        return nil
    }

    /// The name of the set an upload went into, from any channel's loaded sets.
    private func setName(_ setID: String?) -> String? {
        guard let setID else { return nil }
        for channel in store.channels {
            if let row = store.sets(of: channel.id).first(where: { $0.id == setID }) { return row.name }
        }
        return nil
    }
}

/// One library picture: still (a grid of moving webps would be heavy), its name, and "on 7tv" once uploaded.
private struct SevenTvLibraryTile: View {
    let picture: SevenTvLibraryPicture
    let onSevenTv: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 5) {
                ZStack(alignment: .topTrailing) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 14, style: .continuous).fill(CobaltColor.surface)
                        if picture.file.url != nil {
                            EmotePicture(url: picture.file.url, animated: false, side: 76)
                        } else {
                            Image(systemName: Symbol.typeImage)
                                .font(.system(size: 22))
                                .foregroundStyle(CobaltColor.caption)
                        }
                    }
                    .frame(height: 88)
                    if onSevenTv {
                        Label(Copy.SevenTv.onSevenTv, systemImage: Symbol.SevenTv.onSevenTv)
                            .labelStyle(.titleAndIcon)
                            .font(CobaltType.badge)
                            .foregroundStyle(.black)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(CobaltColor.success, in: Capsule())
                            .padding(5)
                            .accessibilityHidden(true)
                    }
                }
                Text(picture.label)
                    .font(Font.cobalt(11.5, .regular, relativeTo: .caption))
                    .foregroundStyle(CobaltColor.text)
                    .lineLimit(1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Copy.SevenTv.libraryTileA11y(picture.label, onSevenTv: onSevenTv))
        .accessibilityHint(Copy.SevenTv.uploadAction)
    }
}

/// One upload: its picture, its name, its state, and where it went.
private struct SevenTvUploadRow: View {
    let upload: SevenTvUploadedEmote
    let state: SevenTvUploadState
    let info: SevenTvEmoteInfo?
    let fallbackPicture: URL?
    let setName: String?
    let ago: String?
    let open: () -> Void

    private var pill: (text: String, tint: Color)? {
        switch state {
        case .unknown: return nil
        case .processing: return (Copy.SevenTv.processingPill, CobaltColor.collection)
        case .ready: return (Copy.SevenTv.readyPill, CobaltColor.success)
        case .gone: return (Copy.SevenTv.gonePill, CobaltColor.caption)
        }
    }

    var body: some View {
        Button(action: open) {
            HStack(spacing: 10) {
                Group {
                    if state == .ready, let url = info?.previewURL {
                        EmotePicture(url: url, animated: info?.animated ?? false, side: 40)
                    } else if let fallbackPicture {
                        EmotePicture(url: fallbackPicture, animated: false, side: 40)
                            .opacity(state == .processing ? 0.6 : 1)
                    } else {
                        ProgressView().controlSize(.small).frame(width: 40, height: 40)
                    }
                }
                .padding(4)
                .background(CobaltColor.elevated, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(upload.name)
                            .font(CobaltType.bodySemibold)
                            .foregroundStyle(CobaltColor.text)
                            .lineLimit(1)
                        if let pill {
                            Text(pill.text)
                                .font(CobaltType.pill)
                                .foregroundStyle(pill.tint)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 2)
                                .background(pill.tint.opacity(0.14), in: Capsule())
                                .contentTransition(.opacity)
                        }
                    }
                    Text(Copy.SevenTv.uploadLine(set: setName, ago: ago))
                        .font(CobaltType.captionSmall)
                        .foregroundStyle(CobaltColor.caption)
                        .lineLimit(1)
                }
                Spacer(minLength: 6)
                Image(systemName: Symbol.SevenTv.website)
                    .font(.system(size: 13))
                    .foregroundStyle(CobaltColor.caption)
                    .accessibilityHidden(true)
            }
            .padding(10)
            .background(CobaltColor.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .animation(Motion.rows, value: state)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Copy.SevenTv.uploadRowA11y(upload.name, state: pill?.text ?? ""))
        .accessibilityHint(Copy.SevenTv.openOn7tv)
    }
}


/// One emote of the account: its still, its name and marks, where it came from, and "add to a set…".
private struct SevenTvOwnedRow: View {
    let emote: SevenTvOwnedEmote
    let fallbackPicture: URL?
    let ago: String?
    let canAddToSet: Bool
    let addToSet: () -> Void
    let open: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Button(action: open) {
                HStack(spacing: 10) {
                    tile
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Text(emote.name)
                                .font(CobaltType.bodySemibold)
                                .foregroundStyle(CobaltColor.text)
                                .lineLimit(1)
                            if emote.fromLibrary {
                                Image(systemName: Symbol.SevenTv.library)
                                    .font(.system(size: 10, weight: .medium))
                                    .foregroundStyle(CobaltColor.caption)
                                    .accessibilityHidden(true)
                            }
                        }
                        marks
                        Text(Copy.SevenTv.ownedLine(fromLibrary: emote.fromLibrary, ago: ago))
                            .font(CobaltType.captionSmall)
                            .foregroundStyle(CobaltColor.caption)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 4)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(
                Copy.SevenTv.ownedRowA11y(
                    emote.name, pending: emote.pending, fromLibrary: emote.fromLibrary, isPrivate: emote.isPrivate,
                    zeroWidth: emote.zeroWidth))
            .accessibilityHint(Copy.SevenTv.openOn7tv)
            if canAddToSet {
                Button(action: addToSet) {
                    Label(Copy.SevenTv.addToSetAction, systemImage: Symbol.SevenTv.addToSet)
                        .labelStyle(.iconOnly)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(CobaltColor.text)
                        .frame(width: Metrics.hit, height: Metrics.hit)
                        .background(CobaltColor.elevated, in: Circle())
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Copy.SevenTv.addToSetAction)
            }
        }
        .padding(10)
        .background(CobaltColor.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .contextMenu {
            if canAddToSet {
                Button(Copy.SevenTv.addToSetAction, systemImage: Symbol.SevenTv.addToSet, action: addToSet)
            }
            Button(Copy.SevenTv.openOn7tv, systemImage: Symbol.SevenTv.website, action: open)
        }
    }

    @ViewBuilder
    private var tile: some View {
        Group {
            if !emote.pending, let url = emote.previewURL {
                EmotePicture(url: url, animated: false, side: 40)
            } else if let fallbackPicture {
                EmotePicture(url: fallbackPicture, animated: false, side: 40).opacity(0.6)
            } else {
                ProgressView().controlSize(.small).frame(width: 40, height: 40)
            }
        }
        .padding(4)
        .background(CobaltColor.elevated, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    @ViewBuilder
    private var marks: some View {
        if emote.pending || emote.isPrivate || emote.zeroWidth {
            HStack(spacing: 5) {
                if emote.pending { pill(Copy.SevenTv.processingOn7tv, tint: CobaltColor.collection, symbol: nil) }
                if emote.isPrivate { pill(Copy.SevenTv.privateMark, tint: CobaltColor.caption, symbol: Symbol.SevenTv.privateEmote) }
                if emote.zeroWidth { pill(Copy.SevenTv.zeroWidthMark, tint: CobaltColor.caption, symbol: Symbol.SevenTv.zeroWidth) }
            }
        }
    }

    private func pill(_ text: String, tint: Color, symbol: String?) -> some View {
        HStack(spacing: 3) {
            if let symbol { Image(systemName: symbol).font(.system(size: 8, weight: .semibold)) }
            Text(text)
        }
        .font(CobaltType.pill)
        .foregroundStyle(tint)
        .padding(.horizontal, 7)
        .padding(.vertical, 2)
        .background(tint.opacity(0.14), in: Capsule())
        .contentTransition(.opacity)
    }
}
