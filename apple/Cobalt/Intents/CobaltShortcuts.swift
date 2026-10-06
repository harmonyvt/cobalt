import AppIntents

/// Siri, Spotlight and the Action button (CONTRACT-PARALLEL.md 15.5). Every phrase contains the app name, as App Shortcuts
/// require. "Upload files" has no phrase: it needs a file, so it is an action in Shortcuts that any shortcut passing files
/// can run. From Siri, "Save links" has no input and reads the clipboard.
struct CobaltShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: SaveLinksIntent(),
            phrases: [
                "Save my copied link with \(.applicationName)",
                "Save a link in \(.applicationName)",
            ],
            shortTitle: "save link",
            systemImageName: "link")
        AppShortcut(
            intent: LatestSavesIntent(),
            phrases: [
                "Get my latest \(.applicationName) save",
                "What did I last save in \(.applicationName)",
            ],
            shortTitle: "latest save",
            systemImageName: "clock.arrow.circlepath")
        if #available(iOS 27, macOS 27, *) {
            AppShortcut(
                intent: MakeWebpIntent(),
                phrases: [
                    "Make a webp in \(.applicationName)",
                    "Make a webp of my latest \(.applicationName) save",
                ],
                shortTitle: "make webp",
                systemImageName: "photo.stack")
        }
    }
}
