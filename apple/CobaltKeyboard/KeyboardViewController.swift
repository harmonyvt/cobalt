import CobaltKit
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Principal class of the custom keyboard (`com.apple.keyboard-service`).
/// The gallery fills it, or typing mode with the ":" emote bar. A globe switches back to the Apple keyboard.
final class KeyboardViewController: UIInputViewController {
    private let model = KeyboardGalleryModel()
    private let typing = KeyboardTypingModel()
    private let globe = UIButton(type: .system)
    private var galleryHost: UIHostingController<KeyboardRootView>!
    private var heightConstraint: NSLayoutConstraint!

    override func loadView() {
        let chrome = KeyboardChromeView(frame: .zero, inputViewStyle: .keyboard)
        chrome.allowsSelfSizing = true
        view = chrome
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        CobaltFont.register()
        model.onCopy = { [weak self] post, choice in self?.copyRendition(post, choice) }
        model.onHold = { [weak self] post, choice in self?.insertLink(post, choice) }
        model.onCopyEmote = { [weak self] hit in self?.copyEmote(hit) }
        model.onHoldEmote = { [weak self] hit in self?.holdEmote(hit) }
        typing.insert = { [weak self] text in self?.typeText(text) }
        typing.deleteBackward = { [weak self] in self?.typeBackspace() }
        typing.pick = { [weak self] hit in self?.pickSuggestion(hit) }
        typing.hold = { [weak self] hit in self?.holdSuggestion(hit) }
        typing.client = { [weak self] in self?.model.keyedClient() ?? .failure(.noKey) }
        model.setFullAccess(hasFullAccess)
        installSubviews()
        updateHeight()
        applyKeyboardAppearance()
        model.reloadIfEmpty()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        updateHeight()
        applyKeyboardAppearance()
        model.setFullAccess(hasFullAccess)
        model.reloadIfEmpty()
        refreshTyping()
    }

    override func viewWillLayoutSubviews() {
        globe.isHidden = !needsInputModeSwitchKey
        updateHeight()
        super.viewWillLayoutSubviews()
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        updateHeight()
        applyKeyboardAppearance()
    }

    override func viewWillTransition(to size: CGSize, with coordinator: UIViewControllerTransitionCoordinator) {
        super.viewWillTransition(to: size, with: coordinator)
        coordinator.animate(alongsideTransition: { _ in self.updateHeight() })
    }

    override func textDidChange(_ textInput: UITextInput?) {
        applyKeyboardAppearance()
        refreshTyping()
    }

    override func selectionDidChange(_ textInput: UITextInput?) {
        refreshTyping()
    }

    private func updateHeight() {
        let pad = traitCollection.userInterfaceIdiom == .pad
        let landscape = traitCollection.verticalSizeClass == .compact
        let height: CGFloat = pad ? 320 : (landscape ? 204 : 291)
        if heightConstraint?.constant != height { heightConstraint?.constant = height }
        (view as? KeyboardChromeView)?.preferredHeight = height
    }

