import Foundation
import UniformTypeIdentifiers

// The repost tools (apple/CONTRACT-GALLERY.md 1.22-1.24, wave A7): `crop` makes a new file of the same media (a tab),
// stored on the server (`PUT /library/items/<id>/made`, 18.6) and on this device; `repost frame` makes a frame on demand
// and sends it to Photos, a folder or the share sheet, and keeps nothing. Both draw with `FrameRenderer`, on the device.

extension AppModel {
    // MARK: - The photo to draw from

    /// The photo behind a rendition (an item, an older single photo, a crop): the copy this device holds, else a download
    /// of the server's file into a temporary folder (`FrameSource.discard()` removes it).
    public func frameSource(of rendition: Rendition) async throws -> FrameSource {
        let fm = FileManager.default
        if let url = rendition.local?.fileURL, fm.fileExists(atPath: url.path) { return FrameSource(url: url, isTemporary: false) }
        guard let file = rendition.file else { throw PipelineFailure.unsupported }
        let folder = fm.temporaryDirectory.appendingPathComponent("cobalt-frames-\(UUID().uuidString.prefix(8))", isDirectory: true)
        let name = file.name.isEmpty ? "photo.jpg" : (file.name as NSString).lastPathComponent
        do {
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            let url = try await ctx.client.download(.libraryItem(id: file.id), to: folder.appendingPathComponent(name), progress: { _ in })
            return FrameSource(url: url, isTemporary: true)
        } catch {
            try? fm.removeItem(at: folder)
            throw mapToolsError(error)
        }
    }

    private func mapToolsError(_ error: Error) -> Error {
        let mapped = pipelineFailure(from: error, during: .saving, limits: ctx.capabilities.limits) ?? error
        if let f = mapped as? PipelineFailure, f == .keyInvalid { markKeyInvalid() }
        return mapped
    }

    /// A temporary file for a frame: `<temp>/cobalt-frames-<id>/<name>`.
    private func frameFile(named name: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("cobalt-frames-\(UUID().uuidString.prefix(8))", isDirectory: true)
            .appendingPathComponent(name)
    }

    /// The `.server` code of a frame that could not be drawn (the photo's file is not a picture this device can read).
    public static let frameFailedCode = "error.app.frame_failed"

    /// `photo 3 · 9:16.jpg` (an item), `photo · 9:16.jpg` (an older single photo).
    public static func frameName(of rendition: Rendition, spec: FrameSpec) -> String {
        let label = rendition.itemIndex.map { "photo \($0 + 1)" } ?? "photo"
        return "\(label) · \(spec.aspect.label).jpg"
    }

    /// `photo 3 · crop 9:16.jpg`: the made file's name on the server.
    public static func cropName(of rendition: Rendition, spec: FrameSpec) -> String {
        let label = rendition.itemIndex.map { "photo \($0 + 1)" } ?? "photo"
        return "\(label) · \(spec.aspect == .free ? "crop" : "crop \(spec.aspect.label)").jpg"
    }

    // MARK: - Crop: a new file of the media

    /// The server can store a crop of this photo: `features.gallery`, and the photo is a row it lists.
    public func canStoreCrop(of rendition: Rendition) -> Bool {
        capabilities.gallery && rendition.file?.id != nil
    }

    /// `save crop`: draws the frame on the device, uploads it as the made file of `rendition` (`role crop`, 18.6), keeps it
    /// on this device with the media, and has the library list it. The photo is untouched; crops accumulate. Throws before
    /// anything changes if the upload fails (`PipelineFailure`: `.unsupported`, `.unreachable`, `.server(code:)`, ...).
    @discardableResult
    public func saveCrop(
        of rendition: Rendition, in item: MediaItem, spec: FrameSpec,
        progress: @escaping @Sendable (TransferProgress) -> Void = { _ in }
    ) async throws -> MadeUpload {
        guard canStoreCrop(of: rendition), let anchor = rendition.file?.id else { throw PipelineFailure.unsupported }
        let source = try await frameSource(of: rendition)
        defer { source.discard() }
        let name = Self.cropName(of: rendition, spec: spec)
        let rendered = frameFile(named: name)
        let made: (width: Int, height: Int, bytes: Int64)
        do {
            made = try await FrameRenderer.render(source.url, spec: spec, to: rendered)
        } catch {
            try? FileManager.default.removeItem(at: rendered.deletingLastPathComponent())
            throw PipelineFailure.server(code: Self.frameFailedCode)
        }
        let upload: MadeUpload
        do {
            upload = try await ctx.client.uploadMade(
                item: anchor, role: .crop, file: rendered, contentType: "image/jpeg", name: name, spec: spec.wireData, progress: progress)
        } catch {
            try? FileManager.default.removeItem(at: rendered.deletingLastPathComponent())
            throw mapToolsError(error)
        }
        if !upload.replaced.isEmpty { library.drop(files: Set(upload.replaced)) }
        // kept with the media on this device (a crop is a made file like any: a tab, a file in the media's Files folder)
        if let local = item.local {
            let session = local.sessionIDs.first ?? item.post?.session?.id ?? item.post?.id
            do {
                let info = MediaInfo(
                    name: (name as NSString).deletingPathExtension, duration: nil, width: made.width, height: made.height,
                    bytes: made.bytes, isImage: true)
                _ = try await store.add(
                    file: rendered, kind: .original, media: info, sessionID: session, link: item.link ?? item.post?.link,
                    remoteURL: nil, move: true, mediaID: local.id, keep: settings.keepVideosOnDevice, role: .crop,
                    madeFrom: [rendition.itemIndex ?? 0], madeSpec: spec.wireData, libraryID: upload.file.id)
            } catch {
                Telemetry.log(.warn, .store, "crop not kept on device", data: Telemetry.errorData(error))
            }
        }
        try? FileManager.default.removeItem(at: rendered.deletingLastPathComponent())
        if item.local == nil { await library.refresh() } else { Task { await library.refresh() } }
        return upload
    }

    // MARK: - Repost frames: on demand, not stored

    /// Makes one frame for each of the photos asked (videos and gifs are skipped and counted) and sends them where the owner
    /// said. Nothing is uploaded and no rendition is made. The first failure stops the rest; frames sent before it stay.
    public func repostFrames(
        _ renditions: [Rendition], spec: FrameSpec, to target: RepostTarget
    ) async throws -> RepostResult {
        let photos = renditions.filter { $0.itemType.map { $0 == .photo } ?? true }
        let skipped = renditions.count - photos.count
        var files: [URL] = []
        for rendition in photos {
            let source = try await frameSource(of: rendition)
            defer { source.discard() }
            let name = Self.frameName(of: rendition, spec: spec)
            let file: URL
            if case .folder(let folder) = target { file = folder.appendingPathComponent(name) } else { file = frameFile(named: name) }
            do {
                try await FrameRenderer.render(source.url, spec: spec, to: file)
            } catch {
                if case .folder = target {} else { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
                throw PipelineFailure.server(code: Self.frameFailedCode)
            }
            if case .photos = target {
                defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }     // a temporary folder of ours
                do {
                    try await ctx.savePhoto(fileURL: file, isImage: true, key: nil)
                } catch {
                    throw pipelineFailure(from: error, during: .saving, limits: ctx.capabilities.limits) ?? error
                }
            }
            files.append(file)
        }
        return RepostResult(files: files, skipped: skipped)
    }
}
