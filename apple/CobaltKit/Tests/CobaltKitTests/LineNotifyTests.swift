import Foundation
import Testing
@testable import CobaltKit

/// Leaving with work on the server (CONTRACT-PARALLEL.md section 6, APP-API-CONTRACT 17.8): one summary opt-in for all
/// of it, taken back when the owner is looking again; the device line keeps the per-session opt-ins.
@MainActor
struct LineNotifyTests {
    @Test func leavingWithServerJobsSendsOnePutAndNoPerSessionOptIns() async {
        let rig = LineRig(.serverBusyWithShare, notifyBridge: true)
        _ = rig.queue.add([.link(linkA), .link(linkB), .link(linkC)], via: .review)
        await rig.settle()
        rig.queue.appLeft()
        await rig.ctx.notify.settled()
        #expect(rig.count("PUT line/notify") == 1)
        #expect(rig.server.notifyCalls.isEmpty, "no per-session PUT: the summary covers them")
        #expect(rig.ctx.notify.lineSource == .line)
        #expect(rig.ctx.notify.log.filter { $0 == "PUT line" }.count == 1)
    }

    @Test func comingBackSendsOneDelete() async {
        let rig = LineRig(.serverBusyWithShare, notifyBridge: true)
        _ = rig.queue.add([.link(linkA)], via: .review)
        await rig.settle()
        rig.queue.appLeft()
        await rig.ctx.notify.settled()
        rig.queue.appForegrounded()
        await rig.ctx.notify.settled()
        #expect(rig.count("DELETE line/notify") == 1)
        #expect(rig.ctx.notify.lineSource == nil)
        rig.queue.appForegrounded()                                  // idempotent: nothing is held, nothing is sent
        await rig.ctx.notify.settled()
        #expect(rig.count("DELETE line/notify") == 1)
    }

    @Test func foregroundWithNothingHeldSendsNothing() async {
        let rig = LineRig(.server, notifyBridge: true)
        rig.queue.appForegrounded()
        await rig.ctx.notify.settled()
        #expect(rig.calls.filter { $0.hasSuffix("line/notify") }.isEmpty)
    }

    @Test func leavingWithNothingOnTheServerSendsNothing() async {
        let rig = LineRig(.server, notifyBridge: true)
        rig.queue.appLeft()
        await rig.ctx.notify.settled()
        #expect(rig.calls.filter { $0.hasSuffix("line/notify") }.isEmpty)
    }

    @Test func leavingTwiceInARowIsOneCall() async {
        let rig = LineRig(.serverBusyWithShare, notifyBridge: true)
        _ = rig.queue.add([.link(linkA)], via: .review)
        await rig.settle()
        rig.queue.appLeft()
        rig.queue.appLeft()
        await rig.ctx.notify.settled()
        #expect(rig.count("PUT line/notify") == 1, "the last intent wins")
    }

    @Test func withoutTheBridgeNothingIsSent() async {
        let rig = LineRig(.serverBusyWithShare)                     // features.line but no notify_bridge
        _ = rig.queue.add([.link(linkA)], via: .review)
        await rig.settle()
        rig.queue.appLeft()
        await rig.ctx.notify.settled()
        #expect(rig.calls.filter { $0.hasSuffix("line/notify") }.isEmpty)
    }

    @Test func aDeviceLineKeepsThePerSessionOptIns() async {
        let rig = LineRig(.off, notifyBridge: true)
        let jobs = rig.queue.add([.link(linkA)], via: .review)
        await rig.drive(until: { jobs[0].pipeline.sessionID != nil }, maxVirtualSeconds: 30)
        let sid = jobs[0].pipeline.sessionID
        rig.queue.appLeft()
        await rig.ctx.notify.settled()
        #expect(rig.server.notifyCalls == ["PUT \(sid ?? "?")"])
        #expect(rig.calls.filter { $0.hasSuffix("line/notify") }.isEmpty, "no line, no summary")
    }

    @Test func aShareSheetOptInIsUntouched() async {
        let rig = LineRig(.serverBusyWithShare, notifyBridge: true)
        let shareSession = "PrEvIeWshareSession0001"
        let optIn = NotifyOptIn(on: [.saved, .failed], label: "from the sheet")
        await rig.ctx.registerNotify(session: shareSession, optIn, source: .shareSheet)
        _ = rig.queue.add([.link(linkA)], via: .review)
        await rig.settle()
        rig.queue.appLeft()
        await rig.ctx.notify.settled()
        rig.queue.appForegrounded()
        await rig.ctx.notify.settled()
        #expect(rig.server.notifyCalls == ["PUT \(shareSession)"], "the sheet's own opt-in is neither re-sent nor taken back: \(rig.server.notifyCalls)")
        #expect(rig.ctx.notify.isRegistered(shareSession))
    }
}
