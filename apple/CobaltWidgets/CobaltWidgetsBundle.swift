import CobaltKit
import SwiftUI
import WidgetKit

/// The widget extension's entry point: one Live Activity, no home-screen widgets
/// (CONTRACT-LIVE.md 2.7). Lane UI replaces the placeholder views in `LiveViews.swift`.
@main
struct CobaltWidgetsBundle: WidgetBundle {
    init() { Telemetry.start(process: .widgets) }

    var body: some Widget {
        CobaltLiveActivity()
    }
}
