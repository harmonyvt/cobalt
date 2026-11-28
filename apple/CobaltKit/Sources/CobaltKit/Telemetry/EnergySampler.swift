import Darwin
import Dispatch
import Foundation
import Synchronization

/// Snapshot of process-level energy and memory counters read via public Mach `task_info` APIs (`TASK_POWER_INFO_V2`
/// and `TASK_VM_INFO`). No private APIs (`libproc` / `proc_pid_rusage`) and no main-thread UI queries.
public struct MachEnergySnapshot: Sendable, Equatable {
    public var userNs: UInt64
    public var systemNs: UInt64
    public var pCoreNs: UInt64
    public var gpuNs: UInt64
    public var interruptWakeups: UInt64
    public var idleWakeups: UInt64
    /// Process energy in nanojoules on ARM/ARM64 (`task_power_info_v2.task_energy`); `nil` on x86_64.
    public var energyNanojoules: UInt64?
    public var physFootprintBytes: UInt64

    public var totalCpuNs: UInt64 { userNs &+ systemNs }

    public init(
        userNs: UInt64 = 0,
        systemNs: UInt64 = 0,
        pCoreNs: UInt64 = 0,
        gpuNs: UInt64 = 0,
        interruptWakeups: UInt64 = 0,
        idleWakeups: UInt64 = 0,
        energyNanojoules: UInt64? = nil,
        physFootprintBytes: UInt64 = 0
    ) {
        self.userNs = userNs
        self.systemNs = systemNs
        self.pCoreNs = pCoreNs
        self.gpuNs = gpuNs
        self.interruptWakeups = interruptWakeups
        self.idleWakeups = idleWakeups
        self.energyNanojoules = energyNanojoules
        self.physFootprintBytes = physFootprintBytes
    }

    private static let timebase: (numer: UInt64, denom: UInt64) = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        let numer = UInt64(info.numer == 0 ? 1 : info.numer)
        let denom = UInt64(info.denom == 0 ? 1 : info.denom)
        return (numer, denom)
    }()

    /// Converts Mach absolute time ticks (used by `total_user`, `total_system`, `task_ptime`) to nanoseconds without
    /// 64-bit multiplication overflow.
    static func ticksToNanos(_ ticks: UInt64, numer: UInt64 = timebase.numer, denom: UInt64 = timebase.denom) -> UInt64 {
        guard ticks > 0 else { return 0 }
        if numer == denom { return ticks }
        let product = ticks.multipliedFullWidth(by: numer)
        if product.high >= denom { return UInt64.max }
        return denom.dividingFullWidth(product).quotient
    }

    /// Reads the current task's public Mach power and VM counters. Safe on any thread; ~10–30 µs.
    public static func readCurrent() -> MachEnergySnapshot? {
        var power = task_power_info_v2_data_t()
        var powerCount = mach_msg_type_number_t(
            MemoryLayout<task_power_info_v2_data_t>.size / MemoryLayout<natural_t>.size
        )
        let powerResult: kern_return_t = withUnsafeMutablePointer(to: &power) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(powerCount)) { intPtr in
                task_info(mach_task_self_, task_flavor_t(TASK_POWER_INFO_V2), intPtr, &powerCount)
            }
        }
        guard powerResult == KERN_SUCCESS else { return nil }

        var vm = task_vm_info_data_t()
        var vmCount = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size
        )
        let vmResult: kern_return_t = withUnsafeMutablePointer(to: &vm) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(vmCount)) { intPtr in
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), intPtr, &vmCount)
            }
        }
        let footprint: UInt64 = vmResult == KERN_SUCCESS ? vm.phys_footprint : 0

        #if arch(arm64) || arch(arm)
        let energy: UInt64? = power.task_energy
        #else
        let energy: UInt64? = nil
        #endif

        return MachEnergySnapshot(
            userNs: ticksToNanos(power.cpu_energy.total_user),
            systemNs: ticksToNanos(power.cpu_energy.total_system),
            pCoreNs: ticksToNanos(power.task_ptime),
            gpuNs: power.gpu_energy.task_gpu_utilisation,
            interruptWakeups: power.cpu_energy.task_interrupt_wakeups,
            idleWakeups: power.cpu_energy.task_platform_idle_wakeups,
            energyNanojoules: energy,
            physFootprintBytes: footprint
        )
    }
}

