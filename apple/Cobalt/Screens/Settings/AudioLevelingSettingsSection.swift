import CobaltKit
import SwiftUI

/// Settings › Media & WebP › Audio loudness (`features.audio_leveling`, v10.1):
/// Mode (`Off` / `Measure` / `Auto`), target (`-14` / `-16` LUFS), default link (`Original` / `Leveled`),
/// unified LUFS ruler + collapsible rule probe, and background backfill for existing library videos.
struct AudioLevelingSettingsSection: View {
    let model: AppModel

    @State private var probeExpanded = false
    @State private var probeLufs: Double = -11.2
    @State private var probeTruePeak: Double = -0.1
    @State private var doneToken = 0
    @State private var backfillSummary: String?
    @Environment(\.shell) private var shell

    private var store: AudioLevelStore { model.audioLeveling }
    private var settings: AudioLevelSettings { store.settings }

    var body: some View {
        if model.capabilities.audioLeveling && model.settings.hasAPIKey {
            Section {
                // 1. Mode (Off / Measure / Auto)
                Picker(selection: Binding(
                    get: { settings.mode },
                    set: { mode in
                        guard mode != settings.mode else { return }
                        Task {
                            await store.update(.init(mode: mode))
                            doneToken += 1
                        }
                    }
                )) {
                    ForEach(AudioLevelMode.allCases, id: \.self) { mode in
                        Text(mode.label).tag(mode)
                    }
                } label: {
                    Label("New saves", systemImage: "waveform")
                }
                .disabled(store.saving || !store.loaded)

                Text(settings.mode.summary)
                    .font(CobaltType.captionSmall)
                    .foregroundStyle(.secondary)

                // 2. Target loudness (-14 / -16 LUFS)
                Picker(selection: Binding(
                    get: { settings.target },
                    set: { target in
                        guard target != settings.target else { return }
                        Task {
                            await store.update(.init(target: target))
                            doneToken += 1
                        }
                    }
                )) {
                    ForEach(AudioTargetLufs.allCases, id: \.self) { target in
                        Text(target.label).tag(target)
                    }
                } label: {
                    Label("Target loudness", systemImage: "slider.horizontal.3")
                }
                .disabled(store.saving || !store.loaded)

                // 3. Default share link (Original / Leveled ?audio=normal)
                Picker(selection: Binding(
                    get: { settings.defaultLink },
                    set: { link in
                        guard link != settings.defaultLink else { return }
                        Task {
                            await store.update(.init(defaultLink: link))
                            doneToken += 1
                        }
                    }
                )) {
                    ForEach(AudioDefaultLink.allCases, id: \.self) { link in
                        Text(link.label).tag(link)
                    }
                } label: {
                    Label("Share links open on", systemImage: "link")
                }
                .disabled(store.saving || !store.loaded)

                // 4. Unified LUFS ruler & collapsible interactive rule probe
                VStack(alignment: .leading, spacing: 10) {
                    LoudnessRulerView(
                        measuredLufs: probeExpanded ? probeLufs : nil,
                        measuredTruePeak: probeExpanded ? probeTruePeak : nil,
                        outputLufs: (probeExpanded && AudioLoudnessClassifier.classify(lufs: probeLufs, truePeak: probeTruePeak).autoLevel)
                            ? Double(settings.target.rawValue)
                            : nil,
                        target: settings.target,
                        showsAxis: true,
                        showsLegend: true
                    )

                    DisclosureGroup("Test auto-level rule", isExpanded: $probeExpanded) {
                        ruleProbeContent
                            .padding(.top, 8)
                    }
                    .font(Font.cobalt(12.5, .medium, relativeTo: .caption))
                }
                .padding(.vertical, 4)

                // 5. Existing library counts + triggerable backfill sweep
                backfillRow

                if let error = store.lastError {
                    Text(error)
                        .font(Font.cobalt(12, .regular, relativeTo: .caption))
                        .foregroundStyle(CobaltColor.errorText)
                }
            } header: {
                Text("Audio loudness").font(CobaltType.caption).textCase(nil)
            } footer: {
                Text("Originals are never overwritten. Bare links always play the untouched original; adding ?audio=normal serves the leveled copy when ready and falls back silently otherwise.")
                    .font(CobaltType.captionSmall)
                    .lineSpacing(2)
            }
            .task {
                await store.load(force: true)
            }
            .haptic(.success, trigger: doneToken)
        }
    }

    // MARK: - Interactive Rule Probe

