import Foundation

/// What a Live Activity shows, and what the server pushes (CONTRACT-LIVE.md 2.2).
///
/// The JSON keys are the Swift property names (camelCase): ActivityKit decodes the pushed
/// `content-state` by property name with a default `JSONDecoder`, so this is the one object that is
/// not snake_case on the wire, and it must be encoded with a plain `JSONEncoder` (no key strategy).
/// Absent optionals are omitted, never `null`; `waking` and `packing` are always written. Times are
/// unix seconds as `Double` (a `Date` would decode as seconds since 2001 on the push path).
public struct LiveContentState: Codable, Hashable, Sendable {
    public enum Stage: String, Codable, Sendable, CaseIterable {
        case fetching, uploading, saving, reading, ready, rendering, done, failed
    }

    public var stage: Stage
    public var rail: Int                 // highlighted cell 0...3 (fetch|upload, save, read, webp); done: 3
    public var since: Double             // unix seconds this stage began (drives the live timer text)
    public var waking: Bool              // fetching: the server is starting
    public var packing: Bool             // rendering: img2webp, no count exists
    public var bytes: Int64?             // uploading, saving: so far
    public var total: Int64?             // uploading, saving: total when known
    public var framesDone: Int?          // reading: developed (of 9); rendering: decoded frames
    public var framesTotal: Int?
    public var title: String?            // the clip's name once known
    public var duration: Double?         // the clip's length once known
    public var resultURL: String?        // done
    public var resultBytes: Int64?
    public var resultWidth: Int?
    public var resultHeight: Int?
    public var resultSeconds: Double?
    public var failure: String?          // failed: a PipelineFailure case name
    public var code: String?             // failed: the server's error code, when there is one

    public var isTerminal: Bool { stage == .done || stage == .failed }

    public init(stage: Stage, rail: Int, since: Double, waking: Bool = false, packing: Bool = false) {
        self.stage = stage
        self.rail = rail
        self.since = since
        self.waking = waking
        self.packing = packing
    }

    // Lenient on the way in (a missing `waking` or `packing` reads as false); the encoder is the
    // synthesized one, which writes every present key and omits the nil optionals.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        stage = try c.decode(Stage.self, forKey: .stage)
        rail = try c.decode(Int.self, forKey: .rail)
        since = try c.decode(Double.self, forKey: .since)
        waking = try c.decodeIfPresent(Bool.self, forKey: .waking) ?? false
        packing = try c.decodeIfPresent(Bool.self, forKey: .packing) ?? false
        bytes = try c.decodeIfPresent(Int64.self, forKey: .bytes)
        total = try c.decodeIfPresent(Int64.self, forKey: .total)
        framesDone = try c.decodeIfPresent(Int.self, forKey: .framesDone)
        framesTotal = try c.decodeIfPresent(Int.self, forKey: .framesTotal)
        title = try c.decodeIfPresent(String.self, forKey: .title)
        duration = try c.decodeIfPresent(Double.self, forKey: .duration)
        resultURL = try c.decodeIfPresent(String.self, forKey: .resultURL)
        resultBytes = try c.decodeIfPresent(Int64.self, forKey: .resultBytes)
        resultWidth = try c.decodeIfPresent(Int.self, forKey: .resultWidth)
        resultHeight = try c.decodeIfPresent(Int.self, forKey: .resultHeight)
        resultSeconds = try c.decodeIfPresent(Double.self, forKey: .resultSeconds)
        failure = try c.decodeIfPresent(String.self, forKey: .failure)
        code = try c.decodeIfPresent(String.self, forKey: .code)
    }

    /// The fixture states of CONTRACT-LIVE.md 2.4 by name, for the widget's previews. The same ten
    /// objects live in `Tests/CobaltKitTests/Fixtures/live-states.json` (a test pins the two equal)
    /// and the server's copy of that file is byte-identical.
    public static let samples: [String: LiveContentState] = {
        func make(
            _ stage: Stage, rail: Int, since: Double, waking: Bool = false, packing: Bool = false,
            _ fill: (inout LiveContentState) -> Void = { _ in }
        ) -> LiveContentState {
            var s = LiveContentState(stage: stage, rail: rail, since: since, waking: waking, packing: packing)
            fill(&s)
            return s
        }
        let name = "instagram_Dd7P496wolG"
        return [
            "fetching_waking": make(.fetching, rail: 0, since: 1_790_000_000, waking: true),
            "uploading": make(.uploading, rail: 0, since: 1_790_000_001) {
                $0.bytes = 1_200_000; $0.total = 18_200_000; $0.title = "IMG_0412.mov"
            },
            "saving_storing": make(.saving, rail: 1, since: 1_790_000_003) {
                $0.bytes = 2_100_000; $0.total = 4_331_778
            },
            "reading": make(.reading, rail: 2, since: 1_790_000_005) {
                $0.framesDone = 4; $0.framesTotal = 9; $0.title = name; $0.duration = 14.77
            },
            "ready": make(.ready, rail: 2, since: 1_790_000_007) {
                $0.title = name; $0.duration = 14.77
            },
            "decoding": make(.rendering, rail: 3, since: 1_790_000_020) {
                $0.framesDone = 42; $0.framesTotal = 150; $0.title = name; $0.duration = 14.77
            },
            "packing": make(.rendering, rail: 3, since: 1_790_000_020, packing: true) {
                $0.framesDone = 150; $0.framesTotal = 150; $0.title = name; $0.duration = 14.77
            },
            "done": make(.done, rail: 3, since: 1_790_000_043) {
                $0.title = name; $0.duration = 14.77
                $0.resultURL = "https://media.capybaraharmony.com/PrEvIeW001.webp"
                $0.resultBytes = 4_500_000; $0.resultWidth = 480; $0.resultHeight = 854; $0.resultSeconds = 10.1
            },
            "failed_render_lost": make(.failed, rail: 3, since: 1_790_000_030) {
                $0.title = name; $0.duration = 14.77
                $0.failure = "renderLost"; $0.code = "error.webp.job_lost"
            },
            "failed_fetch": make(.failed, rail: 0, since: 1_790_000_002) {
                $0.failure = "fetchFailed"; $0.code = "error.api.fetch.empty"
            },
        ]
    }()
}

/// The activity's fixed attributes (CONTRACT-LIVE.md 2.2). Compiles on every platform so the macOS
/// `swift test` run covers the wire shape; `CobaltActivityAttributes` (iOS only) mirrors it.
public struct LiveRunAttributes: Codable, Hashable, Sendable {
    public var run: String               // lowercase UUID
    public var input: String             // "link" | "file"
    public var service: String           // LinkInfo.service ("instagram", "x"), "file" for files
    public var ref: String               // LinkInfo.ref, or the file name
    public var origin: String            // "app" | "share"

    public init(run: UUID, input: String, service: String, ref: String, origin: String) {
        self.run = run.uuidString.lowercased()
        self.input = input
        self.service = service
        self.ref = ref
        self.origin = origin
    }
}

#if os(iOS) && canImport(ActivityKit)
import ActivityKit

/// Same stored properties as `LiveRunAttributes`; the push-to-start `attributes-type` is this
/// type's name, exactly "CobaltActivityAttributes".
public struct CobaltActivityAttributes: ActivityAttributes, Hashable, Sendable {
    public typealias ContentState = LiveContentState
    public var run: String
    public var input: String
    public var service: String
    public var ref: String
    public var origin: String

    public init(_ a: LiveRunAttributes) {
        run = a.run
        input = a.input
        service = a.service
        ref = a.ref
        origin = a.origin
    }
}
#endif
