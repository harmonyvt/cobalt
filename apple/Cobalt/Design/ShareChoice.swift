import CobaltKit
import SwiftUI

// "share" asks what to share (Harmony, 2026-11-23): the file itself, the share link (the rich page on the share host that
// unfurls in Discord, iMessage and X) or the direct link (the file's own URL: the media domain's for a public file, the
// bytes under its private link for a private one). The button opens a short menu with the ones that exist; with only
// one there is no menu and the button does that one, as before.

/// What a share hands the system sheet.
enum ShareForm: Hashable, CaseIterable {
    case file, link, direct

    var title: String {
        switch self {
        case .file: Copy.ShareChoice.file
        case .link: Copy.ShareChoice.link
        case .direct: Copy.ShareChoice.direct
        }
    }

    /// The words where the item stands alone, outside a "share" menu (a flat list of actions).
    var standaloneTitle: String {
        switch self {
        case .file: Copy.ShareChoice.shareFile
        case .link: Copy.ShareChoice.shareLink
        case .direct: Copy.ShareChoice.shareDirect
        }
    }

    var symbol: String {
        switch self {
        case .file: Symbol.ShareChoice.file
        case .link: Symbol.ShareChoice.link
        case .direct: Symbol.ShareChoice.direct
        }
    }
}

/// The ways one file can be shared right now.
struct ShareTargets: Equatable {
    /// The file itself can be sent (it is on this device, or the library can fetch it).
    var file: Bool
    /// The share link: the file's private link while it has one, else its page on the share host.
    var link: URL?
    /// The direct link: the bytes under the private link, else the public file. Nil when it would be `link` again.
    var direct: URL?

    init(file: Bool, link: URL?, direct: URL?) {
        self.file = file
        self.link = link
        self.direct = direct == link ? nil : direct
    }

    /// The forms on offer, in menu order.
    var forms: [ShareForm] {
        var out: [ShareForm] = []
        if file { out.append(.file) }
        if link != nil { out.append(.link) }
        if direct != nil { out.append(.direct) }
        return out
    }

    /// More than one form: the button opens the menu.
    var isChoice: Bool { forms.count > 1 }

    func url(_ form: ShareForm) -> URL? {
        switch form {
        case .file: nil
        case .link: link
        case .direct: direct
        }
    }
}

extension Capabilities {
    /// What a rendition can be shared as. `file`: the caller can send the file itself.
    func shareTargets(for r: Rendition, file: Bool) -> ShareTargets {
        let direct = r.privateURL != nil ? r.privateFileURL : r.publicURL
        return ShareTargets(file: file, link: liveLink(for: r), direct: direct)
    }
}

extension Rendition {
    /// The file is on this device now (the share sheet can take it without a download).
    var isOnDevice: Bool {
        guard let url = local?.fileURL, url.isFileURL else { return false }
        return FileManager.default.fileExists(atPath: url.path)
    }
}

/// The share choices as menu items (inside a context menu or a `Menu`): `share` opening the forms, or the one form alone.
/// The links go straight to the system sheet (`ShareLink`); the file goes through `file`, which fetches it if needed.
struct ShareChoiceMenuItems: View {
    let targets: ShareTargets
    var title = Copy.Media.share
    var symbol = Symbol.Media.share
    /// Sends the file itself. Nil: offer the file only when `fileURL` is set.
    var file: (() -> Void)?
    /// The file on this device, shared directly when `file` is nil.
    var fileURL: URL?

    var body: some View {
        if forms.count > 1 {
            Menu(title, systemImage: symbol) {
                ForEach(forms, id: \.self) { item($0, title: $0.title, symbol: $0.symbol) }
            }
        } else if let only = forms.first {
            item(only, title: title, symbol: symbol)
        }
    }

    private var forms: [ShareForm] {
        targets.forms.filter { $0 != .file || file != nil || fileURL != nil }
    }

    @ViewBuilder
    private func item(_ form: ShareForm, title: String, symbol: String) -> some View {
        if form == .file {
            if let file {
                Button(title, systemImage: symbol, action: file)
            } else if let fileURL {
                ShareLink(item: fileURL) { Label(title, systemImage: symbol) }
            }
        } else if let url = targets.url(form) {
            ShareLink(item: url) { Label(title, systemImage: symbol) }
        }
    }
}

extension Copy {
    enum ShareChoice {
        static let file = "file"
        static let link = "share link"
        static let direct = "direct link"
        static let shareFile = "share file"
        static let shareLink = "share link"
        static let shareDirect = "share direct link"
    }
}

extension Symbol {
    enum ShareChoice {
        static let file = "doc"
        static let link = "text.below.photo"
        static let direct = "link"
    }
}
