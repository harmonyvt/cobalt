import Foundation

// The editor's routes (APP-API-CONTRACT 31.12; `features.editor`; keyed). Every route answers `cache-control: no-store` and
// refuses with `EditError`. Its own file so `HTTPCobaltClient.swift` only grows the capability flag and the three limits.

extension HTTPCobaltClient: EditorClient {
    public func editProjects() async throws -> [EditProject] {
        let req = try editRequest("GET", "/edits", timeout: 20)
        struct Wire: Decodable { var projects: [Lossy<EditProject>] }
        let (data, http) = try await editSend(req)
        return try editAnswer(Wire.self, data, http).projects.compactMap(\.value)
    }

    public func createEditProject(title: String?, timeline: EditTimeline) async throws -> EditProject {
        let req = try editRequest("POST", "/edits", timeout: 30)
        let body = try Self.editBody(CreateBody(title: title, timeline: EditJSON.rounded(timeline)))
        let (data, http) = try await editSend(req, body: body)
        struct Wire: Decodable { var project: EditProject }
        return try editAnswer(Wire.self, data, http).project
    }

    public func editProject(id: String) async throws -> (EditProject, [String: EditSource]) {
        let req = try editRequest("GET", "/edits/\(Self.encode(id))", timeout: 20)
        let (data, http) = try await editSend(req)
        struct Wire: Decodable {
            var project: EditProject
            var sources: [String: Lossy<EditSource>]?
        }
        let wire = try editAnswer(Wire.self, data, http)
        var sources: [String: EditSource] = [:]
        for (_, entry) in wire.sources ?? [:] {
            if let source = entry.value { sources[source.id] = source }       // keyed by the file's own id, never by the JSON key
        }
        return (wire.project, sources)
    }

    public func saveEditProject(id: String, timeline: EditTimeline, baseRevision: Int, title: String?) async throws -> EditProject {
        let req = try editRequest("PUT", "/edits/\(Self.encode(id))", timeout: 30)
        let body = try Self.editBody(SaveBody(timeline: EditJSON.rounded(timeline), baseRevision: baseRevision, title: title))
        let (data, http) = try await editSend(req, body: body)
        struct Wire: Decodable { var project: EditProject }
        return try editAnswer(Wire.self, data, http).project
    }

    public func renameEditProject(id: String, title: String) async throws -> EditProject {
        let req = try editRequest("PATCH", "/edits/\(Self.encode(id))", timeout: 20)
        let (data, http) = try await editSend(req, body: try Self.editBody(RenameBody(title: title)))
        struct Wire: Decodable { var project: EditProject }
        return try editAnswer(Wire.self, data, http).project
    }

    public func deleteEditProject(id: String) async throws {
        let req = try editRequest("DELETE", "/edits/\(Self.encode(id))", timeout: 20)
        let (data, http) = try await editSend(req)
        guard (200..<300).contains(http.statusCode) else { throw editError(data, status: http.statusCode) }
    }

    public func renderEdit(id: String, revision: Int, notify: Bool) async throws -> EditRender {
        let req = try editRequest("POST", "/edits/\(Self.encode(id))/render", timeout: 45)
        let body = try Self.editBody(RenderBody(revision: revision, notify: notify ? true : nil))
        let (data, http) = try await editSend(req, body: body)
        struct Wire: Decodable { var render: EditRender }
        return try editAnswer(Wire.self, data, http).render
    }

    public func editRenders(limit: Int) async throws -> [EditRender] {
        let req = try editRequest("GET", "/edits/renders", query: [("limit", String(min(50, max(1, limit))))], timeout: 20)
        let (data, http) = try await editSend(req)
        struct Wire: Decodable { var renders: [Lossy<EditRender>] }
        return try editAnswer(Wire.self, data, http).renders.compactMap(\.value)
    }

    public func editRender(id: String) async throws -> EditRender {
        let req = try editRequest("GET", "/edits/renders/\(Self.encode(id))", timeout: 20)
        let (data, http) = try await editSend(req)
        struct Wire: Decodable { var render: EditRender }
        return try editAnswer(Wire.self, data, http).render
    }

    public func cancelEditRender(id: String) async throws -> EditRender {
        let req = try editRequest("DELETE", "/edits/renders/\(Self.encode(id))", timeout: 20)
        let (data, http) = try await editSend(req)
        struct Wire: Decodable { var render: EditRender }
        return try editAnswer(Wire.self, data, http).render
    }

    public func putEditLiveToken(renderID: String, token: String, environment: LiveEnvironment) async throws -> Bool {
        let req = try editRequest("PUT", "/live/edits/\(Self.encode(renderID))", timeout: 15)
        let (data, http) = try await editSend(req, body: try Self.editBody(LiveTokenBody(token: token, env: environment.rawValue)))
        struct Wire: Decodable { var pushing: Bool? }
        return try editAnswer(Wire.self, data, http).pushing ?? false
    }

    public func deleteEditLiveToken(renderID: String) async throws {
        let req = try editRequest("DELETE", "/live/edits/\(Self.encode(renderID))", timeout: 15)
        let (data, http) = try await editSend(req)
        guard (200..<300).contains(http.statusCode) else { throw editError(data, status: http.statusCode) }
    }

    // MARK: bodies

    private struct LiveTokenBody: Encodable {
        var token: String
        var env: String
    }

    private struct CreateBody: Encodable {
        var title: String?
        var timeline: EditTimeline
    }

    private struct SaveBody: Encodable {
        var timeline: EditTimeline
        var baseRevision: Int
        var title: String?
        private enum CodingKeys: String, CodingKey { case timeline, baseRevision = "base_revision", title }
    }

    private struct RenameBody: Encodable { var title: String }

    private struct RenderBody: Encodable {
        var revision: Int
        var notify: Bool?
    }

    /// Canonical, like the timeline inside it: keys sorted, no whitespace, nil fields left out.
    private static func editBody<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        do { return try encoder.encode(value) } catch { throw EditError.other("encode") }
    }

    // MARK: plumbing

    private func editRequest(_ method: String, _ path: String, query: [(String, String)] = [], timeout: TimeInterval) throws -> URLRequest {
        do { return try makeRequest(method, path, query: query, keyed: true, timeout: timeout) } catch { throw EditError.from(error) }
    }

    private func editSend(_ req: URLRequest, body: Data? = nil) async throws -> (Data, HTTPURLResponse) {
        do { return try await send(req, body: body) } catch { throw EditError.from(error) }
    }

    /// A 2xx whose body decodes as `T`; a refusal as `EditError`; an unreadable answer as `.other`.
    private func editAnswer<T: Decodable>(_ type: T.Type, _ data: Data, _ http: HTTPURLResponse) throws -> T {
        guard (200..<300).contains(http.statusCode) else { throw editError(data, status: http.statusCode) }
        guard let wire = try? CobaltJSON.decoder().decode(T.self, from: data) else {
            throw EditError.other("invalid response")
        }
        return wire
    }

    /// `{"status":"error","error":{"code"},"path"?,"items"?,"project"?}` as an `EditError`.
    private func editError(_ data: Data, status: Int) -> EditError {
        struct Body: Decodable {
            struct Err: Decodable { var code: String? }
            var error: Err?
            var path: String?
            var items: [String]?
            var project: Lossy<EditProject>?
        }
        guard let body = try? CobaltJSON.decoder().decode(Body.self, from: data), let code = body.error?.code else {
            return status == 503 ? .unavailable : .other("http \(status)")
        }
        let mapped = EditError(code: code, path: body.path, items: body.items ?? [], project: body.project?.value)
        if case .other = mapped, status == 503 { return .unavailable }
        return mapped
    }
}
