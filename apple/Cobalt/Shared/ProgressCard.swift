import CobaltKit
import SwiftUI

/// The ONE progress card (CONTRACT-ORBIT 2c), on the home page, under the focused planet while a webp is
/// made or the video is published, and in the share sheet: what is happening now in plain words, the
/// real numbers, a bar, and the stepper that shows where the run is. It draws no background of its own
/// (the caller puts it on glass or on a surface) and nothing in it is a control. It is one accessibility
/// element: label "progress", value "step 2 of 4, saving to your library, 2.1 of 4.3 MB".
struct ProgressCard: View {
    let story: ProgressStory

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(story.headline)
                .font(CobaltType.bodySemibold)
                .foregroundStyle(CobaltColor.text)
                .lineLimit(2)
                .minimumScaleFactor(0.85)
                .fixedSize(horizontal: false, vertical: true)
                .contentTransition(.opacity)
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                StoryDetail(detail: story.detail)
                Spacer(minLength: 0)
                Text(story.stepText)
                    .font(CobaltType.caption)
                    .foregroundStyle(CobaltColor.captionOnElevated)
                    .monospacedDigit()
                    .lineLimit(1)
                    .fixedSize()
            }
            StoryBar(fraction: story.fraction)
                .padding(.vertical, 2)
            ProgressStepper(story: story)
                .padding(.top, 2)
            if let note = story.footnote {
                Text(note)
                    .font(Font.cobalt(11, .regular, relativeTo: .footnote))
                    .foregroundStyle(CobaltColor.captionOnElevated)
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Copy.progressA11y)
        .accessibilityValue(story.spoken)
        .accessibilityAddTraits(.updatesFrequently)
    }
}

/// The detail line: real numbers only ("2.1 of 4.3 MB", "frame 42 of 150", "waking the server · 4 s").
struct StoryDetail: View {
    let detail: ProgressStory.Detail?

    var body: some View {
        switch detail {
        case .text(let text):
            RollingText(text: text, font: CobaltType.caption)
        case .elapsed(let prefix, let since):
            TimelineView(.periodic(from: since, by: 0.5)) { context in
                RollingText(
                    text: Copy.elapsedLine(prefix, seconds: Int(max(0, context.date.timeIntervalSince(since)))),
                    font: CobaltType.caption)
            }
        case nil:
            EmptyView()
        }
    }
}

/// A number that rolls (`.numericText`), and just changes under Reduce Motion.
struct RollingText: View {
    let text: String
    var font: Font = CobaltType.body
    var color: Color = CobaltColor.captionOnElevated
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Text(text)
            .font(font)
            .foregroundStyle(color)
            .monospacedDigit()
            .lineLimit(1)
            .contentTransition(reduceMotion ? .identity : .numericText())
            .animation(reduceMotion ? nil : .snappy(duration: 0.2), value: text)
    }
}
