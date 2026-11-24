import CobaltKit
import SwiftUI
import WidgetKit

/// The widget extension's entry point, no home-screen widgets. `JobLiveActivity` is the one Live Activity for every job
/// (CONTRACT-JOBLIVE.md): saves, uploads, makes, editor renders, chat replies and swarms.
@main
struct CobaltWidgetsBundle: WidgetBundle {
    init() { Telemetry.start(process: .widgets) }

    var body: some Widget {
        JobLiveActivity()
    }
}
