import Foundation

// "Close without throwing work away" (`Pipeline.detach()`). The visible pipeline goes back to
// `.idle` at once; whatever was in flight for its run is carried on by a hidden `Pipeline` (the
// "detached run") owned by `ctx.background`. The detached run is the same run: it keeps the run's
// `SharedJob` record and Live Activity id, so the record and the activity live until the work
// completes and end the way an attached run's do.

extension Pipeline {
    /// Something of the current run is still on the server or being downloaded, and `reset()` would
    /// lose its result: a render, a host-original publish, the keep-original download.
    var hasDetachableWork: Bool {
        if case .rendering = state, sessionID != nil { return true }
        if hosting == .working, hostRequest != nil { return true }
        if keepRequest != nil, sessionID != nil { return true }
        return false
    }

    /// Closes the run on screen without throwing its work away. If anything is in flight for the
    /// run (render polling, a host-original publish, the keep-original download), a background run
    /// finishes it: a finished webp joins `store.videos` exactly as `.done` does, a finished publish
    /// is recorded on the stored original (`StoredVideo.publicURL`), the keep-original download lands
    /// in the store, and a local notification "your webp is ready" is posted on completion if the app
    /// is not active. The visible pipeline is `.idle` with a new `runID` either way; with nothing in
    /// flight this is `reset()`.
    public func detach() {
        guard !isDetached, ctx.background.allowsDetach, hasDetachableWork else {
            reset()
            return
        }
        ctx.notificationsNowUseful()        // work outlives the screen: the first moment a notification matters
        // With the notify bridge the server speaks for a save or render that is still going, so the
        // owner hears even if this process is suspended before it can post anything itself.
        if ctx.capabilities.notifyBridge, let sid = sessionID, let optIn = notifyOptIn {
            ctx.queueNotify(session: sid, optIn, source: .detached)
        }
        let run = Pipeline(context: ctx)
        // The Live Activity's run moves to the background run first, so its events are routed there.
        ctx.live?.runDetached(from: self, to: run)
        run.adoptDetached(from: self)
        // The visible pipeline gives up everything the background run now owns, so starting over
        // neither cancels the work nor removes its `SharedJob`.
        jobRecordID = UUID()
        takenOverJobID = nil
        begin(input: nil)
        setState(.idle)
        ctx.background.add(run)
        run.startDetachedWork()
    }

    /// Takes over the run `old` was showing: its facts, its record and Live ids, its in-flight calls.
    private func adoptDetached(from old: Pipeline) {
        isDetached = true
        input = old.input
        media = old.media
        trim = old.trim
        crop = old.crop
        origin = old.origin
        sessionID = old.sessionID
        hostedURL = old.hostedURL
        hosting = old.hosting
        result = old.result
        stored = old.stored
        uploadedItemID = old.uploadedItemID
        titleItemID = old.titleItemID
        titleUnsent = old.titleUnsent
        runTitle = old.runTitle
        titleChain = old.titleChain
        renderJobID = old.renderJobID
        localFile = old.localFile
        errorPhase = old.errorPhase
        runStart = old.runStart
        renderStart = old.renderStart
        targetMediaID = old.targetMediaID
        lastRenderRequest = old.lastRenderRequest
        lastRailIndex = old.lastRailIndex
        jobRecordID = old.jobRecordID
        liveRunID = old.liveRunID
        takenOverJobID = old.takenOverJobID
        for id in old.pinnedStoreIDs { pinStored(id) }       // the offline limit keeps off them until the run ends
        state = old.state
        stateLog = [old.state]

        renderRequest = old.renderRequest
        old.renderRequest = nil
        hostRequest = old.hostRequest
        old.hostRequest = nil
        keepRequest = old.keepRequest
        old.keepRequest = nil
    }

    /// Starts what the visible run had in flight, then watches for all of it to finish.
    private func startDetachedWork() {
        if case .rendering = state, let sid = sessionID {
            detachedRendering = true
            errorPhase = .rendering
            let since = renderStart ?? ctx.clock.now()
            let job = renderJobID
            launch { try await $0.runRender(sid, existingJob: job, since: since) }
        }
        if let request = hostRequest {
            hosting = .working
            spawn { p in await p.finishHostOriginal(request) }
        }
        if let request = keepRequest, let sid = sessionID {
            spawn { p in await p.finishKeepOriginal(request, session: sid) }
        }
        detachedCoordinator = Task {
            await self.mainTask?.value
            var i = 0
            while i < self.sideTasks.count {
                await self.sideTasks[i].value
                i += 1
            }
            self.settleDetached()
        }
    }

    /// Everything the background run had to do is done (or was cancelled): its record and Live
    /// Activity end, its pins go, and a finished webp is announced if the app is not active.
    func settleDetached() {
        guard isDetached, !detachedSettled else { return }
        detachedSettled = true
        releaseStorePins()
        settleJobRecords()
        ctx.live?.detachedSettled(self)
        var announce = false
        if detachedRendering, case .done = state { announce = true }
        ctx.background.finished(self, announceWebp: announce)
        // Done here, so the server need not say it too.
        if let sid = sessionID, ctx.notify.mightHold(sid) {
            ctx.queueCancelNotify(session: sid)
        }
        ctx.continued?.pipelineChanged(self)
    }

    /// The work belonged to a server the app no longer talks to (or the app is shutting down).
    func cancelDetached() {
        guard isDetached else { return }
        cancelRunning()
        settleDetached()
    }
}
