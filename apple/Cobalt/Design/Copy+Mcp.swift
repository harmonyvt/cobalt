import Foundation

/// Copy for settings > mcp (APP-API-CONTRACT 35.5): how agents reach the capystore MCP. All lowercase, all new.
extension Copy {
    enum Mcp {
        static let group = "mcp"
        static let how = "how agents connect"
        static let off = "off"
        static let offDetail = "no agent can connect"
        static let publicURL = "public url"
        static let publicDetail = "key in the header"
        static let privateLink = "private link"
        static let privateDetail = "key in the link · claude.ai"

        static func footer(_ mode: McpSettingsModeName) -> String {
            switch mode {
            case .off: return "mcp is off. both urls answer \u{201C}not found\u{201D}."
            case .public: return "for claude code and apps that send a header. claude.ai needs a private link."
            case .private: return "the public url is off while the private link is on. the link is shown once: lost it? rotate; the old one stops at once."
            }
        }

        static let url = "url"
        static let copyURL = "copy url"
        static let copied = "copied"
        static let header = "send a client key as Authorization: Bearer <key>."
        static let link = "link"
        static let lastUsed = "last used"
        static let never = "not yet"
        static let usedBy = "by"
        static let requestsToday = "requests today"
        static let made = "made"
        static let rotate = "rotate link"
        static let working = "working…"
        static let loadFailed = "couldn't load the mcp settings."
        static let retry = "try again"
        static let failed = "that didn't work. try again."
        static let notPrivate = "the private link is off. turn it on first."

        static let confirmPrivateTitle = "turn on the private link?"
        static let confirmPrivateBody = "you get a link with a key inside it for claude.ai. the public url stops answering."
        static let confirmPrivateAction = "turn on private link"
        static let confirmLeaveTitle = "go back to the public url?"
        static let confirmLeaveBody = "the private link stops working now and can't come back."
        static let confirmLeaveAction = "use public url"
        static let confirmPublicTitle = "turn on the public url?"
        static let confirmPublicBody = "agents connect with a client key in the header."
        static let confirmPublicAction = "turn on"
        static let confirmOffTitle = "turn mcp off?"
        static let confirmOffBody = "no agent can connect through either url."
        static let confirmOffAction = "turn off"
        static let confirmRotateTitle = "rotate the private link?"
        static let confirmRotateBody = "the old link stops working right away. paste the new one into claude.ai."
        static let confirmRotateAction = "rotate link"

        static let revealTitle = "your private link"
        static let revealTitleNew = "your new private link"
        static let revealWarning = "copy it now. it won't be shown again, and anyone with it can use your library."
        static let copyLink = "copy link"
        static let done = "done"
        static let cancel = "cancel"
        static let steps = "in claude.ai: settings › connectors › add custom connector, name it capystore, paste the link, leave oauth empty."
    }
}

/// The three modes by name, so the copy does not need CobaltKit's type (this folder is shared with the widget).
enum McpSettingsModeName {
    case off, `public`, `private`
}
