#if DEBUG
import CobaltKit
import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// The combine sheet over the gallery preview scenarios (`AppModel.preview(.galleryInstagram)` and the rest): paste the
/// post, wait for the save, and present the sheet. The launch arguments below put it in any state for a screenshot (the
/// design evidence of lane A2); the `#Preview`s are the same without arguments.
///
///     -previewScenario galleryInstagram -previewCombine 1   (the app shows this scene instead of the shell)
///     -combineOut webp|mp4|image   -combineSource media|run   -combineSeconds 10   -combineSelect 3   -combineUntick 3,4
///     -combineLayout strip|grid2|grid3|row   -combineFade 0|1   -combineFrame keep|9:16|1:1   -combineSound own
///     -combineMake 1 (press make after the sheet is up)   -combineRetry 1 (press try again when it fails)
///     -combineAgain 1 (after it is done, press make another, then make again)
struct CombinePreviewScene: View {
    let model: AppModel
    var out: CombineOutput = .slideshowWebp
    var fromRun = false
    var configure: @MainActor (CombineModel) -> Void = { _ in }
    @State private var media: MediaItem?
    @State private var open = false

    /// A scene read from the launch arguments.
    static func fromLaunchArguments(model: AppModel) -> CombinePreviewScene {
        let d = UserDefaults.standard
        let out: CombineOutput = switch d.string(forKey: "combineOut") {
        case "mp4": .slideshowMp4
        case "image": .galleryImage
        default: .slideshowWebp
        }
        var scene = CombinePreviewScene(model: model, out: out, fromRun: d.string(forKey: "combineSource") == "run")
        scene.configure = { combine in
            if d.object(forKey: "combineSeconds") != nil { combine.seconds = SlideshowPlan.snapped(d.double(forKey: "combineSeconds")) }
            if let fade = d.object(forKey: "combineFade") as? Int { combine.fade = fade != 0 }
            if let frame = d.string(forKey: "combineFrame").flatMap(SlideshowPlan.Frame.init(rawValue:)) { combine.frame = frame }
            if d.string(forKey: "combineSound") == "own" { combine.sound = .own }
            if let layout = d.string(forKey: "combineLayout").flatMap(GalleryLayout.init(rawValue:)) { combine.layout = layout }
            for n in (d.string(forKey: "combineUntick") ?? "").split(separator: ",").compactMap({ Int($0) }) { combine.toggle(n - 1) }
            if d.object(forKey: "combineSelect") != nil { combine.select(d.integer(forKey: "combineSelect") - 1) }
            guard d.bool(forKey: "combineMake") else { return }
            // press the buttons a person would: make, then (when asked) try again or make another; `-combineShootAt <phase>`
            // writes the snapshot when the sheet reaches that phase (edit | sending | queued | making | done | failed)
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(2))
                combine.make()
                var shot = false, retried = false, again = false
                for _ in 0..<900 {
                    try? await Task.sleep(for: .milliseconds(100))
                    let name: String
                    switch combine.phase {
                    case .edit: name = "edit"
                    case .afterSave: name = "afterSave"
                    case .sending: name = "sending"
                    case .queued: name = "queued"
                    case .making: name = "making"
                    case .done: name = "done"
                    case .failed: name = "failed"
                    }
                    if !shot, name == d.string(forKey: "combineShootAt"), !(name == "edit" && !again) {
                        shot = true
                        try? await Task.sleep(for: .milliseconds(800))
                        CombineSnapshot.write(prefix: d.string(forKey: "combineSnapshot") ?? "/tmp/combine")
                    }
                    if name == "failed", d.bool(forKey: "combineRetry"), !retried, shot || d.string(forKey: "combineShootAt") != "failed" {
                        retried = true
                        combine.retry()
                    }
                    if name == "done", d.bool(forKey: "combineAgain"), !again, shot || d.string(forKey: "combineShootAt") != "done" {
                        again = true
                        try? await Task.sleep(for: .seconds(1.5))
                        combine.backToEditing()
                    }
                }
            }
        }
        return scene
    }

    /// `-combineRender /path.png` (+ `-combineWidth 390`, `-combineHeight 800`): the sheet drawn by `ImageRenderer` at a fixed
    /// size, whatever the window system does (native controls such as the segmented pickers may draw as placeholders).
    private func renderIfRequested() {
        let d = UserDefaults.standard
        guard let path = d.string(forKey: "combineRender"), let media else { return }
        let width = d.object(forKey: "combineWidth") == nil ? 390 : d.double(forKey: "combineWidth")
        let height = d.object(forKey: "combineHeight") == nil ? 800 : d.double(forKey: "combineHeight")
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(d.object(forKey: "combineRenderAfter") == nil ? 5 : d.double(forKey: "combineRenderAfter")))
            let content = CombineSheet(model: model, media: media, output: out, configure: configure)
                .frame(width: width, height: height)
                .background(CobaltColor.bg)
                .cobaltRoot(model: model)
            let renderer = ImageRenderer(content: content)
            renderer.scale = 2
            #if os(macOS)
            if let image = renderer.nsImage, let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
               let png = rep.representation(using: .png, properties: [:]) { try? png.write(to: URL(fileURLWithPath: path)) }
            #else
            if let png = renderer.uiImage?.pngData() { try? png.write(to: URL(fileURLWithPath: path)) }
            #endif
            CombineSnapshot.say("combine-snapshot render \(path)")
        }
    }

    var body: some View {
        Color.clear
            .ignoresSafeArea()
            .background(CobaltColor.bg)
            .sheet(isPresented: Binding(get: { open && (fromRun || media != nil) }, set: { open = $0 })) {
                if fromRun {
                    CombineSheet(model: model, pipeline: model.pipeline, output: out, configure: configure)
                } else if let media {
                    CombineSheet(model: model, media: media, output: out, configure: configure)
                }
            }
            .task { await start() }
    }

    private func start() async {
        CombineSnapshot.runIfRequested()
        defer { if UserDefaults.standard.bool(forKey: "combineSelfTest") { CombineSelfTest.run(model: model, media: media) } }
        model.pipeline.start(pastedText: "https://www.instagram.com/p/Ddy0-gpGg5U/")
        for _ in 0..<200 {
            try? await Task.sleep(for: .milliseconds(100))
            if model.pipeline.galleryRun?.phase == .saved { break }
        }
        try? await Task.sleep(for: .milliseconds(600))
        if let local = model.store.media.first(where: { $0.isGallery }) { media = model.mediaItem(for: local) }
        CombineSnapshot.say("scene: media \(media == nil ? "nil" : "\(media!.items.count) items") run=\(fromRun)")
        open = true
        renderIfRequested()
    }
}

