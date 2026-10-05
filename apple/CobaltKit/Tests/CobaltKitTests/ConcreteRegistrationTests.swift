import Foundation
import Testing
@testable import CobaltKit

@MainActor
private final class FakeBacking: BackgroundTaskBacking {
    var accepts = true
    private(set) var events: [String] = []

    func register(identifier: String, launch: @escaping @MainActor (any ContinuedTaskHandle, String) -> Void) -> Bool {
        events.append("register \(identifier) -> \(accepts)")
        return accepts
    }
    func submit(identifier: String, title: String, subtitle: String) throws { events.append("submit \(identifier)") }
    func cancel(identifier: String) { events.append("cancel \(identifier)") }
}

/// The crash: BGTaskScheduler raises an uncatchable exception when a concrete identifier is
/// submitted without being registered, and a wildcard registration is not one.
@MainActor
@Suite(.serialized)
struct ConcreteRegistrationTests {
    private let id = "com.capybaraharmony.cobalt.run.ab12cd34"

    @Test func theConcreteIdentifierIsRegisteredRightBeforeItIsSubmitted() throws {
        let backing = FakeBacking()
        let s = ConcreteRegistrationScheduler(backing: backing)
        #expect(s.register(pattern: ContinuedProcessing.identifierPattern) { _, _ in })
        #expect(backing.events.isEmpty, "the wildcard is never handed to the system")
        try s.submit(identifier: id, title: "t", subtitle: "s")
        #expect(backing.events == ["register \(id) -> true", "submit \(id)"])
        #expect(s.registeredIdentifiers == [id])
    }

    @Test func aRefusedRegistrationThrowsAndNeverSubmits() {
        let backing = FakeBacking()
        backing.accepts = false
        let s = ConcreteRegistrationScheduler(backing: backing)
        _ = s.register(pattern: ContinuedProcessing.identifierPattern) { _, _ in }
        #expect(throws: ContinuedSchedulingError.notRegistered(identifier: id)) {
            try s.submit(identifier: id, title: "t", subtitle: "s")
        }
        #expect(!backing.events.contains { $0.hasPrefix("submit") }, "never submit what is not registered")
    }

    @Test func submittingBeforeAnyLaunchHandlerExistsThrowsAndTouchesNothing() {
        let backing = FakeBacking()
        let s = ConcreteRegistrationScheduler(backing: backing)
        #expect(throws: ContinuedSchedulingError.noLaunchHandler) {
            try s.submit(identifier: id, title: "t", subtitle: "s")
        }
        #expect(backing.events.isEmpty)
    }

    @Test func eachSubmissionRegistersItsOwnIdentifier() throws {
        let backing = FakeBacking()
        let s = ConcreteRegistrationScheduler(backing: backing)
        _ = s.register(pattern: ContinuedProcessing.identifierPattern) { _, _ in }
        try s.submit(identifier: id, title: "t", subtitle: "s")
        try s.submit(identifier: id + "x", title: "t", subtitle: "s")
        #expect(backing.events.filter { $0.hasPrefix("register") }.count == 2)
    }
}