/// Active Twitch/video backend driving the current energy slice.
public enum EnergyPlayerMode: String, Sendable, Equatable {
    case none
    case native
    case embed
}

/// Network interface class reused from `SyncPathWatch`'s existing `NWPathMonitor`.
public enum EnergyNetwork: String, Sendable, Equatable {
    case wifi
    case cell
    case other
    case none
}

/// Ordered wrapper around `ProcessInfo.ThermalState` for peak tracking and flat telemetry strings.
public enum EnergyThermal: String, Sendable, Equatable, Comparable {
    case nominal
    case fair
    case serious
    case critical

    public init(_ state: ProcessInfo.ThermalState) {
        switch state {
        case .nominal: self = .nominal
        case .fair: self = .fair
        case .serious: self = .serious
        case .critical: self = .critical
        @unknown default: self = .nominal
        }
    }

    private var rank: Int {
        switch self {
        case .nominal: 0
        case .fair: 1
        case .serious: 2
        case .critical: 3
        }
    }

    public static func < (lhs: EnergyThermal, rhs: EnergyThermal) -> Bool {
        lhs.rank < rhs.rank
    }
}

/// Cached app workload context attached to `energy_slice`, `thermal_state` and `session_energy` events.
/// Updated only when state actually changes; read from any thread under `EnergySampler`'s mutex with zero MainActor hops.
public struct EnergyWorkload: Sendable, Equatable {
    public var streams: Int
    public var playerMode: EnergyPlayerMode
    public var pip: Bool
    public var bgAudio: Bool
    public var screen: String
    public var replay: Bool
    public var net: EnergyNetwork
    public var thermal: EnergyThermal
    public var lpm: Bool
    public var isForeground: Bool

    public init(
        streams: Int = 0,
        playerMode: EnergyPlayerMode = .none,
        pip: Bool = false,
        bgAudio: Bool = false,
        screen: String = "library",
        replay: Bool = false,
        net: EnergyNetwork = .other,
        thermal: EnergyThermal = .nominal,
        lpm: Bool = false,
        isForeground: Bool = true
    ) {
        self.streams = max(0, streams)
        self.playerMode = playerMode
        self.pip = pip
        self.bgAudio = bgAudio
        self.screen = screen
        self.replay = replay
        self.net = net
        self.thermal = thermal
        self.lpm = lpm
        self.isForeground = isForeground
    }

    /// True while the app is doing active foreground, PiP or background-audio work.
    public var isActiveSession: Bool { isForeground || pip || bgAudio }

    /// Whether a transition between `self` and `other` changes the energy regime enough to close the current slice.
    /// Tab switches (`screen`) alone do not fragment slices.
    func splitsSlice(comparedTo other: EnergyWorkload) -> Bool {
        streams != other.streams
            || playerMode != other.playerMode
            || pip != other.pip
            || bgAudio != other.bgAudio
            || replay != other.replay
            || isForeground != other.isForeground
            || net != other.net
    }
}

/// One emitted telemetry event from `EnergyTracker`.
public struct EnergyEmission: Sendable, Equatable {
    public var name: String
    public var values: [String: TelemetryValue]

    public init(name: String, values: [String: TelemetryValue]) {
        self.name = name
        self.values = values
    }
}

/// Pure, clock-injectable state machine behind `EnergySampler`. Tracks slice deltas, thermal/LPM transitions and
/// true active-session rollups (staying open across PiP and background audio).
struct EnergyTracker: Sendable {
    static let minSliceNs: UInt64 = 5_000_000_000