/// Evidence without the screen: `-combineSnapshot /path/prefix` writes every window of the app itself (the sheet is one) as
/// `prefix-<n>.png`, after `-combineSnapshotAfter` seconds (default 6), by drawing the window's own view hierarchy (no screen
/// recording, nothing else on the desktop is read). The log lines go to a file too (`-combineLog /path`).
@MainActor
enum CombineSnapshot {
    static func say(_ line: String) {
        guard let path = UserDefaults.standard.string(forKey: "combineLog") else { print(line); return }
        let data = Data((line + "\n").utf8)
        if let handle = FileHandle(forWritingAtPath: path) { handle.seekToEndOfFile(); handle.write(data); try? handle.close() }
        else { FileManager.default.createFile(atPath: path, contents: data) }
    }

    static func runIfRequested() {
        let d = UserDefaults.standard
        guard let prefix = d.string(forKey: "combineSnapshot") else { return }
        let after = d.object(forKey: "combineSnapshotAfter") == nil ? 6 : d.double(forKey: "combineSnapshotAfter")
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(after))
            write(prefix: prefix)
        }
    }

    #if os(macOS)
    static func write(prefix: String) {
        for w in NSApp.windows { say("window \(type(of: w)) \(w.frame) sheet=\(w.isSheet) visible=\(w.isVisible) sheets=\(w.sheets.count) attached=\(String(describing: w.attachedSheet.map { type(of: $0) }))") }
        for (n, window) in NSApp.windows.flatMap({ [$0] + $0.sheets }).enumerated() {
            guard let view = window.contentView?.superview ?? window.contentView, view.bounds.width > 40,
                  let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
            view.cacheDisplay(in: view.bounds, to: rep)
            if let png = rep.representation(using: .png, properties: [:]) {
                try? png.write(to: URL(fileURLWithPath: "\(prefix)-\(n).png"))
                say("combine-snapshot window \(n) \(Int(view.bounds.width))x\(Int(view.bounds.height))")
            }
        }
    }
    #else
    static func write(prefix: String) {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        var n = 0
        for window in scenes.flatMap(\.windows) {
            let renderer = UIGraphicsImageRenderer(bounds: window.bounds)
            let image = renderer.image { _ in window.drawHierarchy(in: window.bounds, afterScreenUpdates: true) }
            if let png = image.pngData() {
                try? png.write(to: URL(fileURLWithPath: "\(prefix)-\(n).png"))
                say("combine-snapshot window \(n)")
            }
            n += 1
        }
    }
    #endif
}

