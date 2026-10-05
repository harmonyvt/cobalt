import CobaltKit
import SwiftUI

// Previews and the simulator evidence run both start a pipeline over `AppModel.preview(...)`.
// Paste text per scenario is pinned in CONTRACT 4.7.

extension PreviewScenario {
    /// What the paste circle "reads" in this scenario.
    var pasteText: String {
        switch self {
        case .noLink: return "nothing to see here, just words"
        case .shortClip: return "https://x.com/i/status/2105435404002562056"
        case .picker: return "https://x.com/PopCrave/status/1682176754792955905"
        default: return "https://www.instagram.com/reel/Dd7P496wolG/"
        }
    }

    /// The scenarios the file circle drives rather than the paste circle.
    var usesFile: Bool { self == .tooBig || self == .image }

    var fileURL: URL {
        URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(self == .image ? "cobalt-preview.png" : "cobalt-preview.mov")
    }
}

/// What a preview (or the `-previewScript` launch argument) does after the model exists.
enum PreviewScript: String {
    /// Rest at the idle home.
    case idle
    /// Paste (or pick a file) and let the pipeline run to wherever the scenario stops (the focused planet).
    case input
    /// Like `input`, then press "make webp" as soon as the trim is ready.
    case render
    /// Like `input`, then "public share" (host the original) as soon as the planet is in focus.
    case share
    /// Public share first, then convert to webp: both results on the planet.
    case both
    /// Convert to webp first, then public share.
    case renderThenShare
}

@MainActor
func runPreviewScript(_ script: PreviewScript, scenario: PreviewScenario, pipeline: Pipeline) async {
    guard script != .idle else { return }
    try? await Task.sleep(for: .milliseconds(600))
    #if DEBUG
    // `-previewDelay 3`: rest at the idle home this many seconds first (a real paste comes long after launch)
    let rest = UserDefaults.standard.double(forKey: "previewDelay")
    if rest > 0 { try? await Task.sleep(for: .seconds(rest)) }
    #endif
    if scenario.usesFile { pipeline.start(file: scenario.fileURL) } else { pipeline.start(pastedText: scenario.pasteText) }
    guard script != .input else { return }
    // the focused planet is up once the pipeline is ready (and the morph has landed)
    var ready = false
    for _ in 0..<200 {
        try? await Task.sleep(for: .milliseconds(100))
        switch pipeline.state {
        case .ready: ready = true
        case .failed, .picker, .image, .savedLocally, .done: return
        default: continue
        }
        if ready { break }
    }
    guard ready else { return }
    try? await Task.sleep(for: .milliseconds(1800))
    switch script {
    case .render:
        pipeline.makeWebp()
    case .share:
        pipeline.hostOriginal()
    case .both:
        pipeline.hostOriginal()
        await waitFor { pipeline.hosting == .done }
        try? await Task.sleep(for: .milliseconds(1400))
        pipeline.makeWebp()
    case .renderThenShare:
        pipeline.makeWebp()
        await waitFor { if case .done = pipeline.state { return true } else { return false } }
        try? await Task.sleep(for: .milliseconds(1600))
        pipeline.hostOriginal()
    case .idle, .input:
        break
    }
}

@MainActor
private func waitFor(_ condition: @MainActor () -> Bool) async {
    for _ in 0..<300 {
        if condition() { return }
        try? await Task.sleep(for: .milliseconds(100))
    }
}

/// Builds an `AppModel.preview(scenario)` once and hands it to the content.
struct PreviewHost<Content: View>: View {
    @State private var model: AppModel
    private let scenario: PreviewScenario
    private let script: PreviewScript
    private let content: (AppModel) -> Content

    init(
        _ scenario: PreviewScenario = .happy, script: PreviewScript = .idle, tab: AppTab = .save,
        @ViewBuilder content: @escaping (AppModel) -> Content
    ) {
        let model = AppModel.preview(scenario)
        model.selectedTab = tab
        _model = State(initialValue: model)
        self.scenario = scenario
        self.script = script
        self.content = content
    }

    var body: some View {
        content(model)
            .task { await runPreviewScript(script, scenario: scenario, pipeline: model.pipeline) }
    }
}
