import CobaltKit
@preconcurrency import FileProvider
import Foundation
import Synchronization

/// Lists one container: the domain root (post folders), a post (its originals), or the working set
/// (every original, so a refresh can update icons without the folder being open).
final class FinderEnumerator: NSObject, NSFileProviderEnumerator {
    let parent: NSFileProviderItemIdentifier
    let catalog: FinderCatalog
    private let invalidated = Mutex(false)

    init(parent: NSFileProviderItemIdentifier, catalog: FinderCatalog) {
        self.parent = parent
        self.catalog = catalog
    }

    func invalidate() { invalidated.withLock { $0 = true } }

    func enumerateItems(for observer: any NSFileProviderEnumerationObserver, startingAt page: NSFileProviderPage) {
        let container = parent
        let offset = Self.offset(of: page)
        let catalog = self.catalog
        let invalidated = self.invalidated
        nonisolated(unsafe) let observer = observer
        Task {
            do {
                let snapshot = try await catalog.snapshot(maxAge: 0)
                await catalog.remember(snapshot)
                if invalidated.withLock({ $0 }) { return }
                let ids = Self.children(in: snapshot, parent: container)
                guard container == .rootContainer || container == .workingSet || snapshot.node(container.rawValue)?.isFolder == true else {
                    observer.finishEnumeratingWithError(finderError(FinderLibrary.Failure.notFound))
                    return
                }
                let end = min(offset + Self.pageSize, ids.count)
                let slice = offset < end ? ids[offset..<end] : []
                let items: [any NSFileProviderItem] = slice.compactMap { raw in
                    guard let node = snapshot.node(raw) else { return nil }
                    return FinderItem(node)
                }
                observer.didEnumerate(items)
                if end < ids.count {
                    observer.finishEnumerating(upTo: NSFileProviderPage(rawValue: Data(String(end).utf8)))
                } else {
                    observer.finishEnumerating(upTo: nil)
                }
            } catch {
                observer.finishEnumeratingWithError(finderError(error))
            }
        }
    }

    func enumerateChanges(for observer: any NSFileProviderChangeObserver, from anchor: NSFileProviderSyncAnchor) {
        let catalog = self.catalog
        let invalidated = self.invalidated
        nonisolated(unsafe) let observer = observer
        Task {
            do {
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

    private static let pageSize = 200

    private static func offset(of page: NSFileProviderPage) -> Int {
        if page == .initialPage || page.rawValue.isEmpty { return 0 }
        return Int(String(data: page.rawValue, encoding: .utf8) ?? "") ?? 0
    }

    private static func children(in snapshot: FinderLibrary.Snapshot, parent: NSFileProviderItemIdentifier) -> [String] {
        if parent == .rootContainer { return snapshot.rootChildren }
        // The working set stays empty. Changes still flow through it (signalEnumerator), which is how
        // a refresh updates files that are already on screen, without pinning every original into Recents.
        if parent == .workingSet { return [] }
        return snapshot.children(of: parent.rawValue)
    }
}
