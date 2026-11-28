import CobaltKit
import Darwin
import Foundation
import os
import Synchronization

/// What the main thread was doing when it stopped answering (owner, 2026-11-14: "butter smooth... telemetry first").
/// A `CFRunLoopObserver` on the main RunLoop flips an atomic busy flag when main starts processing sources and clears
/// it at `.beforeWaiting` (when main goes to sleep). A `.utility` watcher thread sleeps on a condition variable with
/// **zero wakeups** whenever the app is inactive/backgrounded/in PiP or the main thread is idle; only while main is
/// actively busy does it check stall duration (without pinging `DispatchQueue.main.async`) and sample stack frames at
/// 250 ms, 700 ms and 1.5 s. When main finishes, the samples go out as one `hang_stack` event: the stall's length, the
/// screen, the breadcrumbs, and each sample's frames as `image+0xoffset`. App frames are symbolicated on the Mac
/// against the build's dSYM (`atos -o <dSYM> -l 0x100000000 <0x100000000 + offset>`).
///
/// Debug builds also raise an alarm for every stall of 100 ms or more once it ends (8.17: the main thread is
/// display-only, apple/ARCHITECTURE.md rule 7).
final class HangSampler: @unchecked Sendable {
    static let shared = HangSampler()

    /// One stall: how long the main thread did not answer, and up to three samples taken during it.
    struct Report: Sendable {
        var stallMs: Int
        var samples: [(atMs: Int, frames: [String])]
    }

    private let startedFlag = Mutex(false)
    private var mainThread: thread_t = 0
    private var stackLow: UInt = 0
    private var stackHigh: UInt = 0
    private let buffer = UnsafeMutablePointer<UInt>.allocate(capacity: HangSampler.maxFrames)
    private let appActive = Atomic<Bool>(true)
    private let mainBusy = Atomic<Bool>(false)
    private let busySinceNs = Atomic<UInt64>(0)
    private let idleAtNs = Atomic<UInt64>(0)
    private let samplerSleeping = Atomic<Bool>(false)
    #if DEBUG
    private let pendingAlarmMs = Atomic<Int>(0)
    #endif
    private let wakeCondition = NSCondition()
    private var runLoopObserver: CFRunLoopObserver?
    private var onHang: (@Sendable (Report) -> Void)?

    private static let maxFrames = 48
    #if DEBUG
    private static let pollNs: UInt64 = 50_000_000
    private static let alarmMs = 100
    private static let alarmLog = Logger(subsystem: "com.capybaraharmony.cobalt", category: "main-thread")
    #else
    private static let pollNs: UInt64 = 100_000_000
    #endif
    private static let idleGraceNs: UInt64 = 250_000_000
    private static let sampleAtMs = [250, 700, 1500]

    #if os(iOS)
    /// iOS user addresses fit in 36 bits; anything above is a pointer-authentication signature on a saved return address.
    private static let addressMask: UInt = 0x0000_000F_FFFF_FFFF
    #else
    private static let addressMask: UInt = 0x0000_7FFF_FFFF_FFFF
    #endif

    /// Call on the main thread, once; later calls do nothing.
    @MainActor
    func start(onHang: @escaping @Sendable (Report) -> Void) {
        let first = startedFlag.withLock { started -> Bool in
            if started { return false }
            started = true
            return true
        }
        guard first else { return }
        self.onHang = onHang
        appActive.store(AppLifecycle.shared.snapshot.isActive, ordering: .sequentiallyConsistent)
        mainThread = mach_thread_self()
        let me = pthread_self()
        stackHigh = UInt(bitPattern: pthread_get_stackaddr_np(me))
        stackLow = stackHigh - UInt(pthread_get_stacksize_np(me))
        installRunLoopObserver()
        let thread = Thread { [self] in loop() }
        thread.name = "capystore.hang-sampler"
        thread.qualityOfService = .utility
        thread.start()
    }

    /// Pauses the watcher completely (0 wakeups/sec) while the app is inactive, hidden, in PiP, or in background.
    @MainActor
    func setActive(_ active: Bool) {
        let prev = appActive.exchange(active, ordering: .sequentiallyConsistent)
        guard prev != active else { return }
        if !active {
            mainBusy.store(false, ordering: .sequentiallyConsistent)
        } else if samplerSleeping.exchange(false, ordering: .sequentiallyConsistent) {
            wakeCondition.lock()
            wakeCondition.signal()
            wakeCondition.unlock()
        }
    }

    // MARK: RunLoop observation (main thread, lock-free on the hot path)

