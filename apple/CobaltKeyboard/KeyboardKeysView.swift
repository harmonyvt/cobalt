import UIKit

/// English QWERTY in the shape of the Apple keyboard. Letters, a one-shot shift (double-tap locks),
/// delete-repeat, and 123 / #+= pages. The globe is kept as a property so the controller can wire
/// `handleInputModeList` to it.
final class KeyboardKeysView: UIView, UIInputViewAudioFeedback {
    var enableInputClicksWhenVisible: Bool { true }

    var insert: (String) -> Void = { _ in }
    var deleteCharacter: () -> Void = {}

    /// Hidden, and its slot given to the space bar, when this keyboard has no switch key.
    var showsGlobe = true {
        didSet {
            guard oldValue != showsGlobe else { return }
            rebuild()
        }
    }

    let globeButton = KeyCap(type: .custom)

    private enum Plane { case letters, numbers, symbols }
    private enum Shift { case off, once, lock }

    private var plane = Plane.letters
    private var shift = Shift.off
    private var lastShiftTap = Date.distantPast
    private var deleteTimer: Timer?
    private var rows: [KeyRow] = []
    private var dark = true

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        globeButton.accessibilityLabel = "next keyboard"
        applySymbol("globe", to: globeButton, point: 18)
        rebuild()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func apply(dark: Bool) {
        self.dark = dark
        restyle()
    }

    // MARK: rows

    private func rebuild() {
        endDelete()
        for row in rows {
            for view in row.views where view !== globeButton { view.removeFromSuperview() }
        }
        globeButton.removeFromSuperview()
        rows = makeRows()
        for row in rows { row.views.forEach { addSubview($0) } }
        restyle()
        setNeedsLayout()
    }

    private func makeRows() -> [KeyRow] {
        switch plane {
        case .letters:
            return [
                KeyRow(views: letterKeys(["q", "w", "e", "r", "t", "y", "u", "i", "o", "p"]), flex: Array(repeating: 1, count: 10), inset: .none),
                KeyRow(views: letterKeys(["a", "s", "d", "f", "g", "h", "j", "k", "l"]), flex: Array(repeating: 1, count: 9), inset: .letter),
                KeyRow(views: [shiftKey()] + letterKeys(["z", "x", "c", "v", "b", "n", "m"]) + [deleteKey()], flex: [1.55] + Array(repeating: 1, count: 7) + [1.55], inset: .none),
                bottom(mode: "123"),
            ]
        case .numbers:
            return [
                KeyRow(views: charKeys(["1", "2", "3", "4", "5", "6", "7", "8", "9", "0"]), flex: Array(repeating: 1, count: 10), inset: .none),
                KeyRow(views: charKeys(["-", "/", ":", ";", "(", ")", "$", "&", "@", "\""]), flex: Array(repeating: 1, count: 10), inset: .none),
                KeyRow(views: [modeKey("#+=")] + charKeys([".", ",", "?", "!", "'"]) + [deleteKey()], flex: [1.55] + Array(repeating: 1, count: 5) + [1.55], inset: .none),
                bottom(mode: "ABC"),
            ]
        case .symbols:
            return [
                KeyRow(views: charKeys(["[", "]", "{", "}", "#", "%", "^", "*", "+", "="]), flex: Array(repeating: 1, count: 10), inset: .none),
                KeyRow(views: charKeys(["_", "\\", "|", "~", "<", ">", "€", "£", "¥", "•"]), flex: Array(repeating: 1, count: 10), inset: .none),
                KeyRow(views: [modeKey("123")] + charKeys([".", ",", "?", "!", "'"]) + [deleteKey()], flex: [1.55] + Array(repeating: 1, count: 5) + [1.55], inset: .none),
                bottom(mode: "ABC"),
            ]
        }
    }

    private func bottom(mode: String) -> KeyRow {
        var views: [UIView] = [modeKey(mode)]
        var flex: [CGFloat] = [1.5]
        if showsGlobe {
            views.append(globeButton)
            flex.append(1.15)
        }
        views.append(spaceKey())
        flex.append(showsGlobe ? 4.2 : 5.35)
        views.append(returnKey())
        flex.append(1.9)
        return KeyRow(views: views, flex: flex, inset: .none)
    }

