import CobaltKit
import SwiftUI

// "copy share" and "copy direct" (Harmony, 2026-10-28): every button that copied one public file's link is two
// side by side. Share is the rich link page (`share_base_url`, APP-API-CONTRACT 22) that unfurls in Discord,
// iMessage and X, and stays the prominent one; direct is the file's own URL on the media domain. A server without
// link pages, or a URL that is not one of its public files, has only the one link: the old single button stays.

/// Which of a public file's two links to copy.
enum LinkForm: Hashable, CaseIterable {
    case share, direct

    var copyTitle: String { self == .share ? Copy.LinkPair.copyShare : Copy.LinkPair.copyDirect }
    /// The menu's words: a menu item stands alone, so it names the link.
    var menuTitle: String { self == .share ? Copy.LinkPair.copyShareLink : Copy.LinkPair.copyDirectLink }
    var symbol: String { self == .share ? Symbol.LinkPair.share : Symbol.LinkPair.direct }
}

extension Copy {
    enum LinkPair {
        static let copyShare = "copy share"
        static let copyDirect = "copy direct"
        static let copyShareLink = "copy share link"
        static let copyDirectLink = "copy direct link"
        static let shareA11y = "copy share link: the preview page that unfurls in chats"
        static let directA11y = "copy direct link: the file itself"
        static let copyAllShare = "copy all share"
        static let copyAllDirect = "copy all direct"
        static let allLinks = "all links"
        static let photoLink = "photo link"
        static let webpLink = "webp link"
        static let videoLink = "video link"
    }
}

extension Symbol {
    enum LinkPair {
        static let share = "doc.on.doc"
        static let direct = "link"
    }
}

extension Capabilities {
    /// The URL to copy for a public file in one form: its link page, or the file itself.
    func link(for url: URL, _ form: LinkForm) -> URL { form == .share ? shareLink(for: url) : url }
    /// True when the file has a link page that differs from its own URL, so there is a choice to offer.
    func hasLinkPair(_ url: URL) -> Bool { shareLink(for: url) != url }
}

/// The two copy buttons in a row: share prominent, direct secondary; the one just copied turns green with a
/// checkmark. Stacks when the two do not fit side by side (large text).
struct CopyLinkPair: View {
    /// The form copied a moment ago, if any (it shows "copied").
    let copied: LinkForm?
    var compact = false
    let copy: (LinkForm) -> Void

    var body: some View {
        ButtonRow {
            button(.share)
            button(.direct)
        }
    }

    @ViewBuilder
    private func button(_ form: LinkForm) -> some View {
        let done = copied == form
        let title = done ? Copy.copied : form.copyTitle
        Group {
            if done {
                Button(title, systemImage: Symbol.checkmark) { copy(form) }.buttonStyle(.cobaltDone(compact: compact))
            } else if form == .share {
                Button(title, systemImage: form.symbol) { copy(form) }.buttonStyle(.cobaltPrimary(compact: compact))
            } else {
                Button(title, systemImage: form.symbol) { copy(form) }.buttonStyle(.cobaltSecondary(compact: compact))
            }
        }
        .symbolBounce(on: done)
        .accessibilityLabel(done ? Copy.copied : (form == .share ? Copy.LinkPair.shareA11y : Copy.LinkPair.directA11y))
    }
}

/// Menu items for a file's link: both forms side by side under a header naming the link ("webp link"; a
/// `ControlGroup` lays them out as a row in a context menu), or the one item when the file has no link page.
struct CopyLinkMenuItems: View {
    let url: URL
    let capabilities: Capabilities
    /// The header over the pair ("webp link").
    let name: String
    /// What the single item says when there is no pair ("copy webp link").
    let single: String
    let copy: (URL, LinkForm) -> Void

    var body: some View {
        if capabilities.hasLinkPair(url) {
            Section(name) {
                ControlGroup {
                    ForEach(LinkForm.allCases, id: \.self) { form in
                        Button(form.copyTitle, systemImage: form.symbol) { copy(url, form) }
                    }
                }
            }
        } else {
            Button(single, systemImage: Symbol.copyLink) { copy(url, .share) }
        }
    }
}

/// `copy all links` of a gallery: "copy all share" and "copy all direct" side by side under "all links", or the one
/// item on a server without link pages.
struct CopyAllLinksMenuItems: View {
    let capabilities: Capabilities
    let copy: (LinkForm) -> Void

    var body: some View {
        if capabilities.shareBaseURL != nil {
            Section(Copy.LinkPair.allLinks) {
                ControlGroup {
                    Button(Copy.LinkPair.copyAllShare, systemImage: Symbol.LinkPair.share) { copy(.share) }
                    Button(Copy.LinkPair.copyAllDirect, systemImage: Symbol.LinkPair.direct) { copy(.direct) }
                }
            }
        } else {
            Button(Copy.Gallery.copyAllLinks, systemImage: Symbol.Gallery.copyLinks) { copy(.share) }
        }
    }
}