/// `-combineSelfTest 1`: asserts the model's rules over the saved gallery and prints one line per check (stdout, so
/// `simctl launch --console` shows it). Not part of the app; the sheet's logic is the model's and these are its edges.
@MainActor
enum CombineSelfTest {
    static func run(model: AppModel, media: MediaItem?) {
        var failures = 0
        func check(_ name: String, _ ok: Bool) {
            if !ok { failures += 1 }
            CombineSnapshot.say("combine-selftest \(ok ? "pass" : "FAIL") \(name)")
        }
        guard let media else { CombineSnapshot.say("combine-selftest FAIL no gallery media"); return }
        let c = CombineModel(app: model, source: .media(media), output: .slideshowWebp)
        let n = c.items.count
        check("items come from the media (\(n))", n >= 2)
        check("order starts as the post's", c.orderedIDs == c.items.map(\.id))
        check("all ticked", c.tickedIDs.count == n)
        c.move(c.orderedIDs[0], onto: c.orderedIDs[2])
        check("drag item 1 onto item 3 splices it into place 3", Array(c.orderedIDs.prefix(3)) == [c.items[1].id, c.items[2].id, c.items[0].id])
        check("the dragged item is selected", c.selected == c.items[0].id)
        c.shift(by: -1)
        check("move earlier swaps with the one before", Array(c.orderedIDs.prefix(3)) == [c.items[1].id, c.items[0].id, c.items[2].id])
        c.toggle(c.items[3].id)
        check("untick removes it from the plan", !c.slideshowPlan(.webp).items.contains(c.items[3].id) && c.slideshowPlan(.webp).items.count == n - 1)
        check("plan items follow the shown order", c.slideshowPlan(.webp).items == c.orderedIDs.filter { $0 != c.items[3].id })
        c.seconds = 2
        check("default gate is open at 2 s", c.gate.allowed)
        c.seconds = 10
        let gate = c.gate
        check("webp over 60 s is refused at 10 s a photo", !gate.allowed && gate.reason?.hasPrefix("too long for a webp:") == true)
        check("it offers the longest step that fits (6.0 s for 9 photos)", gate.ways.contains(.perPhoto(6.5)) || gate.ways.contains(.perPhoto(6.0)))
        check("and the mp4 instead", gate.ways.contains(.makeMp4))
        c.take(.makeMp4)
        check("the mp4 takes 90 s", c.output == .slideshowMp4 && c.gate.allowed)
        c.output = .slideshowWebp
        c.take(.perPhoto(6.5))
        check("taking the fit makes it ok", c.gate.allowed)
        check("size is independent of seconds", { () -> Bool in
            c.seconds = 1; let a = c.estimatedBytes; c.seconds = 6; return a == c.estimatedBytes
        }())
        c.fade = false
        check("crossfade off shrinks the webp", c.webpBytes(fade: false) < c.webpBytes(fade: true))
        c.output = .galleryImage
        check("gallery image has a canvas", c.canvas != nil)
        c.layout = .strip
        check("strip has no cropped photos", c.canvas?.croppedIndices.isEmpty == true)
        for id in c.orderedIDs { if c.isTicked(id) { c.toggle(id) } }
        check("nothing ticked blocks it", !c.gate.allowed)
        CombineSnapshot.say("combine-selftest done failures=\(failures)")
    }
}

#Preview("combine · slideshow webp · instagram 10 photos") {
    PreviewHost(.galleryInstagram) { model in CombinePreviewScene(model: model) }
}
#Preview("combine · slideshow mp4 · mixed") {
    PreviewHost(.galleryMixed) { model in CombinePreviewScene(model: model, out: .slideshowMp4) }
}
#Preview("combine · gallery image · x 4 photos") {
    PreviewHost(.galleryX) { model in CombinePreviewScene(model: model, out: .galleryImage) }
}
#endif
