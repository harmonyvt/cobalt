import Foundation

// "post frame" on save (APP-API-CONTRACT 52.6): once a link's save is ready on the server, the app may ask for a framed copy
// of the saved video. The pipeline only reports the save; `AppModel.postFrameAfterSave` decides.
extension Pipeline {
    /// A single video saved from a web page (not a gallery, not a picture, not an upload) with its library row: reported to
    /// `PipelineContext.postFrameAfterSave`.
    func notePostFrameSave(_ s: StudioSession) {
        guard let report = ctx.postFrameAfterSave, let target = Self.postFrameTarget(s) else { return }
        report(target.itemID, target.link)
    }

    /// The item and page a ready session would frame; nil for a gallery, a picture, an upload or a session without its row.
    nonisolated static func postFrameTarget(_ s: StudioSession) -> (itemID: String, link: URL)? {
        guard s.status == .ready, s.items.isEmpty, let item = s.itemID, !item.isEmpty,
              let duration = s.duration, duration > 0,
              let raw = s.link, !raw.hasPrefix("upload:"), let link = URL(string: raw),
              let scheme = link.scheme?.lowercased(), scheme == "https" || scheme == "http" else { return nil }
        return (item, link)
    }
}