    private struct Session {
        var durationNs: UInt64 = 0
        var streamNs: UInt64 = 0
        var lpmNs: UInt64 = 0
        var cpuNs: UInt64 = 0
        var pCoreNs: UInt64 = 0
        var gpuNs: UInt64 = 0
        var energyNj: UInt64 = 0
        var hasEnergy: Bool = false
        var wakeups: UInt64 = 0
        var idleWakeups: UInt64 = 0
        var peakFootprintBytes: UInt64 = 0
        var peakThermal: EnergyThermal = .nominal
        var maxStreams: Int = 0
        var hadReplay: Bool = false
    }

    private(set) var started = false
    private(set) var workload = EnergyWorkload()
    private var sliceStartNs: UInt64 = 0
    private var sliceStartCounters = MachEnergySnapshot()
    private var thermalSinceNs: UInt64 = 0
    private var lpmSinceNs: UInt64 = 0
    private var session: Session?

    var shouldRunCheckpointTimer: Bool {
        started && workload.streams > 0
    }

    /// Updates cached workload metadata before `start` without taking Mach snapshots or emitting events.
    mutating func cacheBeforeStart(_ transform: (inout EnergyWorkload) -> Void) {
        transform(&workload)
    }

    mutating func start(at nowNs: UInt64, counters: MachEnergySnapshot, workload initial: EnergyWorkload) {
        started = true
        workload = initial
        sliceStartNs = nowNs
        sliceStartCounters = counters
        thermalSinceNs = nowNs
        lpmSinceNs = nowNs
        if initial.isActiveSession {
            session = makeSession(workload: initial, counters: counters)
        } else {
            session = nil
        }
    }

    /// Resets baseline timestamps and Mach counters after telemetry is re-enabled so time spent opted-out is never
    /// attributed to the next slice or session.
    mutating func rebase(at nowNs: UInt64, counters: MachEnergySnapshot) {
        guard started else { return }
        sliceStartNs = nowNs
        sliceStartCounters = counters
        thermalSinceNs = nowNs
        lpmSinceNs = nowNs
        if workload.isActiveSession {
            session = makeSession(workload: workload, counters: counters)
        } else {
            session = nil
        }
    }

    mutating func update(
        _ next: EnergyWorkload,
        at nowNs: UInt64,
        counters: MachEnergySnapshot
    ) -> [EnergyEmission] {
        guard started else {
            start(at: nowNs, counters: counters, workload: next)
            return []
        }
        guard next != workload else { return [] }

        let prev = workload
        var out: [EnergyEmission] = []

        // Thermal and LPM transitions fire immediately with time spent in the previous state.
        if next.thermal != prev.thermal {
            let prevS = elapsedSeconds(from: thermalSinceNs, to: nowNs)
            thermalSinceNs = nowNs
            out.append(EnergyEmission(
                name: "thermal_state",
                values: transitionValues(
                    kind: "thermal", prev: prev.thermal.rawValue, next: next.thermal.rawValue,
                    prevSeconds: prevS, workload: next
                )
            ))
        }
        if next.lpm != prev.lpm {
            let prevS = elapsedSeconds(from: lpmSinceNs, to: nowNs)
            lpmSinceNs = nowNs
            out.append(EnergyEmission(
                name: "thermal_state",
                values: transitionValues(
                    kind: "lpm", prev: prev.lpm ? "on" : "off", next: next.lpm ? "on" : "off",
                    prevSeconds: prevS, workload: next
                )
            ))
        }

        let endingSession = session != nil && !next.isActiveSession
        let startingSession = session == nil && next.isActiveSession
        let split = prev.splitsSlice(comparedTo: next) || endingSession || startingSession

        if split {
            if session != nil {
                if let slice = closeSlice(
                    for: prev,
                    reason: endingSession ? "session_end" : "transition",
                    at: nowNs,
                    counters: counters
                ) {
                    out.append(slice)
                }
            } else {
                sliceStartNs = nowNs
                sliceStartCounters = counters
            }
        } else {
            // Non-splitting metadata change (e.g., screen, thermal, lpm): still update session peaks.
            if var s = session {
                s.peakThermal = max(s.peakThermal, next.thermal)
                s.peakFootprintBytes = max(s.peakFootprintBytes, counters.physFootprintBytes)
                s.maxStreams = max(s.maxStreams, next.streams)
                if next.replay { s.hadReplay = true }
                session = s
            }
        }

        if endingSession, let finished = session {
            session = nil
            if finished.durationNs >= Self.minSliceNs {
                out.append(EnergyEmission(
                    name: "session_energy",
                    values: sessionValues(finished, net: prev.net)
                ))
            }
        } else if startingSession {
            session = makeSession(workload: next, counters: counters)
            sliceStartNs = nowNs
            sliceStartCounters = counters
        } else if var s = session {
            s.peakThermal = max(s.peakThermal, next.thermal)
            s.maxStreams = max(s.maxStreams, next.streams)
            if next.replay { s.hadReplay = true }
            session = s
        }

        workload = next
        return out
    }

