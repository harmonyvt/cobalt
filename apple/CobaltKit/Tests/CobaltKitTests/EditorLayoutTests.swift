import CoreGraphics
import Foundation
import Testing
@testable import CobaltKit

// One editor for every screen (apple/CONTRACT-EDITOR.md 15.1): the slots `EditorLayout` gives each size, on the six screens
// of the mockup (iPhone, Duo folded, Duo open, Duo turned, iPad, Mac) with a 16:9 and a 9:16 canvas.

private struct Screen: Sendable, CustomStringConvertible {
    let w: CGFloat, h: CGFloat
    let platform: EditorLayout.Platform
    let regime: EditorLayout.Regime
    var description: String { "\(Int(w))x\(Int(h))" }
}

private let screens: [Screen] = [
    Screen(w: 402, h: 874, platform: .ios, regime: .compact),     // iPhone
    Screen(w: 461, h: 940, platform: .ios, regime: .compact),     // Duo folded
    Screen(w: 669, h: 951, platform: .ios, regime: .tall),        // Duo open
    Screen(w: 951, h: 669, platform: .ios, regime: .wide),        // Duo open, turned
    Screen(w: 1180, h: 820, platform: .ios, regime: .wide),       // iPad landscape
    Screen(w: 1280, h: 800, platform: .mac, regime: .wide),       // Mac
]

private let aspects: [CGFloat] = [16.0 / 9.0, 9.0 / 16.0]

private let cases: [(Screen, CGFloat)] = screens.flatMap { s in aspects.map { (s, $0) } }

private let tolerance: CGFloat = 0.5

private func layout(_ s: Screen, _ aspect: CGFloat) -> EditorLayout {
    EditorLayout(size: CGSize(width: s.w, height: s.h), platform: s.platform, canvasAspect: aspect)
}

/// Every slot that must not overlap another (the drawer is the one allowed over the timeline).
private func solidSlots(_ l: EditorLayout) -> [(String, CGRect)] {
    var slots = [("topBar", l.topBar), ("picture", l.picture), ("transport", l.transport), ("timeline", l.timeline), ("tools", l.tools)]
    if let inspector = l.inspector { slots.append(("inspector", inspector)) }
    return slots
}

private func inside(_ r: CGRect, _ outer: CGRect) -> Bool {
    r.minX >= outer.minX - tolerance && r.minY >= outer.minY - tolerance
        && r.maxX <= outer.maxX + tolerance && r.maxY <= outer.maxY + tolerance
}

/// Overlap of more than a hair (touching edges are fine).
private func overlaps(_ a: CGRect, _ b: CGRect) -> Bool {
    let i = a.intersection(b)
    return !i.isNull && i.width > tolerance && i.height > tolerance
}

struct EditorLayoutTests {
    @Test(arguments: cases)
    fileprivate func regimeMatchesTheContract(_ s: Screen, _ aspect: CGFloat) {
        #expect(layout(s, aspect).regime == s.regime, "\(s)")
    }

    @Test(arguments: cases)
    fileprivate func pictureIsExactlyTheCanvasShape(_ s: Screen, _ aspect: CGFloat) {
        let p = layout(s, aspect).picture
        #expect(p.width > 100 && p.height > 100, "\(s) picture \(p)")
        #expect(abs(p.width - p.height * aspect) <= tolerance, "\(s) \(aspect): \(p.size)")
    }

    @Test(arguments: cases)
    fileprivate func noBandAboveOrBelowThePicture(_ s: Screen, _ aspect: CGFloat) {
        let l = layout(s, aspect)
        #expect(abs(l.picture.minY - l.topBar.maxY) <= tolerance, "\(s) band above: \(l.picture.minY) vs \(l.topBar.maxY)")
        #expect(abs(l.transport.minY - l.picture.maxY) <= tolerance, "\(s) band below: \(l.transport.minY) vs \(l.picture.maxY)")
        #expect(l.transport.height == EditorLayout.transportHeight)
    }

    @Test(arguments: cases)
    fileprivate func slotsDoNotOverlap(_ s: Screen, _ aspect: CGFloat) {
        let slots = solidSlots(layout(s, aspect))
        for i in slots.indices {
            for j in slots.indices where j > i {
                #expect(!overlaps(slots[i].1, slots[j].1), "\(s) \(aspect): \(slots[i].0) \(slots[i].1) overlaps \(slots[j].0) \(slots[j].1)")
            }
        }
    }

    @Test(arguments: cases)
    fileprivate func everythingIsInsideTheContent(_ s: Screen, _ aspect: CGFloat) {
        let l = layout(s, aspect)
        #expect(l.content == CGRect(x: 0, y: 0, width: s.w, height: s.h))
        for (name, rect) in solidSlots(l) {
            #expect(inside(rect, l.content), "\(s) \(name) \(rect) leaves the content")
        }
        for detent in [l.drawerLow, l.drawerHigh].compactMap({ $0 }) {
            #expect(inside(detent, l.content))
        }
    }

