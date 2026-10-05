import Foundation

// Self-hosted crash and log telemetry (the owner's own server: `POST /telemetry`). The wire shapes
// here are the pinned server contract; nothing in this folder knows about the UI.

public enum TelemetryLevel: String, Sendable, Codable, CaseIterable { case debug, info, warn, error }

public enum TelemetryCategory: String, Sendable, Codable, CaseIterable {
    case app, pipeline, upload, share, photos, sync, net, store, ui, live
}

/// Which process wrote an event: the app, the share extension or the widgets (Live Activity) extension.
public enum TelemetryProcess: String, Sendable, Codable, CaseIterable { case app, share, widgets }

/// A flat value: the wire allows strings, numbers and booleans in an event's `data`, nothing nested.
public enum TelemetryValue: Sendable, Equatable, Codable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)

    public init(from decoder: any Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let b = try? c.decode(Bool.self) { self = .bool(b); return }
        if let i = try? c.decode(Int.self) { self = .int(i); return }
        if let d = try? c.decode(Double.self) { self = .double(d); return }
        self = .string(try c.decode(String.self))
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let s): try c.encode(s)
        case .int(let i): try c.encode(i)
        case .bool(let b): try c.encode(b)
        case .double(let d):
            // JSON has no NaN or infinity: say so as text rather than fail the whole line
            if d.isFinite { try c.encode(d) } else { try c.encode(String(d)) }
        }
    }

    /// A byte count or any other 64-bit number.
    public static func bytes(_ n: Int64) -> TelemetryValue { .int(Int(clamping: n)) }
}

extension TelemetryValue: ExpressibleByStringLiteral, ExpressibleByIntegerLiteral,
    ExpressibleByFloatLiteral, ExpressibleByBooleanLiteral {
    public init(stringLiteral value: String) { self = .string(value) }
    public init(integerLiteral value: Int) { self = .int(value) }
    public init(floatLiteral value: Double) { self = .double(value) }
    public init(booleanLiteral value: Bool) { self = .bool(value) }
}

/// One log line, as the server takes it.
public struct TelemetryEvent: Sendable, Codable, Equatable {
    public var ts: Int64                       // unix milliseconds
    public var level: TelemetryLevel
    public var cat: TelemetryCategory
    public var msg: String                     // at most `TelemetryLimits.messageLength` characters
    public var data: [String: TelemetryValue]  // flat, at most `TelemetryLimits.dataKeys` keys

    public init(ts: Int64, level: TelemetryLevel, cat: TelemetryCategory, msg: String, data: [String: TelemetryValue] = [:]) {
        self.ts = ts
        self.level = level
        self.cat = cat
        self.msg = msg
        self.data = data
    }
}

/// An event as it sits in the shared buffer: the wire event plus where it came from.
struct StoredEvent: Sendable, Codable, Equatable {
    /// `<process run tag>.<sequence>`: unique across every process that writes to the buffer, and the
    /// upload's "already sent" bookkeeping keys on it.
    var i: String
    var p: TelemetryProcess
    var e: TelemetryEvent

    /// The run tag (the part of `i` before the dot).
    var run: String { String(i.prefix { $0 != "." }) }
}

public enum CrashKind: String, Sendable, Codable, CaseIterable {
    case crash, hang, cpu, disk, launch
    case uncleanExit = "unclean_exit"
}

/// A crash, hang or other diagnostic waiting to be sent. The MetricKit JSON that goes with it is kept
/// beside it as raw bytes and passed through untouched (never parsed, never re-encoded).
public struct CrashRecord: Sendable, Codable, Equatable {
    public var id: String
    public var ts: Int64
    public var kind: CrashKind
    public var summary: String
    public var events: [TelemetryEvent]
    public var hasPayload: Bool

    public init(id: String, ts: Int64, kind: CrashKind, summary: String, events: [TelemetryEvent], hasPayload: Bool) {
        self.id = id
        self.ts = ts
        self.kind = kind
        self.summary = summary
        self.events = events
        self.hasPayload = hasPayload
    }
}

/// What the server accepts per request (the pinned contract).
public enum TelemetryLimits {
    public static let messageLength = 300
    public static let summaryLength = 300
    public static let dataKeys = 20
    public static let eventsPerBatch = 500
    public static let crashesPerBatch = 10
    /// The server's cap is 256 KB; stay well under it.
    public static let bodyBytes = 240_000
    /// Events carried by a crash record.
    public static let crashEvents = 100
}

/// Who is talking: the batch's `app` block.
public struct TelemetryAppInfo: Sendable, Codable, Equatable {
    public var version: String
    public var build: String
    public var platform: String      // "ios" | "macos"
    public var os: String
    public var device: String
    public var process: TelemetryProcess

    public init(version: String, build: String, platform: String, os: String, device: String, process: TelemetryProcess) {
        self.version = version
        self.build = build
        self.platform = platform
        self.os = os
        self.device = device
        self.process = process
    }

    /// This process: bundle version and build, platform, OS, hardware model.
    public static func current(process: TelemetryProcess) -> TelemetryAppInfo {
        let info = Bundle.main.infoDictionary ?? [:]
        let v = ProcessInfo.processInfo.operatingSystemVersion
        let version = "\(v.majorVersion).\(v.minorVersion)" + (v.patchVersion > 0 ? ".\(v.patchVersion)" : "")
        #if os(macOS)
        let platform = "macos", osName = "macOS"
        #else
        let platform = "ios", osName = "iOS"
        #endif
        return TelemetryAppInfo(
            version: info["CFBundleShortVersionString"] as? String ?? "0",
            build: info["CFBundleVersion"] as? String ?? "0",
            platform: platform, os: "\(osName) \(version)", device: hardwareModel(), process: process)
    }

    static func hardwareModel() -> String {
        #if targetEnvironment(simulator)
        if let id = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"], !id.isEmpty { return id }
        #endif
        #if os(macOS)
        let name = "hw.model"
        #else
        let name = "hw.machine"
        #endif
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return "unknown" }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return "unknown" }
        return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
}

/// The random id of this install, stable until the app is deleted. Only the app reads it (it is the
/// only process that uploads), so there is no race to create it.
public enum TelemetryInstall {
    static let key = "telemetryInstallID"

    public static func id() -> String { id(defaults: AppGroup.defaults()) }

    static func id(defaults: UserDefaults) -> String {
        if let existing = defaults.string(forKey: key), UUID(uuidString: existing) != nil { return existing }
        let fresh = UUID().uuidString.lowercased()
        defaults.set(fresh, forKey: key)
        return fresh
    }
}