    // MARK: keys

    private func letterKeys(_ letters: [String]) -> [UIView] {
        letters.map { letter in
            let shown = shift == .off ? letter : letter.uppercased()
            let key = charKey(shown)
            key.onTap = { [weak self] in
                guard let self else { return }
                self.type(self.shift == .off ? letter : letter.uppercased())
                if self.shift == .once {
                    self.shift = .off
                    self.rebuild()
                }
            }
            return key
        }
    }

    private func charKeys(_ chars: [String]) -> [UIView] {
        chars.map { text in
            let key = charKey(text)
            key.onTap = { [weak self] in self?.type(text) }
            return key
        }
    }

    private func charKey(_ title: String) -> KeyCap {
        let key = KeyCap(type: .custom)
        key.setTitle(title, for: .normal)
        key.titleLabel?.font = .systemFont(ofSize: 22)
        key.special = false
        return key
    }

    private func shiftKey() -> KeyCap {
        let key = KeyCap(type: .custom)
        key.special = shift == .off
        key.accessibilityLabel = "shift"
        applySymbol(shift == .lock ? "shift.fill" : "shift", to: key, point: 18)
        key.onTap = { [weak self] in self?.toggleShift() }
        return key
    }

    private func deleteKey() -> KeyCap {
        let key = KeyCap(type: .custom)
        key.special = true
        key.accessibilityLabel = "delete"
        applySymbol("delete.left", to: key, point: 18)
        key.onDown = { [weak self] in self?.beginDelete() }
        key.onUp = { [weak self] in self?.endDelete() }
        return key
    }

    private func modeKey(_ title: String) -> KeyCap {
        let key = KeyCap(type: .custom)
        key.special = true
        key.setTitle(title, for: .normal)
        key.titleLabel?.font = .systemFont(ofSize: 16)
        key.onTap = { [weak self] in self?.switchPlane(title) }
        return key
    }

    private func spaceKey() -> KeyCap {
        let key = KeyCap(type: .custom)
        key.special = false
        key.accessibilityLabel = "space"
        key.onTap = { [weak self] in self?.type(" ") }
        return key
    }

    private func returnKey() -> KeyCap {
        let key = KeyCap(type: .custom)
        key.special = true
        key.setTitle("return", for: .normal)
        key.titleLabel?.font = .systemFont(ofSize: 16)
        key.onTap = { [weak self] in self?.type("\n") }
        return key
    }

    private func applySymbol(_ name: String, to key: UIButton, point: CGFloat) {
        let image = UIImage(systemName: name, withConfiguration: UIImage.SymbolConfiguration(pointSize: point, weight: .regular))
        key.setImage(image, for: .normal)
        key.setTitle(nil, for: .normal)
    }

    // MARK: actions

    private func type(_ text: String) {
        UIDevice.current.playInputClick()
        insert(text)
    }

    private func toggleShift() {
        UIDevice.current.playInputClick()
        let now = Date()
        if shift == .lock {
            shift = .off
        } else if shift == .once, now.timeIntervalSince(lastShiftTap) < 0.35 {
            shift = .lock
        } else if shift == .off {
            shift = .once
        } else {
            shift = .off
        }
        lastShiftTap = now
        rebuild()
    }

    private func switchPlane(_ title: String) {
        UIDevice.current.playInputClick()
        switch title {
        case "123": plane = .numbers
        case "#+=": plane = .symbols
        default:
            plane = .letters
        }
        rebuild()
    }

    private func beginDelete() {
        UIDevice.current.playInputClick()
        deleteCharacter()
        deleteTimer?.invalidate()
        let wait = Timer(timeInterval: 0.4, repeats: false) { [weak self] _ in
            guard let self else { return }
            let repeatTimer = Timer(timeInterval: 0.08, repeats: true) { [weak self] _ in
                self?.deleteCharacter()
            }
            RunLoop.main.add(repeatTimer, forMode: .common)
            self.deleteTimer = repeatTimer
        }
        RunLoop.main.add(wait, forMode: .common)
        deleteTimer = wait
    }

