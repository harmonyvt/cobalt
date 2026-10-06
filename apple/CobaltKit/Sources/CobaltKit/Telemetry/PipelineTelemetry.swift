import Foundation
#if os(iOS)
import os
#endif

// What the pipeline and its neighbours say to the log. All the logic is here so the call sites in
// `Pipeline`, `PipelineFlows` and the rest stay one line each.

extension PipelineState {
    var telemetryName: String {
        switch self {
        case .idle: return "idle"
        case .fetching: return "fetching"
        case .uploading: return "uploading"
        case .saving: return "saving"
        case .reading: return "reading"
        case .picker: return "picker"
        case .image: return "image"
        case .ready: return "ready"
        case .rendering: return "rendering"
        case .done: return "done"
        case .savedLocally: return "savedLocally"
        case .failed: return "failed"
        }
    }
}

extension PipelineFailure {
    /// The failure as a code: the server's own where there is one, else the case name.
    var telemetryCode: String {
        switch self {
        case .noLink: return "noLink"
        case .tooLarge: return "tooLarge"
        case .fetchFailed(let code): return code
        case .unsupported: return "unsupported"
        case .serverBusy: return "serverBusy"
        case .renderBusy: return "renderBusy"
        case .renderLost: return "renderLost"
        case .expired: return "expired"
        case .keyMissing: return "keyMissing"
        case .keyInvalid: return "keyInvalid"
        case .unreachable: return "unreachable"
        case .server(let code): return code
        }
    }
}

extension Telemetry {
    /// What an error is, for the log: its type and codes, never its description (descriptions can carry
    /// anything the system felt like putting in them).
    public static func errorData(_ error: any Error) -> [String: TelemetryValue] {
        switch error {
        case let e as CobaltError:
            switch e {
            case .api(let code, let status): return ["error": "CobaltError.api", "code": .string(code), "http": .int(status)]
            case .network(let code): return ["error": "CobaltError.network", "urlError": .int(code.rawValue)]
            case .invalidResponse(let status): return ["error": "CobaltError.invalidResponse", "http": .int(status)]
            case .noAPIKey: return ["error": "CobaltError.noAPIKey"]
            case .tooLarge(let limit): return ["error": "CobaltError.tooLarge", "limit": .bytes(limit)]
            case .cancelled: return ["error": "CobaltError.cancelled"]
            }
        case let e as PipelineFailure:
            return ["error": "PipelineFailure", "code": .string(e.telemetryCode)]
        case let e as URLError:
            return ["error": "URLError", "urlError": .int(e.code.rawValue)]
        default:
            let ns = error as NSError
            return ["error": .string(String(describing: type(of: error))), "domain": .string(ns.domain), "code": .int(ns.code)]
        }
    }

    // MARK: Parallel work (CONTRACT-PARALLEL.md section 8). Category `pipeline` (the server accepts no new one); ids and
    // counts only: no links, titles or file names.

    /// `paste` {via, links, kept, duplicates, concurrent, line}: one paste or drop of links, once the owner has seen
    /// what was found (`links` = found, `kept` = sent on, `duplicates` = left out because they were already saved or
    /// running). The paste code (`AppShell`, the review sheet) calls it; `JobQueue.add` logs the jobs themselves.
    public static func logPaste(via: JobVia, links: Int, kept: Int, duplicates: Int, concurrent: Int, line: LineMode) {
        log(.info, .pipeline, "paste", data: [
            "via": .string(via.rawValue), "links": .int(links), "kept": .int(kept), "duplicates": .int(duplicates),
            "concurrent": .int(concurrent), "line": .string(line == .server ? "server" : "device"),
        ])
    }

    /// `live summary` {jobs, waiting, concurrent, line}: the one Live Activity of a busy period began, or its counts
    /// changed. (`jobs` and `waiting` are what the activity says; `concurrent` is the queue's live count.)
    static func logLiveSummary(jobs: Int, waiting: Int, line: LineMode) {
        log(.info, .pipeline, "live summary", data: [
            "jobs": .int(jobs), "waiting": .int(waiting), "concurrent": .int(jobs),
            "line": .string(line == .server ? "server" : "device"),
        ])
    }

