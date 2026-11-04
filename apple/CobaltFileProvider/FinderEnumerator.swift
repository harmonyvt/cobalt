import CobaltKit
@preconcurrency import FileProvider
import Foundation
import Synchronization

/// Lists one container: the domain root (post folders), a post (its originals), or the working set
/// (every original, so a refresh can update icons without the folder being open).
final class FinderEnumerator: NSObject, NSFileProviderEnumerator {
    let parent: NSFileProviderItemIdentifier
    let catalog: FinderCatalog
    private let invalidated = InvalidationFlag()

    init(parent: NSFileProviderItemIdentifier, catalog: FinderCatalog) {
        self.parent = parent
        self.catalog = catalog
    }

    func invalidate() { invalidated.withLock { $0 = true } }

    func enumerateItems(for observer: any NSFileProviderEnumerationObserver, startingAt page: NSFileProviderPage) {
        let container = parent
        let catalog = self.catalog
        let invalidated = self.invalidated
        nonisolated(unsafe) let observer = observer
        Task {
            do {
                if invalidated.withLock({ $0 }) { return }
                if container == .workingSet {
                    observer.didEnumerate([])
                    observer.finishEnumerating(upTo: nil)
                    return
                }
                if container == .rootContainer {
                    let listing = try await catalog.rootPage(cursor: Self.libraryCursor(of: page))
                    if invalidated.withLock({ $0 }) { return }
                    let items: [any NSFileProviderItem] = listing.folders.map { FinderItem($0) as any NSFileProviderItem }
                    observer.didEnumerate(items)
                    if let next = listing.nextCursor {
                        observer.finishEnumerating(upTo: NSFileProviderPage(rawValue: FinderLibrary.RootPageToken(cursor: next).data))
                    } else {
                        observer.finishEnumerating(upTo: nil)
                    }
                    return
                }
                guard let files = await catalog.children(of: container.rawValue) else {
                    observer.finishEnumeratingWithError(finderError(FinderLibrary.Failure.notFound))
                    return
                }
                let items: [any NSFileProviderItem] = files.map { FinderItem($0) as any NSFileProviderItem }
                observer.didEnumerate(items)
                observer.finishEnumerating(upTo: nil)
            } catch {
                observer.finishEnumeratingWithError(finderError(error))
            }
        }
    }

    func enumerateChanges(for observer: any NSFileProviderChangeObserver, from anchor: NSFileProviderSyncAnchor) {
        let container = parent
        let catalog = self.catalog
        let invalidated = self.invalidated
        nonisolated(unsafe) let observer = observer
        Task {
            do {
                // A full walk only for the working set. Root and folder changes stay on the pages
                // already listed, so opening the location does not wait out the whole library.
                guard container == .workingSet else {
                    let current = await catalog.currentAnchor() ?? Data()
                    observer.finishEnumeratingChanges(upTo: NSFileProviderSyncAnchor(rawValue: current), moreComing: false)
                    return
                }
                let result = try await catalog.sync(from: anchor.rawValue)
                if invalidated.withLock({ $0 }) { return }
                switch result {
                case .current(let snapshot):
                    observer.finishEnumeratingChanges(upTo: NSFileProviderSyncAnchor(rawValue: snapshot.anchor), moreComing: false)
                case .rescan:
                    observer.finishEnumeratingWithError(NSError(
                        domain: NSFileProviderErrorDomain, code: NSFileProviderError.Code.syncAnchorExpired.rawValue))
                case .apply(let delta, let snapshot):
                    let updated: [any NSFileProviderItem] = delta.updated.compactMap { raw in
                        guard let node = snapshot.node(raw) else { return nil }
                        return FinderItem(node)
                    }
                    if !updated.isEmpty { observer.didUpdate(updated) }
                    if !delta.deleted.isEmpty {
                        observer.didDeleteItems(withIdentifiers: delta.deleted.map { NSFileProviderItemIdentifier(rawValue: $0) })
                    }
                    observer.finishEnumeratingChanges(upTo: NSFileProviderSyncAnchor(rawValue: snapshot.anchor), moreComing: false)
                }
            } catch {
                observer.finishEnumeratingWithError(finderError(error))
            }
        }
    }

    func currentSyncAnchor(completionHandler: @escaping (NSFileProviderSyncAnchor?) -> Void) {
        let catalog = self.catalog
        nonisolated(unsafe) let completionHandler = completionHandler
        Task {
            let anchor = await catalog.currentAnchor()
            completionHandler(anchor.map { NSFileProviderSyncAnchor(rawValue: $0) })
        }
    }

    /// The API cursor for this file-provider page. The system's first-page sentinels and empty data
    /// mean "no cursor". Anything else is the cursor the previous page handed back.
    private static func libraryCursor(of page: NSFileProviderPage) -> String? {
        let byName = NSFileProviderPage(NSFileProviderPage.initialPageSortedByName as Data)
        let byDate = NSFileProviderPage(NSFileProviderPage.initialPageSortedByDate as Data)
        if page == byName || page == byDate || page.rawValue.isEmpty { return nil }
        return FinderLibrary.RootPageToken(pageData: page.rawValue).cursor
    }
}

/// `Mutex` is not copyable, so a `Task` cannot take `let flag = self.invalidated`. This class is.
private final class InvalidationFlag: Sendable {
    private let state = Mutex(false)

    func withLock<R>(_ body: (inout Bool) -> R) -> R {
        state.withLock { body(&$0) }
    }
}
