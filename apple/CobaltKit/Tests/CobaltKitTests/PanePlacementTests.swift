import CoreGraphics
import Foundation
import Testing
@testable import CobaltKit

// Where the pane goes (apple/CONTRACT-PANE.md section 2), for the Duo, the iPhone, the iPad and the Mac.
@Suite struct PanePlacementTests {
    private func resolve(_ w: CGFloat, _ h: CGFloat, _ idiom: PanePlacement.Idiom, feature: CGRect? = nil) -> PanePlacement {
        PanePlacement.resolve(size: CGSize(width: w, height: h), idiom: idiom, displayFeatureFrame: feature)
    }

    @Test func duoOpenWideIsTwoScreensSideBySide() {
        #expect(resolve(734, 540, .phone) == .twoScreens(axis: .vertical, hinge: 367))
        #expect(resolve(1080, 800, .phone) == .twoScreens(axis: .vertical, hinge: 540))
    }

    @Test func duoOpenTallIsTwoScreensStacked() {
        #expect(resolve(640, 900, .phone) == .twoScreens(axis: .horizontal, hinge: 450))
        // 600 wide is the threshold; a square or landscape window that narrow is not tall
        #expect(resolve(600, 601, .phone) == .twoScreens(axis: .horizontal, hinge: 300.5))
        #expect(resolve(650, 650, .phone) == .compact)
        #expect(resolve(599, 900, .phone) == .compact)
    }

    @Test func iPhoneIsCompact() {
        #expect(resolve(402, 874, .phone) == .compact)          // iPhone 17 Pro portrait
        #expect(resolve(440, 956, .phone) == .compact)          // Pro Max portrait
        #expect(resolve(375, 667, .phone) == .compact)          // a folded Duo / small phone
    }

    @Test func phoneWideThreshold() {
        #expect(resolve(700, 400, .phone) == .twoScreens(axis: .vertical, hinge: 350))
        #expect(resolve(699, 400, .phone) == .compact)
        // a big phone in landscape is wide enough to count as two screens (the same 700 pt rule the spreads used)
        #expect(resolve(874, 402, .phone) == .twoScreens(axis: .vertical, hinge: 437))
    }

    @Test func iPadGetsTheColumnFrom900() {
        #expect(resolve(1376, 1032, .pad) == .column(width: 440))   // 13" landscape
        #expect(resolve(1032, 1376, .pad) == .column(width: 440))   // 13" portrait
        #expect(resolve(900, 700, .pad) == .column(width: 440))
        #expect(resolve(899, 700, .pad) == .compact)
        #expect(resolve(744, 1133, .pad) == .compact)               // mini portrait
        #expect(resolve(507, 800, .pad) == .compact)                // a Stage Manager sliver
    }

    @Test func macGetsTheColumnFrom900() {
        #expect(resolve(1200, 800, .mac) == .column(width: 400))
        #expect(resolve(900, 600, .mac) == .column(width: 400))
        #expect(resolve(899, 600, .mac) == .compact)
    }

    @Test func aReportedHingeWins() {
        // vertical hinge: a feature taller than wide, on any idiom and any width
        #expect(resolve(402, 874, .phone, feature: CGRect(x: 190, y: 0, width: 20, height: 874))
                == .twoScreens(axis: .vertical, hinge: 200))
        #expect(resolve(1376, 1032, .pad, feature: CGRect(x: 688, y: 0, width: 0, height: 1032))
                == .twoScreens(axis: .vertical, hinge: 688))
        // horizontal hinge: wider than tall
        #expect(resolve(800, 1000, .phone, feature: CGRect(x: 0, y: 495, width: 800, height: 10))
                == .twoScreens(axis: .horizontal, hinge: 500))
        #expect(resolve(1200, 800, .mac, feature: CGRect(x: 0, y: 400, width: 1200, height: 0))
                == .twoScreens(axis: .horizontal, hinge: 400))
    }

    @Test func anEmptyFeatureIsIgnored() {
        #expect(resolve(402, 874, .phone, feature: .zero) == .compact)
        #expect(resolve(402, 874, .phone, feature: .null) == .compact)
        #expect(resolve(1200, 800, .mac, feature: .zero) == .column(width: 400))
    }

    @Test func tabExtentBesideTheScreen() {
        let size = CGSize(width: 1000, height: 800)
        #expect(PanePlacement.twoScreens(axis: .vertical, hinge: 500).tabExtent(in: size) == CGSize(width: 500, height: 800))
        #expect(PanePlacement.twoScreens(axis: .horizontal, hinge: 300).tabExtent(in: size) == CGSize(width: 1000, height: 500))
        #expect(PanePlacement.column(width: 440).tabExtent(in: size) == CGSize(width: 560, height: 800))
        #expect(PanePlacement.compact.tabExtent(in: size) == nil)
    }

    @Test func names() {
        #expect(PanePlacement.twoScreens(axis: .vertical, hinge: 1).name == "wide")
        #expect(PanePlacement.twoScreens(axis: .horizontal, hinge: 1).name == "tall")
        #expect(PanePlacement.column(width: 400).name == "column")
        #expect(PanePlacement.compact.name == "compact")
    }
}
