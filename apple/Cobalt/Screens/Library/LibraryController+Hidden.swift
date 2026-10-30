import CobaltKit
import SwiftUI

/// A `status…` choice that asks first: hiding (their links stop working for good) and making public (anyone with the
/// link can open them). The confirm dialog reads it; the posts are the ones picked when the choice was made.
struct StatusAsk: Identifiable, Equatable {
    let id = UUID()
    let status: PostStatus
    let posts: [LibraryPost]

    static func == (a: StatusAsk, b: StatusAsk) -> Bool { a.id == b.id }
}

/// The hidden album's lock and the bulk status change (APP-API-CONTRACT 37.7).
///
/// **The lock.** Each time the album is opened, and `Settings.hiddenLock` is on, the grid is replaced by a locked card
/// and the system sheet (`HiddenLock`) is asked for. "Unlocked" is `hiddenUnlocked`, in memory on the screen's
/// controller, and `relockHidden()` drops it when: the album is left (`showingHidden` goes false), the app goes to the
/// background, the library tab is left, or the screen goes away. Nothing is stored.
extension LibraryController {
    // MARK: the lock

    /// The album is open and the owner has not passed the lock yet: show the locked card, no rows.
    var hiddenLocked: Bool {
        model.capabilities.hidden && library.showingHidden && model.settings.hiddenLock && !hiddenUnlocked
    }

    /// The album is open and showing posts.
    var albumOpen: Bool {
        model.capabilities.hidden && library.showingHidden && !hiddenLocked
    }

    /// Asks the system. Does nothing while a sheet is up or when the album is not locked.
    func unlockHidden() async {
        guard hiddenLocked, !unlocking else { return }
        unlocking = true
        lockPrompted = true
        let epoch = lockEpoch
        lockMethod = HiddenLock.method()
        let outcome = await HiddenLock.authenticate(reason: Copy.HiddenAlbum.reason)
        unlocking = false
        // the album was left, or the app went to the background, while the sheet was up
        guard epoch == lockEpoch, library.showingHidden else { return }
        switch outcome {
        case .unlocked:
            lockFailed = false
            albumPending = true
            hiddenUnlocked = true
        case .cancelled:
            lockFailed = false
        case .failed:
            lockFailed = true
        }
    }

    /// The locked card appeared or the app came back: asks once per lock without the owner tapping.
    func promptIfNeeded() {
        guard hiddenLocked, !unlocking, !lockPrompted else { return }
        Task {
            // a beat for the app to be in front: the system refuses to show its sheet while the scene is still inactive
            try? await Task.sleep(for: .milliseconds(400))
            await unlockHidden()
        }
    }

    /// Drops the unlock. While the album is open, nothing of it stays up: select mode ends, the pushed detail and the
    /// inspector close, so a hidden post is not left on screen behind the locked card.
    func relockHidden() {
        lockEpoch += 1
        hiddenUnlocked = false
        lockPrompted = false
        lockFailed = false
        albumPending = false
        // with the lock off nothing is dropped: the album stays as the owner left it
        guard library.showingHidden, model.settings.hiddenLock else { return }
        closeAlbumState()
    }

    /// `showingHidden` changed (the chip, settings › open hidden, a kind chip). Always starts locked.
    func hiddenAlbumChanged(open: Bool) {
        lockEpoch += 1
        hiddenUnlocked = false
        lockPrompted = false
        lockFailed = false
        albumPending = false
        closeAlbumState()
        guard open else { return }
        // the kind chips are off while the album is open and its rows follow `kindFilter`: start from everything
        if library.kindFilter != .all { library.kindFilter = .all }
        if !model.settings.hiddenLock { albumPending = true }
        lockMethod = HiddenLock.method()
        promptIfNeeded()
    }

    private func closeAlbumState() {
        endSelecting()
        asking = nil
        opened = nil
        selection = nil
        lit = nil
        // every sheet or dialog that holds a post of the album
        combining = nil
        renaming = nil
        deleting = nil
        makingPrivate = nil
        reveal = nil
        showingSkyMap = false
        peek = nil
    }

    // MARK: a post that is hidden where it can't be shown