    private func endDelete() {
        deleteTimer?.invalidate()
        deleteTimer = nil
    }

    // MARK: paint and place

    private func restyle() {
        let label = KeyboardChrome.label(dark: dark)
        let letter = KeyboardChrome.letterKey(dark: dark)
        let special = KeyboardChrome.specialKey(dark: dark)
        for row in rows {
            for case let key as KeyCap in row.views {
                key.fill = key.special ? special : letter
                key.tintColor = label
                key.setTitleColor(label, for: .normal)
            }
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.width > 1, !rows.isEmpty else { return }
        let gap: CGFloat = 6
        let vGap: CGFloat = 8
        let side: CGFloat = 3
        let rowH = max(32, (bounds.height - vGap * CGFloat(rows.count - 1) - 4) / CGFloat(rows.count))
        let letterWidth = (bounds.width - side * 2 - gap * 9) / 10
        var y: CGFloat = 2
        for row in rows {
            let inset: CGFloat
            if row.inset == .letter {
                inset = max(side, (bounds.width - letterWidth * 9 - gap * 8) / 2)
            } else {
                inset = side
            }
            let flex = row.flex.reduce(0, +)
            let available = bounds.width - inset * 2 - gap * CGFloat(row.views.count - 1)
            let unit = available / max(flex, 1)
            var x = inset
            for (index, view) in row.views.enumerated() {
                let width = (unit * row.flex[index]).rounded(.down)
                view.frame = CGRect(x: x, y: y, width: width, height: rowH)
                x += width + gap
            }
            y += rowH + vGap
        }
    }
}

private struct KeyRow {
    enum Inset { case none, letter }
    var views: [UIView]
    var flex: [CGFloat]
    var inset: Inset
}

/// One key. `onDown` / `onUp` are for delete-repeat. `onTap` fires on touch-up inside.
final class KeyCap: UIButton {
    var special = false
    var fill = UIColor.white { didSet { paint() } }
    var onTap: () -> Void = {}
    var onDown: (() -> Void)?
    var onUp: (() -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        layer.cornerRadius = 5
        layer.cornerCurve = .continuous
        titleLabel?.adjustsFontSizeToFitWidth = true
        titleLabel?.minimumScaleFactor = 0.6
        addTarget(self, action: #selector(down), for: .touchDown)
        addTarget(self, action: #selector(upInside), for: .touchUpInside)
        addTarget(self, action: #selector(up), for: [.touchUpOutside, .touchCancel])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override var isHighlighted: Bool {
        didSet { paint() }
    }

    private func paint() {
        backgroundColor = isHighlighted ? fill.withAlphaComponent(0.65) : fill
    }

    @objc private func down() {
        if let onDown { onDown() } 
    }

    @objc private func upInside() {
        if onDown != nil { onUp?() } else { onTap() }
    }

    @objc private func up() { onUp?() }
}

/// The keyboard's root view. Self-sizing so iOS does not collapse the extension to a one-line bar.
final class KeyboardChromeView: UIInputView, UIInputViewAudioFeedback {
    var enableInputClicksWhenVisible: Bool { true }
    var preferredHeight: CGFloat = 291 {
        didSet { invalidateIntrinsicContentSize() }
    }

    override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric, height: preferredHeight)
    }
}

enum KeyboardChrome {
    static func background(dark: Bool) -> UIColor {
        dark ? UIColor(white: 0.17, alpha: 1) : UIColor(white: 0.82, alpha: 1)
    }

    static func letterKey(dark: Bool) -> UIColor {
        dark ? UIColor(white: 0.45, alpha: 1) : .white
    }

    static func specialKey(dark: Bool) -> UIColor {
        dark ? UIColor(white: 0.32, alpha: 1) : UIColor(white: 0.68, alpha: 1)
    }

    static func label(dark: Bool) -> UIColor {
        dark ? .white : .black
    }
}
