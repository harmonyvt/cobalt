import Foundation

/// The instant share's Live Activity (APP-API-CONTRACT 8.10): the extension closes in a moment, so it cannot register the
/// run itself (`ShareLiveRelay` needs the sheet to stay). Its `POST /studio` carries this as `live`, and the server
/// registers the new session's run and push-starts the activity, then ends it when the save is in the library.
/// The run id is the share's job id. Nil without a push environment (the simulator, the Mac, an unsigned build).
public struct ShareLiveStart: Sendable, Equatable {
    public var run: UUID
    public var environment: LiveEnvironment
    public var service: String
    public var ref: String

    public init(run: UUID, environment: LiveEnvironment, service: String, ref: String) {
        self.run = run
        self.environment = environment
        self.service = service
        self.ref = ref
    }

    public init?(job: UUID, link: LinkInfo, environment: LiveEnvironment?) {
        guard let environment else { return nil }
        self.init(run: job, environment: environment, service: link.service, ref: link.ref)
    }

    var wire: [String: Any] {
        ["run": run.uuidString.lowercased(), "environment": environment.rawValue, "service": service, "ref": ref]
    }
}
