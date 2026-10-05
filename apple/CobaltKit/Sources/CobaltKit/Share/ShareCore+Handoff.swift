import Foundation

// The original follows the sheet out (CONTRACT-SYNC.md decision 6). When the sheet closes for any
// reason (countdown, button, close, swipe), and the run has a studio session, "keep videos on this
// iphone" is on, the store has no original for that session and this is not a "trim in cobalt"
// handoff, the download goes to a background URLSession. It is started here, before the sheet is
// completed (the extension is still visible, so the task is not discretionary), and recorded in the
// app group's `PendingOriginals`.
//
// This also fixes the bug the contract names: closing at "ready" used to call `pipeline.cancel()`,
// which cancels the keep download that was still running.

extension ShareCore {
    func handOffOriginal() {
        guard let originals = ctx.originals, let sid = pipeline.sessionID, capabilities.studio,
              ctx.settings.keepVideosOnDevice, pipeline.stored == nil
        else { return }
        if case .file = pipeline.input { return }                    // the upload runs in the extension; no original to fetch
        let saveReady: Bool
        switch pipeline.state {
        case .fetching, .saving: saveReady = false                   // the server holds the save; the task waits for it
        case .reading, .ready, .rendering, .done: saveReady = true
        default: return                                              // idle, picker, image, failed: nothing was saved
        }
        if ctx.store.videos.contains(where: { $0.kind == .original && $0.sessionID == sid }) { return }
        var link: URL?
        if case .link(let info) = pipeline.input { link = info.url }
        originals.handOff(
            session: sid, link: link, media: pipeline.media, sourceURL: ctx.client.sourceURL(session: sid),
            sourceWait: capabilities.sourceWait, saveReady: saveReady)
    }
}