    /// Coarse periodic checkpoint invoked only while `streams > 0`.
    mutating func checkpoint(at nowNs: UInt64, counters: MachEnergySnapshot) -> [EnergyEmission] {
        guard started, workload.streams > 0, session != nil else { return [] }
        guard let slice = closeSlice(for: workload, reason: "checkpoint", at: nowNs, counters: counters) else {
            return []
        }
        return [slice]
    }

    // MARK: internals

    private func makeSession(workload: EnergyWorkload, counters: MachEnergySnapshot) -> Session {
        var s = Session()
        s.peakFootprintBytes = counters.physFootprintBytes
        s.peakThermal = workload.thermal
        s.maxStreams = workload.streams
        s.hadReplay = workload.replay
        return s
    }

    private mutating func closeSlice(
        for sliceWorkload: EnergyWorkload,
        reason: String,
        at nowNs: UInt64,
        counters: MachEnergySnapshot
    ) -> EnergyEmission? {
        let elapsedNs = nowNs >= sliceStartNs ? nowNs - sliceStartNs : 0
        let dCpuNs = delta(counters.totalCpuNs, sliceStartCounters.totalCpuNs)
        let dPCoreNs = delta(counters.pCoreNs, sliceStartCounters.pCoreNs)
        let dGpuNs = delta(counters.gpuNs, sliceStartCounters.gpuNs)
        let dWakeups = delta(counters.interruptWakeups, sliceStartCounters.interruptWakeups)
        let dIdleWakeups = delta(counters.idleWakeups, sliceStartCounters.idleWakeups)
        let dEnergyNj: UInt64?
        if let curE = counters.energyNanojoules, let prevE = sliceStartCounters.energyNanojoules {
            dEnergyNj = delta(curE, prevE)
        } else {
            dEnergyNj = nil
        }

        sliceStartNs = nowNs
        sliceStartCounters = counters

        if var s = session {
            s.durationNs &+= elapsedNs
            if sliceWorkload.streams > 0 { s.streamNs &+= elapsedNs }
            if sliceWorkload.lpm { s.lpmNs &+= elapsedNs }
            s.cpuNs &+= dCpuNs
            s.pCoreNs &+= dPCoreNs
            s.gpuNs &+= dGpuNs
            if let dEnergyNj {
                s.energyNj &+= dEnergyNj
                s.hasEnergy = true
            }
            s.wakeups &+= dWakeups
            s.idleWakeups &+= dIdleWakeups
            s.peakFootprintBytes = max(s.peakFootprintBytes, counters.physFootprintBytes)
            s.peakThermal = max(s.peakThermal, sliceWorkload.thermal)
            s.maxStreams = max(s.maxStreams, sliceWorkload.streams)
            if sliceWorkload.replay { s.hadReplay = true }
            session = s
        }

        guard elapsedNs >= Self.minSliceNs else { return nil }

        let elapsedS = Double(elapsedNs) / 1_000_000_000
        let cpuS = Double(dCpuNs) / 1_000_000_000
        let pCoreS = Double(dPCoreNs) / 1_000_000_000
        let gpuS = Double(dGpuNs) / 1_000_000_000
        let footprintMb = Int((Double(counters.physFootprintBytes) / 1_048_576).rounded())

        var values: [String: TelemetryValue] = [
            "reason": .string(reason),
            "elapsed_s": .int(Int(elapsedS.rounded())),
            "cpu_s": .double(round2(cpuS)),
            "cpu_pct": .double(round1((cpuS / elapsedS) * 100)),
            "p_core_s": .double(round2(pCoreS)),
            "gpu_s": .double(round2(gpuS)),
            "wakeups": .int(Int(clamping: dWakeups)),
            "wakeups_per_s": .double(round1(Double(dWakeups) / elapsedS)),
            "idle_wakeups": .int(Int(clamping: dIdleWakeups)),
            "footprint_mb": .int(footprintMb),
            "streams": .int(sliceWorkload.streams),
            "player_mode": .string(sliceWorkload.playerMode.rawValue),
            "pip": .bool(sliceWorkload.pip),
            "bg_audio": .bool(sliceWorkload.bgAudio),
            "screen": .string(sliceWorkload.screen),
            "replay": .bool(sliceWorkload.replay),
            "net": .string(sliceWorkload.net.rawValue),
            "thermal": .string(sliceWorkload.thermal.rawValue),
            "lpm": .bool(sliceWorkload.lpm),
            "fg": .bool(sliceWorkload.isForeground),
        ]
        if let dEnergyNj {
            values["energy_mj"] = .double(round1(Double(dEnergyNj) / 1_000_000))
        }
        return EnergyEmission(name: "energy_slice", values: values)
    }

