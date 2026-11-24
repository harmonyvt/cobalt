import Foundation

/// Copy for the settings hub (apple 04-PHASE4 4.1): the four groups the old flat list of sixteen sections was
/// regrouped into, each a page pushed from the hub. All lowercase. Its own file so the regroup never edits
/// `Copy.swift`; the strings of the sections themselves stay where they were.
extension Copy {
    enum SettingsHub {
        static let account = "account & server"
        static let downloads = "downloads & storage"
        static let media = "media & webp"
        static let live = "live & integrations"

        static let accountDetail = "your server, and how this device signs in"
        static let downloadsDetail = "saving, offline copies, photos and library sync"
        static let mediaDetail = "webp quality, post frames, private links and hidden posts"
        static let liveDetail = "live activity, claude and chatgpt, diagnostics and feel"

        /// The group the hub row belongs to, for voiceover: "account & server, your server, and how …".
        static func rowLabel(_ title: String, _ detail: String) -> String { "\(title), \(detail)" }
    }
}
