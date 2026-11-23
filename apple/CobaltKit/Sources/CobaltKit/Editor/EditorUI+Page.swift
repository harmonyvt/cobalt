import Foundation

extension EditorUI.Page {
    /// The page the inspector actually shows (apple/CONTRACT-EDITOR.md 15.1): `ui.page` as a tool or a menu set it, made to fit
    /// what is selected. Nothing selected is the project page; a main clip has the `clip` page and a layer (a clip above lane 0)
    /// the `layer` page, whichever the stored page said; a page that needs a clip falls back to the project when there is none;
    /// an open effects menu is the `effects` page; the Mac's library stays the library.
    public func resolved(selection: EditSession.Selection, effectsOpen: Bool) -> EditorUI.Page {
        if self == .library { return .library }
        if effectsOpen { return .effects }
        switch selection {
        case .none:
            return .project
        case .main:
            switch self {
            case .project, .layer, .effects, .library: return .clip
            case .clip, .sound, .speed, .crop, .trim: return self
            }
        case .overlay:
            switch self {
            case .project, .clip, .speed, .crop, .effects, .library: return .layer
            case .layer, .sound, .trim: return self
            }
        }
    }
}
