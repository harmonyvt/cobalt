import CobaltKit
import CoreTransferable
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

// Adding a photo or a video from the photo library. The system's `PhotosPicker` needs no library
// permission (the owner picks, the app only ever sees that one item). The picked item is a temporary
// file the system deletes the moment the loading closure returns, so it is copied straight into the
// app's inbox (the same folder a Files import or the share extension lands in), and from there it goes
// through the same `pipeline.start(file:)` as a file from Files: the size limit, the "uploading" card,
// everything after.

/// A picked photo or video, copied out of the picker's short-lived temp file.
struct PickedMedia: Transferable, Sendable {
    let url: URL

    /// The server's upload limit in bytes (0: unknown). Set before loading, so an item that can never be
    /// uploaded is refused before it is copied. A plain value read once per load.
    nonisolated(unsafe) static var byteLimit: Int64 = 0
    /// Set when `receive` refused an item over the limit. CoreTransferable hands the loader its own error, not
    /// the one thrown here, so this is how "too big" is told apart from "could not be read".
    nonisolated(unsafe) static var refusedLimit: Int64?

    enum Failure: Error, Equatable {
        case tooLarge(limit: Int64)
        case noFile
    }

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .movie) { try Self.receive($0) }
        FileRepresentation(importedContentType: .image) { try Self.receive($0) }
    }

    /// Copies the received file (deleted when this returns) into its own folder under the temp directory,
    /// keeping the system's file name and extension so a `.heic` stays a `.heic` and a `.mov` a `.mov`.
    private static func receive(_ received: ReceivedTransferredFile) throws -> PickedMedia {
        let fm = FileManager.default
        let size = (try? fm.attributesOfItem(atPath: received.file.path)[.size] as? NSNumber)?.int64Value ?? 0
        if byteLimit > 0, size > byteLimit {
            refusedLimit = byteLimit
            throw Failure.tooLarge(limit: byteLimit)
        }
        let folder = fm.temporaryDirectory.appendingPathComponent("picked-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let copy = folder.appendingPathComponent(received.file.lastPathComponent)
        do { try fm.copyItem(at: received.file, to: copy) } catch {
            try? fm.removeItem(at: folder)
            throw error
        }
        return PickedMedia(url: copy)
    }
}

/// Thread-safe holder of the `Progress` the picker hands back (it is the only way to see an iCloud
/// original download, and to stop it).
private final class LoadHandle: @unchecked Sendable {
    private let lock = NSLock()
    private var progress: Progress?
    private var cancelled = false

    func set(_ progress: Progress) {
        lock.lock()
        self.progress = progress
        let stop = cancelled
        lock.unlock()
        if stop { progress.cancel() }
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let current = progress
        lock.unlock()
        current?.cancel()
    }

    /// 0...1, or nil while the system has no total yet.
    var fraction: Double? {
        lock.lock()
        defer { lock.unlock() }
        guard let progress, !progress.isIndeterminate, progress.totalUnitCount > 0 else { return nil }
        return min(1, max(0, progress.fractionCompleted))
    }
}

@MainActor @Observable
final class PhotoImport {
    enum Phase: Equatable {
        case idle
        /// Copying the picked item out of the library (downloading it first when it lives in iCloud).
        case loading(fraction: Double?)
        case failed(PipelineFailure)
    }

    private(set) var phase: Phase = .idle
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var handle: LoadHandle?

    var isLoading: Bool {
        if case .loading = phase { return true }
        return false
    }

    var failure: PipelineFailure? {
        if case .failed(let f) = phase { return f }
        return nil
    }

    /// The owner picked `item`: copy it, then hand it to the pipeline like a file from Files.
    func load(_ item: PhotosPickerItem, into model: AppModel) {
        guard model.pipelineIsFree, !isLoading else { return }
        model.selectedTab = .save
        model.pipeline.reset()
        phase = .loading(fraction: nil)
        PickedMedia.byteLimit = model.capabilities.limits.maxUploadBytes
        PickedMedia.refusedLimit = nil
        let handle = LoadHandle()
        self.handle = handle
        task = Task { [weak self] in
            // the picker's own progress (an iCloud original downloads before it can be copied)
            let ticker = Task { @MainActor [weak self] in
                while !Task.isCancelled {
                    if let self, self.isLoading { self.phase = .loading(fraction: handle.fraction) }
                    try? await Task.sleep(for: .milliseconds(250))
                }
            }
            defer { ticker.cancel() }
            let outcome: Result<PickedMedia, Error>
            do { outcome = .success(try await Self.fetch(item, handle: handle)) } catch { outcome = .failure(error) }
            #if DEBUG
            // `-previewPhotoHold 6` (simulator evidence only): a local file copies instantly; hold the card as an
            // iCloud original would
            let hold = UserDefaults.standard.double(forKey: "previewPhotoHold")
            if hold > 0 { try? await Task.sleep(for: .seconds(hold)) }
            #endif
            guard let self, !Task.isCancelled, self.isLoading else {
                if case .success(let picked) = outcome { Self.discard(picked.url) }
                return
            }
            self.finish(outcome, item: item, model: model)
        }
    }

