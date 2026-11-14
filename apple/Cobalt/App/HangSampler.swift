import Darwin
import Foundation
import Synchronization

/// What the main thread was doing when it stopped answering (owner, 2026-11-14: "butter smooth... telemetry first").
/// 8.15's frame monitor showed 0.3 to 1.2 s stalls on tab switches and when a detail opens, but not where. A thread of
/// its own pings the main queue every 50 ms; when a ping goes unanswered for 250 ms, it pauses the main thread for a
/// moment and walks its stack (frame pointers, no allocation while paused), again at 700 ms and 1.5 s if the stall goes
/// on. When the main thread answers, the samples go out as one `hang_stack` event: the stall's length, the screen, the
/// breadcrumbs, and each sample's frames as `image+0xoffset` (with the symbol when the system has one). App frames are
/// symbolicated on the Mac against the build's dSYM (`atos -o <dSYM> -l 0x100000000 <0x100000000 + offset>`).
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
    private let buffer = UnsafeMutablePointer<UInt>.allocate(capacity: Self.maxFrames)
    private let outstanding = Atomic<Bool>(false)
    private let pongAt = Atomic<UInt64>(0)
    private var onHang: (@Sendable (Report) -> Void)?

    private static let maxFrames = 48
    private static let pollNs: UInt64 = 50_000_000
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
        mainThread = mach_thread_self()
        let me = pthread_self()
        stackHigh = UInt(bitPattern: pthread_get_stackaddr_np(me))
        stackLow = stackHigh - UInt(pthread_get_stacksize_np(me))
        let thread = Thread { [self] in loop() }
        thread.name = "capystore.hang-sampler"
        thread.qualityOfService = .userInitiated
        thread.start()
    }

    // MARK: the watch

    private func loop() {
        var sentAt: UInt64 = 0
        var lastTick = DispatchTime.now().uptimeNanoseconds
        var samples: [(atMs: Int, frames: [UInt])] = []
        while true {
            usleep(UInt32(Self.pollNs / 1000))
            let now = DispatchTime.now().uptimeNanoseconds
            // the whole process was paused (the app went to the background): start over, nothing stalled
            if now - lastTick > 1_000_000_000 {
                samples = []
                sentAt = now
            }
            lastTick = now
            if !outstanding.load(ordering: .acquiring) {
                if !samples.isEmpty {
                    let answered = pongAt.load(ordering: .acquiring)
                    let stallMs = answered > sentAt ? Int((answered - sentAt) / 1_000_000) : samples.last?.atMs ?? 0
                    report(stallMs: stallMs, samples: samples)
                    samples = []
                }
                sentAt = now
                outstanding.store(true, ordering: .releasing)
                DispatchQueue.main.async { [self] in
                    pongAt.store(DispatchTime.now().uptimeNanoseconds, ordering: .releasing)
                    outstanding.store(false, ordering: .releasing)
                }
            } else {
                let stallMs = Int((now - sentAt) / 1_000_000)
                if samples.count < Self.sampleAtMs.count, stallMs >= Self.sampleAtMs[samples.count] {
                    let frames = sample()
                    if !frames.isEmpty { samples.append((stallMs, frames)) }
                }
            }
        }
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
        while n < Self.maxFrames, fp >= stackLow, fp &+ 16 <= stackHigh, fp & 0x7 == 0,
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
        for i in 0..<n { out.append(buffer[i] & Self.addressMask) }
        return out
    }

    // MARK: the report

    private func report(stallMs: Int, samples: [(atMs: Int, frames: [UInt])]) {
        let named = samples.map { (atMs: $0.atMs, frames: $0.frames.map(Self.describe)) }
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