    /// How much memory the process may still use (iOS: the share extension has about 120 MB in all).
    /// Empty on the Mac.
    public static func memoryData() -> [String: TelemetryValue] {
        #if os(iOS)
        return ["availableMB": .int(Int(os_proc_available_memory() / 1_048_576))]
        #else
        return [:]
        #endif
    }

    /// A file's size in bytes, 0 when it cannot be read.
    public static func fileSize(_ url: URL) -> TelemetryValue {
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0
        return .bytes(size)
    }

    /// `host/path-extension` of a link, for the log: the link itself is fine to send (the owner's own
    /// server) but a short form reads better.
    public static func linkSummary(_ url: URL) -> String {
        url.host(percentEncoded: false) ?? url.absoluteString
    }
}

extension Pipeline {
    private var telemetryRun: String { String(liveRunID.uuidString.prefix(8)).lowercased() }

    /// Called by `setState` just before the state changes: state transitions, upload and save milestones
    /// (every quarter), and a failure with its code. Progress ticks inside one state say nothing.
    func logTransition(to new: PipelineState) {
        var data: [String: TelemetryValue] = ["run": .string(telemetryRun)]
        if let sid = sessionID { data["session"] = .string(String(sid.prefix(8))) }
        switch (state, new) {
        case (.uploading(let old), .uploading(let now)):
            guard Self.crossedQuarter(old, now) else { return }
            data["bytes"] = .bytes(now.bytes)
            if let total = now.total { data["total"] = .bytes(total) }
            Telemetry.log(.info, .upload, "upload progress", data: data)
            return
        case (.saving(let oldBytes, let total, _), .saving(let newBytes, _, _)):
            guard let oldBytes, let newBytes, let total, total > 0,
                  Self.crossedQuarter(TransferProgress(bytes: oldBytes, total: total), TransferProgress(bytes: newBytes, total: total))
            else { return }
            data["bytes"] = .bytes(newBytes)
            data["total"] = .bytes(total)
            Telemetry.log(.info, .pipeline, "save progress", data: data)
            return
        case (.fetching(let since, false), .fetching(let sinceNew, true)) where since == sinceNew:
            data["waking"] = true
            Telemetry.log(.info, .pipeline, "server waking", data: data)
            return
        default:
            break
        }
        guard state.telemetryName != new.telemetryName else { return }
        data["from"] = .string(state.telemetryName)
        var level = TelemetryLevel.info
        var cat = TelemetryCategory.pipeline
        switch new {
        case .uploading(let p):
            cat = .upload
            if let total = p.total { data["total"] = .bytes(total) }
        case .saving(let bytes, let total, _):
            if let bytes { data["bytes"] = .bytes(bytes) }
            if let total { data["total"] = .bytes(total) }
        case .picker(let items): data["items"] = .int(items.count)
        case .image(let m): data["width"] = .int(m.width ?? 0); data["height"] = .int(m.height ?? 0)
        case .done(let r):
            data["bytes"] = .bytes(r.bytes)
            data["seconds"] = .double(r.seconds)
        case .failed(let f):
            level = .error
            data["code"] = .string(f.telemetryCode)
        default: break
        }
        if let m = media, !m.isImage, let d = m.duration { data["duration"] = .double((d * 10).rounded() / 10) }
        Telemetry.log(level, cat, "state \(new.telemetryName)", data: data)
    }

    /// Called by `handle(_:)` with what a step threw and the failure it became: the underlying error,
    /// which the failure alone no longer says.
    func logPipelineError(_ error: any Error, failure: PipelineFailure) {
        var data = Telemetry.errorData(error)
        data["failure"] = .string(failure.telemetryCode)
        data["state"] = .string(state.telemetryName)
        data["run"] = .string(telemetryRun)
        var cat = TelemetryCategory.pipeline
        if case .uploading = state { cat = .upload }
        Telemetry.log(.error, cat, "step failed", data: data)
    }

    private static func crossedQuarter(_ old: TransferProgress, _ new: TransferProgress) -> Bool {
        guard let total = new.total, total > 0 else { return false }
        func quarter(_ p: TransferProgress) -> Int { Int(min(4, (Double(p.bytes) / Double(total) * 4).rounded(.down))) }
        return quarter(new) > quarter(old)
    }
}
