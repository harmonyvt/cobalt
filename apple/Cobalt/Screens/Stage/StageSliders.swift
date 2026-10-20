import CobaltKit
import SwiftUI

// "how crazy" (5...100 tiles on screen) and "tile life" (3...120 s each), the "play videos through" and "unmute all videos"
// switches, then a "more" fold with the tile size, the spotlight's time, how many videos may play at once and the auto
// spotlight. A slider shows its value at once; the store sends the latest values 300 ms after the last move (last write wins),
// so a drag is one request. A switch is sent at once and put back if the server refuses it.

struct StageSliders: View {
    let store: StageStore
    let controller: StageController

    @Environment(\.shell) private var shell
    @State private var moreShown = false

    var body: some View {
        if let stage = store.stage {
            StageCard {
                crazy(stage)
                life(stage)
                playThrough(stage)
                soundAll(stage)
                more(stage)
            }
        }
    }

    // MARK: the two sliders

    private func crazy(_ stage: StageSettings) -> some View {
        StageSliderRow(
            title: Copy.Stage.howCrazy, value: Copy.Stage.onScreen(stage.density),
            low: Copy.Stage.calm, high: Copy.Stage.chaosWord,
            number: Binding(
                get: { Double(store.stage?.density ?? stage.density) },
                set: { store.setDensity(Int($0.rounded())) }),
            range: Self.span(StageRule.densityRange), step: 1)
    }

    private func life(_ stage: StageSettings) -> some View {
        StageSliderRow(
            title: Copy.Stage.tileLife, value: Copy.Stage.eachSeconds(stage.tileSeconds),
            low: Copy.Stage.flicker, high: Copy.Stage.linger,
            number: Binding(
                get: { Double(store.stage?.tileSeconds ?? stage.tileSeconds) },
                set: { store.setTileSeconds(Int($0.rounded())) }),
            range: Self.span(StageRule.tileSecondsRange), step: 1)
    }

    // MARK: the two video switches

    private func playThrough(_ stage: StageSettings) -> some View {
        StageSwitchRow(
            title: Copy.Stage.playThrough, note: Copy.Stage.playThroughNote,
            isOn: Binding(
                get: { store.stage?.playThrough ?? stage.playThrough },
                set: { controller.setPlayThrough($0, shell: shell) }),
            busy: controller.isBusy("playThrough"))
    }

    /// On only while the master `sound` is on too (`sound: false` mutes every tile).
    private func soundAll(_ stage: StageSettings) -> some View {
        StageSwitchRow(
            title: Copy.Stage.soundAll, note: Copy.Stage.soundAllNote,
            isOn: Binding(
                get: {
                    let now = store.stage ?? stage
                    return now.soundAll && now.sound
                },
                set: { controller.setSoundAll($0, shell: shell) }),
            busy: controller.isBusy("soundAll") || controller.isBusy("sound"))
    }

    private static func span(_ range: ClosedRange<Int>) -> ClosedRange<Double> {
        Double(range.lowerBound)...Double(range.upperBound)
    }

    // MARK: more

    private func more(_ stage: StageSettings) -> some View {
        DisclosureGroup(isExpanded: $moreShown) {
            VStack(alignment: .leading, spacing: 14) {
                size(stage)
                spotlightTime(stage)
                videos(stage)
                auto(stage)
            }
            .padding(.top, 10)
        } label: {
            Text(Copy.Stage.moreOptions)
                .font(CobaltType.caption)
                .foregroundStyle(CobaltColor.caption)
        }
        .tint(CobaltColor.caption)
    }

    private func size(_ stage: StageSettings) -> some View {
        StageSliderRow(
            title: Copy.Stage.tileSize, value: Copy.Stage.sizeValue(stage.tileScale),
            low: Copy.Stage.small, high: Copy.Stage.large,
            number: Binding(
                get: { store.stage?.tileScale ?? stage.tileScale },
                set: { store.setTileScale(($0 * 10).rounded() / 10) }),
            range: StageRule.tileScaleRange, step: 0.1)
    }

    private func spotlightTime(_ stage: StageSettings) -> some View {
        StageSliderRow(
            title: Copy.Stage.spotlightTime, value: Copy.Stage.spotlightSecondsValue(stage.spotlightSeconds),
            low: nil, high: nil,
            number: Binding(
                get: { Double(store.stage?.spotlightSeconds ?? stage.spotlightSeconds) },
                set: { store.setSpotlightSeconds(Int($0.rounded())) }),
            range: Self.span(StageRule.spotlightSecondsRange), step: 5)
    }

    private func videos(_ stage: StageSettings) -> some View {
        StageSliderRow(
            title: Copy.Stage.videosAtOnce, value: Copy.Stage.videosValue(stage.videoMax),
            low: Copy.Stage.few, high: Copy.Stage.many,
            number: Binding(
                get: { Double(store.stage?.videoMax ?? stage.videoMax) },
                set: { store.setVideoMax(Int($0.rounded())) }),
            range: Self.span(StageRule.videoMaxRange), step: 1)
    }

    private func auto(_ stage: StageSettings) -> some View {
        StageSwitchRow(
            title: Copy.Stage.spotlightAuto, note: Copy.Stage.spotlightAutoNote,
            isOn: Binding(
                get: { store.stage?.spotlightAuto ?? stage.spotlightAuto },
                set: { controller.setSpotlightAuto($0, shell: shell) }),
            busy: controller.isBusy("auto"))
    }
}

/// A switch with its title and a small caption note under it (the auto spotlight, the two video switches, the wallpaper).
struct StageSwitchRow: View {
    let title: String
    let note: String
    @Binding var isOn: Bool
    var busy = false

    var body: some View {
        Toggle(isOn: $isOn) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(CobaltType.bodySemibold)
                Text(note)
                    .font(CobaltType.badge)
                    .foregroundStyle(CobaltColor.caption)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .toggleStyle(.switch)
        .tint(CobaltColor.success)
        .frame(minHeight: Metrics.hit)
        .disabled(busy)
    }
}

/// A title and its value on one line, the slider under it, and what each end means.
struct StageSliderRow: View {
    let title: String
    let value: String
    let low: String?
    let high: String?
    @Binding var number: Double
    let range: ClosedRange<Double>
    let step: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .font(CobaltType.bodySemibold)
                    .foregroundStyle(CobaltColor.text)
                Spacer(minLength: 8)
                Text(value)
                    .font(CobaltType.caption)
                    .foregroundStyle(CobaltColor.caption)
                    .monospacedDigit()
            }
            .accessibilityHidden(true)
            Slider(value: $number, in: range, step: step)
                .tint(CobaltColor.text)
                .frame(minHeight: Metrics.hit)
                .accessibilityLabel(title)
                .accessibilityValue(value)
            if let low, let high {
                HStack {
                    Text(low)
                    Spacer(minLength: 8)
                    Text(high)
                }
                .font(CobaltType.badge)
                .foregroundStyle(CobaltColor.caption)
                .accessibilityHidden(true)
            }
        }
    }
}
