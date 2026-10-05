import Foundation

// The quick share card (CONTRACT-SHARE-QUICK.md). Sharing a link shows a small card instead of the
// full sheet; the card hands the save to the server the moment the server holds it, then closes by
// itself. The full sheet is still there: the setting "show the full share sheet", the card's expand
// control, and every run the card cannot finish on its own (a file, a picker, plain cobalt).
//
// The types compile everywhere (the logic lives in `ShareCore`, which the Mac test run covers);
// `ShareModel` (iOS only) forwards them.

/// Where the quick card is.
public enum QuickShare: Sendable, Equatable {
    /// The full sheet from the start: the setting is on, or this sheet was built without the card.
    case off
    /// The card, waiting for the server to hold the save.
    case working
    /// The server holds the save: the card shows its check for a moment, then closes.
    case holding
    /// The run failed: the card stays and says why (retry, open cobalt, expand).
    case failed(PipelineFailure)
    /// It was the card, now it is the full sheet.
    case expanded(QuickExpand)

    /// The card is on screen (not the full sheet).
    public var showsCard: Bool {
        switch self {
        case .working, .holding, .failed: return true
        case .off, .expanded: return false
        }
    }
}

/// Why the card became the full sheet.
public enum QuickExpand: Sendable, Equatable {
    /// The owner asked (the expand control, a long press).
    case asked
    /// The run needs the sheet: a file (its upload runs inside the extension), a picker, an image,
    /// plain cobalt, a server that does not finish a save unpolled.
    case needsSheet
}

extension Settings {
    /// "show the full share sheet": off by default, so sharing a link shows the quick card. App-group
    /// defaults (key `shareFullSheet`), so the extension reads what the app's settings wrote.
    public var shareFullSheet: Bool {
        get {
            access(keyPath: \.shareFullSheet)
            return defaults.object(forKey: "shareFullSheet") as? Bool ?? false
        }
        set { withMutation(keyPath: \.shareFullSheet) { defaults.set(newValue, forKey: "shareFullSheet") } }
    }
}
