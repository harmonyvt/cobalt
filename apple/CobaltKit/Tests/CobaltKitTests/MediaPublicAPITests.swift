// Deliberately a plain `import CobaltKit` (no @testable): this file only sees what the app and the
// share extension see. It type-checks the pinned CONTRACT-MEDIA.md section 4 surface, then reads it
// from the `.renditions` preview.
import CoreGraphics
import Foundation
import Testing
import CobaltKit

@MainActor
private func touchMediaStore(_ store: OfflineStore, _ video: StoredVideo) {
    let _: [StoredMedia] = store.media
    let _: [StoredMedia] = store.latestMedia(7)
    let _: StoredMedia? = store.media(id: "m")
    let _: StoredMedia? = store.media(containing: video.id)
    let _: StoredMedia? = store.media(session: "sid")
    let _: String = video.mediaID
    let _: WebpClip? = video.clip
    let usage: StorageUsage = store.usage
    let _: Int = usage.mediaCount
    let _: (String) async -> Bool = store.removeMedia(_:)
    let clip = WebpClip(start: 0, length: 5, crop: CropRect.full, quality: .med, width: 480)
    _ = (clip.start, clip.length, clip.crop, clip.quality, clip.width)
    let _: Bool = clip == clip
    let _: @MainActor (URL, StoredVideo.Kind, MediaInfo, String?, URL?, URL?, Bool, URL?, String?, WebpClip?) async throws -> StoredVideo =
        { try await store.add(file: $0, kind: $1, media: $2, sessionID: $3, link: $4, remoteURL: $5, move: $6, publicURL: $7, mediaID: $8, clip: $9) }
    // every existing call keeps compiling: the new parameters are defaulted
    let _: @MainActor (URL, StoredVideo.Kind, MediaInfo) async throws -> StoredVideo = {
        try await store.add(file: $0, kind: $1, media: $2, sessionID: nil, link: nil, remoteURL: nil, move: true)
    }
}

@MainActor
private func touchMediaModels(_ app: AppModel, _ pipeline: Pipeline, _ media: StoredMedia, _ post: LibraryPost) async throws {
    let _: String = media.id
    let _: StoredVideo? = media.original
    let _: [StoredVideo] = media.webps
    let _: StoredVideo = media.face
    let _: [StoredVideo] = media.renditions
    let _: Date = media.latestAt
    let _: Set<String> = media.sessionIDs
    let _: URL? = media.link
    let _: String = media.title
    let _: Bool = media.isHosted

    let item: MediaItem = app.mediaItem(for: media)
    let _: MediaItem = app.mediaItem(for: post)
    let _: MediaItem? = MediaItem.merge(local: media, post: post)
    let _: String = item.id
    let _: StoredMedia? = item.local
    let _: LibraryPost? = item.post
    let _: String? = item.service
    let _: String? = item.ref
    let _: URL? = item.link
    let _: [Rendition] = item.renditions
    let face: Rendition = item.face
    let _: Int = item.webpCount
    let _: Date = item.latestAt
    let _: Rendition? = item.rendition(id: face.id)
    let _: String = face.id
    switch face.kind {
    case .video: break
    case .webp(number: let n): _ = n
    }
    let _: StoredVideo? = face.local
    let _: LibraryFile? = face.file
    let _: LibraryFile? = face.hosted
    let _: URL? = face.publicURL
    let _: (Int?, Int?, Double?, Int64?) = (face.width, face.height, face.duration, face.bytes)
    let _: Date = face.createdAt
    let _: WebpClip? = face.clip
    let _: String? = face.deletableName

    let _: (MediaItem) async -> Void = app.makeWebp(for:)
    let _: (Rendition, MediaItem) async throws -> Void = app.deleteWebp(_:of:)
    let _: (MediaItem) async -> Bool = app.removeFromDevice(_:)
    let _: (MediaItem) -> Bool = app.isBusy(_:)
    let _: (MediaItem) async throws -> DeleteOutcome = app.deleteEverything(_:)
    let _: (DeleteOutcome) -> Void = { outcome in
        switch outcome {
        case .done, .partial(remaining: _), .leftOnServer(hostedLink: _, privateCopy: _): break
        }
    }
    let _: String? = pipeline.targetMediaID
    let _: String? = pipeline.mediaID
    let _: Bool = app.capabilities.deletePost
    let result = PostDeleteResult(deletedFiles: 1, deletedBytes: 2, remaining: [])
    _ = (result.deletedFiles, result.deletedBytes, result.remaining)
    let _: (any CobaltClient, String) async throws -> PostDeleteResult = { try await $0.deletePost(anchor: $1) }
}

@MainActor
struct MediaPublicAPITests {
    @Test func theSurfaceTheScreensBuildAgainstIsPublicAndReadable() async throws {
        let app = AppModel.preview(.renditions)
        let media = try #require(app.store.media.first)
        let post = try #require(app.library.posts.first)
        // compile-time touch only (never called): the functions above are the check
        _ = touchMediaStore
        _ = touchMediaModels

        let item = app.mediaItem(for: media)
        #expect(item.webpCount == 3 && item.renditions.count == 4)
        #expect(app.mediaItem(for: post).id == app.mediaItem(for: post).id)
        #expect(app.isBusy(item) == false)
        #expect(app.store.usage.mediaCount >= 0)
        #expect(PreviewScenario.allCases.contains(.renditions) && PreviewScenario.allCases.contains(.renditionsLegacy))
        // the pinned error shapes the screens switch on stay as they were
        #expect(PipelineFailure.serverBusy != PipelineFailure.expired)
    }
}