    /// Cancel is the owner's: stops the copy (and an iCloud download) and clears the card.
    func cancel() {
        guard isLoading else { return }
        handle?.cancel()
        task?.cancel()
        task = nil
        phase = .idle
    }

    func dismissFailure() {
        if case .failed = phase { phase = .idle }
    }

    // MARK: loading

    private nonisolated static func fetch(_ item: PhotosPickerItem, handle: LoadHandle) async throws -> PickedMedia {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let progress = item.loadTransferable(type: PickedMedia.self) { result in
                    switch result {
                    case .success(let picked?): continuation.resume(returning: picked)
                    case .success(nil): continuation.resume(throwing: PickedMedia.Failure.noFile)
                    case .failure(let error): continuation.resume(throwing: error)
                    }
                }
                handle.set(progress)
            }
        } onCancel: {
            handle.cancel()
        }
    }

    private func finish(_ outcome: Result<PickedMedia, Error>, item: PhotosPickerItem, model: AppModel) {
        task = nil
        handle = nil
        switch outcome {
        case .failure(let error):
            if Task.isCancelled || (error as? CancellationError) != nil || Self.isCancel(error) {
                phase = .idle
            } else if let limit = PickedMedia.refusedLimit {
                phase = .failed(.tooLarge(limit: limit))
            } else {
                phase = .failed(.server(code: "error.app.file_unreadable"))
            }
        case .success(let picked):
            guard model.pipelineIsFree else {
                // something else started while the library was copying: leave that run alone
                Self.discard(picked.url)
                phase = .idle
                return
            }
            guard let inbox = Self.moveToInbox(picked.url, item: item, store: model.store) else {
                phase = .failed(.server(code: "error.app.file_unreadable"))
                return
            }
            phase = .idle
            // from here it is a file like any other: the pipeline measures it, checks the limit, uploads
            model.importFile(inbox)
        }
    }

    private nonisolated static func isCancel(_ error: Error) -> Bool {
        let ns = error as NSError
        return ns.domain == NSCocoaErrorDomain && ns.code == NSUserCancelledError
            || ns.domain == NSURLErrorDomain && ns.code == NSURLErrorCancelled
    }

    private nonisolated static func discard(_ url: URL) {
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }

    /// The temp copy moves (a rename on the same volume, no second copy of a big video) into the store's
    /// inbox. A name with no extension gets the one the picked item's own type says.
    private static func moveToInbox(_ url: URL, item: PhotosPickerItem, store: OfflineStore) -> URL? {
        var name = url.lastPathComponent
        if (name as NSString).pathExtension.isEmpty,
           let type = item.supportedContentTypes.first(where: { $0.conforms(to: .movie) || $0.conforms(to: .image) }),
           let ext = type.preferredFilenameExtension {
            name += ".\(ext)"
        }
        let destination = store.inboxURL(for: name)
        let fm = FileManager.default
        do {
            if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
            do { try fm.moveItem(at: url, to: destination) } catch { try fm.copyItem(at: url, to: destination) }
        } catch {
            discard(url)
            return nil
        }
        discard(url)
        return destination
    }
}

private struct PhotoImportKey: EnvironmentKey {
    static var defaultValue: PhotoImport? { nil }
}

extension EnvironmentValues {
    /// The photo library import in flight (the home screen draws its card), set by the shell.
    var photoImport: PhotoImport? {
        get { self[PhotoImportKey.self] }
        set { self[PhotoImportKey.self] = newValue }
    }
}

extension ProgressStory {
    /// The card while a picked item is copied out of the photo library: the upload step, with the
    /// system's own percentage when it reports one.
    static func photoImport(fraction: Double?) -> ProgressStory {
        ProgressStory(
            phase: .uploading, headline: Copy.uploading,
            detail: .text(fraction.map { Copy.copyingFromPhotos(percent: Int(($0 * 100).rounded())) } ?? Copy.copyingFromPhotos),
            fraction: fraction, steps: [.upload, .save, .read, .webp], index: 0)
    }
}
