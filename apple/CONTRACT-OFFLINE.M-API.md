# CobaltKit API pinned by wave M1 for the M2 lanes (pull and Mac screens)

Written 2026-10-07 by lane M1 (MF, folder = visible root) after it compiled: iOS and macOS builds, zero new warnings, and
`cd apple/CobaltKit && swift test` green apart from the timing flakes named in the report. This is `CONTRACT-OFFLINE.md`
section 13.14 **as built**; where it differs from 13.14 the difference is marked **DEVIATION**. Lines read from the worktree at
`d7ac30dac` plus the M1 diff. M2 lanes build against exactly this and change it only by asking.

---

## 1. Store (`Store/OfflineFolder.swift`, `OfflineStore.swift`, `OfflineFolderStore.swift`)

```swift
public enum AddOrigin: Sendable, Equatable { case save, keepOffline, adopted, migrated, pulled }   // `.pulled` is new; P's landing uses it
public enum VisibleRootMode: Sendable, Equatable { case documents, macFolder }
public enum RootState: Sendable, Equatable {
    case ready, unreachable(path: String), notAllowed(path: String), wrongFolder(path: String)
}

extension OfflineStore {                                    // @MainActor @Observable
    public internal(set) var visibleRoot: URL?              // DEVIATION: `internal(set)`, not `private(set)` (the swap lives in an extension in another file); nobody outside CobaltKit can write it
    public let rootMode: VisibleRootMode
    public internal(set) var rootState: RootState           // observable; `.ready` always in `.documents`
    public internal(set) var rootDiskFull: Bool             // new: a move into the root failed for lack of space; cleared by the next move that works
    public internal(set) var isAdopting: Bool               // new: FolderAdoption is running
    @discardableResult public func replaceMade(_ id: String) async -> Bool
    // unchanged and still the P lane's to call:
    public func add(file:kind:media:sessionID:link:remoteURL:move:publicURL:mediaID:clip:keep:createdAt:origin:role:itemIndex:madeFrom:madeSpec:libraryID:postItems:) async throws -> StoredVideo
    public func attach(file:to:move:keep:origin:) async throws -> StoredVideo
    @discardableResult public func setKeep(_ keep: Bool, ids: [String]) async -> [String]
    @discardableResult public func removeOfflineCopy(_ id: String) async -> Bool
}
```

