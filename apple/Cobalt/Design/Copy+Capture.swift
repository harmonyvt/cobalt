import Foundation

// The capture tab's words (apple 04-PHASE4 4.1, "capture"): the labelled intake controls, the recent saves strip and the
// focus screen's visible secondary-action labels on the phone. The paste, photos and files words themselves are
// `Copy.paste`, `Copy.sourcePhotos` and `Copy.sourceFiles` (the file menu used them); lowercase house copy.

extension Copy {
    enum Capture {
        /// What VoiceOver says for the two intake buttons that used to be one "file" menu.
        static let photosA11y = "add from photos"
        static let filesA11y = "add from files"

        /// The recent saves strip: its header, the way to the whole library, and what a thumbnail opens.
        static let recent = "recent saves"
        static let seeAll = "see all"
        static func openA11y(_ title: String) -> String { "open \(title)" }

        /// The focus screen's link rows: what the small buttons say on the phone, where the full name ("copy share link") would not fit.
        static let copyShort = "copy"
        static let directShort = "direct"
        static let shareShort = "share"

        /// The active job card's VoiceOver name (the stepper inside reads its own steps).
        static let jobA11y = "saving now"
    }
}
