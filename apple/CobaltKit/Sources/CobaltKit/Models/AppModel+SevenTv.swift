import Foundation

// The bookmarklet's return (APP-API-CONTRACT 57.1): `cobalt-apple://7tv-link?token=<token>`. The app posts the token to
// `POST /7tv/link` and shows the studio tab, whose 7TV card says what came of it (`SevenTvStore.linkOutcome`). The token is
// never logged: log `SevenTvLink.redacted(url)` instead of the link.

extension AppModel {
    /// Handles a `cobalt-apple://7tv-link` link; false for any other link. A link without a token is answered "that isn't a
    /// 7tv token" on the card.
    @discardableResult
    public func openSevenTvLink(_ url: URL) -> Bool {
        guard SevenTvLink.isLink(url) else { return false }
        queueShown = false
        if capabilities.stage || capabilities.kind == .unreachable { selectedTab = .stage }
        let token = SevenTvLink.token(from: url) ?? ""
        Task { await self.sevenTv.link(token: token) }
        return true
    }
}
