import Foundation
import Network
import Synchronization

/// A tiny HTTP/1.1 server on the loopback interface, for the tests that need real sockets:
/// redirects that must not be followed, upload and download progress, and AVFoundation reading
/// an extension-less URL with Range requests. One request per connection (`Connection: close`).
final class LoopbackServer: @unchecked Sendable {
    struct Request: Sendable {
        var method: String
        var target: String                       // path and query as sent
        var headers: [String: String]            // lower-cased names
        var body: Data
        var path: String { target.split(separator: "?", maxSplits: 1).first.map(String.init) ?? target }
        var query: String { target.split(separator: "?", maxSplits: 1).dropFirst().first.map(String.init) ?? "" }
    }

    struct Response: Sendable {
        var status: Int
        var headers: [String: String] = [:]
        var body: Data = Data()

        static func json(_ text: String, status: Int = 200) -> Response {
            Response(status: status, headers: ["content-type": "application/json"], body: Data(text.utf8))
        }
    }

    typealias Handler = @Sendable (Request) -> Response

    private let listener: NWListener
    private let queue = DispatchQueue(label: "cobaltkit.loopback")
    private let handler: Handler
    private let readDelay: Double
    private let seen = Mutex<[Request]>([])
    private(set) var port: UInt16 = 0

    var requests: [Request] { seen.withLock { $0 } }
    var base: URL { URL(string: "http://127.0.0.1:\(port)")! }

    private init(readDelay: Double, handler: @escaping Handler) throws {
        self.readDelay = readDelay
        self.handler = handler
        self.listener = try NWListener(using: .tcp, on: .any)
    }

    /// `readDelay` slows the reading of requests (seconds between reads), so an upload is paced by
    /// the socket buffers the way a slow network would pace it.
    static func start(readDelay: Double = 0, _ handler: @escaping Handler) async throws -> LoopbackServer {
        let server = try LoopbackServer(readDelay: readDelay, handler: handler)
        server.listener.newConnectionHandler = { [unowned server] connection in server.accept(connection) }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let once = Mutex(false)
            server.listener.stateUpdateHandler = { state in
                let first = once.withLock { done -> Bool in
                    if done { return false }
                    switch state {
                    case .ready, .failed: done = true; return true
                    default: return false
                    }
                }
                guard first else { return }
                switch state {
                case .ready: continuation.resume()
                case .failed(let error): continuation.resume(throwing: error)
                default: break
                }
            }
            server.listener.start(queue: server.queue)
        }
        server.port = server.listener.port?.rawValue ?? 0
        return server
    }

    func stop() { listener.cancel() }

    // MARK: connections

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        receive(connection, Inbound())
    }

    /// What has arrived on one connection: the head is parsed once, then only bytes are counted.
    private struct Inbound {
        var buffer = Data()
        var head: (method: String, target: String, headers: [String: String], bodyStart: Int)?
    }

    private func receive(_ connection: NWConnection, _ inbound: Inbound) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 256 << 10) { [self] data, _, isComplete, error in
            var inbound = inbound
            if let data { inbound.buffer.append(data) }
            if inbound.head == nil { inbound.head = Self.parseHead(inbound.buffer) }
            if let head = inbound.head {
                let length = Int(head.headers["content-length"] ?? "0") ?? 0
                if inbound.buffer.count - head.bodyStart >= length {
                    let body = inbound.buffer.subdata(in: head.bodyStart..<(head.bodyStart + length))
                    respond(connection, to: Request(method: head.method, target: head.target, headers: head.headers, body: body))
                    return
                }
            }
            if isComplete || error != nil {
                connection.cancel()
            } else if readDelay > 0 {
                let carried = inbound
                queue.asyncAfter(deadline: .now() + readDelay) { [self] in receive(connection, carried) }
            } else {
                receive(connection, inbound)
            }
        }
    }

    private static func parseHead(_ buffer: Data) -> (method: String, target: String, headers: [String: String], bodyStart: Int)? {
        guard let range = buffer.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let head = String(decoding: buffer[buffer.startIndex..<range.lowerBound], as: UTF8.self)
        let lines = head.components(separatedBy: "\r\n")
        let parts = (lines.first ?? "").split(separator: " ")
        guard parts.count >= 2 else { return nil }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        return (String(parts[0]), String(parts[1]), headers, range.upperBound)
    }

    private func respond(_ connection: NWConnection, to request: Request) {
        seen.withLock { $0.append(request) }
        var response = handler(request)
        let reason = HTTPURLResponse.localizedString(forStatusCode: response.status)
        var head = "HTTP/1.1 \(response.status) \(reason)\r\n"
        response.headers["content-length"] = String(response.body.count)
        response.headers["connection"] = "close"
        for (name, value) in response.headers { head += "\(name): \(value)\r\n" }
        head += "\r\n"
        var out = Data(head.utf8)
        if request.method != "HEAD" { out.append(response.body) }
        connection.send(content: out, completion: .contentProcessed { _ in connection.cancel() })
    }

    // MARK: range helper

    /// Serves `body` honouring a single `Range: bytes=a-b` header, like the Worker's `/source`.
    static func serve(_ body: Data, contentType: String, for request: Request) -> Response {
        var headers = ["content-type": contentType, "accept-ranges": "bytes"]
        guard let range = request.headers["range"], range.hasPrefix("bytes="),
              let dash = range.firstIndex(of: "-")
        else { return Response(status: 200, headers: headers, body: body) }
        let startText = range[range.index(range.startIndex, offsetBy: 6)..<dash]
        let endText = range[range.index(after: dash)...]
        var start = Int(startText) ?? 0
        var end = Int(endText) ?? (body.count - 1)
        if startText.isEmpty { start = max(0, body.count - (Int(endText) ?? 0)); end = body.count - 1 }
        end = min(end, body.count - 1)
        guard start <= end, start < body.count else {
            headers["content-range"] = "bytes */\(body.count)"
            return Response(status: 416, headers: headers)
        }
        headers["content-range"] = "bytes \(start)-\(end)/\(body.count)"
        return Response(status: 206, headers: headers, body: body.subdata(in: start..<(end + 1)))
    }
}
