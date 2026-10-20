import Foundation

// The queue tab's actions (apple/CONTRACT.md section 12). The UI calls these; each goes to the store that owns the work.

extension AppModel {
    /// One action on one row of the queue tab: `open` goes where the work lives (this model's tabs and focus); cancel,
    /// retry and dismiss go to the owner of the work (`UnifiedQueue.perform`).
    public func perform(_ action: QueueAction, on item: QueueItem) async {
        if action == .open {
            open(item)
        } else if let render = item.editRender, action == .cancel {
            // an editor render: the editor's own cancel (`DELETE /edits/renders/<id>`), then the snapshot is read again
            try? await editor.cancel(render: render.id)
            await unifiedQueue.refresh()
        } else if let render = item.editRender, action == .retry {
            // "try again": the project opens with the render confirm up
            queueShown = false
            await openEdit(render.projectID, confirmRender: true)
        } else {
            await unifiedQueue.perform(action, on: item)
        }
    }

    /// Shows the row's work: a job in focus on the save tab, a finished media's detail, the library, Settings.
    public func open(_ item: QueueItem) {
        guard let destination = item.destination else { return }
        queueShown = false                              // iPhone and iPad: the queue sheet gives way to where the work lives
        switch destination {
        case .job(let id):
            guard queue.job(id) != nil else { return }
            queue.focus(id)
            selectedTab = .save
        case .media(let mediaID):
            selectedTab = .save
            requestedMediaID = mediaID
        case .library:
            selectedTab = capabilities.library ? .library : .save
        case .settings:
            selectedTab = .settings
        case .edit(let projectID):
            Task { await openEdit(projectID, confirmRender: false) }
        }
    }

    /// Opens a project in the editor (the presenters show it while `editor.session` is set); `confirmRender` raises the render
    /// confirmation once it is open.
    func openEdit(_ projectID: String, confirmRender: Bool) async {
        guard editor.isAvailable else { return }
        do { try await editor.open(projectID) } catch { return }
        if confirmRender { editor.session?.renderConfirmRequested = true }
    }
}
