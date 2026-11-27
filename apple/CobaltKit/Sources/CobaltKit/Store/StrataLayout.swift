import Foundation

/// How the home screen's chronological strata group offline media (the "core sample" layout).
/// Each bucket is ordered newest-first down into deeper history; its cumulative byte offset gives
/// the leading megabyte ruler and its byte weight sets the stratum's height.
public enum StrataBucket: Hashable, Sendable {
    case today
    case yesterday
    case thisWeek
    /// A distinct calendar month within the recent window (up to ~6 months back).
    case month(year: Int, month: Int)
    case older

    /// Stable identifier for SwiftUI diffing and accessibility.
    public var id: String {
        switch self {
        case .today: return "today"
        case .yesterday: return "yesterday"
        case .thisWeek: return "this-week"
        case .month(let year, let month): return String(format: "%04d-%02d", year, month)
        case .older: return "older"
        }
    }
}

/// One chronological stratum of offline media with its cumulative ruler offset.
public struct StrataLayer: Identifiable, Equatable, Sendable {
    public var id: String { bucket.id }
    public let bucket: StrataBucket
    /// Zero-based geological depth from the surface (`0` = newest visible stratum).
    public let depth: Int
    /// Media in this stratum, newest activity first.
    public let media: [StoredMedia]
    /// Total bytes across every media item in this stratum.
    public let bytes: Int64
    /// Cumulative bytes in all shallower strata above this one (the ruler tick at this layer's top edge).
    public let cumulativeStartBytes: Int64
    /// Cumulative bytes through the bottom of this stratum (`cumulativeStartBytes + bytes`).
    public let cumulativeEndBytes: Int64

    public init(
        bucket: StrataBucket, depth: Int, media: [StoredMedia], bytes: Int64,
        cumulativeStartBytes: Int64, cumulativeEndBytes: Int64
    ) {
        self.bucket = bucket
        self.depth = depth
        self.media = media
        self.bytes = bytes
        self.cumulativeStartBytes = cumulativeStartBytes
        self.cumulativeEndBytes = cumulativeEndBytes
    }
}

/// The complete core sample derived from the device's visible stored media.
public struct StrataColumn: Equatable, Sendable {
    public let layers: [StrataLayer]
    public let totalBytes: Int64
    public let mediaCount: Int
    public let maxLayerBytes: Int64

    public var isEmpty: Bool { layers.isEmpty }

    public init(layers: [StrataLayer], totalBytes: Int64, mediaCount: Int, maxLayerBytes: Int64) {
        self.layers = layers
        self.totalBytes = totalBytes
        self.mediaCount = mediaCount
        self.maxLayerBytes = maxLayerBytes
    }
}

extension StoredMedia {
    /// Total known bytes across all renditions of this media on disk / in the index.
    public var totalBytes: Int64 {
        renditions.reduce(Int64(0)) { $0 + max(0, $1.bytes) }
    }
}

public enum StrataLayout {
    /// How many distinct calendar months back get their own named stratum before collapsing into `.older`.
    public static let namedMonthSpan = 6

    /// Classifies a timestamp relative to `now` into its chronological stratum bucket.
    public static func bucket(for date: Date, now: Date, calendar: Calendar = .current) -> StrataBucket {
        if calendar.isDate(date, inSameDayAs: now) || date > now {
            return .today
        }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
           calendar.isDate(date, inSameDayAs: yesterday) {
            return .yesterday
        }
        let startOfToday = calendar.startOfDay(for: now)
        if let weekCutoff = calendar.date(byAdding: .day, value: -7, to: startOfToday),
           date >= weekCutoff {
            return .thisWeek
        }
        if let monthCutoff = calendar.date(byAdding: .month, value: -namedMonthSpan, to: startOfToday),
           date >= monthCutoff {
            let comps = calendar.dateComponents([.year, .month], from: date)
            if let year = comps.year, let month = comps.month {
                return .month(year: year, month: month)
            }
        }
        return .older
    }

    /// Groups `media` (expected newest-first, as `OfflineStore.media` provides) into chronological strata
    /// with cumulative byte offsets down the leading edge.
    public static func build(
        from media: [StoredMedia],
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> StrataColumn {
        guard !media.isEmpty else {
            return StrataColumn(layers: [], totalBytes: 0, mediaCount: 0, maxLayerBytes: 0)
        }

        // Preserve newest-first ordering across strata even if caller passes unsorted media.
        let sorted = media.sorted { $0.latestAt > $1.latestAt }
        var order: [StrataBucket] = []
        var grouped: [StrataBucket: [StoredMedia]] = [:]

        for item in sorted {
            let b = bucket(for: item.latestAt, now: now, calendar: calendar)
            if grouped[b] == nil { order.append(b) }
            grouped[b, default: []].append(item)
        }

        var cumulative: Int64 = 0
        var maxBytes: Int64 = 0
        var layers: [StrataLayer] = []
        layers.reserveCapacity(order.count)

        for (depth, b) in order.enumerated() {
            let items = grouped[b] ?? []
            let bytes = items.reduce(Int64(0)) { $0 + $1.totalBytes }
            let start = cumulative
            cumulative += bytes
            if bytes > maxBytes { maxBytes = bytes }
            layers.append(StrataLayer(
                bucket: b, depth: depth, media: items, bytes: bytes,
                cumulativeStartBytes: start, cumulativeEndBytes: cumulative))
        }

        return StrataColumn(
            layers: layers,
            totalBytes: cumulative,
            mediaCount: sorted.count,
            maxLayerBytes: maxBytes)
    }

    /// Computes a stratum's visual height proportional to its byte weight.
    /// Small libraries scale linearly (`minHeight + mb * 0.42`), while multi-gigabyte libraries compress
    /// smoothly into `[minHeight, maxHeight]` so every stratum stays scannable and every thumbnail stays tappable.
    public static func layerHeight(
        bytes: Int64,
        maxLayerBytes: Int64,
        minHeight: Double = 92,
        maxHeight: Double = 176
    ) -> Double {
        guard bytes > 0, maxHeight > minHeight else { return minHeight }
        let mb = Double(bytes) / 1_000_000.0
        let rawBonus = mb * 0.42
        let maxRaw = max(1.0, (Double(maxLayerBytes) / 1_000_000.0) * 0.42)
        let span = maxHeight - minHeight
        let bonus = maxRaw > span ? (rawBonus / maxRaw) * span : rawBonus
        return (minHeight + min(span, max(0, bonus))).rounded()
    }

    /// Compact leading-ruler megabyte tick (`"0"`, `"18"`, `"164"`, `"1.4g"` for >= 1000 MB).
    public static func megabyteTick(for bytes: Int64) -> String {
        guard bytes > 0 else { return "0" }
        let mb = Double(bytes) / 1_000_000.0
        if mb >= 1_000 {
            let gb = ((mb / 1_000.0) * 10.0).rounded() / 10.0
            return String(format: "%.1fg", gb)
        }
        if mb < 1 {
            return "<1"
        }
        return "\(Int(mb.rounded()))"
    }
}
