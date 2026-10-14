import CobaltKit
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Principal class of the custom keyboard (`com.apple.keyboard-service`).
/// A tab at the top switches a typing keyboard and the library gallery.
final class KeyboardViewController: UIInputViewController {
    private let model = KeyboardGalleryModel()
    private let keysView = KeyboardKeysView()
    private let tabBar = UIStackView()
    private let keyboardTab = UIButton(type: .system)
    private let galleryTab = UIButton(type: .system)
    private var galleryHost: UIHostingController<KeyboardGalleryView>!
    private var heightConstraint: NSLayoutConstraint!
    private var showingGallery = false

    override func loadView() {
        let chrome = KeyboardChromeView(frame: .zero, inputViewStyle: .keyboard)
        chrome.allowsSelfSizing = true
        view = chrome
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        CobaltFont.register()
        model.onCopy = { [weak self] post in self?.copyFile(post) }
        model.onHold = { [weak self] post in self?.insertLink(post) }
        model.setFullAccess(hasFullAccess)
        installSubviews()
        showGallery(false)
        updateHeight()
        applyKeyboardAppearance()
        model.reloadIfEmpty()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        updateHeight()
        applyKeyboardAppearance()
        model.setFullAccess(hasFullAccess)
        if showingGallery { model.reloadIfEmpty() }
    }

    override func viewWillLayoutSubviews() {
        keysView.showsGlobe = needsInputModeSwitchKey
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
    }

    /// iPhone portrait is the tall keyboard. Landscape is short. iPad stays tall.
    private func updateHeight() {
        let pad = traitCollection.userInterfaceIdiom == .pad
        let landscape = traitCollection.verticalSizeClass == .compact
        let height: CGFloat = pad ? 320 : (landscape ? 204 : 291)
        heightConstraint?.constant = height
        (view as? KeyboardChromeView)?.preferredHeight = height
    }

