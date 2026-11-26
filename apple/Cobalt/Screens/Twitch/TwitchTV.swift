import AVFoundation
import CobaltKit
import SwiftUI
#if os(iOS)
import AVKit
import UIKit
#endif

// The stream on a TV (APP-API-CONTRACT 70.5, app only). Two ways:
//
// - tv mode: the owner turns on Screen Mirroring (Control Center; an app can't start it). While a channel is open in the
//   twitch tab, capystore puts its own window on that screen instead of a copy of the phone: Twitch's player full screen
//   (the shared `TwitchPlayerHost` web view moves there without a reload). The phone stops showing the player and gives its
//   screen to chat. Same delay as watching on the phone, so chat lines up.
// - video only: plain AirPlay of the web video. The TV fetches the stream itself, so it runs several seconds behind the
//   phone; chat is held back (`chatDelay`) to match.
//
// iOS 27 SDK: the system no longer connects a `windowExternalDisplayNonInteractive` scene by itself. The watch view registers
// a scene accessory (`TwitchTVAccessory`), so outside a channel the TV mirrors the phone as usual. Older systems connect the
// scene through `CobaltAppDelegate` (`configurationForConnecting`) and the scene delegate leaves the TV mirroring until a
// channel is open.

/// Where the twitch stream goes when a TV is around. One for the app.
@MainActor @Observable
final class TwitchTV {
    static let shared = TwitchTV()

    /// Chat hold-back choices for video-only AirPlay (seconds; 0 = off).
    static let delayChoices = [0, 5, 10, 15, 20, 30]

    /// A TV screen capystore can draw on is connected (screen mirroring is on and the system handed over its scene).
    private(set) var screenConnected = false
    /// capystore's own window is on the TV, playing the stream.
    private(set) var onTV = false
    /// The phone is sending sound or video to an AirPlay device without screen mirroring (video only).
    private(set) var airPlayRoute = false
    /// Port UID of the active AirPlay output, if any (distinguishes re-selecting a different TV from an audio-only speaker).
    private(set) var airPlayOutputUID: String?
    /// The phone screen is dimmed for watching (tv mode only; restored when tv mode ends).
    private(set) var dimmed = false

    /// The owner's choice while mirroring: the stream on the TV (true) or a plain copy of the phone (false).
    var wanted: Bool = UserDefaults.standard.object(forKey: Keys.wanted) as? Bool ?? true {
        didSet { UserDefaults.standard.set(wanted, forKey: Keys.wanted); refresh() }
    }
    /// Chat drawn over the stream on the TV too (off by default).
    var chatOnTV: Bool = UserDefaults.standard.bool(forKey: Keys.chatOnTV) {
        didSet { UserDefaults.standard.set(chatOnTV, forKey: Keys.chatOnTV) }
    }
    /// Seconds chat waits in video-only AirPlay, so it matches the TV.
    var chatDelay: Int = UserDefaults.standard.object(forKey: Keys.chatDelay) as? Int ?? 10 {
        didSet { UserDefaults.standard.set(chatDelay, forKey: Keys.chatDelay) }
    }

    /// The delay chat runs with now: only while video goes out over AirPlay without capystore's own TV window.
    var activeChatDelay: TimeInterval {
        guard !onTV, !screenConnected else { return 0 }
        if TwitchPlayerHost.shared.activeMode == .lowLatency {
            return TwitchPlayerHost.shared.isAirPlayingVideo ? TimeInterval(chatDelay) : 0
        }
        return airPlayRoute ? TimeInterval(chatDelay) : 0
    }

    @ObservationIgnored weak var model: AppModel?
    @ObservationIgnored private var watching = 0
    #if os(iOS)
    @ObservationIgnored private var scenes: [ObjectIdentifier: TwitchTVSceneDelegate] = [:]
    @ObservationIgnored private var brightnessBefore: CGFloat?
    @ObservationIgnored private var routeObserver: NSObjectProtocol?
    #endif

    private enum Keys {
        static let wanted = "twitch.tv.wanted"
        static let chatOnTV = "twitch.tv.chatOnTV"
        static let chatDelay = "twitch.tv.chatDelay"
    }

