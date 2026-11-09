import Foundation

// Post frames on this device (APP-API-CONTRACT 52.6): the "post frame" switch on save, remembered per site, and the look the
// sheet opens with. App-group defaults, so the share sheet reads the same choices.
extension Settings {
    nonisolated static let postFrameSaveKey = "save.postFrame"
    nonisolated static let postFrameLookKey = "postFrame.look"
    nonisolated static let postFrameAskedKey = "postFrame.asked"

    /// "post frame" on save, by site (`PostFrameStyle.rawValue`): off unless the owner turned it on for that site.
    public var postFrameOnSave: [String: PostFrameSaveChoice] {
        get {
            access(keyPath: \.postFrameOnSave)
            guard let data = defaults.data(forKey: Settings.postFrameSaveKey),
                  let choices = try? JSONDecoder().decode([String: PostFrameSaveChoice].self, from: data) else { return [:] }
            return choices
        }
        set {
            withMutation(keyPath: \.postFrameOnSave) {
                if let data = try? JSONEncoder().encode(newValue) { defaults.set(data, forKey: Settings.postFrameSaveKey) }
            }
        }
    }

    /// The switch and look for one site (off, dark, when never set).
    public func postFrameSaveChoice(for style: PostFrameStyle) -> PostFrameSaveChoice {
        postFrameOnSave[style.rawValue] ?? PostFrameSaveChoice()
    }

    public func setPostFrameSaveChoice(_ choice: PostFrameSaveChoice, for style: PostFrameStyle) {
        var all = postFrameOnSave
        all[style.rawValue] = choice
        postFrameOnSave = all
    }

    /// The look and size the post-frame sheet used last; the default look until the first framed copy.
    public var postFrameLook: PostFrameLook {
        get {
            access(keyPath: \.postFrameLook)
            guard let data = defaults.data(forKey: Settings.postFrameLookKey),
                  let look = try? JSONDecoder().decode(PostFrameLook.self, from: data) else { return PostFrameLook() }
            return look
        }
        set {
            withMutation(keyPath: \.postFrameLook) {
                if let data = try? JSONEncoder().encode(newValue) { defaults.set(data, forKey: Settings.postFrameLookKey) }
            }
        }
    }

    /// The saved items a framed copy was already asked for on save (newest last, at most 200), so a resumed save never asks
    /// twice. Not observed: nothing on screen reads it.
    func postFrameAsked(_ itemID: String) -> Bool {
        (defaults.stringArray(forKey: Settings.postFrameAskedKey) ?? []).contains(itemID)
    }

    func notePostFrameAsked(_ itemID: String) {
        var ids = defaults.stringArray(forKey: Settings.postFrameAskedKey) ?? []
        guard !ids.contains(itemID) else { return }
        ids.append(itemID)
        if ids.count > 200 { ids.removeFirst(ids.count - 200) }
        defaults.set(ids, forKey: Settings.postFrameAskedKey)
    }
}
