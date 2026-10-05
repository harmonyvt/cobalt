import Foundation

// Sends the buffer to the owner's server. The app only: the share extension and the widgets just write.

/// What a `POST /telemetry` answered.
public struct TelemetryHTTPResponse: Sendable, Equatable {
    public var status: Int
    public var errorCode: String?
    public var retryAfter: TimeInterval?

    public init(status: Int, errorCode: String? = nil, retryAfter: TimeInterval? = nil) {
        self.status = status
        self.errorCode = errorCode
        self.retryAfter = retryAfter
    }
}

public protocol TelemetryTransport: Sendable {
    /// Sends one request body. Throws only when there was no HTTP answer (the network).
    func send(_ body: Data) async throws -> TelemetryHTTPResponse
}

/// `POST <server>/telemetry` with the client key (`Authorization: Api-Key <key>`), JSON in, JSON out.
public struct HTTPTelemetryTransport: TelemetryTransport {
    let endpoint: URL
    let apiKey: String
    let session: URLSession

    public init(baseURL: URL, apiKey: String, session: URLSession = .shared) {
        var comps = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)
        let base = (comps?.path ?? "").hasSuffix("/") ? String((comps?.path ?? "").dropLast()) : (comps?.path ?? "")
        comps?.percentEncodedPath = base + "/telemetry"
        self.endpoint = comps?.url ?? baseURL.appendingPathComponent("telemetry")
        self.apiKey = apiKey
        self.session = session
    }

    public func send(_ body: Data) async throws -> TelemetryHTTPResponse {
        var request = URLRequest(url: endpoint, timeoutInterval: 20)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Api-Key \(apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = body
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { return TelemetryHTTPResponse(status: 0) }
        struct Envelope: Decodable { struct E: Decodable { var code: String? }; var error: E? }
        let code = (try? JSONDecoder().decode(Envelope.self, from: data))?.error?.code
        let retry = http.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init)
        return TelemetryHTTPResponse(status: http.statusCode, errorCode: code, retryAfter: retry)
    }
}

/// Whether, and where, an upload may go right now. Decided by the app at the moment of the upload.
public enum TelemetryGate: Sendable {
    /// `secrets` (the API key) are scrubbed from whatever goes out.
    case allowed(transport: any TelemetryTransport, secrets: [String])
    case disabled        // the owner turned "send crash reports and logs" off
    case unsupported     // the server does not advertise `features.telemetry`
    case noKey           // no API key for this server
}

public struct TelemetrySendResult: Sendable, Equatable {
    public enum Outcome: Sendable, Equatable {
        case done
        case nothingToSend
        case disabled, unsupported, noKey
        case backingOff(until: Date)
        /// An HTTP error code from the server (`error.telemetry.rate_limited`, …) or `network`.
        case failed(code: String)
    }
    public var outcome: Outcome
    public var events: Int
    public var crashes: Int

    public init(_ outcome: Outcome, events: Int = 0, crashes: Int = 0) {
        self.outcome = outcome
        self.events = events
        self.crashes = crashes
    }
}

/// What the uploader remembers between runs.
struct TelemetryUploadState: Codable, Equatable, Sendable {
    /// Ids of buffered events already accepted. Pruned to the ones still in the buffer.
    var sent: [String] = []
    var failures = 0
    /// Unix seconds; no attempt before this (a manual "send now" ignores it).
    var nextAttempt: Double = 0
}