    private func installSubviews() {
        heightConstraint = view.heightAnchor.constraint(equalToConstant: 291)
        heightConstraint.priority = UILayoutPriority(999)
        heightConstraint.isActive = true

        let host = UIHostingController(rootView: KeyboardRootView(gallery: model, typing: typing))
        host.view.backgroundColor = .clear
        host.view.translatesAutoresizingMaskIntoConstraints = false
        addChild(host)
        view.addSubview(host.view)
        host.didMove(toParent: self)
        galleryHost = host

        globe.translatesAutoresizingMaskIntoConstraints = false
        globe.accessibilityLabel = "switch keyboard"
        let symbol = UIImage(systemName: "globe", withConfiguration: UIImage.SymbolConfiguration(pointSize: 18, weight: .medium))
        globe.setImage(symbol, for: .normal)
        globe.addTarget(self, action: #selector(handleInputModeList(from:with:)), for: .allTouchEvents)
        view.addSubview(globe)

        NSLayoutConstraint.activate([
            host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            host.view.topAnchor.constraint(equalTo: view.topAnchor, constant: 4),
            host.view.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),

            globe.topAnchor.constraint(equalTo: view.topAnchor, constant: 2),
            globe.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -4),
            globe.widthAnchor.constraint(equalToConstant: 44),
            globe.heightAnchor.constraint(equalToConstant: 36),
        ])
    }

    private func applyKeyboardAppearance() {
        let dark: Bool
        switch textDocumentProxy.keyboardAppearance {
        case .dark:
            view.overrideUserInterfaceStyle = .dark
            dark = true
        case .light:
            view.overrideUserInterfaceStyle = .light
            dark = false
        default:
            view.overrideUserInterfaceStyle = .unspecified
            dark = traitCollection.userInterfaceStyle == .dark
        }
        view.backgroundColor = KeyboardChrome.background(dark: dark)
        globe.tintColor = KeyboardChrome.label(dark: dark)
    }

    private func copyRendition(_ post: LibraryPost, _ choice: KeyboardChoice?) {
        guard model.fullAccess, model.busyID == nil else { return }
        let rendition = choice?.rendition ?? KeyboardFace.of(post)
        guard let rendition else { return }
        model.busyID = post.id
        model.chooserPostID = nil
        let label = choice?.label ?? (KeyboardFace.isPicture(rendition) ? "photo" : "video")
        Task { @MainActor in
            await self.deliver(rendition, label: label)
        }
    }

    /// Puts the rendition's bytes on the general pasteboard. A file already on the phone is reused.
    private func deliver(_ rendition: Rendition, label: String) async {
        var temp: URL?
        defer {
            model.busyID = nil
            model.transfer = nil
            if let temp { try? FileManager.default.removeItem(at: temp) }
        }
        let title = KeyboardFace.fileTitle(label: label, rendition: rendition)
        do {
            guard model.fullAccess else { return }
            if let bytes = rendition.bytes, bytes > KeyboardFace.byteCap {
                model.notice = .failed(KeyboardWords.tooBig(bytes))
                return
            }
            let source: URL
            if let local = model.prepareLocal(rendition) {
                model.transfer = KeyboardTransfer(title: title, detail: KeyboardWords.savedHere)
                source = local
            } else {
                guard let downloaded = try await model.prepareDownload(rendition, title: title) else {
                    model.notice = .failed(Copy.actionFailed)
                    return
                }
                temp = downloaded
                source = downloaded
            }
            let bytes = try Self.byteCount(of: source)
            if bytes > KeyboardFace.byteCap {
                model.notice = .failed(KeyboardWords.tooBig(bytes))
                return
            }
            guard model.fullAccess else { return }
            try writePasteboard(source, label: label)
            model.notice = .copied
        } catch {
            model.notice = .failed(Copy.actionFailed)
        }
    }

    /// Movie types are registered explicitly. Discord asks for `public.movie` and will not
    /// walk from `public.mpeg-4`. WhatsApp reads the mpeg-4 data, so that stays too.
    private func writePasteboard(_ source: URL, label: String) throws {
        let ext = source.pathExtension.lowercased()
        let pasteURL = try snapshot(of: source, ext: ext.isEmpty ? "bin" : ext)
        let type = UTType(filenameExtension: pasteURL.pathExtension) ?? .data
        let identifiers = pasteTypes(ext: pasteURL.pathExtension.lowercased(), type: type)
        let provider = NSItemProvider()
        provider.suggestedName = "\(label).\(pasteURL.pathExtension)"
        for identifier in identifiers {
            provider.registerFileRepresentation(forTypeIdentifier: identifier, fileOptions: [], visibility: .all) { completion in
                completion(pasteURL, false, nil)
                return nil
            }
        }
        if let count = try? Self.byteCount(of: pasteURL), count <= 20_000_000,
           // mapped, not read: the pasteboard keeps these bytes for minutes, and dirty memory counts against the keyboard
           let data = try? Data(contentsOf: pasteURL, options: .alwaysMapped) {
            for identifier in identifiers {
                provider.registerDataRepresentation(forTypeIdentifier: identifier, visibility: .all) { completion in
                    completion(data, nil)
                    return nil
                }
            }
        }
        UIPasteboard.general.setItemProviders([provider], localOnly: false, expirationDate: Date().addingTimeInterval(180))
    }

    private func pasteTypes(ext: String, type: UTType) -> [String] {
        var ids: [String] = []
        func add(_ id: String) {
            if !ids.contains(id) { ids.append(id) }
        }
        let movie = type.conforms(to: .movie) || ext == "mp4" || ext == "m4v" || ext == "mov"
        let image = type.conforms(to: .image) || ["webp", "gif", "png", "jpg", "jpeg", "heic", "heif"].contains(ext)
        if movie {
            add(UTType.movie.identifier)
            if ext == "mov" { add(UTType.quickTimeMovie.identifier) }
            else { add(UTType.mpeg4Movie.identifier) }
            add(type.identifier)
        } else if image {
            add(type.identifier)
            add(UTType.image.identifier)
            if ext == "gif" { add(UTType.gif.identifier) }
        } else {
            add(type.identifier)
        }
        return ids
    }

    /// The last paste stays until the next one. Discord loads the file after this method returns.
    private func snapshot(of source: URL, ext: String) throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("cobalt-keyboard", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        if let items = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) {
            for item in items where item.lastPathComponent.hasPrefix("last-paste") {
                try? FileManager.default.removeItem(at: item)
            }
        }
        let dest = folder.appendingPathComponent("last-paste.\(ext)")
        if FileManager.default.fileExists(atPath: dest.path) {
            try FileManager.default.removeItem(at: dest)
        }
        try FileManager.default.copyItem(at: source, to: dest)
        return dest
    }

    private static func byteCount(of url: URL) throws -> Int64 {
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize
        guard let size else { throw CocoaError(.fileReadUnknown) }
        return Int64(size)
    }

    /// Copies the largest webp. A saved emote uses our public file when we have it; otherwise the 7TV cdn file.
    private func copyEmote(_ hit: EmoteHit) {
        guard model.fullAccess, model.busyID == nil else { return }
        let url = (hit.libraryURL?.scheme == "https" ? hit.libraryURL : nil) ?? hit.fileURL
        guard url.scheme == "https", let host = url.host?.lowercased(),
              host == "cdn.7tv.app" || host == "media.capybaraharmony.com" else { return }
        model.busyID = hit.id
        model.transfer = KeyboardTransfer(title: hit.name, detail: KeyboardWords.downloading)
        Task { @MainActor in
            defer {
                self.model.busyID = nil
                self.model.transfer = nil
            }
            do {
                let (source, _) = try await URLSession.shared.download(from: url)
                let dest = FileManager.default.temporaryDirectory
                    .appendingPathComponent("cobalt-emote-\(hit.id).webp")
                if FileManager.default.fileExists(atPath: dest.path) {
                    try FileManager.default.removeItem(at: dest)
                }
                try FileManager.default.moveItem(at: source, to: dest)
                defer { try? FileManager.default.removeItem(at: dest) }
                let bytes = try Self.byteCount(of: dest)
                if bytes > KeyboardFace.byteCap {
                    self.model.notice = .failed(KeyboardWords.tooBig(bytes))
                    return
                }
                try self.writePasteboard(dest, label: hit.name)
                self.model.notice = .copied
                // a used emote is kept: in the library and first in the typing bar
                Task { @MainActor in _ = await self.linkSaving(hit, quiet: true) }
            } catch {
                self.model.notice = .failed(Copy.actionFailed)
            }
        }
    }

    /// The public link of our copy. An emote that is not saved yet is saved first.
    private func holdEmote(_ hit: EmoteHit) {
        guard model.busyID == nil, model.savingEmoteID == nil else { return }
        Task { @MainActor in
            guard let url = await self.linkSaving(hit) else { return }
            self.textDocumentProxy.insertText(self.model.shareLink(for: url).absoluteString)
            self.model.notice = nil
        }
    }

    /// Our public link for the emote, saving it to the library when it is not there yet. Every use lands in the
    /// recents. Nil after a failure, which shows a notice unless `quiet`.
    private func linkSaving(_ hit: EmoteHit, quiet: Bool = false) async -> URL? {
        if let url = Self.webLink(hit.libraryURL) {
            typing.remember(hit)
            return url
        }
        typing.remember(hit)
        guard model.savingEmoteID == nil else { return nil }
        let client: HTTPCobaltClient
        switch model.keyedClient() {
        case .success(let ready): client = ready
        case .failure(let missing):
            if !quiet { model.notice = .failed(missing == .noAccess ? KeyboardWords.noAccess : KeyboardWords.noKey) }
            return nil
        }
        model.savingEmoteID = hit.id
        defer { model.savingEmoteID = nil }
        do {
            let saved = try await client.saveEmote(id: hit.id)
            var next = hit
            next.libraryID = saved.id
            next.libraryURL = saved.url
            model.markSaved(next)
            typing.remember(next)
            guard let url = Self.webLink(saved.url) else {
                if !quiet { model.notice = .failed(KeyboardWords.emoteDown) }
                return nil
            }
            return url
        } catch {
            if !quiet { model.notice = .failed(KeyboardWords.emoteDown) }
            return nil
        }
    }

    private static func webLink(_ url: URL?) -> URL? {
        guard let url, url.scheme == "https" || url.scheme == "http" else { return nil }
        return url
    }

    // MARK: typing mode

    private func typeText(_ text: String) {
        UIDevice.current.playInputClick()
        model.notice = nil
        textDocumentProxy.insertText(text)
        refreshTyping()
    }

    private func typeBackspace() {
        UIDevice.current.playInputClick()
        model.notice = nil
        textDocumentProxy.deleteBackward()
        refreshTyping()
    }

    private func refreshTyping() {
        let proxy = textDocumentProxy
        let caps = proxy.autocapitalizationType ?? .sentences
        typing.contextChanged(before: proxy.documentContextBeforeInput, autoCapitalize: caps != UITextAutocapitalizationType.none)
    }

    /// Tap in the bar: ":word" becomes the emote's link (saved first when needed).
    private func pickSuggestion(_ hit: EmoteHit) {
        guard let query = typing.query, model.savingEmoteID == nil else { return }
        Task { @MainActor in
            guard let url = await self.linkSaving(hit) else { return }
            self.replaceTrigger(query, with: self.model.shareLink(for: url).absoluteString + " ")
        }
    }

    /// Hold in the bar: ":word" goes and the file is copied, to paste as an attachment.
    private func holdSuggestion(_ hit: EmoteHit) {
        guard let query = typing.query, model.busyID == nil else { return }
        replaceTrigger(query, with: nil)
        copyEmote(hit)
    }

    /// Removes ":query" only while it is still what sits before the cursor (the save may have taken a moment).
    private func replaceTrigger(_ query: String, with text: String?) {
        let proxy = textDocumentProxy
        if EmoteTrigger.query(before: proxy.documentContextBeforeInput) == query {
            for _ in 0...query.count { proxy.deleteBackward() }
        }
        if let text { proxy.insertText(text) }
        refreshTyping()
    }

    private func insertLink(_ post: LibraryPost, _ choice: KeyboardChoice?) {
        guard model.busyID == nil else { return }
        let rendition = choice?.rendition ?? KeyboardFace.of(post)
        guard let rendition, let url = KeyboardFace.publicLink(of: rendition) else {
            model.notice = .failed(KeyboardWords.noPublicLinks)
            return
        }
        textDocumentProxy.insertText(model.shareLink(for: url).absoluteString)
        model.notice = nil
    }
}

/// The keyboard's root view. Self-sizing so iOS does not collapse the extension to a one-line bar.
final class KeyboardChromeView: UIInputView, UIInputViewAudioFeedback {
    var enableInputClicksWhenVisible: Bool { true }
    var preferredHeight: CGFloat = 291 {
        // every layout pass sets it: invalidating an unchanged size only scheduled another pass
        didSet { if preferredHeight != oldValue { invalidateIntrinsicContentSize() } }
    }

    override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric, height: preferredHeight)
    }
}

enum KeyboardChrome {
    static func background(dark: Bool) -> UIColor {
        dark ? UIColor(white: 0.17, alpha: 1) : UIColor(white: 0.82, alpha: 1)
    }

    static func label(dark: Bool) -> UIColor { dark ? .white : .black }
}