    private func transitionValues(
        kind: String,
        prev: String,
        next: String,
        prevSeconds: Int,
        workload: EnergyWorkload
    ) -> [String: TelemetryValue] {
        [
            "kind": .string(kind),
            "prev": .string(prev),
            "next": .string(next),
            "prev_s": .int(prevSeconds),
            "streams": .int(workload.streams),
            "player_mode": .string(workload.playerMode.rawValue),
            "pip": .bool(workload.pip),
            "bg_audio": .bool(workload.bgAudio),
            "screen": .string(workload.screen),
            "replay": .bool(workload.replay),
            "net": .string(workload.net.rawValue),
            "thermal": .string(workload.thermal.rawValue),
            "lpm": .bool(workload.lpm),
            "fg": .bool(workload.isForeground),
        ]
    }

    private func sessionValues(_ s: Session, net: EnergyNetwork) -> [String: TelemetryValue] {
        let durationS = Double(s.durationNs) / 1_000_000_000
        let streamS = Double(s.streamNs) / 1_000_000_000
        let lpmS = Double(s.lpmNs) / 1_000_000_000
        let cpuS = Double(s.cpuNs) / 1_000_000_000
        let pCoreS = Double(s.pCoreNs) / 1_000_000_000
        let gpuS = Double(s.gpuNs) / 1_000_000_000
        let peakMb = Int((Double(s.peakFootprintBytes) / 1_048_576).rounded())

        var values: [String: TelemetryValue] = [
            "duration_s": .int(Int(durationS.rounded())),
            "stream_s": .int(Int(streamS.rounded())),
            "lpm_s": .int(Int(lpmS.rounded())),
            "cpu_s": .double(round2(cpuS)),
            "p_core_s": .double(round2(pCoreS)),
            "gpu_s": .double(round2(gpuS)),
            "wakeups": .int(Int(clamping: s.wakeups)),
            "idle_wakeups": .int(Int(clamping: s.idleWakeups)),
            "peak_footprint_mb": .int(peakMb),
            "peak_thermal": .string(s.peakThermal.rawValue),
            "max_streams": .int(s.maxStreams),
            "replay": .bool(s.hadReplay),
            "net": .string(net.rawValue),
        ]
        if s.hasEnergy {
            values["energy_mj"] = .double(round1(Double(s.energyNj) / 1_000_000))
        }
        return values
    }

