import Foundation

public enum Format {
    /// ≥ 1e9: "1.2 GB" (1 decimal); ≥ 1e6: "4.3 MB" (1 decimal); else "841 KB" (rounded, min "1 KB").
    public static func bytes(_ n: Int64) -> String {
        if n >= 1_000_000_000 { return String(format: "%.1f GB", Double(n) / 1e9) }
        if n >= 1_000_000 { return String(format: "%.1f MB", Double(n) / 1e6) }
        return "\(max(1, Int((Double(n) / 1e3).rounded()))) KB"
    }

    /// "10.0 s"
    public static func seconds(_ s: Double) -> String {
        String(format: "%.1f s", s)
    }

    /// "00:04.1"
    public static func timecode(_ s: Double) -> String {
        let m = Int((s / 60).rounded(.down))
        let r = s - Double(m) * 60
        return String(format: "%02d:%04.1f", m, r)
    }

    /// "720×1280"
    public static func size(_ w: Int, _ h: Int) -> String { "\(w)×\(h)" }

    private static let months = ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"]

    /// "today 12:46", "yesterday 13:59", else "3 oct 09:31". Lowercase, locale independent.
    public static func when(_ d: Date, now: Date) -> String {
        let cal = Calendar.current
        let c = cal.dateComponents([.year, .month, .day, .hour, .minute], from: d)
        let hm = String(format: "%02d:%02d", c.hour ?? 0, c.minute ?? 0)
        if cal.isDate(d, inSameDayAs: now) { return "today \(hm)" }
        if let y = cal.date(byAdding: .day, value: -1, to: now), cal.isDate(d, inSameDayAs: y) {
            return "yesterday \(hm)"
        }
        let month = months[max(0, min(11, (c.month ?? 1) - 1))]
        return "\(c.day ?? 1) \(month) \(hm)"
    }
}