* **Init (internal, for tests and previews):** `OfflineStore.init(root:tools:defaults:now:visibleRoot:ops:syncDirectory:sharedWithApp:rootMode:rootProvider:folderLedger:)`.
  `ops` is now optional (`nil` = `SystemFileOps(mode: rootMode)`). `rootMode` defaults to `.documents`.
  With `.macFolder` and a `rootProvider` the root and its state come from the provider at init (`visibleRoot` is the
  provider's URL even when the folder is not reachable); with `.macFolder` and a bare `visibleRoot` the state is `.ready`
  when the directory exists, else `.unreachable`. `OfflineStore.shared()` builds the Mac store (`#if os(macOS)` at the
  composition root only): `rootMode: .macFolder`, `MacRootProvider(ledger: FolderLedger.shared())`, `sharedWithApp: false`.
* **`canKeep` is true on the Mac** (the root is never nil there). The Mac share extension, if built, keeps `visibleRoot == nil`.
* **`reload()` order in `.macFolder`:** resolve the root (`resolveRoot()`), adopt what FolderSync wrote
  (`adoptFolderSyncFiles()`, only while `.ready`), settle legacy `keep == nil` records to `false`, scan, record the chosen
  folder's identity after a good scan, `runMigrationIfNeeded()` (returns at once in `.macFolder`), promote kept files waiting in
  `files/`. A root that is not `.ready` changes nothing on disk and promotes nothing (kept files wait in `files/`, kept).
* **What every gated operation reads:** `OfflineStore.rootBox` (the usable root, nil when not `.ready`), read when the
  gate is entered, never through a main-actor hop. P's code that touches the root must go through `inGate { root in ... }`
  (internal) the way `promote`, `scanVisibleRoot`, `followTitle`, `removeOfflineCopy` and `purgeVisible` do.
* **Mac deletes go to the Trash:** `OfflineFileOps.removeVisible(_:)` (new protocol requirement): `.macFolder` →
  `FileManager.trashItem` (plain delete only when the volume has no Trash), `.documents` → `removeItem`. Cache, `.part`
  and poster deletes keep `remove(_:)`. Every owner-initiated delete of a visible file (remove offline copy, remove from this
  mac, delete everything, `replaceMade`) uses it.
* **No backup exclusion in the Mac folder:** `excludesBackup` is `rootMode == .documents`; the hidden cache files may stay excluded.
* **Landing in the Mac folder** is the `promote` that `add`/`attach` already run when `keep` is true: tag, rename (or copy to
  `.cobalt-<id>.part`, full sync, size check, rename, delete the source across volumes), one index write.
  P's `pulled` landing is `add(..., keep: true, createdAt: <server's>, origin: .pulled, ...)` and, for a made file, a
  `replaceMade` of the older local record of the same `madeKind` and media **before** the `add` (13.7).
* **`replaceMade(_:)`:** scans first when the record has a visible file (the owner may have renamed it), then: name still
  `givenName` and tag is the record's → delete (Trash on the Mac) and tombstone the id; renamed, or `givenName == nil` → the
  tag is removed, the file stays (the owner's now); another file or none at the path → nothing touched. The record, its poster and
  its flipbook then go. Returns false for an unknown id, an unreadable tag (nothing changed), an index that cannot be written.
  `PipelineGallery.finishMake` calls it in both replace loops.

## 2. Folder (`Folder/MacFolder.swift`, `MacRoot.swift`, `FolderAdoption.swift`, `FolderLedger.swift`, `FolderDestination.swift`)

```swift
@MainActor @Observable public final class MacFolder {
    public enum Problem: Sendable, Equatable { case unreachable, notAllowed, wrongFolder, diskFull }
    public struct Moving: Sendable, Equatable { public var done: Int; public var total: Int; public init(done: Int, total: Int) }
    public struct Status: Sendable, Equatable {
        public var available: Bool; public var path: String; public var isDefault: Bool
        public var problem: Problem?; public var adopting: Bool; public var moving: Moving?
        public init(available: Bool = true, path: String = "~/Movies/cobalt", isDefault: Bool = true,
                    problem: Problem? = nil, adopting: Bool = false, moving: Moving? = nil)
    }
    public enum ChooseOutcome: Sendable, Equatable { case chosen, askMove(count: Int), unchanged, refusedICloud, failed }
    public var status: Status { get }                        // derived from the store: available only in `.macFolder`
    public var isAvailable: Bool { get }
    nonisolated public static var platformHasFolder: Bool    // new: true on macOS
    public func chooseFolder(_ url: URL) async -> ChooseOutcome
    public func resetToDefault() async -> ChooseOutcome
    @discardableResult public func answerMove(_ move: Bool?) async -> (moved: Int, stayed: Int)   // nil = cancel (no change)
    public func reveal(_ videos: [StoredVideo] = []) async  // macOS: files selected in Finder (a gallery item: its folder); the folder when none; nothing while the root is not .ready
    public func displayFolder(of video: StoredVideo) -> String?   // "~/Movies/cobalt/instagram · DeKlsGCGZmx"; nil unless the file is kept
    public func observeActivation()                          // macOS: on app activation, reload only when the root was or is not usable
    public static func preview(_ status: Status) -> MacFolder
    public func setPreviewStatus(_ status: Status)           // no effect on the real one
}
extension AppModel { public var macFolder: MacFolder { get } }    // `folderSync` is gone
```

* **Status mapping:** `problem` is `.unreachable` / `.notAllowed` / `.wrongFolder` from `store.rootState`, `.diskFull`
  from `store.rootDiskFull` while the root is ready. `path` is the display path (`~` for the real home; under the DEBUG sandbox
  `~` stands for the sandbox folder).
* **Choosing (13.5):** `chooseFolder` prepares (bookmark, identity, iCloud refusal by path first, writable check) without
  switching. It answers `.askMove(count:)` when kept files are in the current root and it is `.ready` (state held in the
  object; `answerMove` finishes it); otherwise it switches at once and answers `.chosen`. `resetToDefault()` is the same toward
  `~/Movies/cobalt` (`.unchanged` when already there). `answerMove(true)` moves every kept file that is provably its own, `false`
  leaves them (not offline here any more, nothing deleted), `nil` cancels. The ledger names the new folder *before* the move
  starts, so a crash mid-move reopens on the new folder (what moved is found by tag; what did not stays in the old one, tagged,
  not offline). `status.moving` carries `done` of `total` while it runs. A file in a folder the owner made lands at the top of
  the new root; gallery folders are re-made by tag.
* **Ledger (`FolderLedger`, internal):** only the readers, `choose(path:bookmark:isDefault:volume:fileID:)`,
  `refreshDestination`, `recordIdentity(volume:fileID:)` and `ensureSection` remain. The destination record gained optional
  `volume` and `fileID` (decodes from 1.14.x). The claim, finish, fail, skip and release API went with the worker.
* **Adoption (13.3)** is `FolderAdoption.run`, called by `OfflineStore.adoptFolderSyncFiles()` inside the gate. It never writes
  `folder.json`. Marker `Sync/folder-adoption.json` (see 5). It runs on each `reload()` until the root's section is complete and
  unchanged. The "claimed, failed, or no entry" rule (those records are kept and promoted) runs only on the very first
  adoption this install makes, and for a no-entry record only when the section has entries (a folder FolderSync never used has
  nothing it "would have copied").
* **Removed:** `FolderSync`, `FolderWorker`, `FolderSync.Status/Problem/Progress`, `Settings.folderSync` as a driver (the property
  remains; adoption reads the stored value once, default on).

## 3. Pull stub (`Offline/SavePull.swift`) and the AppModel additions

```swift
@MainActor @Observable public final class SavePull {
    public enum Paused: Sendable, Equatable { case keepOff, folderUnreachable, auth, noServer }
    public struct Status: Sendable, Equatable {
        public var available: Bool; public var lastChecked: Date?; public var paused: Paused?; public var pulling: Int
        public init(available: Bool = false, lastChecked: Date? = nil, paused: Paused? = nil, pulling: Int = 0)
    }
    public var status: Status { get }          // stub: `available` is `store.rootMode == .macFolder`, the rest empty
    public var isAvailable: Bool { get }
    public func check() async                  // stub: does nothing
    public static func preview(_ status: Status) -> SavePull
    public func setPreviewStatus(_ status: Status)
    init(store: OfflineStore)                  // internal; P owns this initializer's growth (ledger, client, clock, ...)
}
extension AppModel {
    public let savePull: SavePull              // stored in AppModel.swift: init(... macFolder: MacFolder? = nil, savePull: SavePull? = nil, ...)
    public func setKeepNewSaves(_ on: Bool)    // stub: writes `settings.keepVideosOnDevice`; P adds the rebaseline
    func holdsSession(_ id: String) -> Bool    // 13.9 layer 1: a live job of `queue` follows it, or `store.sessionIsHeld` (share jobs, pending originals)
}
```

`AppModel.live()` builds `MacFolder(store:ledger:)` (`observeActivation()` on macOS) and `SavePull(store:)`; previews get
`MacFolder.preview(.init(available: MacFolder.platformHasFolder))` and `SavePull.preview(.init(available: MacFolder.platformHasFolder))`.
`offline.markNotNew` now only calls the photos sync (the folder has nothing to mark).
P's work in `AppModel.swift` / `AppModel+Offline.swift` starts from these.

## 4. Screens (what U builds against)

* `model.macFolder.status` / `.isAvailable`, `chooseFolder`, `resetToDefault`, `answerMove`, `reveal`, `displayFolder(of:)`.
* `model.store.canKeep` is true on the Mac; `model.store.rootState`, `rootMode`, `visibleRoot`.
* `model.savePull.status` (stub values until P).
* **Compile shims left for U to replace** (copy as 13.10 pins it, inline strings because `Copy+Folder.swift` is U's):
  `Cobalt/Shared/ShowInFinderButton.swift` (shows when any rendition `place == .offline`, disabled while `.unreachable`),
  `Cobalt/Screens/Settings/FolderSettingsSection.swift` + `FolderSettingsPreviews.swift` (folder row, `choose…`, `show in finder`,
  `use ~/Movies/cobalt`, problem line, the move dialog; no toggle, no backfill), `Cobalt/Screens/Home/GalleryFocus.swift`
  (`place` reads `macFolder.status.path`). `Copy.Folder.*` strings that 13.10 retires are untouched, and now unused:
  `toggle`, `saved`, `waiting`, `saving`, `statusRow`, `gaveUp`, `folderMissing`, `notAllowed`, `diskFull`, `backfill*`,
  `existingRow`, `footer`, `footerOff`, `chooseMessage`.

## 5. Files and formats

* **Marker `Sync/folder-adoption.json`:** `{sections: {<ledger section id>: {at (ISO 8601), adopted, skipped: {reason: n}, pendingCache: [{name, path, bytes}], entries, complete}}}`.
  Reasons: `noRecord`, `missing`, `changed`, `tagConflict` (final), `busy`, `unreadable` (not final).
  **DEVIATION:** `pendingCache` holds objects (the cache name, the folder file that replaced it, its size), not bare names, so an
  interrupted run deletes a hidden copy only against a whole folder file.
* **Tombstones** (`<hidden>/tombstones.json`) are unchanged; every cobalt-initiated delete of a visible file adds the id.
* **DEBUG sandbox `-cobaltSandboxRoot <dir>`:** `AppGroup.sandboxRoot` (nil in release). Everything this process stores goes under
  `<dir>/Application Support/{Videos,Sync,Jobs,Telemetry,Saves}` (the layout of the real `~/Library/Application Support`, so
  `ditto` copies drop in), the Mac default folder is `<dir>/Movies/cobalt`, the preferences live in a `cobalt.sandbox.<hash>` suite,
  the keychain is in memory (the owner's is never opened; paste a test key in Settings), and `sendTelemetry` defaults off. Launch it
  with `open -n <app> --args -cobaltSandboxRoot <dir>`; a direct exec of the binary also works.

## 6. Test seams for M2 tests (`Tests/CobaltKitTests/`)

* `MacRig` (`OwnerFolderFixture.swift`): temp folder, hidden store, `Sync/`, ledger; `seed(SeedItem)`, `commit()`, `store(ops:)`
  (a `.macFolder` store with a `MacRootProvider` whose default folder is the rig's folder), `index()`, `record(_:)`, `cacheFiles()`,
  `files(in:)`, `tag(_:in:)`, `exists(_:in:)`, `trash` (a `TrashBin`).
* `OwnerFolder`: the owner's folder of 2026-10-07 (6 top-level files, the tagged gallery folder, 8 ledger entries, 6 legacy and 2
  wave-1 records, the leaked exclusion, `holiday.mov`, `my clip.mp4`). `snapshot(of:)` and `FileAttributes` compare folders.
* `TestFileOps` (`OfflineTestSupport.swift`) gained `trash: TrashBin?` (a fake Trash), `crossVolumeFrom: URL?` (EXDEV for renames out
  of a folder) and new crash steps `OfflineMoveStep.adoptTagged`, `.adoptMarked`, `.adoptIndexed`.

## 7. Not verified here

* The pull, G-MB (a background download surviving a Mac app quit), real `trashItem` on external and network volumes, `fileIdentifier`
  stability on exFAT: all as in 13.16.
* A run against the owner's real folder and store: none was made (hard rule). The adoption counts for it (8 of 8) are predicted by
  `OwnerFolderTests` (the fixture uses the real names, keys and kinds with scaled-down sizes: 8 of 8 adopted when nothing is renamed, 7 of 8 with the renamed file); V repeats it on a `ditto` copy under
  `-cobaltSandboxRoot`.
