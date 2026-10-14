import CobaltKit
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Principal class of the custom keyboard (`com.apple.keyboard-service`).
/// The gallery fills the keyboard. ABC returns to the Apple keyboard.
final class KeyboardViewController: UIInputViewController {
    private let model = KeyboardGalleryModel()
    private let switchBar = UIView()
    private let nextKeyboardButton = UIButton(type: .system)
    private var galleryAboveBar: NSLayoutConstraint!
    private var galleryAtBottom: NSLayoutConstraint!

    override func viewDidLoad() {
        super.viewDidLoad()
        CobaltFont.register()
        view.backgroundColor = .clear
        model.onCopy = { [weak self] post in self?.copyFile(post) }
        model.onHold = { [weak self] post in self?.insertLink(post) }
        model.setFullAccess(hasFullAccess)
        installSubviews()
        applyKeyboardAppearance()
        model.reloadIfEmpty()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        applyKeyboardAppearance()
        model.setFullAccess(hasFullAccess)
        model.reloadIfEmpty()
    }

    override func viewWillLayoutSubviews() {
        let showSwitch = needsInputModeSwitchKey
        if nextKeyboardButton.isHidden == showSwitch {
            nextKeyboardButton.isHidden = !showSwitch
            switchBar.isHidden = !showSwitch
            // Drop the unused pin before adding the other, so the two bottoms never both apply.
            if showSwitch {
                galleryAtBottom.isActive = false
                galleryAboveBar.isActive = true
            } else {
                galleryAboveBar.isActive = false
                galleryAtBottom.isActive = true
            }
        }
        super.viewWillLayoutSubviews()
    }

    override func textDidChange(_ textInput: UITextInput?) {
        applyKeyboardAppearance()
    }

    /// Pins the gallery to the edges above a 44pt bar. The bar goes away when the switch key does.
    private func installSubviews() {
        let host = UIHostingController(rootView: KeyboardGalleryView(model: model))
        host.view.backgroundColor = .clear
        addChild(host)
        host.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(host.view)

        switchBar.translatesAutoresizingMaskIntoConstraints = false
        switchBar.backgroundColor = .clear
        view.addSubview(switchBar)

        nextKeyboardButton.setTitle("ABC", for: .normal)
        nextKeyboardButton.titleLabel?.font = UIFont(name: "IBMPlexMono-Medm", size: 16)
            ?? .monospacedSystemFont(ofSize: 16, weight: .medium)
        nextKeyboardButton.translatesAutoresizingMaskIntoConstraints = false
        // A SwiftUI Button cannot receive the UIEvent this selector needs.
        nextKeyboardButton.addTarget(self, action: #selector(handleInputModeList(from:with:)), for: .allTouchEvents)
        switchBar.addSubview(nextKeyboardButton)

        galleryAboveBar = host.view.bottomAnchor.constraint(equalTo: switchBar.topAnchor)
        galleryAtBottom = host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor)

        NSLayoutConstraint.activate([
            host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            host.view.topAnchor.constraint(equalTo: view.topAnchor),
            galleryAboveBar,
            switchBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            switchBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            switchBar.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            switchBar.heightAnchor.constraint(equalToConstant: 44),
            nextKeyboardButton.leadingAnchor.constraint(equalTo: switchBar.leadingAnchor, constant: 8),
            nextKeyboardButton.topAnchor.constraint(equalTo: switchBar.topAnchor),
            nextKeyboardButton.bottomAnchor.constraint(equalTo: switchBar.bottomAnchor),
            nextKeyboardButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 44),
        ])
        host.didMove(toParent: self)
    }

    private func applyKeyboardAppearance() {
        switch textDocumentProxy.keyboardAppearance {
        case .dark:
            view.overrideUserInterfaceStyle = .dark
        case .light:
            view.overrideUserInterfaceStyle = .light
        default:
            view.overrideUserInterfaceStyle = .unspecified
        }
        nextKeyboardButton.setTitleColor(.label, for: .normal)
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
