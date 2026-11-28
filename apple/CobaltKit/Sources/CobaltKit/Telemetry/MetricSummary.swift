import Foundation
#if canImport(MetricKit)
import MetricKit

/// MetricKit's daily metric payload, flattened to the numbers worth a chart: how smooth scrolling was, how slow
/// launches and hangs were, how much CPU, GPU, memory, network, disk, display luminance and background time the app
/// used. Averages of histograms use each bucket's middle.
enum MetricSummary {
    private static let energyKeys: Set<String> = [
        "cpu_kinst", "wifi_dl_mb", "cell_dl_mb", "disk_write_mb", "apl", "bg_s", "bg_audio_s",
    ]

    static func values(_ p: MXMetricPayload) -> [String: TelemetryValue] {
        var out: [String: TelemetryValue] = [:]
        out["version"] = .string(p.latestApplicationVersion)
        out["hours"] = .double(round1(p.timeStampEnd.timeIntervalSince(p.timeStampBegin) / 3600))
        if let build = p.metaData?.applicationBuildVersion { out["build"] = .string(build) }
        #if os(iOS)
        if let ratio = p.animationMetrics?.scrollHitchTimeRatio {
            out["scroll_hitch_ratio"] = .double(round1(ratio.value))
        }
        #endif
        if let launch = p.applicationLaunchMetrics {
            put(&out, "launch", launch.histogrammedTimeToFirstDraw)
            put(&out, "resume", launch.histogrammedApplicationResumeTime)
        }
        if let hangs = p.applicationResponsivenessMetrics {
            put(&out, "hang", hangs.histogrammedApplicationHangTime)
        }
        if let cpu = p.cpuMetrics {
            out["cpu_s"] = .double(round1(cpu.cumulativeCPUTime.converted(to: .seconds).value))
            let kinst = Int(cpu.cumulativeCPUInstructions.value.rounded())
            if kinst > 0 { out["cpu_kinst"] = .int(kinst) }
        }
        if let gpu = p.gpuMetrics {
            out["gpu_s"] = .double(round1(gpu.cumulativeGPUTime.converted(to: .seconds).value))
        }
        if let memory = p.memoryMetrics {
            out["peak_mb"] = .int(Int(memory.peakMemoryUsage.converted(to: .megabytes).value.rounded()))
        }
        if let time = p.applicationTimeMetrics {
            out["foreground_s"] = .int(Int(time.cumulativeForegroundTime.converted(to: .seconds).value.rounded()))
            let bg = Int(time.cumulativeBackgroundTime.converted(to: .seconds).value.rounded())
            if bg > 0 { out["bg_s"] = .int(bg) }
            let bgAudio = Int(time.cumulativeBackgroundAudioTime.converted(to: .seconds).value.rounded())
            if bgAudio > 0 { out["bg_audio_s"] = .int(bgAudio) }
        }
        if let net = p.networkTransferMetrics {
            let wifi = round1(net.cumulativeWifiDownload.converted(to: .megabytes).value)
            let cell = round1(net.cumulativeCellularDownload.converted(to: .megabytes).value)
            if wifi > 0 { out["wifi_dl_mb"] = .double(wifi) }
            if cell > 0 { out["cell_dl_mb"] = .double(cell) }
        }
        if let disk = p.diskIOMetrics {
            let writeMb = round1(disk.cumulativeLogicalWrites.converted(to: .megabytes).value)
            if writeMb > 0 { out["disk_write_mb"] = .double(writeMb) }
        }
        if let apl = p.displayMetrics?.averagePixelLuminance {
            out["apl"] = .double(round1(apl.averageMeasurement.value))
        }
        return out
    }

    /// Splits a full daily payload into two ≤20-key dictionaries so `TelemetryLog` never silently truncates keys under
    /// `TelemetryLimits.dataKeys` while PostHog still receives the full flat `daily_metrics` event.
    static func splitForLog(
        _ full: [String: TelemetryValue]
    ) -> (core: [String: TelemetryValue], energy: [String: TelemetryValue]) {
        guard full.count > TelemetryLimits.dataKeys else { return (full, [:]) }
        var core: [String: TelemetryValue] = [:]
        var energy: [String: TelemetryValue] = [:]
        for (k, v) in full {
            if energyKeys.contains(k) {
                energy[k] = v
            } else {
                core[k] = v
            }
        }
        if !energy.isEmpty {
            if let v = full["version"] { energy["version"] = v }
            if let b = full["build"] { energy["build"] = b }
            if let h = full["hours"] { energy["hours"] = h }
            if let fg = full["foreground_s"] { energy["foreground_s"] = fg }
        }
        return (core, energy)
    }

    /// `<name>_ms` (mean) and `<name>_n` (how many) from a duration histogram; nothing when it is empty.
    private static func put(_ out: inout [String: TelemetryValue], _ name: String, _ h: MXHistogram<UnitDuration>) {
        var count = 0
        var sum = 0.0
        for case let bucket as MXHistogramBucket<UnitDuration> in h.bucketEnumerator {
            let mid = (bucket.bucketStart.converted(to: .milliseconds).value + bucket.bucketEnd.converted(to: .milliseconds).value) / 2
            count += bucket.bucketCount
            sum += mid * Double(bucket.bucketCount)
        }
        guard count > 0 else { return }
        out["\(name)_ms"] = .int(Int((sum / Double(count)).rounded()))
        out["\(name)_n"] = .int(count)
    }

    private static func round1(_ v: Double) -> Double { (v * 10).rounded() / 10 }
}
#endif
