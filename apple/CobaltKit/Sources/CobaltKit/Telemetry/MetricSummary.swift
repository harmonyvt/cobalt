import Foundation
#if canImport(MetricKit)
import MetricKit

/// MetricKit's daily metric payload, flattened to the few numbers worth a chart: how smooth scrolling was, how slow
/// launches and hangs were, how much CPU, GPU and memory the app used. Averages of histograms use each bucket's middle.
enum MetricSummary {
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
        }
        if let gpu = p.gpuMetrics {
            out["gpu_s"] = .double(round1(gpu.cumulativeGPUTime.converted(to: .seconds).value))
        }
        if let memory = p.memoryMetrics {
            out["peak_mb"] = .int(Int(memory.peakMemoryUsage.converted(to: .megabytes).value.rounded()))
        }
        if let time = p.applicationTimeMetrics {
            out["foreground_s"] = .int(Int(time.cumulativeForegroundTime.converted(to: .seconds).value.rounded()))
        }
        return out
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
