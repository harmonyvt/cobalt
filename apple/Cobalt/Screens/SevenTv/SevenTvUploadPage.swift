import CobaltKit
import SwiftUI

// "upload" of the 7tv tab (APP-API-CONTRACT 57.9, mockup `7tv-tab/` upload): the library's animated pictures (webps and gifs,
// newest first; 7TV's own emotes saved into the library are left out) with an "on 7tv" mark once one was uploaded
// (`GET /7tv/uploads` matched by file id); a tap opens the "upload to 7tv" sheet (name, crop, size, set). Then "your uploads":
// each emote capystore uploaded, its picture, "processing" while 7TV makes its sizes (read every 5 s while this page shows),
// and where it went; a tap opens it on 7tv.app.

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
                Text(Copy.SevenTv.yourUploads)
                    .font(CobaltType.bodySemibold)
                    .foregroundStyle(CobaltColor.text)
                    .padding(.top, 4)
                    .accessibilityAddTraits(.isHeader)
                uploadsList
            }
            .padding(.horizontal, Metrics.gutter)
            .padding(.bottom, 16)
            .frame(maxWidth: Metrics.columnMax, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .refreshable {
            await library.refresh()
            await store.loadUploads()
        }
        .task {
            if library.posts.isEmpty { await library.refresh() }
        }
        .task {
            await store.loadUploads()
            await store.watchUploads()
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
