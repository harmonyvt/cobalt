import Foundation

/// Where in the flow an error came up; a few codes mean different things in each.
enum ErrorPhase: Sendable { case saving, rendering }

/// A server error that did not map to anything specific. While rendering, the failure itself says so
/// (`PipelineFailure.renderPhasePrefix` on its code) so `keepsTrim` needs no side channel: a
/// failure while saving has no trim to keep.
func serverFailure(_ code: String, during phase: ErrorPhase) -> PipelineFailure {
    guard phase == .rendering, !code.hasPrefix(PipelineFailure.renderPhasePrefix) else { return .server(code: code) }
    return .server(code: PipelineFailure.renderPhasePrefix + code)
}

/// Section 4.5 error code map: `error.*` → `PipelineFailure`.
func mapFailure(code: String, during phase: ErrorPhase, limits: Capabilities.Limits = .fork) -> PipelineFailure {
    if code.hasPrefix("error.api.fetch.") || code.hasPrefix("error.api.content.") || code.hasPrefix("error.api.link.") {
        return .fetchFailed(code: code)
    }
    switch code {
    case "error.webp.no_video", "error.webp.bad_source", "error.webp.download_failed":
        return .fetchFailed(code: code)
    case "error.api.auth.key.missing":
        return .keyMissing
    case "error.api.auth.key.invalid", "error.api.auth.key.not_api_key", "error.api.auth.key.not_found":
        return .keyInvalid
    case "error.studio.busy", "error.library.busy":
        return .serverBusy
    case "error.webp.busy":
        return .renderBusy
    case "error.webp.job_lost", "error.studio.save_lost":
        return phase == .rendering ? .renderLost : .server(code: code)
    case "error.studio.expired":
        return .expired
    case "error.library.too_large":
        return .tooLarge(limit: limits.maxUploadBytes)
    case "error.studio.too_large", "error.webp.too_large":
        return .tooLarge(limit: limits.maxSourceBytes)
    case "error.webp.unsupported", "error.library.unsupported", "error.studio.not_video",
         "error.library.not_toggleable":
        return .unsupported
    default:
        return serverFailure(code, during: phase)
    }
}

/// Turns anything a pipeline step can throw into a `PipelineFailure`; nil means "cancelled, say nothing".
func pipelineFailure(from error: Error, during phase: ErrorPhase, limits: Capabilities.Limits = .fork) -> PipelineFailure? {
    switch error {
    case let f as PipelineFailure:
        return f
    case let e as CobaltError:
        switch e {
        case .api(let code, _): return mapFailure(code: code, during: phase, limits: limits)
        case .network(let code): return code == .cancelled ? nil : .unreachable
        case .invalidResponse(let status): return serverFailure("http.\(status)", during: phase)
        case .noAPIKey: return .keyMissing
        case .tooLarge(let limit): return .tooLarge(limit: limit)
        case .cancelled: return nil
        }
    case is CancellationError:
        return nil
    case let e as PhotosError:
        // Never "something went wrong (error.app.unknown)": the owner can act on a refused permission.
        switch e {
        case .denied: return .server(code: PipelineFailure.photosDeniedCode)
        case .unreadable: return .server(code: "error.app.no_original")
        case .failed: return .server(code: PipelineFailure.photosFailedCode)
        }
    case let e as URLError:
        return e.code == .cancelled ? nil : .unreachable
    default:
        return serverFailure("error.app.unknown", during: phase)
    }
}
