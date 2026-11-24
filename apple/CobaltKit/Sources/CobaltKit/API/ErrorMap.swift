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

/// The two codes of `POST /` for a link cobalt cannot read at all.
func isUnreadableLinkCode(_ code: String) -> Bool {
    code == "error.api.link.invalid" || code == "error.api.link.unsupported"
}

/// What a failed fetch says about the post, from the sites' error codes (apple 02-PHASE2 2.2.3). The table is the extension's
/// (`extension/src/lib/progress.ts`) plus the content and YouTube codes the server passes through; `Copy` words each one, so no
/// raw `error.api.*` string ever reaches a card.
public enum FetchProblem: Sendable, Equatable {
    /// No video in the post (`error.api.fetch.empty`, `error.webp.no_video`).
    case empty
    /// Removed, or not there (`error.api.content.video.unavailable`, `…post.unavailable`).
    case unavailable
    /// Private (`error.api.content.video.private`, `…post.private`).
    case isPrivate
    /// Needs a sign-in for an age limit (`error.api.content.video.age`, `…post.age`).
    case ageRestricted
    /// YouTube asked for a sign-in (`error.api.youtube.login`).
    case loginRequired
    /// Not available where the server is (`error.api.content.video.region`).
    case region
    /// A live stream, which cannot be saved (`error.api.content.video.live`).
    case live
    /// Longer than the server takes (`error.api.content.too_long`).
    case tooLong
    /// The site is limiting the server (`error.api.fetch.rate`, `error.api.rate_exceeded`).
    case rateLimited
    /// The download failed, for a reason the site did not say (`error.api.fetch.fail` and the rest).
    case failed

    public init(code: String) {
        switch code {
        case "error.api.fetch.empty", "error.webp.no_video": self = .empty
        case "error.api.youtube.login": self = .loginRequired
        case "error.api.fetch.rate", "error.api.rate_exceeded", "error.api.rate_limit": self = .rateLimited
        case "error.api.content.too_long": self = .tooLong
        case "error.api.content.video.live": self = .live
        case "error.api.content.video.region": self = .region
        case "error.api.content.video.unavailable", "error.api.content.post.unavailable": self = .unavailable
        default:
            if code.hasSuffix(".private") { self = .isPrivate }
            else if code.hasSuffix(".age") { self = .ageRestricted }
            else { self = .failed }
        }
    }

    /// Asking again cannot cure it: the post, the site or the account is what is in the way. (A rate limit and a plain
    /// failure pass; a download that failed once may work the next time.)
    public var retryHelps: Bool {
        switch self {
        case .rateLimited, .failed: return true
        default: return false
        }
    }
}

extension PipelineFailure {
    /// What the fetch failure says about the post; nil for every other failure.
    public var fetchProblem: FetchProblem? {
        if case .fetchFailed(let code) = self { return FetchProblem(code: code) }
        return nil
    }

    /// The failure as one code, for a surface that lists failures by code (the share card's rows, a log line): the server's
    /// own where the failure carries one, else the code that maps to the case.
    public var code: String {
        switch self {
        case .noLink: return "error.app.no_link"
        case .tooLarge: return "error.studio.too_large"
        case .fetchFailed(let code), .linkUnreadable(let code), .server(let code): return code
        case .unsupported: return "error.webp.unsupported"
        case .serverBusy: return "error.studio.busy"
        case .renderBusy: return "error.webp.busy"
        case .renderLost: return "error.webp.job_lost"
        case .expired: return "error.studio.expired"
        case .keyMissing: return "error.api.auth.key.missing"
        case .keyInvalid: return "error.api.auth.key.invalid"
        case .unreachable: return "error.app.offline"
        }
    }

    /// "try again" can cure it. The input (a file too large, a link capystore does not read, a key) and a post the site
    /// refuses (private, age limit, a sign-in, removed, region) cannot be cured by asking again; every surface that offers
    /// "try again" asks this.
    public var isRetryable: Bool {
        switch self {
        case .noLink, .tooLarge, .unsupported, .linkUnreadable, .keyMissing, .keyInvalid: return false
        case .fetchFailed: return fetchProblem?.retryHelps ?? true
        default: return true
        }
    }
}

/// The codes of the server's own save failures that have a plain sentence of their own (`extension/src/lib/progress.ts`
/// `FRIENDLY`): the ones that do not map to a specific `PipelineFailure` case. `Copy` words them.
public enum ServerProblem: Sendable, Equatable {
    case saveLost, cancelled, notFound, uploadFailed, other

    public init(code: String) {
        switch code {
        case "error.studio.save_lost": self = .saveLost
        case "error.studio.cancelled": self = .cancelled
        case "error.studio.not_found": self = .notFound
        case "error.studio.upload_failed": self = .uploadFailed
        default: self = .other
        }
    }
}

/// Section 4.5 error code map: `error.*` → `PipelineFailure`.
func mapFailure(code: String, during phase: ErrorPhase, limits: Capabilities.Limits = .fork) -> PipelineFailure {
    // `link.invalid` (not a URL cobalt can use) and `link.unsupported` (a site it does not know) say nothing about the
    // post: they are their own failure. `fetch.*` and `content.*` are the sites' answers (empty, private, removed, age or
    // region locked, too long), the family the "private or removed" wording belongs to.
    if isUnreadableLinkCode(code) { return .linkUnreadable(code: code) }
    // `error.api.youtube.*` (a sign-in asked for, a token that ran out, no format) is YouTube's answer about the post, the same
    // family: it never falls through to a raw code.
    if code.hasPrefix("error.api.fetch.") || code.hasPrefix("error.api.content.") || code.hasPrefix("error.api.link.")
        || code.hasPrefix("error.api.youtube.") {
        return .fetchFailed(code: code)
    }
    switch code {
    case "error.api.rate_exceeded", "error.api.rate_limit":
        return .serverBusy
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
    case "error.studio.line_full":
        return .lineFull
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
