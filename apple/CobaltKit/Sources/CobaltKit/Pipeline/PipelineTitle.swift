import Foundation

// The title of a run (CONTRACT-LIBRARY2 decisions 4 and 8). Typed before the upload has returned its item
// id, it is held on the run and sent the moment the id is known; typed after, it is sent at once. The same
// title lands on this device's records, the Live Activity and the notify label immediately.

extension Pipeline {
    /// The owner typed (or cleared) a title. `nil`, empty or blank = back to the default. Safe at any state;
    /// ignored once the run was reset (an idle pipeline has no run to name).
    public func setTitle(_ raw: String?) {
        if case .idle = state { return }
        applyTitle(raw)
    }

    /// `setTitle` without the idle guard: a resumed job's `pendingTitle` applies before its first state.
    func applyTitle(_ raw: String?) {
        let cleaned = raw.flatMap(MediaTitle.clean)
        guard cleaned != runTitle else { return }
        let hadTitle = runTitle != nil
        runTitle = cleaned
        titleUnsent = true
        syncStoreTitle(clearing: hadTitle)
        titleChanged()
        sendTitleIfPossible()
    }

    /// The run's title on this device's records of its media (decision 8). A new rendition of a titled media
    /// inherits the media's title in `OfflineStore.add`; this covers the first record of a new media and a
    /// title typed after the media landed. `clearing`: this run had a title before, so an empty one clears it.
    func syncStoreTitle(clearing: Bool = false) {
        guard let media = mediaID else { return }
        guard runTitle != nil || clearing else { return }
        ctx.store.writeTitle(runTitle, media: media)
    }

    /// The label, the Live Activity and a continued-processing subtitle follow the title.
    private func titleChanged() {
        ctx.live?.stateChanged(self)
        // An opt-in the server holds carries the old label: send it again (idempotent, replaces `label`).
        if let sid = sessionID, let source = ctx.notify.registered[sid], let optIn = notifyOptIn {
            ctx.queueNotify(session: sid, optIn, source: source)
        }
        ctx.continued?.pipelineChanged(self)
    }

    /// The server's copy, when the library file the post hangs on is known and the server has titles.
    /// Sent in order behind any earlier title of this run; a failure goes to the queue.
    func sendTitleIfPossible() {
        guard titleUnsent, let item = titleItemID, ctx.capabilities.titles else { return }
        titleUnsent = false
        let title = runTitle
        let client = ctx.client
        let queue = ctx.titles
        let previous = titleChain
        titleChain = Task { @MainActor in
            await previous?.value
            do {
                _ = try await client.setTitle(anchor: item, title)
                queue.remove(itemID: item)                // what an older failure queued is superseded
            } catch {
                if TitleQueue.isFinal(error) {
                    queue.remove(itemID: item)
                } else {
                    queue.enqueue(itemID: item, title: title, now: Date())
                    Telemetry.log(.warn, .net, "title queued", data: Telemetry.errorData(error))
                }
            }
        }
    }

    /// Everything the title chain has sent so far has answered (tests).
    func titlesSettled() async {
        var seen = titleChain
        while let current = seen {
            await current.value
            if titleChain == current { return }
            seen = titleChain
        }
    }

    /// Queued titles go out with a new run, in the background (never awaited by the run).
    func flushTitleQueue() {
        guard ctx.capabilities.titles else { return }
        let client = ctx.client
        let queue = ctx.titles
        Task { await queue.flush(client: client) }
    }

    /// A job from the share sheet, closed before the upload returned its item id: its title waits for the
    /// session, whose link (`upload:<item id>`) names the file.
    func resolveTitleItem(session sid: String) {
        guard titleItemID == nil else { return }
        spawn { p in
            guard let s = try? await p.ctx.client.session(sid, wait: 0), let link = s.link,
                  link.hasPrefix("upload:") else { return }
            let id = String(link.dropFirst("upload:".count))
            guard !id.isEmpty, p.titleItemID == nil else { return }
            p.titleItemID = id
            p.sendTitleIfPossible()
        }
    }

    /// What the notification and the continued-processing subtitle call this work (decision 9), at most
    /// `MediaTitle.notifyLength` code points.
    var resolvedTitle: MediaTitle.Resolved {
        var service: String?
        var ref: String?
        var fileName: String? = media?.name
        switch input {
        case .link(let info): service = info.service; ref = info.ref
        case .file(let name, _, _): if fileName == nil { fileName = name }
        case nil: break
        }
        return MediaTitle.resolve(custom: runTitle, service: service, ref: ref, fileName: fileName)
    }
}
