import Foundation

/// The small record the Mac app and the File Provider extension share: which server, and whether the
/// sidebar location is on. The API key stays in the shared keychain (`Settings.apiKey`); this file
/// never holds it.
///
/// Opening the app-group container on macOS is what raises the "access data from other apps" prompt,
/// so the app calls `liveContainer()` only after the owner turns the sidebar on (and on later launches
/// while it stays on). The Videos store is not moved into the group.
public enum FinderBridge {
    public static let domainIdentifier = "capystore"
    public static let displayName = "Capystore"
    public static let enabledDefaultsKey = "finderSidebar.enabled"

    public struct Record: Codable, Equatable, Sendable {
        public var serverURL: String
        public var enabled: Bool

        public init(serverURL: String, enabled: Bool) {
            self.serverURL = serverURL
            self.enabled = enabled
        }

        public var url: URL? { URL(string: serverURL) }
    }

    public static func fileURL(in container: URL) -> URL {
        container.appendingPathComponent("Finder", isDirectory: true).appendingPathComponent("bridge.json")
    }

    public static func snapshotURL(in container: URL) -> URL {
        container.appendingPathComponent("Finder", isDirectory: true).appendingPathComponent("snapshot.json")
    }

    public static func read(in container: URL) -> Record? {
        guard let data = try? Data(contentsOf: fileURL(in: container)) else { return nil }
        return try? JSONDecoder().decode(Record.self, from: data)
    }

    public static func write(_ record: Record, in container: URL) throws {
        let url = fileURL(in: container)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(record).write(to: url, options: .atomic)
    }

    /// The real group container. Nil under `-cobaltSandboxRoot` (a debug run must not touch the owner's group)
    /// and when the entitlement is missing.
    public static func liveContainer() -> URL? {
        if AppGroup.sandboxRoot != nil { return nil }
        return FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: AppGroup.id)
    }

    public static func saved() -> Record? {
        guard let container = liveContainer() else { return nil }
        return read(in: container)
    }

    /// Writes the bridge. Nil container (no entitlement, or a sandbox debug run) throws.
    public static func publish(serverURL: URL, enabled: Bool) throws {
        guard let container = liveContainer() else { throw CocoaError(.fileNoSuchFile) }
        try write(Record(serverURL: serverURL.absoluteString, enabled: enabled), in: container)
    }

    /// Keeps the server in step while the sidebar is already on. Does nothing when the bridge was never written.
    public static func noteServer(_ url: URL) {
        guard let container = liveContainer(), var record = read(in: container) else { return }
        record.serverURL = url.absoluteString
        try? write(record, in: container)
    }
}
