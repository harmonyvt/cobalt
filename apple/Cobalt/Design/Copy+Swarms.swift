import CobaltKit
import Foundation

/// Copy for the swarms screens (apple/CONTRACT-SWARMS.md; APP-API-CONTRACT 59, 61, 62): the list, the one swarm screen, the
/// agent sheet, the check screen and the results board. All lowercase, plain words: never "propose", "scope", "batch", "spec" or
/// "mode". Plain values only (counts, dates, CobaltKit types), since `Cobalt/Design` is compiled into the extensions too. The
/// sentences that describe a swarm itself (the row line, the three facts, money) are `SwarmWords` in CobaltKit.
extension Copy {
    enum Swarms {
        static let title = "swarms"

        // MARK: the list

        static let waiting = "waiting for you"
        static let running = "running"
        static let finished = "finished"
        static let loading = "loading swarms…"
        static let emptyTitle = "no swarms yet"
        static let emptyBody = "when claude code or the chat asks to run one, it waits for you here"
        static let tryAgain = "try again"
        static let refresh = "refresh"
        static func score(_ score: Double) -> String { "score \(SwarmWords.score(score))" }

        // MARK: the swarm screen

        static let approve = "approve"
        static let decline = "decline"
        static let stop = "stop"
        static let stopping = "stopping…"
        static let retry = "retry"
        static let ok = "ok"
        static let checkFirst = "check first"
        static func apply(_ n: Int) -> String { "apply \(n)" }
        static let seeResults = "see results"
        static let seeChanges = "see what changed"
        static let seeTold = "see exactly what it's told"
        static var confirmHint: String { Platform.isMac ? "touch id confirms" : "face id confirms" }
        static let gone = "that swarm is gone"
        static let loadingOne = "loading…"

        static func agentsDone(_ done: Int, of total: Int) -> String { "\(done) of \(total) agents done" }
        static func changesApplied(_ done: Int, of total: Int) -> String { "\(done) of \(total) changes applied" }
        static func agentFailed(_ agent: Int) -> String { "agent \(agent) failed" }
        static func agentFailedRetry(_ agent: Int) -> String { "agent \(agent) failed · retry" }
        static func agentAsking(_ agent: Int, who: String?) -> String { "agent \(agent) is asking \(who ?? "the one that asked")" }
        static func andMore(_ n: Int) -> String { "and \(n) more" }
        static func duplicatesLeftOut(_ n: Int) -> String {
            n == 1 ? "1 looks like a duplicate and is left out" : "\(n) look like duplicates and are left out"
        }
        static func spent(_ money: String) -> String { "\(money) spent" }
        static func applyFailed(_ n: Int) -> String { n == 1 ? "1 couldn't be applied" : "\(n) couldn't be applied" }
        static func applied(_ n: Int) -> String { "applied \(n)" }
        static let noError = "it stopped before any agent finished"

        /// The two status words the design puts on each square (VoiceOver).
        static func cell(_ agent: Int, _ status: SwarmCell.Status) -> String {
            switch status {
            case .queued: return "agent \(agent), waiting its turn"
            case .running: return "agent \(agent), working"
            case .waiting: return "agent \(agent), asking a question"
            case .done: return "agent \(agent), done"
            case .failed: return "agent \(agent), failed"
            case .skipped: return "agent \(agent), skipped"
            }
        }

        // MARK: what it's told

        static let toldTitle = "what it's told"
        static let toldPrompt = "its instructions"
        static let toldItems = "the first items"
        static let toldTools = "what it can look at"
        static let toldWrites = "what it can change"
        static let nothing = "nothing"
        static func moreItems(_ n: Int) -> String { "and \(n) more" }

        // MARK: the agent sheet

        static func agent(_ n: Int) -> String { "agent \(n)" }
        static let previousAgent = "previous agent"
        static let nextAgent = "next agent"
        static let close = "close"
        static let did = "what it did"
        static let itsChanges = "its changes"
        static let conversation = "conversation"
        static let nothingYet = "nothing yet"
        static let thinking = "loading this agent…"
        static let waitingForAnswer = "waiting for an answer"
        static let allAgents = "all agents"
        static let you = "you"
        static func reply(to agent: Int) -> String { "reply to agent \(agent)" }
        static let send = "send"
        static let sendA11y = "send the reply"
        static func conversationLabel(from: String, to: String) -> String { "\(from) → \(to)" }

        // MARK: check changes

        static let checkTitle = "check changes"
        static func changesReady(_ n: Int) -> String { n == 1 ? "1 change ready" : "\(n) changes ready" }
        static let tapToChange = "tap a new name to change it"
        static let renameTitle = "new name"
        static let save = "save"
        static let cancel = "cancel"
        static let keepA11y = "keep this change"
        static let dropA11y = "leave this change out"
        static let changeDone = "done"
        static let loadingChanges = "loading the changes…"
        static let noChanges = "no changes"

        /// What a server clash line says, in plain words ("duplicate name: also proposed by #118").
        static func clash(_ raw: String) -> String {
            if raw.hasPrefix("duplicate name") { return "another change already uses this name" }
            if raw.hasPrefix("duplicate") { return "another change is exactly the same" }
            if raw.hasPrefix("invalid") { return "this one isn't allowed" }
            return "this one clashes with another change"
        }

        // MARK: the results board

        static let boardTitle = "results"
        static let searchPrompt = "search the results"
        static let all = "all"
        static let sort = "sort"
        static func sortName(_ sort: BoardSort) -> String {
            switch sort {
            case .agent: return "agent"
            case .score: return "score"
            case .title: return "title"
            }
        }
        static func resultCount(_ n: Int) -> String { n == 1 ? "1 result" : "\(n) results" }
        static let boardEmpty = "nothing matches"
        static let boardNone = "no results yet"
        static let loadingBoard = "loading the results…"
        static let agentsStrip = "agents, coloured by score"
        static func groupChip(_ value: String, _ count: Int) -> String { "\(value) · \(count)" }
        static let details = "details"
        static let media = "media"
        static let links = "links"
        static let fields = "fields"
        static let open = "open"
        static let done = "done"
        static func failedCard(_ agent: Int) -> String { "agent \(agent) failed" }

        // MARK: problems

        /// A refusal or failure in the app's voice (`SwarmError.words`).
        static func problem(_ error: SwarmError) -> String { error.words }
    }
}
