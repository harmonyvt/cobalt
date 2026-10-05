import Foundation

/// How much the device keeps offline (CONTRACT-LIVE.md section 4). Decimal gigabytes, like `Format`
/// and the iOS storage screen.
public enum StorageLimit: String, Sendable, Codable, CaseIterable {
    case gb1, gb2, gb5, gb10, gb20, unlimited

    /// 1_000_000_000 … 20_000_000_000; nil = no limit.
    public var bytes: Int64? {
        switch self {
        case .gb1: return 1_000_000_000
        case .gb2: return 2_000_000_000
        case .gb5: return 5_000_000_000
        case .gb10: return 10_000_000_000
        case .gb20: return 20_000_000_000
        case .unlimited: return nil
        }
    }

    public static let `default`: StorageLimit = .gb5
}

/// Where the limit lives: the app-group defaults, key `storageLimit`, read inside every enforcement
/// so the app and the share extension always agree without wiring (CONTRACT-LIVE.md 4.2).
enum LimitDefaults {
    static let key = "storageLimit"
    /// Tests only: a byte count that is no `StorageLimit` case (fake sizes). Wins over `key` while
    /// present; `Settings.storageLimit` clears it, so the owner's choice always has the last word.
    static let bytesKey = "storageLimitBytes"

    static func choice(_ defaults: UserDefaults) -> StorageLimit {
        defaults.string(forKey: key).flatMap(StorageLimit.init(rawValue:)) ?? .default
    }

    /// The effective limit in bytes; nil = unlimited.
    static func bytes(_ defaults: UserDefaults) -> Int64? {
        if let n = defaults.object(forKey: bytesKey) as? NSNumber { return n.int64Value }
        return choice(defaults).bytes
    }

    static func write(_ bytes: Int64?, to defaults: UserDefaults) {
        if let match = StorageLimit.allCases.first(where: { $0.bytes == bytes }) {
            defaults.set(match.rawValue, forKey: key)
            defaults.removeObject(forKey: bytesKey)
        } else if let bytes {
            defaults.set(NSNumber(value: bytes), forKey: bytesKey)
        }
    }
}
