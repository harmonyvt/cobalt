import CoreGraphics
import Testing
@testable import CobaltKit

@Suite("TwitchWatchLayout")
struct TwitchWatchLayoutTests {
    @Test("folded iPhone / Duo portrait uses full-width 16:9 stacked layout")
    func foldedPortrait() {
        let layout = TwitchWatchLayout.resolve(isWideShape: false, size: CGSize(width: 402, height: 733))
        guard case .stacked(let maxH) = layout else {
            Issue.record("expected stacked, got \(layout)")
            return
        }
        // 402 * 9 / 16 = 226.125, well under 733 * 0.38 = 279
        #expect(maxH == CGFloat(402) * 9 / 16)
        #expect(!TwitchWatchLayout.isInlineStreamBar(width: 402, accessibilityText: false))
    }

    @Test("folded iPhone portrait with software keyboard caps video to keep chat and composer visible")
    func foldedPortraitWithKeyboard() {
        let layout = TwitchWatchLayout.resolve(isWideShape: false, size: CGSize(width: 402, height: 433))
        guard case .stacked(let maxH) = layout else {
            Issue.record("expected stacked, got \(layout)")
            return
        }
        // 433 * 0.38 = 165 < 226.125 -> caps video so chat stays visible
        #expect(maxH == 165)
    }

    @Test("landscape single-screen iPhone sheet automatically uses side-by-side layout")
    func landscapePhoneSheet() {
        let layout = TwitchWatchLayout.resolve(isWideShape: false, size: CGSize(width: 874, height: 314))
        guard case .sideBySide(let chatWidth) = layout else {
            Issue.record("expected sideBySide, got \(layout)")
            return
        }
        #expect(chatWidth == 367)
        // media side gets 874 - 367 = 507 >= 480 -> single-row inline stream bar
        #expect(TwitchWatchLayout.isInlineStreamBar(width: 874 - chatWidth, accessibilityText: false))
    }

    @Test("Duo open wide in screen state stacks cleanly in the left half")
    func duoWideScreen() {
        let layout = TwitchWatchLayout.resolve(isWideShape: false, size: CGSize(width: 475, height: 612))
        guard case .stacked(let maxH) = layout else {
            Issue.record("expected stacked, got \(layout)")
            return
        }
        // 612 * 0.38 = 233 < 475 * 9 / 16 (267.19) -> protects chat & emote picker height
        #expect(maxH == 233)
        #expect(!TwitchWatchLayout.isInlineStreamBar(width: 475, accessibilityText: false))
    }

    @Test("Duo open tall in screen state uses side-by-side in the top screen")
    func duoTallScreen() {
        let layout = TwitchWatchLayout.resolve(isWideShape: true, size: CGSize(width: 669, height: 418))
        guard case .sideBySide(let chatWidth) = layout else {
            Issue.record("expected sideBySide, got \(layout)")
            return
        }
        #expect(chatWidth == 281)
        // media side gets 388 pt -> compact two-row stream bar
        #expect(!TwitchWatchLayout.isInlineStreamBar(width: 669 - chatWidth, accessibilityText: false))
    }

    @Test("Duo open tall spanned top screen uses single-row inline stream bar")
    func duoTallSpanMediaBar() {
        #expect(TwitchWatchLayout.isInlineStreamBar(width: 669, accessibilityText: false))
        #expect(!TwitchWatchLayout.isInlineStreamBar(width: 669, accessibilityText: true))
    }

    @Test("iPad and Mac leading columns stack with full-width 16:9 video")
    func padAndMacColumns() {
        for width in [CGFloat(440), CGFloat(400)] {
            let layout = TwitchWatchLayout.resolve(isWideShape: false, size: CGSize(width: width, height: 760))
            guard case .stacked(let maxH) = layout else {
                Issue.record("expected stacked, got \(layout)")
                return
            }
            #expect(maxH == width * 9 / 16)
        }
    }

    @Test("iPad and Mac spanned wide views cap chat column at 400 pt")
    func padAndMacSpanned() {
        for width in [CGFloat(1194), CGFloat(1440)] {
            let layout = TwitchWatchLayout.resolve(isWideShape: true, size: CGSize(width: width, height: 760))
            guard case .sideBySide(let chatWidth) = layout else {
                Issue.record("expected sideBySide, got \(layout)")
                return
            }
            #expect(chatWidth == 400)
            #expect(TwitchWatchLayout.isInlineStreamBar(width: width - chatWidth, accessibilityText: false))
        }
    }

    @Test("unmeasured container falls back sensibly from shape")
    func unmeasuredFallback() {
        #expect(TwitchWatchLayout.resolve(isWideShape: false, size: .zero) == .stacked(videoMaxHeight: nil))
        #expect(TwitchWatchLayout.resolve(isWideShape: true, size: .zero) == .sideBySide(chatWidth: 320))
    }

    @Test("keyboard-open guarantee caps video height on folded outer and unfolded tall postures")
    func keyboardOpenGuarantee() {
        // Folded Outer with keyboard visible (~402 x 433 remaining above keyboard)
        let outerMax = TwitchWatchLayout.stackedVideoMaxHeight(for: CGSize(width: 402, height: 433), keyboardOpen: true)
        #expect(outerMax == 147)
        // Unfolded Tall with keyboard visible (~669 x 560 remaining above keyboard) -> capped at 180 pt
        let tallMax = TwitchWatchLayout.stackedVideoMaxHeight(for: CGSize(width: 669, height: 560), keyboardOpen: true)
        #expect(tallMax == 180)
        // Very short compact height never crushes below floor
        let floorMax = TwitchWatchLayout.stackedVideoMaxHeight(for: CGSize(width: 390, height: 320), keyboardOpen: true)
        #expect(floorMax == TwitchWatchLayout.keyboardVideoMinHeight)
    }

    @Test("compact overlay stream bar activates in tabletop and stacked keyboard-open postures")
    func compactOverlayStreamBarRules() {
        #expect(TwitchWatchLayout.compactOverlayStreamBar(isStacked: false, isTabletop: true, keyboardOpen: false))
        #expect(TwitchWatchLayout.compactOverlayStreamBar(isStacked: false, isTabletop: true, keyboardOpen: true))
        #expect(TwitchWatchLayout.compactOverlayStreamBar(isStacked: true, isTabletop: false, keyboardOpen: true))
        #expect(!TwitchWatchLayout.compactOverlayStreamBar(isStacked: true, isTabletop: false, keyboardOpen: false))
        #expect(!TwitchWatchLayout.compactOverlayStreamBar(isStacked: false, isTabletop: false, keyboardOpen: true))
    }

    @Test("single-focus wide watch uses ~62/38 split clamped between 280 and 400 pt")
    func singleFocusWideChatWidth() {
        // iPhone Duo Unfolded Wide (951 pt) -> 361 pt chat (~38%), 590 pt video (~62%)
        #expect(TwitchWatchLayout.singleFocusChatWidth(for: 951) == 361)
        // iPad / Mac large canvas -> capped at 400 pt
        #expect(TwitchWatchLayout.singleFocusChatWidth(for: 1366) == 400)
        // Smaller landscape width -> floored at 280 pt
        #expect(TwitchWatchLayout.singleFocusChatWidth(for: 669) == 280)
    }
}