    private func delta(_ current: UInt64, _ previous: UInt64) -> UInt64 {
        current >= previous ? current - previous : 0
    }

    private func elapsedSeconds(from startNs: UInt64, to endNs: UInt64) -> Int {
        guard endNs >= startNs else { return 0 }
        return Int((Double(endNs - startNs) / 1_000_000_000).rounded())
    }

    private func round1(_ v: Double) -> Double { (v * 10).rounded() / 10 }
    private func round2(_ v: Double) -> Double { (v * 100).rounded() / 100 }
}

/// Process-lifetime energy telemetry sampler backed by public Mach counters (`TASK_POWER_INFO_V2` + `TASK_VM_INFO`).
///
/// - **Zero timers while idle**: emits `energy_slice` only on workload transitions (≥ 5 s) and on a single coalesced
///   5-minute checkpoint timer (`leeway: 30 s`) strictly while `streams > 0` and an emitter is installed.
/// - **Zero MainActor hops during sampling**: callers push workload metadata into a `Mutex` only when state changes.
/// - **Zero private or deprecated APIs**: no `libproc`/`proc_pid_rusage`, no `UIScreen.main`, no `UIDevice.batteryLevel`.
public final class EnergySampler: @unchecked Sendable {
    public static let shared = EnergySampler()

    /// Interval between streaming checkpoints (5 min) — 0.2 wakeups/min while watching, 0 while idle.
    public static let checkpointIntervalSeconds = 300
    public static let checkpointLeewaySeconds = 30

    private let state = Mutex(EnergyTracker())
    private let emitSlot = Mutex<(@Sendable (String, [String: TelemetryValue]) -> Void)?>(nil)
    private let timerLock = Mutex<DispatchSourceTimer?>(nil)
    private let timerQueue = DispatchQueue(label: "com.capybaraharmony.cobalt.energy", qos: .utility)

    private let now: @Sendable () -> UInt64
    private let readCounters: @Sendable () -> MachEnergySnapshot?

    public init(
        now: @escaping @Sendable () -> UInt64 = { DispatchTime.now().uptimeNanoseconds },
        readCounters: @escaping @Sendable () -> MachEnergySnapshot? = { MachEnergySnapshot.readCurrent() }
    ) {
        self.now = now
        self.readCounters = readCounters
    }

    /// Sink where `energy_slice`, `thermal_state` and `session_energy` events go (wired to `Analytics.event` by the app).
    /// Setting this to `nil` also cancels any active checkpoint timer so analytics-off incurs zero timer wakeups.
    public var emit: (@Sendable (String, [String: TelemetryValue]) -> Void)? {
        get { emitSlot.withLock { $0 } }
        set {
            let reenabled = emitSlot.withLock { slot -> Bool in
                let wasNil = slot == nil
                slot = newValue
                return wasNil && newValue != nil
            }
            if reenabled, state.withLock({ $0.started }) {
                let ts = now()
                let counters = readCounters() ?? MachEnergySnapshot()
                state.withLock { $0.rebase(at: ts, counters: counters) }
            }
            syncTimer()
        }
    }

    /// Seeds baseline Mach counters and initial lifecycle/screen/replay state while preserving any pre-cached
    /// `net` or playback fields already pushed before startup. Idempotent.
    public func start(_ seed: (inout EnergyWorkload) -> Void) {
        let alreadyStarted = state.withLock { $0.started }
        guard !alreadyStarted else { return }
        let ts = now()
        let counters = readCounters() ?? MachEnergySnapshot()
        state.withLock { tracker in
            guard !tracker.started else { return }
            var initial = tracker.workload
            seed(&initial)
            tracker.start(at: ts, counters: counters, workload: initial)
        }
        syncTimer()
    }

    /// Convenience overload for tests that provide a full initial `EnergyWorkload`.
    public func start(workload: EnergyWorkload) {
        start { $0 = workload }
    }

