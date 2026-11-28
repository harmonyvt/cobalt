import Foundation
import Synchronization
import Testing
@testable import CobaltKit

@Suite("energy sampler")
struct EnergySamplerTests {
    private let sec: UInt64 = 1_000_000_000

    private func snap(
        cpuS: Double = 0,
        pCoreS: Double = 0,
        gpuS: Double = 0,
        wakeups: UInt64 = 0,
        idleWakeups: UInt64 = 0,
        energyMj: Double? = nil,
        footprintMb: UInt64 = 100
    ) -> MachEnergySnapshot {
        MachEnergySnapshot(
            userNs: UInt64(cpuS * 1_000_000_000),
            systemNs: 0,
            pCoreNs: UInt64(pCoreS * 1_000_000_000),
            gpuNs: UInt64(gpuS * 1_000_000_000),
            interruptWakeups: wakeups,
            idleWakeups: idleWakeups,
            energyNanojoules: energyMj.map { UInt64($0 * 1_000_000) },
            physFootprintBytes: footprintMb * 1_048_576
        )
    }

    @Test func ticksToNanosHandlesAppleSiliconTimebaseWithoutOverflow() {
        // Apple Silicon mach_timebase_info is 125/3 (24 MHz counter)
        #expect(MachEnergySnapshot.ticksToNanos(24_000_000, numer: 125, denom: 3) == 1_000_000_000)
        #expect(MachEnergySnapshot.ticksToNanos(1_000, numer: 1, denom: 1) == 1_000)
        #expect(MachEnergySnapshot.ticksToNanos(0, numer: 125, denom: 3) == 0)
        // Very large tick count (10 years at 24 MHz) must not overflow 64-bit multiplication.
        let tenYearsTicks: UInt64 = 24_000_000 * 86_400 * 365 * 10
        let nanos = MachEnergySnapshot.ticksToNanos(tenYearsTicks, numer: 125, denom: 3)
        #expect(nanos == 1_000_000_000 * 86_400 * 365 * 10)
    }

    @Test func liveMachCountersReadSucceeds() throws {
        let current = try #require(MachEnergySnapshot.readCurrent())
        #expect(current.physFootprintBytes > 0)
    }

    @Test func transitionEmitsEnergySliceWithDeltasAndIgnoresScreenOnlyChanges() throws {
        var tracker = EnergyTracker()
        let initial = EnergyWorkload(streams: 0, playerMode: .none, screen: "library", net: .wifi)
        tracker.start(at: 0, counters: snap(cpuS: 10, wakeups: 100, energyMj: 500, footprintMb: 120), workload: initial)

        // Screen switch alone does not fragment the slice.
        var onTwitch = initial
        onTwitch.screen = "twitch"
        let screenEvents = tracker.update(onTwitch, at: 20 * sec, counters: snap(cpuS: 12, wakeups: 120, energyMj: 600, footprintMb: 130))
        #expect(screenEvents.isEmpty)

        // Starting 2 native streams closes the idle slice (20 -> 30s = 30s total since start).
        var dual = onTwitch
        dual.streams = 2
        dual.playerMode = .native
        let events = tracker.update(
            dual,
            at: 30 * sec,
            counters: snap(cpuS: 13, pCoreS: 0.5, gpuS: 1.5, wakeups: 160, idleWakeups: 30, energyMj: 950, footprintMb: 200)
        )
        #expect(events.count == 1)
        let slice = try #require(events.first)
        #expect(slice.name == "energy_slice")
        #expect(slice.values["reason"] == .string("transition"))
        #expect(slice.values["elapsed_s"] == .int(30))
        #expect(slice.values["cpu_s"] == .double(3))
        #expect(slice.values["cpu_pct"] == .double(10))
        #expect(slice.values["p_core_s"] == .double(0.5))
        #expect(slice.values["gpu_s"] == .double(1.5))
        #expect(slice.values["energy_mj"] == .double(450))
        #expect(slice.values["wakeups"] == .int(60))
        #expect(slice.values["wakeups_per_s"] == .double(2))
        #expect(slice.values["idle_wakeups"] == .int(30))
        #expect(slice.values["footprint_mb"] == .int(200))
        #expect(slice.values["streams"] == .int(0))
        #expect(slice.values["player_mode"] == .string("none"))
        #expect(slice.values["net"] == .string("wifi"))
        #expect(tracker.shouldRunCheckpointTimer)
    }