    private init() {
        #if os(iOS)
        routeObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { TwitchTV.shared.readRoute() }
        }
        readRoute()
        #endif
    }

    /// The channel open in the twitch tab, when the stream should be on the TV.
    var tvChannel: String? {
        guard wanted, watching > 0 else { return nil }
        return model?.twitch.channel
    }

    // MARK: the watch view

    /// A watch view came on screen (or a channel changed under it).
    func watchStarted(_ model: AppModel) {
        self.model = model
        TwitchPlayerHost.shared.attachModel(model)
        watching += 1
        refresh()
    }

    func watchEnded() {
        watching = max(0, watching - 1)
        refresh()
    }

    /// Re-decide what the TV shows (a channel opened or closed, the owner's choice changed).
    func refresh() {
        #if os(iOS)
        let show = tvChannel != nil
        for scene in scenes.values { scene.show(show ? model : nil) }
        let nowOnTV = show && scenes.values.contains { $0.isShowing }
        if nowOnTV != onTV {
            onTV = nowOnTV
            if nowOnTV { TwitchPlayerHost.shared.handleTVModeActivated() }
        }
        // Locking the phone ends screen mirroring: while the stream is on the TV the phone stays awake.
        UIApplication.shared.isIdleTimerDisabled = onTV
        if !onTV, dimmed { undim() }
        #endif
    }

    #if os(iOS)
    // MARK: the TV scene

    func attach(_ scene: TwitchTVSceneDelegate) {
        scenes[ObjectIdentifier(scene)] = scene
        screenConnected = true
        refresh()
    }

    func detach(_ scene: TwitchTVSceneDelegate) {
        scenes[ObjectIdentifier(scene)] = nil
        screenConnected = !scenes.isEmpty
        refresh()
    }

    // MARK: the phone screen

    /// Dims the phone so it can rest face up while the stream plays on the TV; again to undo.
    func toggleDim() {
        dimmed ? undim() : dim()
    }

    private func dim() {
        guard let screen = phoneScreen else { return }
        brightnessBefore = screen.brightness
        screen.brightness = 0.02
        dimmed = true
    }

    private func undim() {
        if let screen = phoneScreen, let before = brightnessBefore { screen.brightness = before }
        brightnessBefore = nil
        dimmed = false
    }

    private var phoneScreen: UIScreen? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.session.role == .windowApplication }?
            .screen
    }

    // MARK: AirPlay (video only)

    fileprivate func readRoute() {
        let out = AVAudioSession.sharedInstance().currentRoute.outputs
        let port = out.first { $0.portType == .airPlay }
        let airPlay = port != nil
        let uid = port?.uid
        let changed = (airPlay != airPlayRoute) || (uid != airPlayOutputUID)
        if airPlay != airPlayRoute { airPlayRoute = airPlay }
        if uid != airPlayOutputUID { airPlayOutputUID = uid }
        if changed {
            TwitchPlayerHost.shared.airPlayRouteChanged(active: airPlay, outputUID: uid)
        }
    }
    #endif
}

#if os(iOS)
// MARK: - the TV scene

/// The TV's scene (`windowExternalDisplayNonInteractive`). Holds capystore's TV window while a channel should be on the
/// TV; without one the system mirrors the phone.
@MainActor
final class TwitchTVSceneDelegate: NSObject, UIWindowSceneDelegate {
    var window: UIWindow?
    private weak var windowScene: UIWindowScene?

    var isShowing: Bool { window != nil }

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        guard let scene = scene as? UIWindowScene else { return }
        windowScene = scene
        TwitchTV.shared.attach(self)
    }

    func sceneDidDisconnect(_ scene: UIScene) {
        hide()
        TwitchTV.shared.detach(self)
    }

    /// Puts the TV window up for `model` (nil: takes it down, the TV mirrors the phone again).
    func show(_ model: AppModel?) {
        guard let model else { hide(); return }
        guard window == nil, let windowScene else { return }
        let w = UIWindow(windowScene: windowScene)
        let root = UIHostingController(rootView: TwitchTVRoot(model: model))
        root.view.backgroundColor = .black
        w.rootViewController = root
        w.isHidden = false
        window = w
    }

    private func hide() {
        guard let w = window else { return }
        w.isHidden = true
        w.windowScene = nil
        window = nil
    }

    /// The scene's setup, for `CobaltAppDelegate` (systems before iOS 27) and the iOS 27 accessory.
    static func configuration(role: UISceneSession.Role) -> UISceneConfiguration {
        let config = UISceneConfiguration(name: "twitch-tv", sessionRole: role)
        config.delegateClass = TwitchTVSceneDelegate.self
        return config
    }
}