    /// Mutates the cached workload context and emits any resulting slice, thermal, or session events outside the lock.
    /// Before `start` (or while no emitter is attached), caches metadata with zero Mach syscalls and zero timers.
    public func update(_ transform: (inout EnergyWorkload) -> Void) {
        let hasEmitter = emitSlot.withLock { $0 != nil }
        let shouldSample: Bool = state.withLock { tracker in
            guard tracker.started else {
                tracker.cacheBeforeStart(transform)
                return false
            }
            var preview = tracker.workload
            transform(&preview)
            guard preview != tracker.workload else { return false }
            if !hasEmitter {
                tracker.cacheBeforeStart(transform)
                return false
            }
            return true
        }
        guard shouldSample else {
            syncTimer()
            return
        }

        let ts = now()
        let counters = readCounters() ?? MachEnergySnapshot()
        let emissions: [EnergyEmission] = state.withLock { tracker in
            var next = tracker.workload
            transform(&next)
            return tracker.update(next, at: ts, counters: counters)
        }
        syncTimer()
        dispatch(emissions)
    }

    /// Updates cached network class from `SyncPathWatch`'s existing `NWPathMonitor`.
    public func setNetwork(_ net: EnergyNetwork) {
        update { $0.net = net }
    }

    /// Updates the current screen name (does not split slices by itself).
    public func setScreen(_ screen: String) {
        update { $0.screen = screen }
    }

    /// Updates whether PostHog Session Replay is currently active.
    public func setReplay(_ active: Bool) {
        update { $0.replay = active }
    }

    /// Updates lifecycle phase, thermal state and Low Power Mode from `AppLifecycle`.
    public func setLifecycle(isForeground: Bool, thermal: ProcessInfo.ThermalState, lpm: Bool) {
        let mapped = EnergyThermal(thermal)
        update {
            $0.isForeground = isForeground
            $0.thermal = mapped
            $0.lpm = lpm
        }
    }

    /// Updates live video playback workload from `TwitchPlayerHost`.
    public func setPlayback(streams: Int, mode: EnergyPlayerMode, pip: Bool, bgAudio: Bool) {
        let clamped = max(0, streams)
        update {
            $0.streams = clamped
            $0.playerMode = clamped > 0 ? mode : .none
            $0.pip = pip
            $0.bgAudio = bgAudio
        }
    }

    /// Runs a streaming checkpoint manually (called by the coalesced 5-minute timer or tests).
    public func checkpoint() {
        let needed = state.withLock { $0.shouldRunCheckpointTimer }
        guard needed, emitSlot.withLock({ $0 != nil }) else { return }
        let ts = now()
        let counters = readCounters() ?? MachEnergySnapshot()
        let emissions = state.withLock { $0.checkpoint(at: ts, counters: counters) }
        dispatch(emissions)
    }

    // MARK: internals

    private func dispatch(_ emissions: [EnergyEmission]) {
        guard !emissions.isEmpty, let sink = emitSlot.withLock({ $0 }) else { return }
        for item in emissions {
            sink(item.name, item.values)
        }
    }

    private func syncTimer() {
        let wantTimer = state.withLock { $0.shouldRunCheckpointTimer } && emitSlot.withLock({ $0 != nil })
        timerLock.withLock { slot in
            if wantTimer {
                guard slot == nil else { return }
                let timer = DispatchSource.makeTimerSource(queue: timerQueue)
                let interval = DispatchTimeInterval.seconds(Self.checkpointIntervalSeconds)
                let leeway = DispatchTimeInterval.seconds(Self.checkpointLeewaySeconds)
                timer.schedule(deadline: .now() + interval, repeating: interval, leeway: leeway)
                timer.setEventHandler { [weak self] in
                    self?.checkpoint()
                }
                timer.resume()
                slot = timer
            } else if let existing = slot {
                existing.cancel()
                slot = nil
            }
        }
    }
}
