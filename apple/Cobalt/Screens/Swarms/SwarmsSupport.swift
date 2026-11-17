import CobaltKit
import SwiftUI

// What the swarms screens share: where a screen can go, the square colours, the controller that runs an answer and keeps the
// problem it hit, and the small views several screens draw (the facts card, the sentence).

/// One step further than the swarm screen: its plain-lists detail, the check screen or the results board.
enum SwarmStep: Hashable {
    case told, check, board
}

/// Where the list opens: a swarm, optionally already on one of its steps or with an agent open (a link, a launch argument).
struct SwarmDestination: Hashable {
    var id: String
    var step: SwarmStep?
    var agent: Int?

    init(id: String, step: SwarmStep? = nil, agent: Int? = nil) {
        self.id = id
        self.step = step
        self.agent = agent
    }

    init(route: SwarmRoute) {
        switch route {
        case .swarm(let id): self.init(id: id)
        case .review(let id): self.init(id: id, step: .check)
        case .board(let id): self.init(id: id, step: .board)
        }
    }
}

enum SwarmColor {
    /// A square waiting on a question, and the notes that mean "look here".
    static let amber = Color(light: 0xa85f00, dark: 0xf5ad5b)
    /// The owner's side of a conversation.
    static let ownerBubble = Color(light: 0xdbe8fb, dark: 0x1f3350)

    static func cell(_ status: SwarmCell.Status) -> Color {
        switch status {
        case .queued: return CobaltColor.elevated
        case .running: return CobaltColor.text
        case .waiting: return amber
        case .done: return CobaltColor.success
        case .failed: return CobaltColor.error
        case .skipped: return CobaltColor.border
        }
    }
}

/// Runs one answer (approve, decline, stop, apply, a reply) and keeps what went wrong, so the screen can say it with the inline
/// status. The store asks Face ID itself; a backed-out check arrives here as `notConfirmed` ("nothing was sent").
@MainActor @Observable
final class SwarmController {
    var problem: SwarmError?
    var busy = false

    func run(_ work: @MainActor () async throws -> Void) async {
        guard !busy else { return }
        busy = true
        problem = nil
        do { try await work() } catch { problem = SwarmError.from(error) }
        busy = false
    }

    func clear() { problem = nil }
}

/// A problem line with its "ok".
struct SwarmProblemLine: View {
    let error: SwarmError
    let dismiss: () -> Void

    var body: some View {
        InlineStatus(message: Copy.Swarms.problem(error)) {
            Button(Copy.Swarms.ok, action: dismiss)
                .buttonStyle(.cobaltSecondary(fullWidth: false, compact: true))
        }
    }
}

/// The swarm's sentence, big.
struct SwarmSentence: View {
    let text: String

    var body: some View {
        Text(text)
            .font(Font.cobalt(21, .semibold, relativeTo: .title2))
            .foregroundStyle(CobaltColor.text)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityAddTraits(.isHeader)
    }
}

/// The small grey line over the sentence ("claude code asks · expires in 52 min", "running · 3 min").
struct SwarmWho: View {
    let text: String
    var tint: Color = CobaltColor.caption

    var body: some View {
        Text(text)
            .font(CobaltType.caption)
            .foregroundStyle(tint)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A card of rows: the three facts, the "see what it's told" row.
struct SwarmCard<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(spacing: 0) { content() }
            .background(CobaltColor.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay { RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(CobaltColor.border.opacity(0.5), lineWidth: 1) }
    }
}

struct SwarmFactRow: View {
    let symbol: String
    let text: String
    var last = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Image(systemName: symbol)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(CobaltColor.caption)
                    .frame(width: 20)
                    .accessibilityHidden(true)
                Text(text)
                    .font(CobaltType.body)
                    .foregroundStyle(CobaltColor.text)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            if !last { Divider().overlay(CobaltColor.hairline).padding(.leading, 46) }
        }
        .accessibilityElement(children: .combine)
    }
}

/// The thin bar the running screen and the applying screen show.
struct SwarmBar: View {
    let fraction: Double

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(CobaltColor.elevated)
                Capsule().fill(CobaltColor.text).frame(width: max(0, proxy.size.width * min(1, max(0, fraction))))
            }
        }
        .frame(height: 6)
        .motion(Motion.card, value: fraction)
        .accessibilityHidden(true)
    }
}
