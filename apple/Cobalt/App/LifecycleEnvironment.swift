import CobaltKit
import SwiftUI

// The view tree's copy of the app's state (apple/ARCHITECTURE.md, "Who owns what"). `AppLifecycle` (CobaltKit) is the
// one listener; the root window view copies its snapshots into the Environment, and screens read
// `@Environment(\.lifecycle)` instead of `@Environment(\.scenePhase)`. App and Scene bodies and `.commands` read
// neither: they are part of SwiftUI's dependency graph, and a live read there made the #113 loop.

// The `\.lifecycle` entry itself is in Cobalt/Shared/LifecycleValue.swift, so the share extension (which compiles
// Cobalt/Shared but not Cobalt/App) can read it too.

extension View {
    /// The root of each window: feeds `\.lifecycle` from `AppLifecycle.shared`, and writes the launch marker the
    /// TestFlight gate waits for once the first window has drawn.
    func publishesLifecycle() -> some View { modifier(PublishesLifecycle()) }
}

private struct PublishesLifecycle: ViewModifier {
    @State private var snapshot = AppLifecycle.shared.snapshot

    func body(content: Content) -> some View {
        content
            .environment(\.lifecycle, snapshot)
            .task {
                for await next in AppLifecycle.shared.snapshots() where next != snapshot {
                    snapshot = next
                }
            }
            .onAppear { LaunchMarker.firstWindowAppeared() }
    }
}

/// `Library/Caches/launch-ok`: written once per process when the first window's root view appears. The TestFlight
/// launch gate (deploy/apple/launch-gate.sh) deletes it, launches the release build and fails the upload unless the
/// app is still alive after 15 s AND this file exists, so a crash or a hang before the first frame stops the upload.
/// It costs one tiny file write off the main thread per launch, in every build.
enum LaunchMarker {
    static let fileName = "launch-ok"
    @MainActor private static var written = false

    @MainActor static func firstWindowAppeared() {
        guard !written else { return }
        written = true
        let stamp = ISO8601DateFormatter().string(from: .now)
        Task.detached(priority: .utility) {
            guard let caches = try? FileManager.default.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            else { return }
            try? Data(stamp.utf8).write(to: caches.appendingPathComponent(fileName), options: .atomic)
        }
    }
}