    @Test(arguments: cases)
    fileprivate func theDrawerCoversOnlyTheTimeline(_ s: Screen, _ aspect: CGFloat) {
        let l = layout(s, aspect)
        if s.regime == .wide {
            #expect(l.drawerLow == nil && l.drawerHigh == nil)
            #expect(l.inspector != nil)
            return
        }
        #expect(l.inspector == nil)
        guard let low = l.drawerLow, let high = l.drawerHigh else {
            Issue.record("\(s) has no drawer")
            return
        }
        for drawer in [low, high] {
            #expect(inside(drawer, l.timeline), "\(s) drawer \(drawer) leaves the timeline \(l.timeline)")
            #expect(!overlaps(drawer, l.picture) && !overlaps(drawer, l.transport) && !overlaps(drawer, l.tools))
            #expect(abs(drawer.maxY - l.timeline.maxY) <= tolerance, "the drawer rises from the timeline's bottom")
        }
        #expect(low.height <= high.height)
        #expect(low.height <= EditorLayout.drawerDetentHeight + tolerance)
        #expect(high.height <= l.timeline.height + tolerance)
    }

    @Test(arguments: cases)
    fileprivate func theTimelineTakesEveryPointLeft(_ s: Screen, _ aspect: CGFloat) {
        let l = layout(s, aspect)
        switch l.regime {
        case .compact, .tall:
            #expect(abs(l.timeline.minY - l.transport.maxY) <= tolerance)
            #expect(abs(l.timeline.maxY - l.tools.minY) <= tolerance)
            #expect(abs(l.tools.maxY - s.h) <= tolerance)
            #expect(l.tools.width == s.w && l.tools.height == EditorLayout.toolRowHeight)
            let cap = s.h * (l.regime == .tall ? EditorLayout.tallPictureCap : EditorLayout.compactPictureCap)
            #expect(l.picture.height <= cap + tolerance)
            // centred across, the side bands equal
            #expect(abs(l.picture.minX - (s.w - l.picture.maxX)) <= tolerance)
        case .wide:
            #expect(l.timeline.minX == 0 && l.timeline.width == s.w)
            #expect(abs(l.timeline.maxY - s.h) <= tolerance)
            #expect(l.timeline.height >= EditorLayout.wideTimelineMinimum - tolerance)
            #expect(l.timeline.height >= s.h * EditorLayout.wideTimelineFraction - tolerance)
            #expect(abs(l.transport.maxY - l.timeline.minY) <= tolerance, "nothing between the transport and the timeline")
            // the rail on the left, the inspector on the right, the picture centred in the middle column
            #expect(l.tools.minX == 0 && l.tools.width == EditorLayout.toolRailWidth)
            let inspector = l.inspector!
            #expect(abs(inspector.maxX - s.w) <= tolerance)
            #expect(inspector.width <= EditorLayout.inspectorWidth && inspector.width >= EditorLayout.inspectorMinWidth)
            #expect(abs(l.transport.minX - l.tools.maxX) <= tolerance && abs(l.transport.maxX - inspector.minX) <= tolerance)
            #expect(abs((l.picture.minX - l.transport.minX) - (l.transport.maxX - l.picture.maxX)) <= tolerance)
            #expect(abs(l.tools.minY - l.topBar.maxY) <= tolerance && abs(inspector.minY - l.topBar.maxY) <= tolerance)
            #expect(abs(l.tools.maxY - l.timeline.minY) <= tolerance && abs(inspector.maxY - l.timeline.minY) <= tolerance)
        }
    }

    @Test func regimeThresholds() {
        func r(_ w: CGFloat, _ h: CGFloat) -> EditorLayout.Regime { EditorLayout.regime(for: CGSize(width: w, height: h)) }
        #expect(r(599, 900) == .compact)
        #expect(r(600, 900) == .tall)
        #expect(r(899, 1200) == .tall)
        #expect(r(900, 1200) == .wide)      // width ≥ 900 is wide even when taller than wide
        #expect(r(700, 699) == .wide)
        #expect(r(699, 600) == .compact)    // 600…699 landscape: neither tall nor wide
        #expect(r(750, 750) == .compact)    // square under 900
        #expect(r(1024, 1366) == .wide)     // iPad Pro portrait is ≥ 900 wide
        #expect(r(744, 1133) == .tall)      // iPad mini portrait
    }

    @Test func ashortWideScreenKeepsAPicture() {
        // an iPhone turned sideways, after the safe area
        let l = EditorLayout(size: CGSize(width: 750, height: 381), platform: .ios, canvasAspect: 16.0 / 9.0)
        #expect(l.regime == .wide)
        #expect(l.timeline.height <= (381 - EditorLayout.topBarHeight) * EditorLayout.wideTimelineMaxFraction + tolerance)
        #expect(l.picture.height >= 100)
    }