    @Test func shortTransitionsSkipMicroSliceButRollIntoSessionEnergy() throws {
        var tracker = EnergyTracker()
        let base = EnergyWorkload(streams: 1, playerMode: .native, net: .cell)
        tracker.start(at: 0, counters: snap(cpuS: 0, wakeups: 0, energyMj: 0, footprintMb: 150), workload: base)

        // 2-second burst before switching to 2 streams: too short for an energy_slice, must still enter session.
        var dual = base
        dual.streams = 2
        let quick = tracker.update(dual, at: 2 * sec, counters: snap(cpuS: 1, wakeups: 20, energyMj: 100, footprintMb: 180))
        #expect(quick.isEmpty)

        // Background without PiP or bgAudio after 8 more seconds (total 10s).
        var bg = dual
        bg.streams = 0
        bg.playerMode = .none
        bg.isForeground = false
        let ended = tracker.update(bg, at: 10 * sec, counters: snap(cpuS: 5, wakeups: 100, energyMj: 600, footprintMb: 210))
        #expect(ended.map(\.name) == ["energy_slice", "session_energy"])

        let session = try #require(ended.last)
        #expect(session.values["duration_s"] == .int(10))
        #expect(session.values["stream_s"] == .int(10))
        #expect(session.values["cpu_s"] == .double(5))
        #expect(session.values["wakeups"] == .int(100))
        #expect(session.values["energy_mj"] == .double(600))
        #expect(session.values["peak_footprint_mb"] == .int(210))
        #expect(session.values["max_streams"] == .int(2))
    }

    @Test func pipAndBackgroundAudioKeepSessionOpenUntilPlaybackStops() throws {
        var tracker = EnergyTracker()
        let fgStream = EnergyWorkload(streams: 2, playerMode: .native, pip: false, bgAudio: false, isForeground: true)
        tracker.start(at: 0, counters: snap(cpuS: 0, wakeups: 0), workload: fgStream)

        // Entering background with PiP keeps the session open.
        var bgPiP = fgStream
        bgPiP.isForeground = false
        bgPiP.pip = true
        let toPiP = tracker.update(bgPiP, at: 60 * sec, counters: snap(cpuS: 15, wakeups: 300, footprintMb: 240))
        #expect(toPiP.map(\.name) == ["energy_slice"])
        #expect(toPiP[0].values["reason"] == .string("transition"))
        #expect(toPiP[0].values["fg"] == .bool(true))

        // Periodic checkpoint during background PiP streaming.
        let cp = tracker.checkpoint(at: 360 * sec, counters: snap(cpuS: 75, wakeups: 900, footprintMb: 260))
        #expect(cp.map(\.name) == ["energy_slice"])
        #expect(cp[0].values["reason"] == .string("checkpoint"))
        #expect(cp[0].values["pip"] == .bool(true))
        #expect(cp[0].values["fg"] == .bool(false))

        // Stopping PiP while still in background finally ends the session.
        var stopped = bgPiP
        stopped.streams = 0
        stopped.playerMode = .none
        stopped.pip = false
        let end = tracker.update(stopped, at: 420 * sec, counters: snap(cpuS: 85, wakeups: 1000, footprintMb: 190))
        #expect(end.map(\.name) == ["energy_slice", "session_energy"])
        let session = try #require(end.last)
        #expect(session.values["duration_s"] == .int(420))
        #expect(session.values["stream_s"] == .int(420))
        #expect(session.values["cpu_s"] == .double(85))
        #expect(session.values["peak_footprint_mb"] == .int(260))
        #expect(!tracker.shouldRunCheckpointTimer)
    }

    @Test func thermalAndLpmTransitionsPreserveNonNominalBaseline() throws {
        var tracker = EnergyTracker()
        // App launches already in `.fair` thermal state — no spurious launch transition.
        let warm = EnergyWorkload(streams: 2, playerMode: .native, thermal: .fair, lpm: false)
        tracker.start(at: 10 * sec, counters: snap(), workload: warm)

        // Climbs to `.serious` 90 s later and enables LPM.
        var hot = warm
        hot.thermal = .serious
        hot.lpm = true
        let events = tracker.update(hot, at: 100 * sec, counters: snap())
        #expect(events.count == 2)
        #expect(events[0].name == "thermal_state")
        #expect(events[0].values["kind"] == .string("thermal"))
        #expect(events[0].values["prev"] == .string("fair"))
        #expect(events[0].values["next"] == .string("serious"))
        #expect(events[0].values["prev_s"] == .int(90))
        #expect(events[0].values["streams"] == .int(2))

        #expect(events[1].name == "thermal_state")
        #expect(events[1].values["kind"] == .string("lpm"))
        #expect(events[1].values["prev"] == .string("off"))
        #expect(events[1].values["next"] == .string("on"))
        #expect(events[1].values["prev_s"] == .int(90))
    }

