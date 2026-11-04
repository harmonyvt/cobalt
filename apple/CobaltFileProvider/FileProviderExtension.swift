import CobaltKit
@preconcurrency import FileProvider
import Foundation

/// Read-only Capystore domain. Finder lists posts as folders and downloads an original when it is
/// opened or Quick Looked. Writes are refused: the item capabilities do not offer them, and the
/// calls below answer unsupported so a drop or a rename is reverted.
final class FileProviderExtension: NSObject, NSFileProviderReplicatedExtension, NSFileProviderThumbnailing {
    let domain: NSFileProviderDomain
    let catalog = FinderCatalog()

    required init(domain: NSFileProviderDomain) {
        self.domain = domain
        super.init()
    }

    func invalidate() {}

    func item(
        for identifier: NSFileProviderItemIdentifier, request: NSFileProviderRequest,
        completionHandler: @escaping (NSFileProviderItem?, Error?) -> Void
    ) -> Progress {
        if identifier == .rootContainer {
            completionHandler(FinderRootItem(), nil)
            return Progress()
        }
        let catalog = self.catalog
        // `completion` is a function value, not a trailing closure, so it has to be a normal argument.
        return work(
            { try await catalog.snapshot(maxAge: FinderCatalog.freshInterval) },
            result: { snapshot in
                guard let node = snapshot.node(identifier.rawValue) else { throw FinderLibrary.Failure.notFound }
                return FinderItem(node)
            },
            completion: completionHandler)
    }

    func fetchContents(
        for itemIdentifier: NSFileProviderItemIdentifier, version requestedVersion: NSFileProviderItemVersion?,
        request: NSFileProviderRequest, completionHandler: @escaping (URL?, NSFileProviderItem?, Error?) -> Void
    ) -> Progress {
        let catalog = self.catalog
        nonisolated(unsafe) let completion = completionHandler
        // `FileManager` is not `Sendable`. The local is the explicit opt-out so the task may delete a
        // cancelled download.
        nonisolated(unsafe) let files = FileManager.default
        let progress = Progress()
        let task = Task {
            do {
                let (url, node) = try await catalog.contents(of: itemIdentifier.rawValue)
                if Task.isCancelled {
                    try? files.removeItem(at: url.deletingLastPathComponent())
                    return
                }
                completion(url, FinderItem(node), nil)
            } catch {
                if Task.isCancelled { return }
                completion(nil, nil, finderError(error))
            }
        }
        progress.cancellationHandler = { task.cancel() }
        return progress
    }

    func createItem(
        basedOn itemTemplate: NSFileProviderItem, fields: NSFileProviderItemFields, contents url: URL?,
        options: NSFileProviderCreateItemOptions, request: NSFileProviderRequest,
        completionHandler: @escaping (NSFileProviderItem?, NSFileProviderItemFields, Bool, Error?) -> Void
    ) -> Progress {
        completionHandler(nil, [], false, Self.readOnly)
        return Progress()
    }

    func modifyItem(
        _ item: NSFileProviderItem, baseVersion version: NSFileProviderItemVersion, changedFields: NSFileProviderItemFields,
        contents newContents: URL?, options: NSFileProviderModifyItemOptions, request: NSFileProviderRequest,
        completionHandler: @escaping (NSFileProviderItem?, NSFileProviderItemFields, Bool, Error?) -> Void
    ) -> Progress {
        completionHandler(nil, [], false, Self.readOnly)
        return Progress()
    }

    func deleteItem(
        identifier: NSFileProviderItemIdentifier, baseVersion version: NSFileProviderItemVersion,
        options: NSFileProviderDeleteItemOptions, request: NSFileProviderRequest,
        completionHandler: @escaping (Error?) -> Void
    ) -> Progress {
        completionHandler(Self.readOnly)
        return Progress()
    }

    func enumerator(for containerItemIdentifier: NSFileProviderItemIdentifier, request: NSFileProviderRequest) throws -> NSFileProviderEnumerator {
        FinderEnumerator(parent: containerItemIdentifier, catalog: catalog)
    }

    func fetchThumbnails(
        for itemIdentifiers: [NSFileProviderItemIdentifier], requestedSize size: CGSize,
        perThumbnailCompletionHandler: @escaping (NSFileProviderItemIdentifier, Data?, Error?) -> Void,
        completionHandler: @escaping (Error?) -> Void
    ) -> Progress {
        let catalog = self.catalog
        nonisolated(unsafe) let each = perThumbnailCompletionHandler
        nonisolated(unsafe) let done = completionHandler
        let progress = Progress()
        let pixels = Int(max(size.width, size.height) * 2)
        let task = Task {
            for identifier in itemIdentifiers {
                if Task.isCancelled { break }
                do {
                    let data = try await catalog.thumbnail(of: identifier.rawValue, maxPixel: pixels)
                    each(identifier, data, nil)
                } catch {
                    each(identifier, nil, finderError(error))
                }
            }
            done(nil)
        }
        progress.cancellationHandler = { task.cancel() }
        return progress
    }

    private static let readOnly = NSError(domain: NSCocoaErrorDomain, code: NSFeatureUnsupportedError)

    /// Runs `load`, then `result`, and always calls `completion` with either the item or the error.
    private func work(
        _ load: @escaping @Sendable () async throws -> FinderLibrary.Snapshot,
        result: @escaping @Sendable (FinderLibrary.Snapshot) throws -> FinderItem,
        completion: @escaping (NSFileProviderItem?, Error?) -> Void
    ) -> Progress {
        nonisolated(unsafe) let completion = completion
        let progress = Progress()
        let task = Task {
            do {
                let item = try result(try await load())
                if Task.isCancelled { return }
                completion(item, nil)
            } catch {
                if Task.isCancelled { return }
                completion(nil, finderError(error))
            }
        }
        progress.cancellationHandler = { task.cancel() }
        return progress
    }
}
