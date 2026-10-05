import Foundation

extension PipelineContext {
    /// A fully wired context over `PreviewClient`: in-memory settings and keychain, a temp-dir
    /// store seeded with the orbit, nothing on the network.
    static func preview(_ scenario: PreviewScenario, timeScale: Double, clock: any PipelineClock) -> PipelineContext {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("cobalt-preview-\(UUID().uuidString.prefix(8))", isDirectory: true)
        let suite = "cobalt.preview.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite) ?? .standard
        defaults.removePersistentDomain(forName: suite)
        let settings = Settings(defaults: defaults, keychain: .memory())
        try? settings.setAPIKey(pasted: "7c1f2a60-4b0e-4d2f-9a53-3f1d8e9b6a21")

        let client = PreviewClient(scenario: scenario, timeScale: timeScale, clock: clock)
        let tools = PreviewMediaTools(clock: clock, clip: PreviewData.clip(for: scenario))
        // stamps come from the preview clock, like the seeds (a virtual clock in tests, the real one in previews)
        let store = OfflineStore(
            root: dir.appendingPathComponent("Videos", isDirectory: true), tools: tools, defaults: defaults,
            now: { clock.now() })
        if scenario != .emptyOrbit {
            store.seed(PreviewData.seeds(for: scenario, now: clock.now()))
            store.usageBase = PreviewData.usage
        }
        let jobs = SharedJobStore(directory: dir.appendingPathComponent("Jobs", isDirectory: true))
        return PipelineContext(
            client: client, capabilities: PreviewData.capabilities(for: scenario), settings: settings,
            store: store, jobs: jobs, tools: tools, clock: clock, photos: PreviewPhotos(clock: clock),
            clipboard: MemoryClipboard(), intake: PreviewIntake(scenario: scenario), isPreview: true)
    }
}