/// Batches pending crashes and buffered events and posts them. Keeps what was not accepted, marks what
/// was, backs off exponentially after a failure.
actor TelemetryUploader {
    static let backoffBase: Double = 30
    static let backoffCap: Double = 3_600
    /// Smallest request body a 413 shrinks the budget to.
    static let minimumBudget = 8_000

    private let log: TelemetryLog
    private let crashes: CrashStore
    private let stateURL: URL
    private let app: @Sendable () -> TelemetryAppInfo
    private let install: @Sendable () -> String
    private let gate: @Sendable () async -> TelemetryGate
    private let now: @Sendable () -> Date
    private var state: TelemetryUploadState
    private var running: Task<TelemetrySendResult, Never>?

    init(
        log: TelemetryLog, crashes: CrashStore, stateURL: URL,
        app: @escaping @Sendable () -> TelemetryAppInfo,
        install: @escaping @Sendable () -> String,
        gate: @escaping @Sendable () async -> TelemetryGate,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.log = log
        self.crashes = crashes
        self.stateURL = stateURL
        self.app = app
        self.install = install
        self.gate = gate
        self.now = now
        self.state = (try? Data(contentsOf: stateURL)).flatMap { try? JSONDecoder().decode(TelemetryUploadState.self, from: $0) } ?? TelemetryUploadState()
    }

    /// Events and crashes not yet accepted.
    func pendingCounts() -> (events: Int, crashes: Int) {
        let sent = Set(state.sent)
        return (log.readAll().filter { !sent.contains($0.i) }.count, crashes.count)
    }

    /// One pass over everything pending. Calls made while one is running join it. `force` (the owner's
    /// "send logs now") ignores the backoff, never the gate.
    func upload(force: Bool = false) async -> TelemetrySendResult {
        if let running { return await running.value }
        let task = Task { await self.run(force: force) }
        running = task
        let result = await task.value
        running = nil
        return result
    }

    private func run(force: Bool) async -> TelemetrySendResult {
        let transport: any TelemetryTransport
        let secrets: [String]
        switch await gate() {
        case .disabled: return TelemetrySendResult(.disabled)
        case .unsupported: return TelemetrySendResult(.unsupported)
        case .noKey: return TelemetrySendResult(.noKey)
        case .allowed(let t, let s): transport = t; secrets = s
        }
        let current = now()
        if !force, current.timeIntervalSince1970 < state.nextAttempt {
            return TelemetrySendResult(.backingOff(until: Date(timeIntervalSince1970: state.nextAttempt)))
        }

        let allEvents = log.readAll()
        let present = Set(allEvents.map(\.i))
        state.sent = state.sent.filter(present.contains)               // forget ids the ring buffer dropped
        var sentIDs = Set(state.sent)
        var events = allEvents.filter { !sentIDs.contains($0.i) }
        var crashList = crashes.pending()
        if events.isEmpty, crashList.isEmpty { return TelemetrySendResult(.nothingToSend) }

        let info = app()
        let installID = install()
        var limits = TelemetryBatcher.Limits()
        var sentEvents = 0, sentCrashes = 0
        var guardrail = 0                                              // bounds the 413 shrinking loop

        while let batch = TelemetryBatcher.next(events: events, crashes: crashList, limits: limits) {
            guard let body = try? TelemetryBody.encode(batch: batch, app: info, install: installID, secrets: secrets) else {
                // cannot even be encoded: it can never be sent
                TelemetryBatcher.consume(batch, events: &events, crashes: &crashList)
                retire(batch, sentIDs: &sentIDs)
                continue
            }
            let response: TelemetryHTTPResponse
            do {
                response = try await transport.send(body)
            } catch {
                persist(sentIDs)
                return fail(code: "network", counts: (sentEvents, sentCrashes), retryAfter: nil)
            }
            switch response.status {
            case 200..<300:
                retire(batch, sentIDs: &sentIDs)
                TelemetryBatcher.consume(batch, events: &events, crashes: &crashList)
                sentEvents += batch.events.count
                sentCrashes += batch.crashes.count
                state.failures = 0
                state.nextAttempt = 0
                persist(sentIDs)
            case 413:
                // too big for this server: shrink the budget and form the batch again; a single record
                // that is still too big loses its payload, then goes
                guardrail += 1
                if limits.bodyBytes > Self.minimumBudget, guardrail <= 8 {
                    limits.bodyBytes = max(Self.minimumBudget, limits.bodyBytes / 2)
                } else if let crash = batch.crashes.first, crash.payload != nil {
                    crashes.dropPayload(of: crash.record.id)
                    if let i = crashList.firstIndex(where: { $0.record.id == crash.record.id }) { crashList[i].payload = nil }
                } else {
                    TelemetryBatcher.consume(batch, events: &events, crashes: &crashList)
                    retire(batch, sentIDs: &sentIDs)
                    persist(sentIDs)
                }
            case 400:
                // the server will never take this one: keeping it would wedge everything behind it
                TelemetryBatcher.consume(batch, events: &events, crashes: &crashList)
                retire(batch, sentIDs: &sentIDs)
                persist(sentIDs)
                log.log(.warn, .net, "telemetry batch rejected", data: [
                    "status": .int(400), "events": .int(batch.events.count), "crashes": .int(batch.crashes.count),
                    "code": .string(response.errorCode ?? ""),
                ])
            default:
                persist(sentIDs)
                return fail(
                    code: response.errorCode ?? "http.\(response.status)", counts: (sentEvents, sentCrashes),
                    retryAfter: response.retryAfter)
            }
        }
        persist(sentIDs)
        return TelemetrySendResult(.done, events: sentEvents, crashes: sentCrashes)
    }

    /// An accepted batch is done with; a refused one is dropped (never to be retried) the same way.
    private func retire(_ batch: TelemetryBatch, sentIDs: inout Set<String>) {
        for e in batch.events { sentIDs.insert(e.i) }
        crashes.remove(batch.crashes.map(\.record.id))
    }

    private func persist(_ sentIDs: Set<String>) {
        state.sent = Array(sentIDs)
        if let data = try? JSONEncoder().encode(state) { try? data.write(to: stateURL, options: .atomic) }
    }

    private func fail(code: String, counts: (Int, Int), retryAfter: TimeInterval?) -> TelemetrySendResult {
        state.failures += 1
        let wait = retryAfter ?? min(Self.backoffCap, Self.backoffBase * pow(2, Double(state.failures - 1)))
        state.nextAttempt = now().timeIntervalSince1970 + wait
        log.log(.warn, .net, "telemetry upload failed", data: ["code": .string(code), "failures": .int(state.failures), "retryIn": .int(Int(wait))])
        if let data = try? JSONEncoder().encode(state) { try? data.write(to: stateURL, options: .atomic) }
        return TelemetrySendResult(.failed(code: code), events: counts.0, crashes: counts.1)
    }

    /// Seconds to wait after `failures` failures in a row.
    static func backoff(afterFailures failures: Int) -> Double {
        min(backoffCap, backoffBase * pow(2, Double(max(0, failures - 1))))
    }
}