    /// The post is hidden (the device knows it) and the unlocked album is not what is on screen: it is shown nowhere.
    func hiddenOutsideAlbum(_ id: String?) -> Bool {
        guard let id, !albumOpen else { return false }
        return library.hiddenPosts.contains { $0.id == id } || model.settings.hiddenIndex.contains(post: id)
    }

    /// A post became hidden (from its detail, a menu, another device's sync), or the album closed or locked: the pushed
    /// detail, the inspector and every sheet or dialog holding that post close. The detail of a post hidden from itself
    /// shows its status line first (the shell's), then goes.
    func closeHiddenDetails() {
        if hiddenOutsideAlbum(selection) { selection = nil }
        if hiddenOutsideAlbum(opened?.item.post?.id) { opened = nil }
        if hiddenOutsideAlbum(combining?.post?.id) { combining = nil }
        if hiddenOutsideAlbum(renaming?.post?.id) { renaming = nil }
        if hiddenOutsideAlbum(deleting?.post?.id) { deleting = nil }
        if hiddenOutsideAlbum(makingPrivate?.post?.id) { makingPrivate = nil }
        if let ask = asking, ask.status == .public, ask.posts.contains(where: { hiddenOutsideAlbum($0.id) }) { asking = nil }
        if hiddenOutsideAlbum(peek?.item.post?.id) { peek = nil }
    }

    /// The album's first page, once it is open (unlocked, or the lock is off).
    func loadAlbum() async {
        guard albumOpen else { return }
        albumPending = true
        await library.loadHidden()
        albumPending = false
    }

    // MARK: status…

    /// The picked posts on screen as the library holds them, in the order they were ticked.
    func pickedPosts(_ rows: [LibraryRow]) -> [LibraryPost] {
        pickedRows(rows).compactMap { $0.item.post }
    }

    /// The `status…` menu's pick, or `unhide`: hiding and making public ask first, the rest go at once.
    func chooseStatus(_ status: PostStatus, posts: [LibraryPost]) {
        guard model.capabilities.hidden, !posts.isEmpty, !library.statusInFlight, !changingStatus else { return }
        switch status {
        case .hidden, .public:
            asking = StatusAsk(status: status, posts: posts)
        case .off, .private:
            applyStatus(status, posts: posts)
        }
    }

    /// The confirm said yes.
    func confirmStatus(_ ask: StatusAsk) {
        asking = nil
        applyStatus(ask.status, posts: ask.posts)
    }

    /// One `setStatus` call for the posts, said in the shell's status line. Select mode ends once some changed.
    func applyStatus(_ status: PostStatus, posts: [LibraryPost]) {
        guard !posts.isEmpty, !library.statusInFlight, !changingStatus else { return }
        changingStatus = true
        let fromAlbum = library.showingHidden
        Task {
            let outcome = await library.setStatus(status, posts: posts)
            changingStatus = false
            var parts: [String] = []
            // posts the server refused, and (apart) posts that took it with a file the server could not switch
            let fileIDs = Set(outcome.fileFailures.map(\.id))
            let filePosts = posts.filter { fileIDs.contains($0.id) || $0.files.contains { fileIDs.contains($0.id) } }.count
            if outcome.changed > 0 { parts.append(Copy.HiddenAlbum.done(status, count: outcome.changed, fromAlbum: fromAlbum)) }
            if !outcome.failed.isEmpty { parts.append(Copy.HiddenAlbum.failed(outcome.failed.count)) }
            if filePosts > 0 { parts.append(Copy.HiddenAlbum.filesFailed(filePosts)) }
            if !parts.isEmpty { showStatus(parts.joined(separator: " · ")) }
            switch (outcome.changed > 0, outcome.failed.isEmpty && filePosts == 0) {
            case (true, true): doneTick += 1
            case (true, false): warnTick += 1
            case (false, false): failTick += 1
            case (false, true): break
            }
            if outcome.changed > 0 {
                withAnimation(Motion.rows) { endSelecting() }
            }
        }
    }

    /// The posts a context menu acts on: the clicked row, plus the rest of a table selection it is part of.
    func statusTargets(_ row: LibraryRow, also others: [LibraryRow]) -> [LibraryPost] {
        let rows = others.contains(where: { $0.id == row.id }) ? others : [row]
        return rows.compactMap { $0.item.post }
    }
}
