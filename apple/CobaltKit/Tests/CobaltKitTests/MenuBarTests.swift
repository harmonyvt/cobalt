import Foundation
import Testing
@testable import CobaltKit

@MainActor
struct MenuBarIconTests {
    @Test func idleDrawsNoRing() {
        #expect(MenuBarIcon.state(phases: [], failed: false) == .idle)
    }

    @Test func aFailureWithNothingRunningIsOnlyTheDot() {
        let state = MenuBarIcon.state(phases: [], failed: true)
        #expect(state.ring == nil && state.failed)
    }

    @Test func theRingIsTheMeanOfTheLiveJobs() {
        // download at 50% fills 0.40 of the ring; waiting sits at 0.05; mean 0.225
        let state = MenuBarIcon.state(phases: [.downloading(0.5), .waiting], failed: false)
        #expect(state.ring == 0.225)
        #expect(!state.failed)
    }

    @Test func savingFillsTheLastFifthAndAFailureKeepsTheDot() {
        // saving at 50% is 0.8 + 0.1
        let state = MenuBarIcon.state(phases: [.saving(0.5)], failed: true)
        #expect(state.ring == 0.9 && state.failed)
    }

    @Test func checkingIsASliverAndFractionsClamp() {
        #expect(MenuBarIcon.contribution(.checking) == 0.05)
        #expect(MenuBarIcon.contribution(.waiting) == 0.05)
        #expect(MenuBarIcon.contribution(.downloading(-1)) == 0)
        #expect(MenuBarIcon.contribution(.downloading(2)) == 0.8)
        #expect(MenuBarIcon.contribution(.saving(1)) == 1)
    }
}

struct MenuBarPasteTests {
    private let linkA = URL(string: "https://www.tiktok.com/@capy/video/1")!
    private let linkB = URL(string: "https://youtu.be/abcdefghijk")!

    @Test func noLinkStaysAStatus() {
        #expect(MenuBarPaste.plan(fileCount: 0, links: [], isLive: { _ in false }) == .noLink)
    }

    @Test func oneNewLinkSavesDirectly() {
        let plan = MenuBarPaste.plan(fileCount: 0, links: [linkA], isLive: { _ in false })
        #expect(plan == .saveLinks([linkA]))
    }

    @Test func oneLinkAlreadySavingIsNotAChoice() {
        // the window says "already saving that one." and does not open a sheet
        let plan = MenuBarPaste.plan(fileCount: 0, links: [linkA], isLive: { _ in true })
        #expect(plan == .alreadySaving)
    }

    @Test func severalLinksNeedTheReviewEvenWhenOneIsAlreadySaving() {
        // the review is where an already-saved link is confirmed; a live one is untickable there
        let plan = MenuBarPaste.plan(fileCount: 0, links: [linkA, linkB], isLive: { $0 == linkA })
        #expect(plan == .needsAttention(.review))
    }

    @Test func oneFileNeedsTheNameSheet() {
        let plan = MenuBarPaste.plan(fileCount: 1, links: [linkA], isLive: { _ in false })
        #expect(plan == .needsAttention(.nameFile))
    }

    @Test func severalFilesSaveWithNoSheet() {
        #expect(MenuBarPaste.plan(fileCount: 3, links: [linkA], isLive: { _ in false }) == .saveFiles)
    }

    @Test func aPickerOrAnUnnamedFileNeedsTheWindow() {
        #expect(MenuBarPaste.jobNeedsOwner(isPicker: true, waitsForTitle: false))
        #expect(MenuBarPaste.jobNeedsOwner(isPicker: false, waitsForTitle: true))
        #expect(!MenuBarPaste.jobNeedsOwner(isPicker: false, waitsForTitle: false))
    }
}

@MainActor
struct MenuBarFinderTests {
    @Test func theStubIsHidden() {
        let finder = MenuBarFinderModel()
        #expect(!finder.isAvailable)
        #expect(finder.status == .unavailable)
    }

    @Test func connectingPublishesTheSwitchAndOpen() async {
        let finder = MenuBarFinderModel()
        var enabled = false
        var opened = 0
        finder.connect(
            refresh: {
                MenuBarFinderStatus(
                    available: true, enabled: enabled, phase: enabled ? .upToDate : .off,
                    note: enabled ? nil : "sign in to show the library in finder.")
            },
            setEnabled: { on in enabled = on },
            open: { opened += 1 })
        #expect(finder.isAvailable && !finder.status.enabled && finder.status.phase == .off)
        await finder.setEnabled(true)
        #expect(finder.status.enabled && finder.status.phase == .upToDate && finder.status.note == nil)
        finder.openInFinder()
        #expect(opened == 1)
    }

    @Test func anUpdateCarriesAFraction() {
        let status = MenuBarFinderStatus(available: true, enabled: true, phase: .updating(fraction: 0.4))
        #expect(status.phase == .updating(fraction: 0.4))
    }
}

@MainActor
struct MenuBarSettingTests {
    @Test func theMenuBarIconDefaultsOnAndRemembersOff() {
        let defaults = UserDefaults(suiteName: "cobaltkit.tests.menubar.\(UUID().uuidString)")!
        let settings = Settings(defaults: defaults, keychain: .memory())
        #expect(settings.menuBarExtra)
        settings.menuBarExtra = false
        #expect(Settings(defaults: defaults, keychain: .memory()).menuBarExtra == false)
    }
}
