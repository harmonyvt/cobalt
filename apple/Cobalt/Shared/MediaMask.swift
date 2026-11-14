import SwiftUI
#if canImport(PostHog) && os(iOS)
@preconcurrency import PostHog
#endif

extension View {
    /// Hides this view in session replays (a solid block in the recording). Every view that draws the owner's media wears
    /// it (APP-API-CONTRACT 58): thumbnails, players, the photo and video heroes, the editor, emotes. A no-op on the Mac
    /// (PostHog has no Mac replay) and in the extensions, which do not link PostHog.
    @ViewBuilder
    func mediaMask() -> some View {
        #if canImport(PostHog) && os(iOS)
        self.postHogMask()
        #else
        self
        #endif
    }
}