    @MainActor
    private func installRunLoopObserver() {
        let activities: CFRunLoopActivity = [.entry, .beforeSources, .afterWaiting, .beforeWaiting, .exit]
        let observer = CFRunLoopObserverCreateWithHandler(kCFAllocatorDefault, activities.rawValue, true, 0) {
            [weak self] _, activity in
            guard let self else { return }
            let now = DispatchTime.now().uptimeNanoseconds
            if activity == .beforeWaiting || activity == .exit {
                let wasBusy = self.mainBusy.exchange(false, ordering: .sequentiallyConsistent)
                self.idleAtNs.store(now, ordering: .releasing)
                #if DEBUG
                if wasBusy, self.appActive.load(ordering: .relaxed) {
                    let start = self.busySinceNs.load(ordering: .acquiring)
                    if start > 0, now > start {
                        let ms = Int((now - start) / 1_000_000)
                        if ms >= HangSampler.alarmMs {
                            self.pendingAlarmMs.store(ms, ordering: .releasing)
                            if self.samplerSleeping.exchange(false, ordering: .sequentiallyConsistent) {
                                self.wakeCondition.lock()
                                self.wakeCondition.signal()
                                self.wakeCondition.unlock()
                            }
                        }
                    }
                }
                #else
                _ = wasBusy
                #endif
            } else {
                guard self.appActive.load(ordering: .relaxed) else { return }
                let alreadyBusy = self.mainBusy.load(ordering: .relaxed)
                if !alreadyBusy {
                    self.busySinceNs.store(now, ordering: .releasing)
                    self.mainBusy.store(true, ordering: .sequentiallyConsistent)
                    if self.samplerSleeping.exchange(false, ordering: .sequentiallyConsistent) {
                        self.wakeCondition.lock()
                        self.wakeCondition.signal()
                        self.wakeCondition.unlock()
                    }
                }
            }
        }
        if let observer {
            runLoopObserver = observer
            CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
        }
    }

    // MARK: the watch

    private func loop() {
        var trackedStartNs: UInt64 = 0
        var lastActiveNs = DispatchTime.now().uptimeNanoseconds
        var lastTick = lastActiveNs
        var samples: [(atMs: Int, frames: [UInt])] = []

        while true {
            let active = appActive.load(ordering: .sequentiallyConsistent)
            let busy = mainBusy.load(ordering: .sequentiallyConsistent)

            #if DEBUG
            let alarm = pendingAlarmMs.exchange(0, ordering: .acquiring)
            if alarm >= HangSampler.alarmMs {
                HangSampler.alarm(stallMs: alarm)
            }
            #endif

            if !active {
                samples = []
                trackedStartNs = 0
                sleepUntilWoken()
                lastTick = DispatchTime.now().uptimeNanoseconds
                lastActiveNs = lastTick
                continue
            }

            let now = DispatchTime.now().uptimeNanoseconds
            // If the whole process was suspended, discard any in-flight samples.
            if now >= lastTick, now - lastTick > 1_000_000_000 {
                samples = []
                trackedStartNs = 0
            }
            lastTick = now

            if busy {
                lastActiveNs = now
                let start = busySinceNs.load(ordering: .acquiring)
                if start > 0, start != trackedStartNs {
                    if !samples.isEmpty {
                        flushReport(startNs: trackedStartNs, samples: samples)
                        samples = []
                    }
                    trackedStartNs = start
                }
                if trackedStartNs > 0, now > trackedStartNs {
                    let stallMs = Int((now - trackedStartNs) / 1_000_000)
                    if samples.count < HangSampler.sampleAtMs.count, stallMs >= HangSampler.sampleAtMs[samples.count] {
                        let frames = sample()
                        if !frames.isEmpty { samples.append((stallMs, frames)) }
                    }
                }
            } else {
                if !samples.isEmpty {
                    flushReport(startNs: trackedStartNs, samples: samples)
                    samples = []
                }
                trackedStartNs = 0
                if now >= lastActiveNs, now - lastActiveNs >= HangSampler.idleGraceNs {
                    sleepUntilWoken()
                    lastTick = DispatchTime.now().uptimeNanoseconds
                    lastActiveNs = lastTick
                    continue
                }
            }

            usleep(UInt32(HangSampler.pollNs / 1000))
        }
    }

    private func sleepUntilWoken() {
        wakeCondition.lock()
        samplerSleeping.store(true, ordering: .sequentiallyConsistent)
        let shouldWakeNow: Bool
        if appActive.load(ordering: .sequentiallyConsistent) {
            #if DEBUG
            let hasAlarm = pendingAlarmMs.load(ordering: .acquiring) >= HangSampler.alarmMs
            #else
            let hasAlarm = false
            #endif
            shouldWakeNow = mainBusy.load(ordering: .sequentiallyConsistent) || hasAlarm
        } else {
            shouldWakeNow = false
        }
        if shouldWakeNow {
            samplerSleeping.store(false, ordering: .sequentiallyConsistent)
            wakeCondition.unlock()
            return
        }
        wakeCondition.wait()
        samplerSleeping.store(false, ordering: .sequentiallyConsistent)
        wakeCondition.unlock()
    }

