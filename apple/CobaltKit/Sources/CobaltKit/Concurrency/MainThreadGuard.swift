import Foundation

/// Cheap tripwires for the 8.17 rule that the main thread is display-only (apple/ARCHITECTURE.md). An engine function
/// that reads the disk, decodes JSON or decodes an image starts with `MainThreadGuard.assertOffMain()`; a debug build
/// stops right there when someone calls it from the main thread, so the mistake shows up on the developer's desk
/// instead of as a 400 ms frame on a phone. Release builds compile both calls down to nothing.
///
/// Callable from any isolation: the functions are synchronous and nonisolated, and only read `Thread.isMainThread`.
public enum MainThreadGuard {
    /// Stops a debug build when called on the main thread. `what` names the work in the failure message; it defaults
    /// to the calling function.
    @inline(__always)
    public nonisolated static func assertOffMain(
        _ what: StaticString = #function, file: StaticString = #fileID, line: UInt = #line
    ) {
        #if DEBUG
        if isViolation(expectMain: false, onMain: Thread.isMainThread) {
            assertionFailure("\(what) ran on the main thread; it belongs in an engine (apple/ARCHITECTURE.md)",
                             file: file, line: line)
        }
        #endif
    }

    /// Stops a debug build when called off the main thread: for code that must only ever touch UI state.
    @inline(__always)
    public nonisolated static func assertOnMain(
        _ what: StaticString = #function, file: StaticString = #fileID, line: UInt = #line
    ) {
        #if DEBUG
        if isViolation(expectMain: true, onMain: Thread.isMainThread) {
            assertionFailure("\(what) ran off the main thread", file: file, line: line)
        }
        #endif
    }

    /// Whether the guards trap in this build: true in debug, false in release.
    public nonisolated static var isEnforced: Bool {
        #if DEBUG
        true
        #else
        false
        #endif
    }

    /// The one decision both guards make, apart so tests can check it without trapping.
    nonisolated static func isViolation(expectMain: Bool, onMain: Bool) -> Bool {
        expectMain != onMain
    }
}
