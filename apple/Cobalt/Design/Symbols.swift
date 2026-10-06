import CobaltKit
import SwiftUI

/// The SF Symbols the app uses, one name per meaning, so a button, a row and a menu that say the
/// same thing show the same icon. Icon first, lowercase word after: every control is a `Label`, and
/// an icon-only spot (a toolbar, the close button) keeps the word as its accessibility label.
enum Symbol {
    // tabs
    static let save = "arrow.down.circle"
    static let library = "photo.on.rectangle.angled"
    static let settings = "gearshape"

    // actions
    static let paste = "doc.on.clipboard"
    static let file = "paperclip"
    static let makeWebp = "sparkles"
    static let trim = "timeline.selection"
    static let savePhotos = "photo.badge.arrow.down"
    static let host = "link.badge.plus"
    static let copy = "doc.on.doc"
    static let copyLink = "doc.on.doc"
    static let link = "link"
    static let share = "square.and.arrow.up"
    static let saveAs = "square.and.arrow.down"
    static let delete = "trash"
    static let close = "xmark"
    static let keep = "checkmark"
    static let backToTrim = "arrow.uturn.backward"
    static let retry = "arrow.clockwise"
    static let reset = "arrow.counterclockwise"
    static let openApp = "arrow.up.forward.app"
    static let web = "arrow.up.right.square"

    // jobs alongside (CONTRACT-PARALLEL): the tray, a job in line, stopping one, the review sheet's tick boxes
    static let tray = "rectangle.stack"
    static let queued = "clock"
    static let stop = "stop.circle"
    static let tickOn = "checkmark.square.fill"
    static let tickOff = "square"

    // the focused planet and its file-type badges
    static let publicShare = "link.badge.plus"
    static let convert = "sparkles"
    static let webpBadge = "sparkles"
    static let linkBadge = "link"
    static let soundOn = "speaker.wave.2.fill"
    static let soundOff = "speaker.slash.fill"
    static let typeVideo = "film"
    static let typeImage = "photo"

    // the file circle's menu
    static let sourcePhotos = "photo.on.rectangle"
    static let sourceFiles = "folder"

    // states
    static let error = "exclamationmark.triangle"
    static let done = "checkmark.circle"
    static let checkmark = "checkmark"
    static let lock = "lock"

    // settings rows
    static let api = "globe"
    static let server = "server.rack"
    static let key = "key"
    static let quality = "slider.horizontal.3"
    /// The device the videos are kept on: a laptop on the Mac, a phone elsewhere.
    static var device: String { Platform.isMac ? "laptopcomputer" : "iphone" }
    static let storage = "internaldrive"
    static let haptics = "iphone.radiowaves.left.and.right"
    static let motion = "figure.walk.motion"
    static let notifications = "bell"
    static let inspector = "sidebar.trailing"
    static let width = "arrow.left.and.right"
    static let selection = "scissors"

    // the step rail
    static func step(_ step: Rail.Step) -> String {
        switch step {
        case .fetch: return "arrow.down"
        case .upload: return "arrow.up"
        case .save: return "externaldrive"
        case .read: return "film"
        case .webp: return "sparkles"
        case .host: return "link.badge.plus"
        }
    }
}

extension View {
    /// A bounce on the symbols inside when `value` changes (copy → copied), still under Reduce Motion.
    func symbolBounce<V: Equatable>(on value: V) -> some View {
        modifier(SymbolBounce(value: value))
    }
}

private struct SymbolBounce<V: Equatable>: ViewModifier {
    let value: V
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        if reduceMotion {
            content.contentTransition(.symbolEffect(.replace))
        } else {
            content.symbolEffect(.bounce, value: value).contentTransition(.symbolEffect(.replace))
        }
    }
}