/// Registers the TV scene while the watch view is on screen (iOS 27 and later). Nothing before iOS 27: the app delegate
/// does it there.
struct TwitchTVAccessory: UIViewControllerRepresentable {
    let enabled: Bool

    func makeUIViewController(context: Context) -> TwitchTVAccessoryController {
        TwitchTVAccessoryController()
    }

    func updateUIViewController(_ controller: TwitchTVAccessoryController, context: Context) {
        controller.setEnabled(enabled)
    }
}

final class TwitchTVAccessoryController: UIViewController {
    private var registration: AnyObject?
    private var enabled = true

    override func viewDidLoad() {
        super.viewDidLoad()
        view.isUserInteractionEnabled = false
        view.backgroundColor = .clear
        if #available(iOS 27.0, *) {
            let config = TwitchTVSceneDelegate.configuration(role: .windowExternalDisplayNonInteractive)
            let reg = registerSceneAccessory(UISceneAccessory.externalNonInteractive(sceneConfiguration: config))
            reg.isEnabled = enabled
            registration = reg
        }
    }

    func setEnabled(_ on: Bool) {
        enabled = on
        if #available(iOS 27.0, *), let reg = registration as? UISceneAccessoryRegistration {
            reg.isEnabled = on
        }
    }
}

// MARK: - what the TV shows

/// The TV window: Twitch's player edge to edge, and the chat column when the owner turned it on.
struct TwitchTVRoot: View {
    let model: AppModel

    private var tv: TwitchTV { .shared }
    private var store: TwitchStore { model.twitch }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let channel = tv.tvChannel {
                TwitchPlayer(channel: channel, showsDelay: false)
                    .aspectRatio(16 / 9, contentMode: .fit)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                if tv.chatOnTV {
                    TwitchTVChat(snapshot: store.chat)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
                        .padding(28)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }
                Label(Copy.Twitch.tvBrand, systemImage: Symbol.Twitch.tv)
                    .font(Font.cobalt(15, .medium))
                    .foregroundStyle(.white.opacity(0.55))
                    .padding(28)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
            } else {
                Text(Copy.Twitch.tvIdle)
                    .font(Font.cobalt(22, .medium))
                    .foregroundStyle(.white.opacity(0.6))
            }
        }
        .animation(.easeOut(duration: 0.25), value: tv.chatOnTV)
        .preferredColorScheme(.dark)
    }
}

/// The newest chat lines on the TV, see-through, no scrolling and no taps (the phone is the remote).
private struct TwitchTVChat: View {
    let snapshot: TwitchChatSnapshot?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Spacer(minLength: 0)
            ForEach((snapshot?.lines ?? []).suffix(14)) { line in
                TwitchChatRow(
                    line: line,
                    paint: snapshot?.paints[line.login],
                    sevenTvBadge: snapshot?.sevenTvBadges[line.login],
                    canAddEmotes: false)
                .equatable()
            }
        }
        .padding(12)
        .frame(width: 380)
        .frame(maxHeight: .infinity)
        .clipped()
        .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 22))
        .environment(\.colorScheme, .dark)
    }
}

// MARK: - AirPlay picker

/// The system's AirPlay device list (video only).
struct TwitchAirPlayButton: UIViewRepresentable {
    var tint: UIColor = .label

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> AVRoutePickerView {
        let picker = AVRoutePickerView()
        picker.prioritizesVideoDevices = true
        picker.tintColor = tint
        picker.activeTintColor = UIColor(TwitchChatPalette.twitch)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIView(_ view: AVRoutePickerView, context: Context) {
        view.tintColor = tint
    }

    final class Coordinator: NSObject, AVRoutePickerViewDelegate {
        nonisolated func routePickerViewWillBeginPresentingRoutes(_ routePickerView: AVRoutePickerView) {
            Task { @MainActor in
                TwitchPlayerHost.shared.prepareAirPlayRoutePicker()
            }
        }

        nonisolated func routePickerViewDidEndPresentingRoutes(_ routePickerView: AVRoutePickerView) {
            Task { @MainActor in
                TwitchPlayerHost.shared.finishAirPlayRoutePicker()
            }
        }
    }
}
#endif