    @Test func samplerAvoidsSyscallsBeforeStartAndRebasesOnReenable() throws {
        struct Rig: Sendable {
            var clock: UInt64 = 0
            var counterReads = 0
            var fakeCounters: MachEnergySnapshot
        }
        let rig = Mutex(Rig(fakeCounters: snap(cpuS: 1, wakeups: 10)))
        let emitted = Mutex<[EnergyEmission]>([])

        let sampler = EnergySampler(
            now: { rig.withLock { $0.clock } },
            readCounters: {
                rig.withLock { r in
                    r.counterReads += 1
                    return r.fakeCounters
                }
            }
        )

        // Pre-start updates cache workload with zero Mach counter reads.
        sampler.setNetwork(.cell)
        sampler.setScreen("twitch")
        #expect(rig.withLock { $0.counterReads } == 0)

        // Start reads baseline once and preserves pre-cached `.cell` + `"twitch"`.
        sampler.emit = { name, values in emitted.withLock { $0.append(EnergyEmission(name: name, values: values)) } }
        sampler.start { w in
            w.isForeground = true
            w.thermal = .nominal
            w.lpm = false
        }
        #expect(rig.withLock { $0.counterReads } == 1)

        // Opting out disables Mach reads.
        sampler.emit = nil
        rig.withLock { r in
            r.clock = 100 * sec
            r.fakeCounters = snap(cpuS: 50, wakeups: 5000)
        }
        sampler.setPlayback(streams: 1, mode: .native, pip: false, bgAudio: false)
        #expect(rig.withLock { $0.counterReads } == 1)
        #expect(emitted.withLock { $0 }.isEmpty)

        // Re-enabling rebases counters so the 49s of opted-out CPU is not attributed to the next slice.
        sampler.emit = { name, values in emitted.withLock { $0.append(EnergyEmission(name: name, values: values)) } }
        #expect(rig.withLock { $0.counterReads } == 2)

        rig.withLock { r in
            r.clock = 130 * sec
            r.fakeCounters = snap(cpuS: 53, wakeups: 5060)
        }
        sampler.setPlayback(streams: 0, mode: .none, pip: false, bgAudio: false)

        let items = emitted.withLock { $0 }
        #expect(items.count == 1)
        #expect(items[0].name == "energy_slice")
        #expect(items[0].values["elapsed_s"] == .int(30))
        #expect(items[0].values["cpu_s"] == .double(3))
        #expect(items[0].values["wakeups"] == .int(60))
        #expect(items[0].values["net"] == .string("cell"))
        #expect(items[0].values["screen"] == .string("twitch"))
    }

    #if canImport(MetricKit)
    @Test func metricSummarySplitForLogStaysUnderDataKeyCap() {
        var full: [String: TelemetryValue] = [:]
        // 14 core keys + 7 energy keys = 21 keys (> TelemetryLimits.dataKeys = 20)
        for k in [
            "version", "build", "hours", "scroll_hitch_ratio",
            "launch_ms", "launch_n", "resume_ms", "resume_n",
            "hang_ms", "hang_n", "cpu_s", "gpu_s", "peak_mb", "foreground_s",
        ] {
            full[k] = .int(1)
        }
        for k in ["cpu_kinst", "wifi_dl_mb", "cell_dl_mb", "disk_write_mb", "apl", "bg_s", "bg_audio_s"] {
            full[k] = .int(2)
        }
        #expect(full.count == 21)

        let split = MetricSummary.splitForLog(full)
        #expect(split.core.count <= TelemetryLimits.dataKeys)
        #expect(split.energy.count <= TelemetryLimits.dataKeys)
        #expect(!split.energy.isEmpty)
        let unionKeys = Set(split.core.keys).union(split.energy.keys)
        #expect(unionKeys == Set(full.keys))
    }
    #endif
}