    @Test func aDraggedTimelineEdgeIsClamped() {
        let size = CGSize(width: 1280, height: 800)
        let short = EditorLayout(size: size, platform: .mac, canvasAspect: 16.0 / 9.0, preferredTimelineHeight: 100)
        #expect(abs(short.timeline.height - EditorLayout.wideTimelineMinimum) <= tolerance)
        let tallTimeline = EditorLayout(size: size, platform: .mac, canvasAspect: 16.0 / 9.0, preferredTimelineHeight: 2000)
        #expect(tallTimeline.picture.height >= EditorLayout.widePreferredPictureMinimum - tolerance)
        #expect(abs(tallTimeline.picture.minY - tallTimeline.topBar.maxY) <= tolerance)
        let mid = EditorLayout(size: size, platform: .mac, canvasAspect: 16.0 / 9.0, preferredTimelineHeight: 420)
        #expect(abs(mid.timeline.height - 420) <= tolerance)
    }

    @Test func aWidthLimitedPictureGivesTheRestToTheTimeline() {
        // a very wide canvas in the middle column: the picture is held back by width, not height
        let l = EditorLayout(size: CGSize(width: 951, height: 669), platform: .ios, canvasAspect: 4)
        #expect(abs(l.picture.width - (951 - EditorLayout.toolRailWidth - l.inspector!.width)) <= tolerance)
        #expect(l.timeline.height > 669 * EditorLayout.wideTimelineFraction)
        #expect(abs(l.transport.maxY - l.timeline.minY) <= tolerance)
    }

    @Test func theCanvasInitUsesTheProjectsShape() {
        let canvas = EditCanvas(shape: .story, resolution: .p1080, fps: 30)
        let l = EditorLayout(size: CGSize(width: 402, height: 874), platform: .ios, canvas: canvas)
        #expect(abs(l.canvasAspect - CGFloat(canvas.w) / CGFloat(canvas.h)) < 0.0001)
        #expect(abs(l.picture.width / l.picture.height - l.canvasAspect) < 0.01)
    }

    @Test func inspectorRectFollowsTheDetent() {
        let phone = EditorLayout(size: CGSize(width: 402, height: 874), platform: .ios, canvasAspect: 16.0 / 9.0)
        #expect(phone.inspectorRect(.closed) == nil)
        #expect(phone.inspectorRect(.low) == phone.drawerLow)
        #expect(phone.inspectorRect(.high) == phone.drawerHigh)
        let mac = EditorLayout(size: CGSize(width: 1280, height: 800), platform: .mac, canvasAspect: 16.0 / 9.0)
        for detent in EditorLayout.DrawerDetent.allCases { #expect(mac.inspectorRect(detent) == mac.inspector) }
    }
}

// MARK: - the screen's memory (15.2)

@MainActor
struct EditorLayoutEditorUITests {
    @Test func aRegimeChangeCommitsTheGestureOnlyWhenItChanges() {
        let ui = EditorUI()
        var commits = 0
        ui.regimeChanged(to: .compact) { commits += 1 }
        #expect(commits == 0, "the first layout is not a change")
        ui.regimeChanged(to: .compact) { commits += 1 }
        #expect(commits == 0)
        ui.regimeChanged(to: .wide) { commits += 1 }
        #expect(commits == 1)
        #expect(ui.regime == .wide)
    }

    @Test func narrowingWithAToolOpenBringsUpTheDrawer() {
        let ui = EditorUI()
        ui.regimeChanged(to: .wide) {}
        ui.open(.speed, page: .speed)
        ui.drawer = .closed          // wide never shows the drawer; say it was down
        ui.regimeChanged(to: .compact) {}
        #expect(ui.drawer == .low)
        #expect(ui.page == .speed && ui.openTool == .speed)
    }

    @Test func zoomScrollAndPageSurviveRegimeChanges() {
        let ui = EditorUI()
        ui.timelinePointsPerSecond = 120
        ui.timelineScrollSeconds = 14.5
        ui.pictureZoom = 2
        ui.open(.trim, page: .trim)
        ui.drawer = .high
        for regime in [EditorLayout.Regime.compact, .wide, .tall, .compact] { ui.regimeChanged(to: regime) {} }
        #expect(ui.timelinePointsPerSecond == 120 && ui.timelineScrollSeconds == 14.5 && ui.pictureZoom == 2)
        #expect(ui.page == .trim && ui.openTool == .trim && ui.drawer == .high)
    }

    @Test func openingAToolWithoutAPageLeavesTheDrawer() {
        let ui = EditorUI()
        ui.open(.addClip, page: nil)
        #expect(ui.openTool == .addClip && ui.drawer == .closed)
        ui.open(.sound, page: .sound)
        #expect(ui.drawer == .low)
        ui.stepDrawer(up: true)
        #expect(ui.drawer == .high)
        ui.stepDrawer(up: true)
        #expect(ui.drawer == .high)
        ui.stepDrawer(up: false)
        ui.stepDrawer(up: false)
        #expect(ui.drawer == .closed && ui.openTool == nil)
        ui.open(.crop, page: .crop)
        ui.closeTool()
        #expect(ui.openTool == nil && ui.page == .project && ui.drawer == .closed)
    }
}