    private func flushReport(startNs: UInt64, samples: [(atMs: Int, frames: [UInt])]) {
        let ended = idleAtNs.load(ordering: .acquiring)
        let stallMs = (startNs > 0 && ended > startNs)
            ? Int((ended - startNs) / 1_000_000)
            : (samples.last?.atMs ?? 0)
        report(stallMs: stallMs, samples: samples)
    }

    // MARK: the sample

    /// The main thread's return addresses, newest first. Nothing in here allocates or takes a lock while the main thread
    /// is paused (it may hold the allocator's lock); every frame pointer is checked to lie in the main thread's stack.
    private func sample() -> [UInt] {
        guard thread_suspend(mainThread) == KERN_SUCCESS else { return [] }
        var n = 0
        var fp: UInt = 0
        #if arch(arm64)
        var state = arm_thread_state64_t()
        var count = mach_msg_type_number_t(MemoryLayout<arm_thread_state64_t>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &state) { pointer in
            pointer.withMemoryRebound(to: natural_t.self, capacity: Int(count)) {
                thread_get_state(mainThread, thread_state_flavor_t(6 /* ARM_THREAD_STATE64 */), $0, &count)
            }
        }
        if kr == KERN_SUCCESS {
            buffer[n] = UInt(state.__pc); n += 1
            buffer[n] = UInt(state.__lr); n += 1
            fp = UInt(state.__fp)
        }
        #elseif arch(x86_64)
        var state = x86_thread_state64_t()
        var count = mach_msg_type_number_t(MemoryLayout<x86_thread_state64_t>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &state) { pointer in
            pointer.withMemoryRebound(to: natural_t.self, capacity: Int(count)) {
                thread_get_state(mainThread, thread_state_flavor_t(4 /* x86_THREAD_STATE64 */), $0, &count)
            }
        }
        if kr == KERN_SUCCESS {
            buffer[n] = UInt(state.__rip); n += 1
            fp = UInt(state.__rbp)
        }
        #endif
        // a frame record is [previous frame pointer, return address]; frame pointers only grow toward the stack's top
        while n < HangSampler.maxFrames, fp >= stackLow, fp &+ 16 <= stackHigh, fp & 0x7 == 0,
              let record = UnsafePointer<UInt>(bitPattern: fp) {
            let next = record[0]
            let ret = record[1]
            if ret == 0 { break }
            buffer[n] = ret; n += 1
            if next <= fp { break }
            fp = next
        }
        thread_resume(mainThread)
        var out: [UInt] = []
        out.reserveCapacity(n)
        for i in 0..<n { out.append(buffer[i] & HangSampler.addressMask) }
        return out
    }

    // MARK: the report

    #if DEBUG
    /// Loud on purpose: a warn line in the app's own log (and so in the Xcode console) plus an os_log fault, which
    /// Console.app and Instruments show in red. Runs on the sampler's thread after the main thread answered.
    private static func alarm(stallMs: Int) {
        Telemetry.log(.warn, .ui, "main thread stall", data: ["ms": .int(stallMs)])
        alarmLog.fault("main thread stall: \(stallMs, privacy: .public) ms (apple/ARCHITECTURE.md)")
    }
    #endif

    private func report(stallMs: Int, samples: [(atMs: Int, frames: [UInt])]) {
        let named = samples.map { (atMs: $0.atMs, frames: $0.frames.map(HangSampler.describe)) }
        onHang?(Report(stallMs: stallMs, samples: named))
    }

    /// `SwiftUICore symbol+0x1c` when the image exports a symbol there, else `cobalt+0x1a2b3c` (offset from the image's
    /// load address).
    private static func describe(_ address: UInt) -> String {
        var info = Dl_info()
        guard address > 0x1000, let pointer = UnsafeRawPointer(bitPattern: address),
              dladdr(pointer, &info) != 0, let base = info.dli_fbase else {
            return "0x" + String(address, radix: 16)
        }
        let image = info.dli_fname.map { String(cString: $0).split(separator: "/").last.map(String.init) ?? "?" } ?? "?"
        if let name = info.dli_sname, let start = info.dli_saddr {
            let symbol = String(cString: name)
            if !symbol.hasPrefix("<redacted>") {
                return "\(image) \(symbol.prefix(90))+\(address - UInt(bitPattern: start))"
            }
        }
        return "\(image)+0x" + String(address - UInt(bitPattern: base), radix: 16)
    }
}