    private var ruleProbeContent: some View {
        let verdict = AudioLoudnessClassifier.classify(lufs: probeLufs, truePeak: probeTruePeak)
        let gain = Double(settings.target.rawValue) - probeLufs

        return VStack(alignment: .leading, spacing: 10) {
            // Presets including the -11.2 LUFS true-peak edge case
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    probePreset("Loud −6.2", lufs: -6.2, tp: 0.4)
                    probePreset("Clip −11.2", lufs: -11.2, tp: -0.1)
                    probePreset("Clean −11.2", lufs: -11.2, tp: -1.0)
                    probePreset("Balanced −15.1", lufs: -15.1, tp: -1.4)
                    probePreset("Quiet −28.4", lufs: -28.4, tp: -10.2)
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Integrated loudness")
                        .font(CobaltType.captionSmall)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(AudioLoudnessInfo.formatLufs(probeLufs))
                        .font(Font.cobalt(12, .semibold, relativeTo: .caption))
                        .monospacedDigit()
                }
                Slider(value: $probeLufs, in: -32...0, step: 0.1)
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("True peak")
                        .font(CobaltType.captionSmall)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(AudioLoudnessInfo.formatTruePeak(probeTruePeak))
                        .font(Font.cobalt(12, .semibold, relativeTo: .caption))
                        .foregroundStyle(probeTruePeak > -0.3 ? Color(hex: 0xf87171) : .primary)
                        .monospacedDigit()
                }
                Slider(value: $probeTruePeak, in: -6...1.5, step: 0.1)
            }

            // Live verdict box
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Circle()
                        .fill(verdict.zone.tint)
                        .frame(width: 7, height: 7)
                    Text(verdict.autoLevel ? "Auto-levels to \(settings.target.label) (\(AudioLoudnessInfo.formatGain(gain)))" : verdict.zone.label)
                        .font(Font.cobalt(12, .semibold, relativeTo: .caption))
                        .monospacedDigit()
                    Spacer()
                    Text(verdict.rule)
                        .font(Font.cobalt(10.5, .medium, relativeTo: .caption2))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Text(verdict.summary)
                    .font(CobaltType.captionSmall)
                    .foregroundStyle(.secondary)
            }
            .padding(10)
            .background(verdict.zone.tint.opacity(0.1), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(verdict.zone.tint.opacity(0.28), lineWidth: 0.75)
            )
        }
    }

    private func probePreset(_ title: String, lufs: Double, tp: Double) -> some View {
        let active = abs(probeLufs - lufs) < 0.05 && abs(probeTruePeak - tp) < 0.05
        return Button {
            probeLufs = lufs
            probeTruePeak = tp
        } label: {
            Text(title)
                .font(Font.cobalt(11, .semibold, relativeTo: .caption2))
                .monospacedDigit()
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .foregroundStyle(active ? CobaltColor.onText : .primary)
                .background(
                    active ? Color.accentColor : Color.secondary.opacity(0.14),
                    in: Capsule()
                )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Backfill Row

    private var backfillRow: some View {
        let counts = settings.counts
        let eligible = counts.unmeasured + counts.needsLevel

        return VStack(alignment: .leading, spacing: 8) {
            LabeledContent {
                if store.loaded {
                    Text("\(counts.leveled) leveled · \(counts.measured)/\(counts.totalVideos) measured")
                        .font(Font.cobalt(12, .regular, relativeTo: .caption))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                } else {
                    ProgressView().controlSize(.small)
                }
            } label: {
                Label("Existing library", systemImage: "books.vertical")
            }

            HStack(spacing: 10) {
                Button {
                    Task { await runBackfill() }
                } label: {
                    HStack(spacing: 6) {
                        if store.backfilling {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "waveform.badge.plus")
                        }
                        Text(backfillButtonTitle(eligible: eligible))
                            .font(Font.cobalt(12.5, .semibold, relativeTo: .caption))
                    }
                }
                .buttonStyle(.bordered)
                .disabled(store.backfilling || !store.loaded || settings.mode == .off || counts.totalVideos == 0)

                if let summary = backfillSummary {
                    Text(summary)
                        .font(CobaltType.captionSmall)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                } else if counts.rendering > 0 {
                    Text("\(counts.rendering) rendering…")
                        .font(CobaltType.captionSmall)
                        .foregroundStyle(Color(hex: 0xfbbf24))
                        .monospacedDigit()
                }
            }
        }
        .padding(.vertical, 2)
    }

    private func backfillButtonTitle(eligible: Int) -> String {
        if store.backfilling { return "Scanning…" }
        if settings.mode == .measure { return "Measure Existing" }
        return eligible > 0 ? "Scan & Level (\(min(eligible, 10)))" : "Scan Existing"
    }

    private func runBackfill() async {
        backfillSummary = nil
        do {
            let result = try await store.backfill(limit: 10)
            doneToken += 1
            let total = result.queuedMeasure + result.queuedLevel
            if total == 0 {
                backfillSummary = "Everything up to date"
                shell.showStatus("All videos already measured")
            } else {
                let parts = [
                    result.queuedMeasure > 0 ? "\(result.queuedMeasure) measuring" : nil,
                    result.queuedLevel > 0 ? "\(result.queuedLevel) leveling" : nil,
                ].compactMap { $0 }
                let text = "Queued " + parts.joined(separator: ", ")
                backfillSummary = text
                shell.showStatus(text)
            }
        } catch {
            // store.lastError already populated
        }
    }
}

#if DEBUG
#Preview("settings · audio loudness") {
    PreviewHost(.happy, tab: .settings) { model in
        Form { AudioLevelingSettingsSection(model: model) }.formStyle(.grouped)
    }
}
#endif
