import CobaltKit
import SwiftUI
import WidgetKit

/// The widget extension's entry point: the run Live Activity (CONTRACT-LIVE.md 2.7) and the editor render's
/// (CONTRACT-EDITOR.md section 11), a chat reply's (CONTRACT-PARALLEL.md 15.10), no home-screen widgets.
@main
struct CobaltWidgetsBundle: WidgetBundle {
    init() { Telemetry.start(process: .widgets) }

    var body: some Widget {
        CobaltLiveActivity()
        EditLiveActivity()
        ChatLiveActivity()
    }
}
