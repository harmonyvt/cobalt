import Foundation

// Chat videos (APP-API-CONTRACT 45): a chat thread replayed as an MP4, made by the editor's render containers as a render
// of kind `chat` (`EditRender.kind`). The request's options; the render itself is `EditRender`.

/// `shape`: 1080x1920 (the server's default), 1920x1080, 1080x1080.
public enum ChatVideoShape: String, Sendable, CaseIterable, Hashable {
    case portrait, landscape, square
}

/// `theme`: the chat drawn dark (the server's default) or light.
public enum ChatVideoTheme: String, Sendable, CaseIterable, Hashable {
    case dark, light
}

/// The pacing the sheet offers (typing, popping, streaming; the posts' videos always play at 1x). The server takes 0.5...2.
public enum ChatVideoSpeed: Double, Sendable, CaseIterable, Hashable {
    case slow = 0.75
    case normal = 1
    case fast = 1.5
}

/// What the "make video" sheet asks for.
public struct ChatVideoOptions: Sendable, Equatable {
    public var shape: ChatVideoShape
    public var theme: ChatVideoTheme
    public var speed: ChatVideoSpeed
    /// Only from this message on (a message's "make video from here"); nil: the whole thread.
    public var from: String?
    /// One Hark message when it ends (31.11).
    public var notify: Bool

    public init(
        shape: ChatVideoShape = .portrait, theme: ChatVideoTheme = .dark, speed: ChatVideoSpeed = .normal, from: String? = nil,
        notify: Bool = false
    ) {
        self.shape = shape
        self.theme = theme
        self.speed = speed
        self.from = from
        self.notify = notify
    }
}
