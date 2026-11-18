import Foundation

// AI video background removal (APP-API-CONTRACT 67). Bria, $0.0225 a second, 60 seconds at most.
// `GET` quotes, `POST` starts a job, `GET …/:job` polls the same pending / success / error shape as a studio render.
// The result is a private ProRes alternate (`role = alt`, `made_spec.kind = "rmbg"`). The server updates a Live Activity
// that was already registered for the session; this client polls and the editor shows the same progress on its card.

public struct RmbgQuote: Sendable, Equatable {
    public var seconds: Double
    public var estimateUSD: Double
    public var maxSeconds: Double
    public var tooLong: Bool
    /// $0.0225, from the quote when the server sends it, otherwise the price section 67 names.
    public var usdPerSecond: Double

    public init(seconds: Double, estimateUSD: Double, maxSeconds: Double, tooLong: Bool, usdPerSecond: Double = 0.0225) {
        self.seconds = seconds
        self.estimateUSD = estimateUSD
        self.maxSeconds = maxSeconds
        self.tooLong = tooLong
        self.usdPerSecond = usdPerSecond
    }

    public static let pricePerSecond = 0.0225
    public static let maxSecondsLimit = 60.0
}

public struct RmbgJob: Sendable, Equatable {
    public enum State: String, Sendable { case pending, success, error }
    public var id: String
    public var state: State
    public var itemID: String?
    public var seconds: Double?
    public var estimateUSD: Double?
    public var phase: String?
    public var errorCode: String?

    public init(
        id: String, state: State, itemID: String? = nil, seconds: Double? = nil, estimateUSD: Double? = nil,
        phase: String? = nil, errorCode: String? = nil
    ) {
        self.id = id
        self.state = state
        self.itemID = itemID
        self.seconds = seconds
        self.estimateUSD = estimateUSD
        self.phase = phase
        self.errorCode = errorCode
    }
}

public enum RmbgError: Error, Equatable, Sendable {
    case notFound, notVideo, tooLong, unknownDuration, off, failed, offline, badRequest
    case other(String)

    init(code: String, status: Int) {
        switch code {
        case "error.rmbg.not_found": self = .notFound
        case "error.rmbg.not_video": self = .notVideo
        case "error.rmbg.too_long": self = .tooLong
        case "error.rmbg.unknown_duration": self = .unknownDuration
        case "error.rmbg.off": self = .off
        case "error.rmbg.bad_request": self = .badRequest
        case "error.rmbg.failed", "error.rmbg.storage": self = .failed
        default: self = status == 0 ? .offline : .other(code)
        }
    }
}

public protocol RmbgClient: Sendable {
    func rmbgQuote(of id: String) async throws -> RmbgQuote
    func rmbgStart(of id: String, spill: Double) async throws -> RmbgJob
    func rmbgStatus(of id: String, job: String) async throws -> RmbgJob
}

extension HTTPCobaltClient: RmbgClient {
    public func rmbgQuote(of id: String) async throws -> RmbgQuote {
        let req = try rmbgRequest("GET", "/library/items/\(Self.encode(id))/rmbg")
        return try await rmbgSend(req, body: nil, as: QuoteWire.self).quote
    }

    public func rmbgStart(of id: String, spill: Double) async throws -> RmbgJob {
        let req = try rmbgRequest("POST", "/library/items/\(Self.encode(id))/rmbg", timeout: 60)
        let body = try JSONSerialization.data(withJSONObject: ["spill": min(1, max(0, spill))])
        return try await rmbgSend(req, body: body, as: JobWire.self, accept: 200..<300).job
    }

    public func rmbgStatus(of id: String, job: String) async throws -> RmbgJob {
        let req = try rmbgRequest("GET", "/library/items/\(Self.encode(id))/rmbg/\(Self.encode(job))", timeout: 40)
        return try await rmbgSend(req, body: nil, as: JobWire.self).job
    }

    private func rmbgRequest(_ method: String, _ path: String, timeout: TimeInterval = 30) throws -> URLRequest {
        do { return try makeRequest(method, path, keyed: true, timeout: timeout) }
        catch { throw RmbgError.other("request") }
    }

    private func rmbgSend<W: Decodable & RmbgWire>(
        _ request: URLRequest, body: Data?, as: W.Type, accept: Range<Int> = 200..<300
    ) async throws -> W {
        let answer: (Data, HTTPURLResponse)
        do { answer = try await send(request, body: body) }
        catch let e as CobaltError {
            if case .network = e { throw RmbgError.offline }
            throw RmbgError.other("network")
        }
        let (data, http) = answer
        // 202 is the start. `send` does not treat it as a failure; we accept it here.
        let ok = accept.contains(http.statusCode) || http.statusCode == 202
        guard ok else {
            struct Err: Decodable { struct E: Decodable { var code: String? }; var error: E? }
            let code = (try? JSONDecoder().decode(Err.self, from: data))?.error?.code ?? "http \(http.statusCode)"
            throw RmbgError(code: code, status: http.statusCode)
        }
        guard let wire = try? JSONDecoder().decode(W.self, from: data) else { throw RmbgError.other("invalid response") }
        return wire
    }
}

extension PreviewClient: RmbgClient {
    public func rmbgQuote(of id: String) async throws -> RmbgQuote {
        editorState.record("GET /library/items/\(id)/rmbg")
        return RmbgQuote(seconds: 4, estimateUSD: 0.09, maxSeconds: 60, tooLong: false)
    }

    public func rmbgStart(of id: String, spill: Double) async throws -> RmbgJob {
        editorState.record("POST /library/items/\(id)/rmbg")
        return RmbgJob(id: "rmbgpreviewjob000000", state: .pending, seconds: 4, estimateUSD: 0.09, phase: "queued")
    }

    public func rmbgStatus(of id: String, job: String) async throws -> RmbgJob {
        editorState.record("GET /library/items/\(id)/rmbg/\(job)")
        return RmbgJob(id: job, state: .success, itemID: id, seconds: 4, estimateUSD: 0.09)
    }
}

private protocol RmbgWire: Decodable {}

private struct QuoteWire: RmbgWire {
    var seconds: Double
    var estimateUSD: Double
    var maxSeconds: Double
    var tooLong: Bool
    var usdPerSecond: Double?

    var quote: RmbgQuote {
        RmbgQuote(
            seconds: seconds, estimateUSD: estimateUSD, maxSeconds: maxSeconds, tooLong: tooLong,
            usdPerSecond: usdPerSecond ?? RmbgQuote.pricePerSecond)
    }

    enum CodingKeys: String, CodingKey {
        case seconds
        case estimateUSD = "estimate_usd"
        case maxSeconds = "max_seconds"
        case tooLong = "too_long"
        case usdPerSecond = "usd_per_second"
    }
}

private struct JobWire: RmbgWire {
    var status: String
    var id: String
    var itemID: String?
    var seconds: Double?
    var estimateUSD: Double?
    var phase: String?
    var error: Err?

    struct Err: Decodable { var code: String? }

    var job: RmbgJob {
        let state: RmbgJob.State = status == "success" ? .success : status == "error" ? .error : .pending
        return RmbgJob(
            id: id, state: state, itemID: itemID, seconds: seconds, estimateUSD: estimateUSD, phase: phase,
            errorCode: error?.code)
    }

    enum CodingKeys: String, CodingKey {
        case status, id, seconds, phase, error
        case itemID = "item_id"
        case estimateUSD = "estimate_usd"
    }
}
