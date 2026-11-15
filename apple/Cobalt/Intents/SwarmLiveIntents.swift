import AppIntents
import CobaltKit
import Foundation

// Live Activities are iOS only (LiveActivityIntent is unavailable on macOS); the Mac approves from its notification.
#if os(iOS)

// The buttons of a swarm's Live Activity (apple/CONTRACT-SWARMS.md 4; APP-API-CONTRACT 61.5).
//
// This file is compiled into BOTH the app and the widget extension (project.yml lists it under CobaltWidgets as well): the
// extension needs the types for `Button(intent:)`, and the system runs a `LiveActivityIntent` in the app's process, so the
// app target needs them to answer. Two copies of a few lines is what an intent shared by an app and its extension costs; a
// CobaltKit home would need `AppIntentsPackage` plumbing for the metadata to be found, and these have no other use.
//
// `perform` is one line into `SwarmIntentHost` (CobaltKit), which calls the API with the device's own signed-in session and
// puts the answer on the activity at once. Approve and apply spend money or change things, so the system asks for Face ID /
// Touch ID first (`.requiresAuthentication`); decline and stop only ever end or stop work, so they do not.

/// What a swarm button refuses with, as a plain sentence the system shows as is.
struct SwarmIntentError: Error, CustomLocalizedStringResourceConvertible {
    let message: String

    init(_ error: Error) {
        switch error {
        case let e as SwarmError: message = e.words
        case let e as SwarmIntentHostError: message = e.words
        default: message = SwarmError.other.words
        }
    }

    var localizedStringResource: LocalizedStringResource {
        LocalizedStringResource(String.LocalizationValue(message))
    }
}

private func runSwarmAction(_ action: SwarmLiveAction, swarm: String, hash: String?) async throws {
    do {
        try await SwarmIntentHost.run(action, swarm: swarm, hash: hash)
    } catch {
        throw SwarmIntentError(error)
    }
}

/// "approve" on the Lock Screen card: runs the plan the owner is looking at (`hash` pins which plan).
struct ApproveSwarmIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Approve swarm"
    static let description = IntentDescription("Approves the swarm that is waiting for you.")
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication
    static let openAppWhenRun = false

    @Parameter(title: "Swarm") var swarm: String
    @Parameter(title: "Plan") var hash: String

    init() {}
    init(swarm: String, hash: String) {
        self.swarm = swarm
        self.hash = hash
    }

    func perform() async throws -> some IntentResult {
        try await runSwarmAction(.approve, swarm: swarm, hash: hash)
        return .result()
    }
}

/// "apply" on the Lock Screen card: applies the kept changes, leaving out the ones that look like duplicates.
struct ApplySwarmIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Apply swarm changes"
    static let description = IntentDescription("Applies the changes a swarm found, leaving out duplicates.")
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication
    static let openAppWhenRun = false

    @Parameter(title: "Swarm") var swarm: String
    @Parameter(title: "Plan") var hash: String

    init() {}
    init(swarm: String, hash: String) {
        self.swarm = swarm
        self.hash = hash
    }

    func perform() async throws -> some IntentResult {
        try await runSwarmAction(.apply, swarm: swarm, hash: hash)
        return .result()
    }
}

/// "decline": the swarm never runs. No Face ID: it only ever says no.
struct DeclineSwarmIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Decline swarm"
    static let description = IntentDescription("Declines the swarm that is waiting for you.")
    static let openAppWhenRun = false

    @Parameter(title: "Swarm") var swarm: String

    init() {}
    init(swarm: String) { self.swarm = swarm }

    func perform() async throws -> some IntentResult {
        try await runSwarmAction(.decline, swarm: swarm, hash: nil)
        return .result()
    }
}

/// "stop": a running swarm stops at once. No Face ID: it only ever ends work.
struct StopSwarmIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Stop swarm"
    static let description = IntentDescription("Stops a running swarm.")
    static let openAppWhenRun = false

    @Parameter(title: "Swarm") var swarm: String

    init() {}
    init(swarm: String) { self.swarm = swarm }

    func perform() async throws -> some IntentResult {
        try await runSwarmAction(.stop, swarm: swarm, hash: nil)
        return .result()
    }
}

#endif
