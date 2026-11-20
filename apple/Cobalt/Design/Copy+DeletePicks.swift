import CobaltKit
import Foundation

/// Copy for the select panel's trash circle and its sheet (`LibraryDeleteSheet`). All lowercase.
extension Copy {
    enum DeletePicks {
        static let delete = "delete"                                       // the circle's name (hold, VoiceOver)
        static let deleteHint = "deletes the picks for everyone. you choose the files first."
        static func title(_ posts: Int) -> String { posts == 1 ? "delete this?" : "delete \(posts)?" }
        static let message = "deleted for everyone. links you shared to them stop working. this can't be undone."
        static func holdButton(_ files: Int) -> String { files == 1 ? "hold to delete 1 file" : "hold to delete \(files) files" }
        static func linksLose(_ n: Int) -> String { n == 1 ? "1 share link loses a file" : "\(n) share links lose a file" }
        static func collectionsShrink(_ n: Int) -> String { n == 1 ? "1 collection gets smaller" : "\(n) collections get smaller" }
        static let everything = "everything"
        static let choose = "choose files"
        static let videoGoesWithEverything = "the video itself only goes with everything."
        static func line(_ plan: DeletePick.Plan, files: Int, of choosable: Int) -> String {
            switch plan {
            case .everything: "everything"
            case .nothing: "kept"
            case .keepOneItem: "keep one photo, or tick everything"
            case .files: "\(files) of \(choosable) \(choosable == 1 ? "file" : "files")"
            }
        }
        static func button(_ files: Int) -> String {
            files == 0 ? "nothing ticked" : "delete \(files) \(files == 1 ? "file" : "files")"
        }
        static func deleted(_ posts: Int) -> String { posts == 1 ? "deleted." : "deleted \(posts)." }
        static func someFailed(_ failed: Int) -> String {
            "couldn't delete \(failed). \(failed == 1 ? "it is" : "they are") still there."
        }
    }
}
