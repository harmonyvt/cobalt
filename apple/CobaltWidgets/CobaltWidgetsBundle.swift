import CobaltKit
import SwiftUI
import WidgetKit

/// The widget extension's entry point, no home-screen widgets. `JobLiveActivity` is the one Live Activity for every job
/// (CONTRACT-JOBLIVE.md): saves, uploads, makes, editor renders and chat replies. The three before it stay one more release
/// so activities already on screen keep drawing: the run's (CONTRACT-LIVE.md 2.7), the editor render's (CONTRACT-EDITOR.md
/// section 11) and a chat reply's (CONTRACT-PARALLEL.md 15.10). They are deleted in the follow-up (CONTRACT-JOBLIVE.md 5).
@main
struct CobaltWidgetsBundle: WidgetBundle {
    init() { Telemetry.start(process: .widgets) }

    var body: some Widget {
        JobLiveActivity()
        CobaltLiveActivity()
        EditLiveActivity()
        ChatLiveActivity()
    }
}