    private func installSubviews() {
        heightConstraint = view.heightAnchor.constraint(equalToConstant: 291)
        heightConstraint.priority = UILayoutPriority(999)
        heightConstraint.isActive = true

        tabBar.axis = .horizontal
        tabBar.spacing = 6
        tabBar.distribution = .fillEqually
        tabBar.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(tabBar)

        configureTab(keyboardTab, title: KeyboardWords.keyboard, gallery: false)
        configureTab(galleryTab, title: KeyboardWords.gallery, gallery: true)
        tabBar.addArrangedSubview(keyboardTab)
        tabBar.addArrangedSubview(galleryTab)

        keysView.translatesAutoresizingMaskIntoConstraints = false
        keysView.insert = { [weak self] text in self?.textDocumentProxy.insertText(text) }
        keysView.deleteCharacter = { [weak self] in self?.textDocumentProxy.deleteBackward() }
        // A SwiftUI button cannot receive the UIEvent this selector needs.
        keysView.globeButton.addTarget(self, action: #selector(handleInputModeList(from:with:)), for: .allTouchEvents)
        view.addSubview(keysView)

        let host = UIHostingController(rootView: KeyboardGalleryView(model: model))
        host.view.backgroundColor = .clear
        host.view.translatesAutoresizingMaskIntoConstraints = false
        addChild(host)
        view.addSubview(host.view)
        host.didMove(toParent: self)
        galleryHost = host

        let bodyTop = tabBar.bottomAnchor
        let bodyBottom = view.safeAreaLayoutGuide.bottomAnchor
        NSLayoutConstraint.activate([
            tabBar.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 8),
            tabBar.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -8),
            tabBar.topAnchor.constraint(equalTo: view.topAnchor, constant: 4),
            tabBar.heightAnchor.constraint(equalToConstant: 44),

            keysView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            keysView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            keysView.topAnchor.constraint(equalTo: bodyTop, constant: 6),
            keysView.bottomAnchor.constraint(equalTo: bodyBottom),

            host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            host.view.topAnchor.constraint(equalTo: bodyTop, constant: 6),
            host.view.bottomAnchor.constraint(equalTo: bodyBottom),
        ])
    }

    private func configureTab(_ button: UIButton, title: String, gallery: Bool) {
        button.setTitle(title, for: .normal)
        button.titleLabel?.font = UIFont(name: "IBMPlexMono-Medm", size: 15)
            ?? .systemFont(ofSize: 15, weight: .medium)
        button.layer.cornerRadius = 8
        button.layer.cornerCurve = .continuous
        button.addAction(UIAction { [weak self] _ in self?.showGallery(gallery) }, for: .touchUpInside)
    }

    private func showGallery(_ gallery: Bool) {
        showingGallery = gallery
        keysView.isHidden = gallery
        galleryHost.view.isHidden = !gallery
        styleTabs()
        if gallery {
            model.setFullAccess(hasFullAccess)
            model.reloadIfEmpty()
        }
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
        keysView.apply(dark: dark)
        styleTabs()
    }

    private func styleTabs() {
        let dark = view.overrideUserInterfaceStyle == .dark
            || (view.overrideUserInterfaceStyle == .unspecified && traitCollection.userInterfaceStyle == .dark)
        let label = KeyboardChrome.label(dark: dark)
        let quiet = label.withAlphaComponent(0.55)
        let selectedFill = dark ? UIColor(white: 1, alpha: 0.18) : UIColor(white: 1, alpha: 0.72)
        for (button, selected) in [(keyboardTab, !showingGallery), (galleryTab, showingGallery)] {
            button.backgroundColor = selected ? selectedFill : .clear
            button.setTitleColor(selected ? label : quiet, for: .normal)
        }
    }

    /// One download at a time. A second tap, or a hold, while one is in flight does nothing.
    private func copyFile(_ post: LibraryPost) {
        guard model.fullAccess, model.busyID == nil else { return }
        model.busyID = post.id
        Task { @MainActor in
            await self.deliverCopy(post)
        }
    }

    /// Downloads the face, then puts its bytes on the general pasteboard. The temp file is removed
    /// when this returns, which is after the pasteboard write (or after it throws).
    private func deliverCopy(_ post: LibraryPost) async {
        var temp: URL?
        defer {
            model.busyID = nil
            if let temp { try? FileManager.default.removeItem(at: temp) }
        }
        do {
            guard model.fullAccess else { return }
            // The server already knows the size. Skip the download when it cannot be copied.
            if let bytes = KeyboardFace.of(post)?.bytes, bytes > 8_000_000 {
                model.notice = .failed(KeyboardWords.tooBig)
                return
            }
            guard let url = try await model.prepareFile(for: post) else {
                model.notice = .failed(Copy.actionFailed)
                return
            }
            temp = url
            let bytes = try Self.byteCount(of: url)
            // Over this stays on disk. Reading it, or decoding a UIImage, gets the keyboard killed.
            if bytes > 8_000_000 {
                model.notice = .failed(KeyboardWords.tooBig)
                return
            }
            guard model.fullAccess else { return }
            let data = try Data(contentsOf: url)
            guard model.fullAccess else { return }
            writePasteboard(data, ext: url.pathExtension)
            model.notice = .copied
        } catch {
            model.notice = .failed(Copy.actionFailed)
        }
    }

    /// One representation. `UIPasteboard.general.image` is not set: that flattens a gif to one frame.
    private func writePasteboard(_ data: Data, ext: String) {
        let type = UTType(filenameExtension: ext) ?? .data
        var item: [String: Any] = [type.identifier: data]
        if type.conforms(to: .image) {
            item[UTType.image.identifier] = data
        }
        UIPasteboard.general.setItems([item])
    }

    private static func byteCount(of url: URL) throws -> Int {
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize
        guard let size else { throw CocoaError(.fileReadUnknown) }
        return size
    }

    /// Inserts the face's public URL. No public URL inserts nothing (never the source page).
    private func insertLink(_ post: LibraryPost) {
        guard model.busyID == nil else { return }
        guard let url = KeyboardFace.publicLink(of: post) else {
            model.notice = .failed(KeyboardWords.noPublicLinks)
            return
        }
        textDocumentProxy.insertText(url.absoluteString)
        model.notice = nil
    }
}
