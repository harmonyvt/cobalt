import CobaltKit
@preconcurrency import FileProvider
import UniformTypeIdentifiers

/// A folder or a file in the Capystore domain. Built from a `FinderLibrary.Node`; the system tracks
/// whether the bytes have been downloaded.
final class FinderItem: NSObject, NSFileProviderItem, @unchecked Sendable {
    let node: FinderLibrary.Node

    init(_ node: FinderLibrary.Node) {
        self.node = node
    }

    var itemIdentifier: NSFileProviderItemIdentifier { NSFileProviderItemIdentifier(rawValue: node.raw) }
    var parentItemIdentifier: NSFileProviderItemIdentifier {
        guard let parent = node.parent else { return .rootContainer }
        return NSFileProviderItemIdentifier(rawValue: parent.raw)
    }
    var filename: String { node.name }
    var contentType: UTType {
        node.isFolder ? .folder : (UTType(node.typeIdentifier) ?? .data)
    }
    var capabilities: NSFileProviderItemCapabilities {
        // Read-only. Evicting drops the local copy only; it does not delete the library file.
        if node.isFolder { return [.allowsContentEnumerating, .allowsReading] }
        return [.allowsReading, .allowsEvicting]
    }
    var documentSize: NSNumber? {
        guard let bytes = node.bytes, !node.isFolder else { return nil }
        return NSNumber(value: bytes)
    }
    var childItemCount: NSNumber? {
        guard let count = node.childCount else { return nil }
        return NSNumber(value: count)
    }
    var creationDate: Date? { node.createdAt }
    var contentModificationDate: Date? { node.createdAt }
    var itemVersion: NSFileProviderItemVersion {
        NSFileProviderItemVersion(contentVersion: node.contentVersion, metadataVersion: node.metadataVersion)
    }
}

/// The domain root. Finder asks for it; it is not a post.
final class FinderRootItem: NSObject, NSFileProviderItem, @unchecked Sendable {
    var itemIdentifier: NSFileProviderItemIdentifier { .rootContainer }
    var parentItemIdentifier: NSFileProviderItemIdentifier { .rootContainer }
    var filename: String { FinderBridge.displayName }
    var contentType: UTType { .folder }
    var capabilities: NSFileProviderItemCapabilities { [.allowsContentEnumerating, .allowsReading] }
    var itemVersion: NSFileProviderItemVersion {
        NSFileProviderItemVersion(contentVersion: Data([0]), metadataVersion: Data([0]))
    }
}

func finderError(_ error: Error) -> NSError {
    if let error = error as NSError?, error.domain == NSFileProviderErrorDomain { return error }
    let code: NSFileProviderError.Code
    switch FinderLibrary.failure(from: error) {
    case .unauthorized: code = .notAuthenticated
    case .unreachable: code = .serverUnreachable
    case .notFound: code = .noSuchItem
    case .other: code = .cannotSynchronize
    }
    return NSError(domain: NSFileProviderErrorDomain, code: code.rawValue)
}
