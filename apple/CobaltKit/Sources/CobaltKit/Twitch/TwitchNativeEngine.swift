@preconcurrency import AVFoundation
import CoreMedia
import Foundation

// Pure-Swift low-latency Twitch playback engine (`#EXT-X-TWITCH-PREFETCH` -> MPEG-TS -> VideoToolbox + AAC).
//
// Runs completely off the main thread:
// - `TwitchStreamResolver` fetches GQL PlaybackAccessToken + Usher master/media playlists (`fast_bread=true`)
// - `ChunkedStreamSession` streams `#EXT-X-TWITCH-PREFETCH` HTTP responses incrementally via `URLSessionDataDelegate`,
//   overlapping the next prefetch segment so there is zero gap at 2-second segment boundaries
// - `MPEGTSDemuxer` demuxes incoming chunks into H.264 AVCC frames and ADTS AAC frames
// - `SampleBufferPipeline` wraps them into `CMSampleBuffer`s and feeds an `AVSampleBufferDisplayLayer`'s
//   `AVSampleBufferVideoRenderer` + `AVSampleBufferAudioRenderer` driven by `AVSampleBufferRenderSynchronizer`,
//   using gentle pitch-preserving rate adjustments (1.06x / 1.12x) to stay glued to the live edge.

public struct TwitchNativeStats: Sendable, Equatable {
    /// Estimated latency to the broadcaster in seconds (from `X-SERVER-TIME` and `#EXT-X-PROGRAM-DATE-TIME`).
    public let delay: Double?
    /// Media currently queued ahead of the playhead (seconds).
    public let bufferSeconds: Double
    /// True when the channel's playlist is delivering Twitch low-latency prefetch segments.
    public let isLowLatency: Bool
    /// Current playback rate (1.0 normally, 1.06–1.12 while gently catching up to live).
    public let rate: Float
    /// True while rebuffering.
    public let isBuffering: Bool
    /// True once the render synchronizer clock has started rendering frames/audio.
    public let isClockStarted: Bool
    /// True when buffering has persisted long enough to trigger automatic recovery.
    public let isStalled: Bool

    public init(
        delay: Double?,
        bufferSeconds: Double,
        isLowLatency: Bool,
        rate: Float,
        isBuffering: Bool,
        isClockStarted: Bool = false,
        isStalled: Bool = false
    ) {
        self.delay = delay
        self.bufferSeconds = bufferSeconds
        self.isLowLatency = isLowLatency
        self.rate = rate
        self.isBuffering = isBuffering
        self.isClockStarted = isClockStarted
        self.isStalled = isStalled
    }
}

public enum TwitchNativeEvent: Sendable, Equatable {
    case loading
    /// Signed Usher master playlist URL for this session (used for Video-Only AirPlay `AVPlayer` handoff).
    case streamURL(URL)
    case variants([TwitchVariant], selectedID: String)
    case playing
    case paused
    /// Explicit user-intent pause state (separate from rebuffering or temporary OS interruptions).
    case userPausedChanged(Bool)
    case offline
    case stats(TwitchNativeStats)
    /// Native playback could not run for this stream (caller should fall back to Twitch's embed).
    case failed(String)
}

/// Volume ramp curve used for single-stream mute transitions and Wave-2 dual-stream audio focus crossfades.
public enum TwitchVolumeRampCurve: Sendable, Equatable {
    case linear
    case equalPower

    /// Interpolates gain in `0...1` at normalized progress `t ∈ [0, 1]`.
    /// `.equalPower` uses `cos(π/2 * t)` on fade-out and `sin(π/2 * t)` on fade-in so `g_out² + g_in² = 1`.
    public func interpolate(from start: Float, to end: Float, progress: Double) -> Float {
        let t = max(0.0, min(1.0, progress))
        let s = max(0.0, min(1.0, start))
        let e = max(0.0, min(1.0, end))
        if abs(e - s) < 0.00001 { return e }
        switch self {
        case .linear:
            return s + Float(t) * (e - s)
        case .equalPower:
            if e < s {
                let gain = Float(cos(.pi * 0.5 * t))
                return e + (s - e) * gain
            } else {
                let gain = Float(sin(.pi * 0.5 * t))
                return s + (e - s) * gain
            }
        }
    }
}

// MARK: - SampleBuffer helpers (public for unit testing)

public enum TwitchSampleBufferFactory {
    /// Wraps an MPEG-4 `AudioSpecificConfig` (typically 2 bytes) in the ISO 14496-1 `ES_Descriptor`
    /// (`esds` magic cookie) expected by CoreMedia's `CMAudioFormatDescriptionCreate` for `kAudioFormatMPEG4AAC`.
    public static func esdsCookie(for audioSpecificConfig: Data) -> Data {
        let ascLen = audioSpecificConfig.count
        let decConfigLen = 13 + 2 + ascLen
        let esDescrLen = 3 + 2 + decConfigLen + 3
        var out = Data()
        out.reserveCapacity(2 + esDescrLen)
        // ES_DescrTag (0x03)
        out.append(contentsOf: [0x03, UInt8(esDescrLen), 0x00, 0x01, 0x00])
        // DecoderConfigDescrTag (0x04)
        out.append(contentsOf: [
            0x04, UInt8(decConfigLen),
            0x40,                   // objectTypeIndication: MPEG-4 Audio (ISO/IEC 14496-3)
            0x15,                   // streamType = 5 (audio) << 2 | 1
            0x00, 0x00, 0x00,       // bufferSizeDB
            0x00, 0x00, 0x00, 0x00, // maxBitrate
            0x00, 0x00, 0x00, 0x00, // avgBitrate
        ])
        // DecSpecificInfoTag (0x05)
        out.append(contentsOf: [0x05, UInt8(ascLen)])
        out.append(audioSpecificConfig)
        // SLConfigDescrTag (0x06)
        out.append(contentsOf: [0x06, 0x01, 0x02])
        return out
    }

    public static func videoFormatDescription(sps: Data, pps: Data) -> CMVideoFormatDescription? {
        sps.withUnsafeBytes { spsRaw in
            pps.withUnsafeBytes { ppsRaw in
                guard let spsPtr = spsRaw.baseAddress?.assumingMemoryBound(to: UInt8.self),
                      let ppsPtr = ppsRaw.baseAddress?.assumingMemoryBound(to: UInt8.self)
                else { return nil }
                var pointers: [UnsafePointer<UInt8>] = [spsPtr, ppsPtr]
                var sizes: [Int] = [sps.count, pps.count]
                var desc: CMVideoFormatDescription?
                let status = CMVideoFormatDescriptionCreateFromH264ParameterSets(
                    allocator: kCFAllocatorDefault,
                    parameterSetCount: 2,
                    parameterSetPointers: &pointers,
                    parameterSetSizes: &sizes,
                    nalUnitHeaderLength: 4,
                    formatDescriptionOut: &desc
                )
                return status == noErr ? desc : nil
            }
        }
    }

    public static func audioFormatDescription(
        sampleRate: Int, channels: Int, audioObjectType: Int, audioSpecificConfig: Data
    ) -> CMAudioFormatDescription? {
        var asbd = AudioStreamBasicDescription(
            mSampleRate: Float64(sampleRate),
            mFormatID: kAudioFormatMPEG4AAC,
            mFormatFlags: UInt32(audioObjectType),
            mBytesPerPacket: 0,
            mFramesPerPacket: 1024,
            mBytesPerFrame: 0,
            mChannelsPerFrame: UInt32(channels),
            mBitsPerChannel: 0,
            mReserved: 0
        )
        let cookie = esdsCookie(for: audioSpecificConfig)
        var desc: CMAudioFormatDescription?
        let status = cookie.withUnsafeBytes { raw in
            CMAudioFormatDescriptionCreate(
                allocator: kCFAllocatorDefault,
                asbd: &asbd,
                layoutSize: 0,
                layout: nil,
                magicCookieSize: cookie.count,
                magicCookie: raw.baseAddress,
                extensions: nil,
                formatDescriptionOut: &desc
            )
        }
        return status == noErr ? desc : nil
    }

    public static func videoSampleBuffer(
        frame: DemuxedVideoFrame, formatDescription: CMVideoFormatDescription
    ) -> CMSampleBuffer? {
        guard !frame.avccData.isEmpty else { return nil }
        guard let blockBuffer = makeBlockBuffer(from: frame.avccData) else { return nil }
        let pts = CMTime(value: frame.pts90k, timescale: MPEGTSDemuxer.timescale)
        let dts = frame.dts90k == frame.pts90k
            ? CMTime.invalid
            : CMTime(value: frame.dts90k, timescale: MPEGTSDemuxer.timescale)
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: pts, decodeTimeStamp: dts)
        var sampleSize = frame.avccData.count
        var sampleBuffer: CMSampleBuffer?
        let status = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            formatDescription: formatDescription,
            sampleCount: 1,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSize,
            sampleBufferOut: &sampleBuffer
        )
        guard status == noErr, let sampleBuffer else { return nil }
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: true) as? [NSMutableDictionary],
           let dict = attachments.first {
            let notSync: CFBoolean = frame.isKeyframe ? kCFBooleanFalse : kCFBooleanTrue
            dict[kCMSampleAttachmentKey_NotSync] = notSync
            dict[kCMSampleAttachmentKey_DependsOnOthers] = notSync
        }
        return sampleBuffer
    }

    public static func audioSampleBuffer(
        frame: DemuxedAudioFrame, formatDescription: CMAudioFormatDescription
    ) -> CMSampleBuffer? {
        guard !frame.aacData.isEmpty else { return nil }
        guard let blockBuffer = makeBlockBuffer(from: frame.aacData) else { return nil }
        let pts = CMTime(value: frame.pts90k, timescale: MPEGTSDemuxer.timescale)
        let dur = CMTime(value: 1024, timescale: CMTimeScale(max(1, frame.sampleRate)))
        var timing = CMSampleTimingInfo(duration: dur, presentationTimeStamp: pts, decodeTimeStamp: .invalid)
        var sampleSize = frame.aacData.count
        var sampleBuffer: CMSampleBuffer?
        let status = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            formatDescription: formatDescription,
            sampleCount: 1,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSize,
            sampleBufferOut: &sampleBuffer
        )
        return status == noErr ? sampleBuffer : nil
    }

    private static func makeBlockBuffer(from data: Data) -> CMBlockBuffer? {
        var blockBuffer: CMBlockBuffer?
        let length = data.count
        let createStatus = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: length,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: length,
            flags: 0,
            blockBufferOut: &blockBuffer
        )
        guard createStatus == kCMBlockBufferNoErr, let blockBuffer else { return nil }
        let copyStatus = data.withUnsafeBytes { raw in
            CMBlockBufferReplaceDataBytes(
                with: raw.baseAddress!,
                blockBuffer: blockBuffer,
                offsetIntoDestination: 0,
                dataLength: length
            )
        }
        return copyStatus == kCMBlockBufferNoErr ? blockBuffer : nil
    }
}

// MARK: - Chunked HTTP streamer (URLSessionDataDelegate)

/// Streams HTTP chunked responses (such as `#EXT-X-TWITCH-PREFETCH` segments) immediately as chunks arrive.
private final class ChunkedStreamSession: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private struct Entry {
        let continuation: AsyncThrowingStream<Data, Error>.Continuation
        let task: URLSessionDataTask
    }

    private let lock = NSLock()
    private var entries: [Int: Entry] = [:]
    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 8
        config.timeoutIntervalForResource = 20
        config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        config.httpMaximumConnectionsPerHost = 6
        return URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }()

    func stream(url: URL) -> AsyncThrowingStream<Data, Error> {
        var req = URLRequest(url: url, timeoutInterval: 8)
        req.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        return stream(request: req)
    }

    func stream(request: URLRequest) -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream(bufferingPolicy: .unbounded) { continuation in
            let task = session.dataTask(with: request)
            let id = task.taskIdentifier

            lock.lock()
            entries[id] = Entry(continuation: continuation, task: task)
            lock.unlock()

            continuation.onTermination = { [weak self] _ in
                guard let self else { return }
                self.lock.lock()
                let removed = self.entries.removeValue(forKey: id)
                self.lock.unlock()
                removed?.task.cancel()
            }
            task.resume()
        }
    }

    func fetchData(url: URL, byteRange: TwitchByteRange? = nil) async throws -> Data {
        var req = URLRequest(url: url, timeoutInterval: 8)
        req.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        if let byteRange {
            req.setValue(byteRange.httpRangeHeader, forHTTPHeaderField: "Range")
        }
        var out = Data()
        for try await chunk in stream(request: req) {
            try Task.checkCancellation()
            out.append(chunk)
        }
        return out
    }

    func invalidate() {
        lock.lock()
        let current = entries
        entries.removeAll()
        lock.unlock()
        for entry in current.values {
            entry.task.cancel()
            entry.continuation.finish()
        }
        session.invalidateAndCancel()
    }

    func urlSession(
        _ session: URLSession, dataTask: URLSessionDataTask,
        didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            finish(taskID: dataTask.taskIdentifier, error: TwitchHLSError.playlistFailed(http.statusCode))
            completionHandler(.cancel)
            return
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        let entry = entries[dataTask.taskIdentifier]
        lock.unlock()
        entry?.continuation.yield(data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        finish(taskID: task.taskIdentifier, error: error)
    }

    private func finish(taskID: Int, error: Error?) {
        lock.lock()
        let entry = entries.removeValue(forKey: taskID)
        lock.unlock()
        guard let entry else { return }
        if let error {
            entry.continuation.finish(throwing: error)
        } else {
            entry.continuation.finish()
        }
    }
}

/// Overlapped prefetch handle: begins reading the next segment in the background and replays its chunks in order.
private actor OverlappedSegmentFetch {
    let segment: TwitchSegment
    private var buffered: [Data] = []
    private var finished = false
    private var failure: Error?
    private var waiter: CheckedContinuation<Void, Never>?
    private var readerTask: Task<Void, Never>?

    init(segment: TwitchSegment) {
        self.segment = segment
    }

    func start(stream: @escaping @Sendable (URL) -> AsyncThrowingStream<Data, Error>) {
        let url = segment.url
        readerTask = Task.detached(priority: .userInitiated) { [weak self] in
            do {
                for try await chunk in stream(url) {
                    if Task.isCancelled {
                        await self?.markDone(error: CancellationError())
                        return
                    }
                    guard let self else { return }
                    await self.append(chunk)
                }
                await self?.markDone(error: nil)
            } catch {
                await self?.markDone(error: error)
            }
        }
    }

    func cancel() {
        readerTask?.cancel()
        readerTask = nil
        markDone(error: CancellationError())
    }

    /// Consumes chunks in exact arrival order (draining any already-buffered chunks immediately).
    /// Cancellation of the calling task cancels the underlying reader immediately so callers never hang.
    func nextChunk() async throws -> Data? {
        while true {
            try Task.checkCancellation()
            if !buffered.isEmpty {
                return buffered.removeFirst()
            }
            if let failure { throw failure }
            if finished { return nil }
            await withTaskCancellationHandler {
                await self.waitForChunkOrDone()
            } onCancel: {
                Task { await self.cancel() }
            }
        }
    }

    private func waitForChunkOrDone() async {
        guard buffered.isEmpty, failure == nil, !finished else { return }
        await withCheckedContinuation { cont in
            if !buffered.isEmpty || failure != nil || finished {
                cont.resume()
            } else {
                waiter = cont
            }
        }
    }

    private func append(_ data: Data) {
        guard !finished else { return }
        buffered.append(data)
        if let w = waiter {
            waiter = nil
            w.resume()
        }
    }

    private func markDone(error: Error?) {
        if let error, failure == nil { failure = error }
        finished = true
        if let w = waiter {
            waiter = nil
            w.resume()
        }
    }
}

private struct UnsafeSendable<T>: @unchecked Sendable {
    let value: T
}

// MARK: - AVSampleBuffer render pipeline (dedicated serial queue)

/// Serializes all `AVSampleBufferVideoRenderer`, `AVSampleBufferAudioRenderer`, and `AVSampleBufferRenderSynchronizer`
/// calls on one private queue (`mediaQueue`).
private final class SampleBufferPipeline: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.capybaraharmony.cobalt.twitch.media", qos: .userInitiated)
    private let synchronizer = AVSampleBufferRenderSynchronizer()
    private let audioRenderer = AVSampleBufferAudioRenderer()
    private weak var videoRenderer: AVSampleBufferVideoRenderer?

    private var videoFormatDesc: CMVideoFormatDescription?
    private var lastSPS: Data?
    private var lastPPS: Data?

    private var audioFormatDesc: CMAudioFormatDescription?
    private var lastASC: Data?

    private var pendingVideo: [CMSampleBuffer] = []
    private var pendingAudio: [CMSampleBuffer] = []
    private var awaitingKeyframe = true
    private var audioOnly = false
    private var videoOutputEnabled = true

    private var activeGeneration: UInt64 = 0
    private var clockStarted = false
    private var isPaused = false
    private var isInterrupted = false
    private var isBuffering = false
    private var bufferingSince: ContinuousClock.Instant?
    private var isMuted = false
    private var volume: Float = 1.0
    private var isLowLatency = true
    private var firstSamplePTS: Double?
    private var highestVideoPTS: Double?
    private var highestAudioPTS: Double?

    // Broadcaster delay anchor: `(ptsSeconds, programDateTime)` + `serverClockOffset`.
    private var pdtAnchorPTS: Double?
    private var pdtAnchorDate: Date?
    private var serverClockOffset: TimeInterval = 0
    private var pendingSegmentPDT: Date?

    private var onPlayingChange: (@Sendable (Bool, UInt64) -> Void)?
    private var audioRequestRegistered = false
    private var observers: [NSObjectProtocol] = []
    private var videoFlushObserver: NSObjectProtocol?

    init() {
        audioRenderer.audioTimePitchAlgorithm = .timeDomain
        synchronizer.addRenderer(audioRenderer)
        #if os(iOS)
        synchronizer.delaysRateChangeUntilHasSufficientMediaData = false
        #endif
        registerNotifications()
    }

    deinit {
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
        if let videoFlushObserver {
            NotificationCenter.default.removeObserver(videoFlushObserver)
        }
    }

    private func registerNotifications() {
        let nc = NotificationCenter.default
        let audioFlushed = nc.addObserver(
            forName: .AVSampleBufferAudioRendererWasFlushedAutomatically,
            object: audioRenderer,
            queue: nil
        ) { [weak self] _ in
            self?.handleAudioRendererFlushed()
        }
        observers.append(audioFlushed)
    }

    func setCallbacks(
        onPlayingChange: @escaping @Sendable (Bool, UInt64) -> Void
    ) {
        queue.async {
            self.onPlayingChange = onPlayingChange
        }
    }

    func attach(videoRenderer: AVSampleBufferVideoRenderer) {
        let box = UnsafeSendable(value: videoRenderer)
        queue.async { [weak self] in
            guard let self else { return }
            let vr = box.value
            if !self.audioRequestRegistered {
                self.audioRequestRegistered = true
                self.audioRenderer.requestMediaDataWhenReady(on: self.queue) { [weak self] in
                    self?.drainAudio()
                }
            }
            if self.videoRenderer === vr {
                self.recoverVideoRendererIfNeeded(vr)
                self.drainVideo()
                return
            }
            if let existing = self.videoRenderer {
                existing.stopRequestingMediaData()
                self.synchronizer.removeRenderer(existing, at: .invalid)
            }
            if let oldObserver = self.videoFlushObserver {
                NotificationCenter.default.removeObserver(oldObserver)
                self.videoFlushObserver = nil
            }
            self.videoRenderer = vr
            self.videoFlushObserver = NotificationCenter.default.addObserver(
                forName: AVSampleBufferVideoRenderer.requiresFlushToResumeDecodingDidChangeNotification,
                object: vr,
                queue: nil
            ) { [weak self] _ in
                self?.recoverVideoRenderer()
            }
            self.synchronizer.addRenderer(vr)
            self.recoverVideoRendererIfNeeded(vr)
            vr.requestMediaDataWhenReady(on: self.queue) { [weak self] in
                self?.drainVideo()
            }
            self.drainVideo()
        }
    }

    /// Re-checks the attached `AVSampleBufferVideoRenderer` immediately after a view reparenting or layout swap
    /// (e.g., fold/unfold or span transition) so decoding resumes without waiting for the next telemetry tick.
    func recoverVideoRenderer() {
        queue.async { [weak self] in
            guard let self, self.videoOutputEnabled, let vr = self.videoRenderer else { return }
            self.recoverVideoRendererIfNeeded(vr)
            self.drainVideo()
        }
    }

    func configure(audioOnly: Bool, isLowLatency: Bool) {
        queue.async {
            self.audioOnly = audioOnly
            self.isLowLatency = isLowLatency
        }
    }

    func updateServerClock(serverTime: Date, receivedAt: Date) {
        queue.async {
            let sample = serverTime.timeIntervalSince(receivedAt)
            if self.serverClockOffset == 0 {
                self.serverClockOffset = sample
            } else {
                // Light EMA so network jitter doesn't make the delay badge jump wildly.
                self.serverClockOffset = self.serverClockOffset * 0.7 + sample * 0.3
            }
        }
    }

    func beginSegment(programDateTime: Date?) {
        queue.async {
            self.pendingSegmentPDT = programDateTime
        }
    }

    func enqueue(_ samples: [DemuxedSample]) {
        guard !samples.isEmpty else { return }
        queue.async {
            self.ingestOnQueue(samples)
        }
    }

    func setPaused(_ paused: Bool, generation: UInt64) {
        queue.async {
            self.activeGeneration = generation
            self.isPaused = paused
            if paused {
                self.synchronizer.rate = 0
                self.bufferingSince = nil
                self.onPlayingChange?(false, generation)
            } else if self.clockStarted && !self.isInterrupted {
                self.synchronizer.rate = 1.0
                self.onPlayingChange?(true, generation)
            }
        }
    }

    func setInterrupted(_ interrupted: Bool, generation: UInt64) {
        queue.async {
            self.activeGeneration = generation
            self.isInterrupted = interrupted
            if interrupted {
                self.synchronizer.rate = 0
                self.bufferingSince = nil
                self.onPlayingChange?(false, generation)
            }
        }
    }

    func setMuted(_ muted: Bool) {
        queue.async {
            self.isMuted = muted
            self.audioRenderer.isMuted = muted
        }
    }

    func setVolume(_ volume: Float) {
        let clamped = max(0.0, min(1.0, volume))
        queue.async {
            self.volume = clamped
            self.audioRenderer.volume = clamped
        }
    }

    func setVideoOutputEnabled(_ enabled: Bool) {
        queue.async {
            guard self.videoOutputEnabled != enabled else { return }
            self.videoOutputEnabled = enabled
            if !enabled {
                self.pendingVideo.removeAll(keepingCapacity: true)
                self.videoRenderer?.flush(removingDisplayedImage: false)
                self.highestVideoPTS = nil
                self.awaitingKeyframe = true
            } else {
                // Require an IDR keyframe on resume so video recovers without macroblock artifacts.
                // Clear any stale pre-background video PTS so telemetry doesn't trigger a false stall before the IDR arrives.
                self.highestVideoPTS = nil
                self.awaitingKeyframe = true
                if let vr = self.videoRenderer {
                    self.recoverVideoRendererIfNeeded(vr)
                }
            }
        }
    }

    func flush(clearImage: Bool, generation: UInt64) {
        queue.async {
            self.activeGeneration = generation
            self.synchronizer.rate = 0
            self.audioRenderer.flush()
            if clearImage {
                self.videoRenderer?.flush(removingDisplayedImage: true)
            } else {
                self.videoRenderer?.flush()
            }
            self.pendingVideo.removeAll(keepingCapacity: true)
            self.pendingAudio.removeAll(keepingCapacity: true)
            self.awaitingKeyframe = true
            self.clockStarted = false
            self.isPaused = false
            self.isInterrupted = false
            self.isBuffering = false
            self.bufferingSince = nil
            self.firstSamplePTS = nil
            self.highestVideoPTS = nil
            self.highestAudioPTS = nil
            self.pdtAnchorPTS = nil
            self.pdtAnchorDate = nil
            self.pendingSegmentPDT = nil
            self.videoFormatDesc = nil
            self.lastSPS = nil
            self.lastPPS = nil
            self.audioFormatDesc = nil
            self.lastASC = nil
        }
    }

    func tickTelemetry() async -> TwitchNativeStats {
        await withCheckedContinuation { cont in
            queue.async {
                cont.resume(returning: self.computeTelemetryAndPaceOnQueue())
            }
        }
    }

    // MARK: - Notification handlers

    private func handleAudioRendererFlushed() {
        queue.async { [weak self] in
            guard let self, self.clockStarted else { return }
            Telemetry.log(.info, .live, "twitch.native.audio_flushed")
            self.audioRenderer.flush()
            let nowPTS = self.synchronizer.currentTime().seconds
            if nowPTS.isFinite {
                // Drop queued audio frames that are already behind the current playhead.
                self.pendingAudio.removeAll { sb in
                    let pts = CMSampleBufferGetPresentationTimeStamp(sb).seconds
                    return pts.isFinite && pts < nowPTS - 0.1
                }
            }
            self.drainAudio()
            if !self.isPaused && !self.isInterrupted && !self.isBuffering && self.synchronizer.rate == 0 {
                self.synchronizer.rate = 1.0
            }
        }
    }

    // MARK: - Queue-confined internals

    private func recoverVideoRendererIfNeeded(_ vr: AVSampleBufferVideoRenderer) {
        guard vr.status == .failed || vr.requiresFlushToResumeDecoding else { return }
        let wasFailed = vr.status == .failed
        let neededFlush = vr.requiresFlushToResumeDecoding
        Telemetry.log(.info, .live, "twitch.native.video_flush", data: ["failed": .bool(wasFailed)])
        vr.flush()
        pendingVideo.removeAll(keepingCapacity: true)
        awaitingKeyframe = true
        if !clockStarted {
            // If the renderer failed or was invalidated by view reparenting before playback started, clear the
            // old flushed PTS anchors and audio queue so the synchronizer starts cleanly on the next IDR keyframe
            // instead of starting the clock seconds behind the newly enqueued video frames.
            firstSamplePTS = nil
            highestVideoPTS = nil
            highestAudioPTS = nil
            pdtAnchorPTS = nil
            pdtAnchorDate = nil
            audioRenderer.flush()
            pendingAudio.removeAll(keepingCapacity: true)
        } else {
            // Clear stale video PTS while waiting for the next IDR keyframe so live audio isn't falsely stalled.
            highestVideoPTS = nil
        }
        if wasFailed || neededFlush {
            vr.stopRequestingMediaData()
            vr.requestMediaDataWhenReady(on: queue) { [weak self] in
                self?.drainVideo()
            }
        }
    }

    private func ingestOnQueue(_ samples: [DemuxedSample]) {
        guard !isPaused && !isInterrupted else { return }

        // Recover cleanly if VideoToolbox invalidated the display layer (e.g., background transition or view reparenting).
        if videoOutputEnabled, let vr = videoRenderer {
            recoverVideoRendererIfNeeded(vr)
        }

        let skipVideo = audioOnly || !videoOutputEnabled
        for sample in samples {
            switch sample {
            case .video(let frame):
                guard !skipVideo else { continue }
                if awaitingKeyframe {
                    guard frame.isKeyframe, let sps = frame.sps, let pps = frame.pps else { continue }
                    if sps != lastSPS || pps != lastPPS || videoFormatDesc == nil {
                        guard let desc = TwitchSampleBufferFactory.videoFormatDescription(sps: sps, pps: pps) else { continue }
                        videoFormatDesc = desc
                        lastSPS = sps
                        lastPPS = pps
                    }
                    awaitingKeyframe = false
                } else if let sps = frame.sps, let pps = frame.pps, (sps != lastSPS || pps != lastPPS || videoFormatDesc == nil) {
                    if let desc = TwitchSampleBufferFactory.videoFormatDescription(sps: sps, pps: pps) {
                        videoFormatDesc = desc
                        lastSPS = sps
                        lastPPS = pps
                    }
                }
                guard let desc = videoFormatDesc,
                      let sb = TwitchSampleBufferFactory.videoSampleBuffer(frame: frame, formatDescription: desc)
                else { continue }

                let ptsSec = Double(frame.pts90k) / Double(MPEGTSDemuxer.timescale)
                recordAnchorIfNeeded(ptsSeconds: ptsSec)
                if firstSamplePTS == nil { firstSamplePTS = ptsSec }
                highestVideoPTS = max(highestVideoPTS ?? ptsSec, ptsSec)
                pendingVideo.append(sb)

            case .audio(let frame):
                if frame.audioSpecificConfig != lastASC || audioFormatDesc == nil {
                    guard let desc = TwitchSampleBufferFactory.audioFormatDescription(
                        sampleRate: frame.sampleRate,
                        channels: frame.channels,
                        audioObjectType: frame.audioObjectType,
                        audioSpecificConfig: frame.audioSpecificConfig
                    ) else { continue }
                    audioFormatDesc = desc
                    lastASC = frame.audioSpecificConfig
                }
                guard let desc = audioFormatDesc,
                      let sb = TwitchSampleBufferFactory.audioSampleBuffer(frame: frame, formatDescription: desc)
                else { continue }

                let ptsSec = Double(frame.pts90k) / Double(MPEGTSDemuxer.timescale)
                if skipVideo {
                    recordAnchorIfNeeded(ptsSeconds: ptsSec)
                    if firstSamplePTS == nil { firstSamplePTS = ptsSec }
                }
                highestAudioPTS = max(highestAudioPTS ?? ptsSec, ptsSec)
                pendingAudio.append(sb)
            }
        }

        // Prevent unbounded memory growth if rendering is paused or blocked.
        if pendingVideo.count > 480 {
            pendingVideo.removeFirst(pendingVideo.count - 240)
            awaitingKeyframe = true
        }
        if pendingAudio.count > 480 {
            pendingAudio.removeFirst(pendingAudio.count - 240)
        }

        drainVideo()
        drainAudio()
        startClockIfReady()
    }

    private func recordAnchorIfNeeded(ptsSeconds: Double) {
        if let pdt = pendingSegmentPDT {
            pendingSegmentPDT = nil
            pdtAnchorPTS = ptsSeconds
            pdtAnchorDate = pdt
        }
    }

    private func drainVideo() {
        guard let vr = videoRenderer else { return }
        if videoOutputEnabled {
            recoverVideoRendererIfNeeded(vr)
        }
        while !pendingVideo.isEmpty && vr.isReadyForMoreMediaData {
            let sb = pendingVideo.removeFirst()
            vr.enqueue(sb)
        }
    }

    private func drainAudio() {
        while !pendingAudio.isEmpty && audioRenderer.isReadyForMoreMediaData {
            let sb = pendingAudio.removeFirst()
            audioRenderer.enqueue(sb)
        }
    }

    private func startClockIfReady() {
        guard !clockStarted, !isPaused, !isInterrupted, let start = firstSamplePTS else { return }
        let skipVideo = audioOnly || !videoOutputEnabled
        let highest: Double
        if skipVideo {
            highest = highestAudioPTS ?? start
        } else {
            // Once an initial video keyframe has established `firstSamplePTS`, count either video or audio advance
            // toward the startup cushion so low-FPS / static streams start promptly instead of stalling.
            highest = max(highestVideoPTS ?? start, highestAudioPTS ?? start)
        }
        let cushion = highest - start
        // Start playback once we have ~0.30 s buffered so the first frame shows almost instantly without immediate underrun.
        let minStartCushion = isLowLatency ? 0.30 : 0.80
        guard cushion >= minStartCushion else { return }
        clockStarted = true
        isBuffering = false
        bufferingSince = nil
        audioRenderer.isMuted = isMuted
        audioRenderer.volume = volume
        let startTime = CMTime(seconds: start, preferredTimescale: MPEGTSDemuxer.timescale)
        synchronizer.setRate(1.0, time: startTime)
        onPlayingChange?(true, activeGeneration)
    }

    private func computeTelemetryAndPaceOnQueue() -> TwitchNativeStats {
        if videoOutputEnabled, let vr = videoRenderer {
            recoverVideoRendererIfNeeded(vr)
        }

        let nowPTS = synchronizer.currentTime().seconds
        let skipVideo = audioOnly || !videoOutputEnabled
        // While waiting for the next IDR keyframe after background-audio resume or renderer flush on an already-live
        // clock, measure buffer health from audio so playback never falsely pauses/stalls during keyframe re-acquisition.
        let useAudioBuffer = skipVideo || (clockStarted && awaitingKeyframe && highestAudioPTS != nil)
        let highest: Double? = useAudioBuffer ? highestAudioPTS : (highestVideoPTS ?? highestAudioPTS)
        let bufferSec: Double
        if clockStarted, nowPTS.isFinite, let highest {
            bufferSec = max(0, highest - nowPTS)
        } else if let start = firstSamplePTS, let highest {
            bufferSec = max(0, highest - start)
        } else {
            bufferSec = 0
        }

        var isStalled = false

        // Smooth live-edge chase and underrun protection.
        if clockStarted && !isPaused && !isInterrupted {
            let resumeTarget = isLowLatency ? 0.35 : 0.85
            if isBuffering {
                if bufferSec >= resumeTarget {
                    isBuffering = false
                    bufferingSince = nil
                    synchronizer.rate = 1.0
                } else if let since = bufferingSince {
                    let stuck = ContinuousClock.now - since
                    if stuck >= .seconds(6) {
                        isStalled = true
                    } else if stuck >= .seconds(2), nowPTS.isFinite, let highest, nowPTS > highest + 1.5 {
                        // Synchronizer ran ahead of incoming PTS (e.g. after discontinuity/flush): trigger recovery early.
                        isStalled = true
                    }
                }
            } else if bufferSec < 0.05 {
                isBuffering = true
                bufferingSince = .now
                synchronizer.rate = 0.0
            } else if isLowLatency {
                // Gently speed up with pitch-preserving audio when buffer grows past live target.
                let desiredRate: Float
                if bufferSec > 3.2 {
                    desiredRate = 1.12
                } else if bufferSec > 2.0 {
                    desiredRate = 1.06
                } else if bufferSec <= 1.25 {
                    desiredRate = 1.0
                } else {
                    desiredRate = synchronizer.rate
                }
                if abs(synchronizer.rate - desiredRate) > 0.005 {
                    synchronizer.rate = desiredRate
                }
            } else if abs(synchronizer.rate - 1.0) > 0.005 {
                synchronizer.rate = 1.0
            }
        }

        // Broadcaster delay from segment PROGRAM-DATE-TIME + Twitch X-SERVER-TIME clock offset.
        var delay: Double?
        if clockStarted, nowPTS.isFinite, let anchorPTS = pdtAnchorPTS, let anchorDate = pdtAnchorDate {
            let playingBroadcastTime = anchorDate.addingTimeInterval(nowPTS - anchorPTS)
            let liveServerNow = Date.now.addingTimeInterval(serverClockOffset)
            let rawDelay = liveServerNow.timeIntervalSince(playingBroadcastTime)
            if rawDelay.isFinite && rawDelay > 0.05 && rawDelay < 120 {
                delay = rawDelay
            }
        }

        return TwitchNativeStats(
            delay: delay,
            bufferSeconds: bufferSec,
            isLowLatency: isLowLatency,
            rate: synchronizer.rate,
            isBuffering: isBuffering,
            isClockStarted: clockStarted,
            isStalled: isStalled
        )
    }
}

// MARK: - Engine actor

/// `AVSampleBufferVideoRenderer` is thread-safe for enqueue and flush operations; this box lets MainActor views hand it
/// across to `TwitchNativeEngine` without triggering Swift 6 region-isolation warnings.
public struct TwitchVideoRendererBox: @unchecked Sendable {
    public let renderer: AVSampleBufferVideoRenderer

    public init(_ renderer: AVSampleBufferVideoRenderer) {
        self.renderer = renderer
    }
}

/// Drives a single live Twitch stream from GQL/Usher through chunked prefetching into `AVSampleBufferDisplayLayer`.
public actor TwitchNativeEngine {
    public typealias EventHandler = @Sendable (TwitchNativeEvent) -> Void
    public typealias SegmentStreamer = @Sendable (URL) -> AsyncThrowingStream<Data, Error>
    public typealias SampleTap = @Sendable ([DemuxedSample]) -> Void

    private enum SegmentContainer: String {
        case unknown
        case mpegts
        case fmp4
    }

    private struct InitMapCacheKey: Hashable {
        let urlKey: String
        let byteRange: TwitchByteRange?

        init(url: URL, byteRange: TwitchByteRange?) {
            // Strip rotating query params (e.g. `?dna=...`) so the same init map across refreshes hits cache.
            self.urlKey = "\(url.host() ?? "")\(url.path())"
            self.byteRange = byteRange
        }
    }

    private struct SegmentConsumeResult {
        let succeeded: Bool
        let sampleCount: Int
        let hadKeyframe: Bool
    }

    private let resolver: TwitchStreamResolver
    private let customSegmentStreamer: SegmentStreamer?
    private let startupTimeout: Duration
    private let firstJoinPrefetchTimeout: Duration
    private let emptyPlaylistRefreshPolls: Int
    private let audioSession: AudioSessionCoordinator
    private let audioClaimID = "twitch.native.\(UUID().uuidString)"
    private let pipeline = SampleBufferPipeline()
    private var streamer = ChunkedStreamSession()
    private var tsDemuxer = MPEGTSDemuxer()
    private var fmp4Demuxer = FMP4Demuxer()
    private var activeContainer: SegmentContainer = .unknown
    private var initSegmentCache: [InitMapCacheKey: Data] = [:]
    private var initSegmentCacheOrder: [InitMapCacheKey] = []
    private var loadedInitMapKey: InitMapCacheKey?

    // Non-PII startup/failure diagnostics for PostHog telemetry.
    private var diagHasMap = false
    private var diagSamples = 0
    private var diagKeyframes = 0
    private var diagSegments = 0

    private var onEvent: EventHandler?
    private var onSamples: SampleTap?
    private var audioObserverRegistered = false
    private var channel: String?
    private var authToken: String?
    private var variants: [TwitchVariant] = []
    private var selectedVariant: TwitchVariant?
    private var preferredVariantID: String?

    private var userPaused = false
    private var isInterrupted = false
    private var isMuted = false
    private var currentVolume: Float = 1.0
    private var volumeRampTask: Task<Void, Never>?
    private var generation: UInt64 = 0
    private var runTask: Task<Void, Never>?
    private var telemetryTask: Task<Void, Never>?
    private var overlappedFetch: OverlappedSegmentFetch?
    private var loadingSince: ContinuousClock.Instant?
    private var stallRecoveries = 0

    /// Explicit user-requested pause state (distinct from transient pacer buffering or system interruptions).
    public var isUserPaused: Bool { userPaused }
    /// Current target audio renderer gain (`0.0...1.0`).
    public var volume: Float { currentVolume }

    public init(
        resolver: TwitchStreamResolver = TwitchStreamResolver(),
        startupTimeout: Duration = .seconds(12),
        firstJoinPrefetchTimeout: Duration = .seconds(4),
        emptyPlaylistRefreshPolls: Int = 10,
        segmentStreamer: SegmentStreamer? = nil,
        audioSession: AudioSessionCoordinator = .shared
    ) {
        self.resolver = resolver
        self.startupTimeout = startupTimeout
        self.firstJoinPrefetchTimeout = firstJoinPrefetchTimeout
        self.emptyPlaylistRefreshPolls = max(2, emptyPlaylistRefreshPolls)
        self.customSegmentStreamer = segmentStreamer
        self.audioSession = audioSession
    }

    deinit {
        volumeRampTask?.cancel()
        audioSession.removeObserver(id: audioClaimID)
        audioSession.release(audioClaimID)
    }

    public func setEventHandler(_ handler: @escaping EventHandler) {
        self.onEvent = handler
        pipeline.setCallbacks(
            onPlayingChange: { [weak self] playing, gen in
                guard let self else { return }
                Task { await self.handlePlayingChange(playing, gen: gen) }
            }
        )
        registerAudioObserverIfNeeded()
    }

    /// Registers a non-blocking tap that receives every demuxed H.264/AAC sample batch for rolling clip capture.
    public func setSampleTap(_ tap: SampleTap?) {
        self.onSamples = tap
    }

    public func attach(videoRenderer box: TwitchVideoRendererBox) {
        pipeline.attach(videoRenderer: box.renderer)
    }

    /// Triggers immediate video-renderer recovery and queue drain (e.g., after view reparenting on layout swap / span).
    public func recoverVideoRenderer() {
        pipeline.recoverVideoRenderer()
    }

    public func start(channel: String, authToken: String?, preferredVariantID: String? = nil) {
        let clean = TwitchStreamResolver.sanitize(channel)
        guard !clean.isEmpty else { return }
        registerAudioObserverIfNeeded()
        stopInternal(clearImage: true, releaseAudioClaim: false)
        self.channel = clean
        self.authToken = authToken
        self.preferredVariantID = preferredVariantID
        self.userPaused = false
        self.isInterrupted = false
        self.stallRecoveries = 0
        generation &+= 1
        let gen = generation
        pipeline.flush(clearImage: true, generation: gen)
        pipeline.setVolume(currentVolume)
        pipeline.setMuted(isMuted)
        self.loadingSince = .now
        audioSession.claim(audioClaimID, kind: .playback(allowsPiP: true))
        emit(.userPausedChanged(false))
        emit(.loading)
        startTelemetryLoop(gen: gen)
        runTask = Task.detached(priority: .userInitiated) { [weak self] in
            await self?.runSession(gen: gen)
        }
    }

    public func stop() {
        stopInternal(clearImage: true, releaseAudioClaim: true)
    }

    public func setPaused(_ paused: Bool) {
        guard channel != nil else { return }
        if paused == userPaused && !isInterrupted { return }
        userPaused = paused
        emit(.userPausedChanged(paused))
        if paused {
            isInterrupted = false
            loadingSince = nil
            pipeline.setPaused(true, generation: generation)
            // Stop active segment downloads while paused so we don't burn data; resume jumps straight to live.
            runTask?.cancel()
            runTask = nil
            telemetryTask?.cancel()
            telemetryTask = nil
            cancelOverlap()
            audioSession.release(audioClaimID)
        } else {
            // Resuming a live stream restarts cleanly at the live edge.
            isInterrupted = false
            guard let ch = channel else { return }
            let auth = authToken
            let pref = selectedVariant?.id ?? preferredVariantID
            start(channel: ch, authToken: auth, preferredVariantID: pref)
        }
    }

    public func setMuted(_ muted: Bool) {
        volumeRampTask?.cancel()
        volumeRampTask = nil
        isMuted = muted
        pipeline.setMuted(muted)
    }

    public func setVolume(_ volume: Float) {
        volumeRampTask?.cancel()
        volumeRampTask = nil
        let clamped = max(0.0, min(1.0, volume))
        currentVolume = clamped
        pipeline.setVolume(clamped)
    }

    /// Smoothly ramps `AVSampleBufferAudioRenderer.volume` over `duration` (equal-power by default).
    ///
    /// Click-free endpoint handling: when `updateMuteOnEndpoints` is true, unmuting runs *before* ramping up from 0,
    /// and muting runs *only after* gain settles at 0.
    public func rampVolume(
        to target: Float,
        duration: Duration = .milliseconds(160),
        curve: TwitchVolumeRampCurve = .equalPower,
        updateMuteOnEndpoints: Bool = true
    ) {
        volumeRampTask?.cancel()
        volumeRampTask = nil

        let goal = max(0.0, min(1.0, target))
        let startVol = currentVolume

        if updateMuteOnEndpoints && goal > 0.001 && isMuted {
            isMuted = false
            pipeline.setMuted(false)
        }

        let totalSeconds = Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
        guard totalSeconds > 0.005, abs(goal - startVol) > 0.001 else {
            currentVolume = goal
            pipeline.setVolume(goal)
            if updateMuteOnEndpoints && goal <= 0.001 && !isMuted {
                isMuted = true
                pipeline.setMuted(true)
            }
            return
        }

        let stepInterval: Duration = .milliseconds(16)
        let steps = max(1, Int((totalSeconds / 0.016).rounded()))
        volumeRampTask = Task { [weak self] in
            for step in 1...steps {
                try? await Task.sleep(for: stepInterval)
                guard let self, !Task.isCancelled else { return }
                let progress = Double(step) / Double(steps)
                let gain = curve.interpolate(from: startVol, to: goal, progress: progress)
                await self.applyRampedVolume(gain)
            }
            guard let self, !Task.isCancelled else { return }
            await self.finishVolumeRamp(goal: goal, updateMuteOnEndpoints: updateMuteOnEndpoints)
        }
    }

    /// Disables or re-enables video decoding/enqueuing while audio continues uninterrupted (e.g. screen-locked
    /// background audio without Picture-in-Picture).
    public func setVideoOutputEnabled(_ enabled: Bool) {
        pipeline.setVideoOutputEnabled(enabled)
    }

    public func selectVariant(id: String) {
        preferredVariantID = id
        guard channel != nil, let match = variants.first(where: { $0.id == id && $0.isNativeCompatible }) else { return }
        if selectedVariant?.id == match.id && runTask != nil {
            return
        }
        selectedVariant = match
        // Restart playback loop on the new variant without re-resolving GQL/Usher unless needed.
        runTask?.cancel()
        telemetryTask?.cancel()
        cancelOverlap()
        resetDemuxers(clearInitCache: false)
        resetDiagnostics()
        generation &+= 1
        let gen = generation
        pipeline.flush(clearImage: false, generation: gen)
        loadingSince = .now
        emit(.variants(variants.filter(\.isNativeCompatible), selectedID: match.id))
        emit(.loading)
        startTelemetryLoop(gen: gen)
        runTask = Task.detached(priority: .userInitiated) { [weak self] in
            await self?.streamVariantLoop(variant: match, gen: gen)
        }
    }

    /// Flushes buffered frames and rejoins directly at the latest prefetch edge.
    /// Pass `refreshStream: true` during stall recovery so a stale/reassigned Weaver URL is re-resolved from GQL/Usher.
    public func jumpToLive(refreshStream: Bool = false) {
        guard channel != nil else { return }
        if userPaused {
            setPaused(false)
            return
        }
        isInterrupted = false
        guard let variant = selectedVariant, !refreshStream else {
            runTask?.cancel()
            telemetryTask?.cancel()
            cancelOverlap()
            resetDemuxers(clearInitCache: false)
            resetDiagnostics()
            generation &+= 1
            let gen = generation
            pipeline.flush(clearImage: false, generation: gen)
            loadingSince = .now
            startTelemetryLoop(gen: gen)
            runTask = Task.detached(priority: .userInitiated) { [weak self] in
                await self?.runSession(gen: gen)
            }
            return
        }
        runTask?.cancel()
        telemetryTask?.cancel()
        cancelOverlap()
        resetDemuxers(clearInitCache: false)
        resetDiagnostics()
        generation &+= 1
        let gen = generation
        pipeline.flush(clearImage: false, generation: gen)
        loadingSince = .now
        startTelemetryLoop(gen: gen)
        runTask = Task.detached(priority: .userInitiated) { [weak self] in
            await self?.streamVariantLoop(variant: variant, gen: gen)
        }
    }

    // MARK: - Playback loops

    private func registerAudioObserverIfNeeded() {
        guard !audioObserverRegistered else { return }
        audioObserverRegistered = true
        audioSession.addObserver(id: audioClaimID) { [weak self] event in
            guard let self else { return }
            Task { await self.handleAudioEvent(event) }
        }
    }

    private func applyRampedVolume(_ volume: Float) {
        currentVolume = volume
        pipeline.setVolume(volume)
    }

    private func finishVolumeRamp(goal: Float, updateMuteOnEndpoints: Bool) {
        currentVolume = goal
        pipeline.setVolume(goal)
        if updateMuteOnEndpoints && goal <= 0.001 && !isMuted {
            isMuted = true
            pipeline.setMuted(true)
        }
        volumeRampTask = nil
    }

    private func activeSegmentStream() -> SegmentStreamer {
        if let customSegmentStreamer { return customSegmentStreamer }
        let s = streamer
        return { url in s.stream(url: url) }
    }

    private func handlePlayingChange(_ playing: Bool, gen: UInt64) {
        guard gen == generation else { return }
        if playing {
            loadingSince = nil
            stallRecoveries = 0
        }
        emit(playing ? .playing : .paused)
    }

    private func handleAudioEvent(_ event: AudioSessionEvent) {
        switch event {
        case .interruptionBegan:
            guard channel != nil, !userPaused, !isInterrupted else { return }
            isInterrupted = true
            loadingSince = nil
            // Halt segment pulls AND notify pipeline/UI so the 480-frame cap never overflows during a call/Siri.
            runTask?.cancel()
            runTask = nil
            telemetryTask?.cancel()
            telemetryTask = nil
            cancelOverlap()
            pipeline.setInterrupted(true, generation: generation)

        case .interruptionEnded(let shouldResume):
            guard isInterrupted else { return }
            isInterrupted = false
            guard channel != nil, !userPaused else {
                pipeline.setInterrupted(false, generation: generation)
                return
            }
            if shouldResume {
                audioSession.claim(audioClaimID, kind: .playback(allowsPiP: true))
                audioSession.reactivateIfNeeded()
                jumpToLive()
            } else {
                userPaused = true
                pipeline.setInterrupted(false, generation: generation)
                pipeline.setPaused(true, generation: generation)
                audioSession.release(audioClaimID)
                emit(.userPausedChanged(true))
            }

        case .routeOldDeviceUnavailable:
            guard channel != nil, !userPaused else { return }
            setPaused(true)

        case .mediaServicesReset:
            guard channel != nil, !userPaused, !isInterrupted else { return }
            audioSession.claim(audioClaimID, kind: .playback(allowsPiP: true))
            audioSession.reactivateIfNeeded()
            jumpToLive()
        }
    }

    private func startTelemetryLoop(gen: UInt64) {
        telemetryTask?.cancel()
        let interval: Duration = startupTimeout < .seconds(2) ? .milliseconds(50) : .milliseconds(500)
        telemetryTask = Task.detached(priority: .utility) { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard let self, !Task.isCancelled else { return }
                await self.pollTelemetry(gen: gen)
            }
        }
    }

    private func failSession(gen: UInt64, reason: String) {
        guard gen == generation else { return }
        Telemetry.log(.warn, .live, "twitch.native.failed", data: diagnosticData(reason: reason))
        generation &+= 1
        runTask?.cancel()
        runTask = nil
        telemetryTask?.cancel()
        telemetryTask = nil
        cancelOverlap()
        loadingSince = nil
        audioSession.release(audioClaimID)
        emit(.failed(reason))
    }

    private func stopInternal(clearImage: Bool, releaseAudioClaim: Bool) {
        generation &+= 1
        let gen = generation
        volumeRampTask?.cancel()
        volumeRampTask = nil
        runTask?.cancel()
        runTask = nil
        telemetryTask?.cancel()
        telemetryTask = nil
        cancelOverlap()
        streamer.invalidate()
        streamer = ChunkedStreamSession()
        resetDemuxers(clearInitCache: true)
        resetDiagnostics()
        pipeline.flush(clearImage: clearImage, generation: gen)
        loadingSince = nil
        stallRecoveries = 0
        isInterrupted = false
        channel = nil
        variants = []
        selectedVariant = nil
        if releaseAudioClaim {
            userPaused = false
            audioSession.release(audioClaimID)
        }
    }

    private var activeUnsupportedVideoCodec: String? {
        fmp4Demuxer.unsupportedVideoCodec ?? tsDemuxer.unsupportedVideoCodec
    }

    private func resetDemuxers(clearInitCache: Bool) {
        tsDemuxer.reset()
        fmp4Demuxer.reset()
        activeContainer = .unknown
        loadedInitMapKey = nil
        if clearInitCache {
            initSegmentCache.removeAll()
            initSegmentCacheOrder.removeAll()
        }
    }

    private func resetDiagnostics() {
        diagHasMap = false
        diagSamples = 0
        diagKeyframes = 0
        diagSegments = 0
    }

    func diagnosticData(reason: String? = nil) -> [String: TelemetryValue] {
        var data: [String: TelemetryValue] = [
            "container": .string(activeContainer.rawValue),
            "hasMap": .bool(diagHasMap),
            "samples": .int(diagSamples),
            "keyframes": .int(diagKeyframes),
            "segments": .int(diagSegments),
        ]
        if let variantID = selectedVariant?.id {
            data["variant"] = .string(variantID)
        }
        if let reason {
            data["reason"] = .string(reason)
        }
        return data
    }

    private func beginActiveDiscontinuity() -> [DemuxedSample] {
        let flushed: [DemuxedSample]
        switch activeContainer {
        case .fmp4:
            flushed = fmp4Demuxer.beginDiscontinuity()
        case .mpegts:
            flushed = tsDemuxer.beginDiscontinuity()
        case .unknown:
            flushed = []
        }
        let highest = max(tsDemuxer.highestContinuousPTS, fmp4Demuxer.highestContinuousPTS)
        if highest > 0 {
            tsDemuxer.rebaseTimeline(after: highest)
            fmp4Demuxer.rebaseTimeline(after: highest)
        }
        return flushed
    }

    private func switchContainerIfNeeded(to target: SegmentContainer) -> [DemuxedSample] {
        guard target != .unknown else { return [] }
        guard activeContainer != target else { return [] }
        let previous = activeContainer
        activeContainer = target
        guard previous != .unknown else { return [] }

        let flushed: [DemuxedSample]
        let highest: Int64
        switch previous {
        case .mpegts:
            flushed = tsDemuxer.beginDiscontinuity()
            highest = max(tsDemuxer.highestContinuousPTS, fmp4Demuxer.highestContinuousPTS)
            if highest > 0 {
                fmp4Demuxer.rebaseTimeline(after: highest)
            }
        case .fmp4:
            flushed = fmp4Demuxer.beginDiscontinuity()
            highest = max(fmp4Demuxer.highestContinuousPTS, tsDemuxer.highestContinuousPTS)
            if highest > 0 {
                tsDemuxer.rebaseTimeline(after: highest)
            }
        case .unknown:
            flushed = []
        }
        return flushed
    }

    private func fetchInitSegmentData(url: URL, byteRange: TwitchByteRange?) async throws -> Data {
        if let customSegmentStreamer {
            var collected = Data()
            for try await chunk in customSegmentStreamer(url) {
                collected.append(chunk)
            }
            if let range = byteRange {
                let start = max(0, range.offset)
                let end = min(collected.count, start + range.length)
                if start <= end && start < collected.count {
                    return collected.subdata(in: start..<end)
                }
            }
            return collected
        }
        return try await streamer.fetchData(url: url, byteRange: byteRange)
    }

    private func ensureInitSegmentLoaded(url: URL, byteRange: TwitchByteRange?, gen: UInt64) async -> Bool {
        let key = InitMapCacheKey(url: url, byteRange: byteRange)
        if loadedInitMapKey == key && fmp4Demuxer.hasInitConfig {
            return true
        }

        let data: Data
        if let cached = initSegmentCache[key] {
            data = cached
        } else {
            do {
                let fetched = try await fetchInitSegmentData(url: url, byteRange: byteRange)
                guard gen == generation, !Task.isCancelled, !fetched.isEmpty else { return false }
                data = fetched
                initSegmentCache[key] = fetched
                initSegmentCacheOrder.append(key)
                if initSegmentCacheOrder.count > 16 {
                    let evicted = initSegmentCacheOrder.removeFirst()
                    initSegmentCache.removeValue(forKey: evicted)
                }
            } catch {
                return false
            }
        }

        let configured = fmp4Demuxer.loadInitSegment(data)
        if configured || fmp4Demuxer.unsupportedVideoCodec != nil {
            loadedInitMapKey = key
        }
        return configured
    }

    private func cancelOverlap() {
        let prev = overlappedFetch
        overlappedFetch = nil
        if let prev {
            Task { await prev.cancel() }
        }
    }

    private func emit(_ event: TwitchNativeEvent) {
        onEvent?(event)
    }

    private func runSession(gen: UInt64) async {
        guard let ch = channel else { return }
        do {
            let resolved = try await resolver.resolveStream(channel: ch, authToken: authToken)
            guard gen == generation, !Task.isCancelled else { return }

            let compatible = resolved.variants.filter(\.isNativeCompatible)
            guard !compatible.isEmpty else {
                failSession(gen: gen, reason: "unsupported codec")
                return
            }
            variants = resolved.variants
            let chosen = pickVariant(from: compatible, preferredID: preferredVariantID)
            selectedVariant = chosen
            emit(.streamURL(resolved.masterURL))
            emit(.variants(compatible, selectedID: chosen.id))
            await streamVariantLoop(variant: chosen, gen: gen)
        } catch TwitchHLSError.offline {
            guard gen == generation else { return }
            telemetryTask?.cancel()
            telemetryTask = nil
            loadingSince = nil
            audioSession.release(audioClaimID)
            emit(.offline)
        } catch TwitchHLSError.integrityRequired {
            failSession(gen: gen, reason: "integrity check required")
        } catch is CancellationError {
            return
        } catch {
            failSession(gen: gen, reason: "\(error)")
        }
    }

    private func pickVariant(from compatible: [TwitchVariant], preferredID: String?) -> TwitchVariant {
        if let preferredID, let exact = compatible.first(where: { $0.id == preferredID }) {
            return exact
        }
        // Default to the best video variant (source / highest bandwidth), never audio-only unless that's all there is.
        if let video = compatible.first(where: { !$0.isAudioOnly }) {
            return video
        }
        return compatible[0]
    }

    private enum RefreshResult {
        case variant(TwitchVariant)
        case offline
        case failed
    }

    private func streamVariantLoop(variant: TwitchVariant, gen: UInt64) async {
        pipeline.setMuted(isMuted)
        pipeline.setVolume(currentVolume)
        resetDemuxers(clearInitCache: false)

        var lastConsumedSeq: Int?
        var seenKeys: [String] = []
        var seenKeySet: Set<String> = []
        var playlistFailures = 0
        var segmentFailures = 0
        var consecutiveEmptySegments = 0
        var emptyCandidatePolls = 0
        var tokenRefreshes = 0
        var startupCompletedFallbackUsed = false
        var activeVariant = variant

        func markSeen(_ seg: TwitchSegment) {
            lastConsumedSeq = max(lastConsumedSeq ?? seg.sequence, seg.sequence)
            let key = seg.dedupKey
            if seenKeySet.insert(key).inserted {
                seenKeys.append(key)
                if seenKeys.count > 64 {
                    let old = seenKeys.removeFirst()
                    seenKeySet.remove(old)
                }
            }
        }

        func isUnseen(_ seg: TwitchSegment) -> Bool {
            if seenKeySet.contains(seg.dedupKey) { return false }
            if let last = lastConsumedSeq {
                return seg.sequence > last
            }
            return true
        }

        func resetSequenceStateForRefresh() {
            lastConsumedSeq = nil
            seenKeys.removeAll()
            seenKeySet.removeAll()
            emptyCandidatePolls = 0
            cancelOverlap()
            let flushed = beginActiveDiscontinuity()
            pipeline.enqueue(flushed)
        }

        while gen == generation, !Task.isCancelled {
            // 1. Poll the live media playlist.
            let playlist: TwitchMediaPlaylist
            do {
                let receivedAt = Date.now
                playlist = try await resolver.fetchMediaPlaylist(url: activeVariant.url)
                playlistFailures = 0
                if playlist.hasInitMap {
                    diagHasMap = true
                }
                if let serverTime = playlist.serverTime {
                    pipeline.updateServerClock(serverTime: serverTime, receivedAt: receivedAt)
                }
                pipeline.configure(audioOnly: activeVariant.isAudioOnly, isLowLatency: playlist.isLowLatency)
            } catch TwitchHLSError.offline {
                // Twitch Weaver variant URLs can 404 after edge reassignment or token expiry even while the
                // broadcaster is still live: re-resolve Usher once before declaring the stream offline.
                if tokenRefreshes < 3 {
                    tokenRefreshes += 1
                    switch await refreshStreamURL(preferredID: activeVariant.id, attempt: tokenRefreshes) {
                    case .variant(let refreshed):
                        activeVariant = refreshed
                        playlistFailures = 0
                        resetSequenceStateForRefresh()
                        continue
                    case .offline:
                        break
                    case .failed:
                        playlistFailures += 1
                        if playlistFailures >= 4 {
                            failSession(gen: gen, reason: "playlist unavailable")
                            return
                        }
                        try? await Task.sleep(for: .milliseconds(500))
                        continue
                    }
                }
                if gen == generation {
                    telemetryTask?.cancel()
                    telemetryTask = nil
                    loadingSince = nil
                    audioSession.release(audioClaimID)
                    emit(.offline)
                }
                return
            } catch is CancellationError {
                return
            } catch {
                playlistFailures += 1
                // Twitch playback tokens expire periodically (~20 min) or weaver reassigns: refresh before failing.
                if playlistFailures >= 2, tokenRefreshes < 3 {
                    tokenRefreshes += 1
                    if case .variant(let refreshed) = await refreshStreamURL(preferredID: activeVariant.id, attempt: tokenRefreshes) {
                        activeVariant = refreshed
                        playlistFailures = 0
                        resetSequenceStateForRefresh()
                        continue
                    }
                }
                if playlistFailures >= 4 {
                    failSession(gen: gen, reason: "playlist unavailable")
                    return
                }
                try? await Task.sleep(for: .milliseconds(500))
                continue
            }

            guard gen == generation, !Task.isCancelled else { return }
            if playlist.isEndList {
                telemetryTask?.cancel()
                telemetryTask = nil
                loadingSince = nil
                audioSession.release(audioClaimID)
                emit(.offline)
                return
            }

            let all = playlist.allSegments
            guard !all.isEmpty else {
                emptyCandidatePolls += 1
                if emptyCandidatePolls >= emptyPlaylistRefreshPolls, tokenRefreshes < 3 {
                    tokenRefreshes += 1
                    Telemetry.log(.warn, .live, "twitch.native.playlist_frozen", data: ["polls": .int(emptyCandidatePolls)])
                    if case .variant(let refreshed) = await refreshStreamURL(preferredID: activeVariant.id, attempt: tokenRefreshes) {
                        activeVariant = refreshed
                        resetSequenceStateForRefresh()
                        continue
                    }
                }
                let waitMs = startupTimeout < .seconds(2) ? 40 : 450
                try? await Task.sleep(for: .milliseconds(waitMs))
                continue
            }

            // Detect a sequence reset (e.g., stream restart or weaver reassignment).
            if let last = lastConsumedSeq, let newest = all.last?.sequence, newest < last - 10 {
                lastConsumedSeq = nil
                seenKeys.removeAll()
                seenKeySet.removeAll()
                let flushed = beginActiveDiscontinuity()
                pipeline.enqueue(flushed)
            }

            // 2. Choose the next segment(s) to consume.
            let candidates: [TwitchSegment]
            if lastConsumedSeq == nil {
                // First join: try the low-latency prefetch edge first, unless a prefetch failure already sent us
                // back to the latest completed segment (which reliably begins with SPS/PPS + IDR keyframe).
                if !startupCompletedFallbackUsed, !playlist.prefetchSegments.isEmpty {
                    candidates = playlist.prefetchSegments
                } else if let latestCompleted = playlist.segments.last {
                    candidates = [latestCompleted] + playlist.prefetchSegments
                } else {
                    candidates = Array(playlist.segments.suffix(2))
                }
            } else {
                var unseen = all.filter(isUnseen)
                // If we fell far behind the live edge (> 3 segments), skip straight to the live edge.
                if unseen.count > 3 {
                    unseen = Array(unseen.suffix(2))
                    let flushed = beginActiveDiscontinuity()
                    pipeline.enqueue(flushed)
                }
                candidates = unseen
            }

            guard !candidates.isEmpty else {
                emptyCandidatePolls += 1
                // If Weaver returns a frozen playlist whose sequence stops advancing, refresh the stream URL
                // proactively instead of waiting for buffer drain + stall recovery + startup timeout.
                if emptyCandidatePolls >= emptyPlaylistRefreshPolls, tokenRefreshes < 3 {
                    tokenRefreshes += 1
                    Telemetry.log(.warn, .live, "twitch.native.playlist_frozen", data: ["polls": .int(emptyCandidatePolls)])
                    if case .variant(let refreshed) = await refreshStreamURL(preferredID: activeVariant.id, attempt: tokenRefreshes) {
                        activeVariant = refreshed
                        resetSequenceStateForRefresh()
                        continue
                    }
                }
                // Already caught up to the latest prefetch segment; wait a short beat and poll again.
                let waitMs = startupTimeout < .seconds(2) ? 40 : (playlist.isLowLatency ? 450 : 900)
                try? await Task.sleep(for: .milliseconds(waitMs))
                continue
            }
            emptyCandidatePolls = 0

            let current = candidates[0]
            let nextSegment = candidates.count > 1 ? candidates[1] : nil

            // Start overlapping the next prefetch segment right away so handoff has zero RTT gap.
            if let nextSegment, nextSegment.isPrefetch {
                let existingSeq = overlappedFetch?.segment.sequence
                if existingSeq != nextSegment.sequence {
                    cancelOverlap()
                    let next = OverlappedSegmentFetch(segment: nextSegment)
                    await next.start(stream: activeSegmentStream())
                    overlappedFetch = next
                }
            }

            // 3. Consume `current` (reusing overlapped fetch if we already started it on the previous turn!).
            let isFirstJoin = (lastConsumedSeq == nil)
            let keyframeLimit: Duration? = (isFirstJoin && current.isPrefetch && !startupCompletedFallbackUsed)
                ? firstJoinPrefetchTimeout
                : nil
            let result = await consumeSegment(
                current,
                gen: gen,
                firstKeyframeTimeout: keyframeLimit,
                audioOnly: activeVariant.isAudioOnly
            )
            guard gen == generation, !Task.isCancelled else { return }

            if let bad = activeUnsupportedVideoCodec {
                failSession(gen: gen, reason: "unsupported codec: \(bad)")
                return
            }

            // On first join onto a prefetch segment: if the prefetch failed, timed out waiting for a keyframe,
            // or ended without a video keyframe, don't pin `lastConsumedSeq` to it — immediately fall back to the
            // latest completed segment so the decoder gets a clean IDR + SPS/PPS boundary instead of spinning.
            let missingInitialKeyframe = isFirstJoin && current.isPrefetch && !activeVariant.isAudioOnly && !result.hadKeyframe
            if isFirstJoin && current.isPrefetch && (!result.succeeded || missingInitialKeyframe) && !startupCompletedFallbackUsed {
                startupCompletedFallbackUsed = true
                cancelOverlap()
                Telemetry.log(
                    .info, .live, "twitch.native.prefetch_fallback",
                    data: ["ok": .bool(result.succeeded), "keyframe": .bool(result.hadKeyframe)]
                )
                if let fallbackSeg = playlist.segments.last {
                    let fb = await consumeSegment(fallbackSeg, gen: gen, firstKeyframeTimeout: nil, audioOnly: activeVariant.isAudioOnly)
                    guard gen == generation, !Task.isCancelled else { return }
                    if let bad = activeUnsupportedVideoCodec {
                        failSession(gen: gen, reason: "unsupported codec: \(bad)")
                        return
                    }
                    if fb.succeeded && fb.sampleCount > 0 {
                        markSeen(fallbackSeg)
                        segmentFailures = 0
                        consecutiveEmptySegments = 0
                        continue
                    }
                }
            }

            let effectiveSuccess: Bool
            if result.succeeded && result.sampleCount == 0 {
                consecutiveEmptySegments += 1
                markSeen(current)
                // 3 consecutive HTTP-200 segments with 0 decodable samples means the stream/edge is unreadable
                // (e.g. corrupt TS/fMP4, DRM/encrypted slate, or broken mux): escalate instead of spinning until timeout.
                effectiveSuccess = consecutiveEmptySegments < 3
            } else if result.succeeded {
                consecutiveEmptySegments = 0
                markSeen(current)
                segmentFailures = 0
                effectiveSuccess = true
            } else {
                effectiveSuccess = false
            }

            if !effectiveSuccess {
                segmentFailures += 1
                // Once already playing, advance past a broken segment after one failure so we don't loop on a 404.
                if !isFirstJoin {
                    markSeen(current)
                }
                if segmentFailures >= 2, tokenRefreshes < 3 {
                    tokenRefreshes += 1
                    if case .variant(let refreshed) = await refreshStreamURL(preferredID: activeVariant.id, attempt: tokenRefreshes) {
                        activeVariant = refreshed
                        segmentFailures = 0
                        consecutiveEmptySegments = 0
                        resetSequenceStateForRefresh()
                        continue
                    }
                }
                if segmentFailures >= 4 {
                    failSession(gen: gen, reason: "segment fetch failed")
                    return
                }
                try? await Task.sleep(for: .milliseconds(350))
            }
        }
    }

    private func refreshStreamURL(preferredID: String, attempt: Int) async -> RefreshResult {
        guard let ch = channel else { return .failed }
        Telemetry.log(.info, .live, "twitch.native.token_refresh", data: ["attempt": .int(attempt)])
        do {
            let refreshed = try await resolver.resolveStream(channel: ch, authToken: authToken)
            let compat = refreshed.variants.filter(\.isNativeCompatible)
            guard !compat.isEmpty else { return .failed }
            variants = refreshed.variants
            let chosen = pickVariant(from: compat, preferredID: preferredID)
            selectedVariant = chosen
            emit(.streamURL(refreshed.masterURL))
            return .variant(chosen)
        } catch TwitchHLSError.offline {
            return .offline
        } catch {
            return .failed
        }
    }

    /// Streams one segment chunk-by-chunk into `MPEGTSDemuxer` or `FMP4Demuxer` and `SampleBufferPipeline`.
    private func consumeSegment(
        _ segment: TwitchSegment,
        gen: UInt64,
        firstKeyframeTimeout: Duration?,
        audioOnly: Bool
    ) async -> SegmentConsumeResult {
        diagSegments += 1
        if segment.isDiscontinuity {
            let flushed = beginActiveDiscontinuity()
            if !flushed.isEmpty { onSamples?(flushed) }
            pipeline.enqueue(flushed)
        }
        pipeline.beginSegment(programDateTime: segment.programDateTime)

        var totalSamples = 0
        var hadKeyframe = false

        func record(_ samples: [DemuxedSample]) {
            guard !samples.isEmpty else { return }
            totalSamples += samples.count
            diagSamples += samples.count
            for s in samples {
                if case .video(let v) = s, v.isKeyframe {
                    hadKeyframe = true
                    diagKeyframes += 1
                }
            }
            if !samples.isEmpty { onSamples?(samples) }
            pipeline.enqueue(samples)
        }

        // Claim any matching overlapped fetch early so we always cancel it on init-segment failure.
        var activeFetch: OverlappedSegmentFetch?
        if let overlap = overlappedFetch, overlap.segment.sequence == segment.sequence {
            overlappedFetch = nil
            activeFetch = overlap
        }

        var resolvedContainer: SegmentContainer = .unknown
        var sniffBuffer = Data()

        if let mapURL = segment.initMapURL {
            diagHasMap = true
            let loaded = await ensureInitSegmentLoaded(url: mapURL, byteRange: segment.initMapByteRange, gen: gen)
            if gen != generation || Task.isCancelled || fmp4Demuxer.unsupportedVideoCodec != nil || !loaded {
                if let activeFetch { await activeFetch.cancel() }
                return SegmentConsumeResult(succeeded: false, sampleCount: 0, hadKeyframe: false)
            }
            let switched = switchContainerIfNeeded(to: .fmp4)
            record(switched)
            resolvedContainer = .fmp4
        }

        func pushChunk(_ chunk: Data) -> [DemuxedSample] {
            guard !chunk.isEmpty else { return [] }
            if resolvedContainer == .unknown {
                sniffBuffer.append(chunk)
                if sniffBuffer.first == 0x47 {
                    resolvedContainer = .mpegts
                } else if sniffBuffer.count >= 8 {
                    resolvedContainer = FMP4Demuxer.isLikelyFMP4(sniffBuffer) ? .fmp4 : .mpegts
                } else {
                    return []
                }
                let switched = switchContainerIfNeeded(to: resolvedContainer)
                let buffered = sniffBuffer
                sniffBuffer.removeAll(keepingCapacity: false)
                let pushed: [DemuxedSample] = (resolvedContainer == .fmp4)
                    ? fmp4Demuxer.push(buffered)
                    : tsDemuxer.push(buffered)
                return switched.isEmpty ? pushed : (switched + pushed)
            }
            return (resolvedContainer == .fmp4)
                ? fmp4Demuxer.push(chunk)
                : tsDemuxer.push(chunk)
        }

        func flushActiveSegment() -> [DemuxedSample] {
            var out: [DemuxedSample] = []
            if resolvedContainer == .unknown, !sniffBuffer.isEmpty {
                resolvedContainer = (activeContainer == .fmp4) ? .fmp4 : .mpegts
                out.append(contentsOf: switchContainerIfNeeded(to: resolvedContainer))
                let buffered = sniffBuffer
                sniffBuffer.removeAll(keepingCapacity: false)
                out.append(contentsOf: resolvedContainer == .fmp4 ? fmp4Demuxer.push(buffered) : tsDemuxer.push(buffered))
            }
            switch resolvedContainer {
            case .fmp4:
                out.append(contentsOf: fmp4Demuxer.flushSegment())
            case .mpegts:
                out.append(contentsOf: tsDemuxer.flushSegment())
            case .unknown:
                break
            }
            return out
        }

        // Wrap in an OverlappedSegmentFetch when `firstKeyframeTimeout` is active so a stalled first-join prefetch aborts cleanly on deadline.
        if activeFetch == nil, firstKeyframeTimeout != nil {
            let fetch = OverlappedSegmentFetch(segment: segment)
            await fetch.start(stream: activeSegmentStream())
            activeFetch = fetch
        }

        if let fetch = activeFetch {
            var timeoutTask: Task<Void, Never>?
            if let limit = firstKeyframeTimeout {
                timeoutTask = Task {
                    try? await Task.sleep(for: limit)
                    guard !Task.isCancelled else { return }
                    await fetch.cancel()
                }
            }
            defer { timeoutTask?.cancel() }

            do {
                while gen == generation, !Task.isCancelled {
                    guard let chunk = try await fetch.nextChunk() else { break }
                    let samples = pushChunk(chunk)
                    if activeUnsupportedVideoCodec != nil {
                        await fetch.cancel()
                        return SegmentConsumeResult(succeeded: false, sampleCount: totalSamples, hadKeyframe: hadKeyframe)
                    }
                    record(samples)
                    if timeoutTask != nil, (hadKeyframe || (audioOnly && totalSamples > 0)) {
                        timeoutTask?.cancel()
                        timeoutTask = nil
                    }
                }
                if gen != generation || Task.isCancelled {
                    await fetch.cancel()
                    return SegmentConsumeResult(succeeded: false, sampleCount: totalSamples, hadKeyframe: hadKeyframe)
                }
                let tail = flushActiveSegment()
                record(tail)
                return SegmentConsumeResult(succeeded: true, sampleCount: totalSamples, hadKeyframe: hadKeyframe)
            } catch {
                await fetch.cancel()
                _ = beginActiveDiscontinuity()
                return SegmentConsumeResult(succeeded: false, sampleCount: totalSamples, hadKeyframe: hadKeyframe)
            }
        }

        // Otherwise open a direct chunked stream now.
        let streamFn = activeSegmentStream()
        do {
            for try await chunk in streamFn(segment.url) {
                guard gen == generation, !Task.isCancelled else {
                    return SegmentConsumeResult(succeeded: false, sampleCount: totalSamples, hadKeyframe: hadKeyframe)
                }
                let samples = pushChunk(chunk)
                if activeUnsupportedVideoCodec != nil {
                    return SegmentConsumeResult(succeeded: false, sampleCount: totalSamples, hadKeyframe: hadKeyframe)
                }
                record(samples)
            }
            let tail = flushActiveSegment()
            record(tail)
            return SegmentConsumeResult(succeeded: true, sampleCount: totalSamples, hadKeyframe: hadKeyframe)
        } catch {
            _ = beginActiveDiscontinuity()
            return SegmentConsumeResult(succeeded: false, sampleCount: totalSamples, hadKeyframe: hadKeyframe)
        }
    }

    private func pollTelemetry(gen: UInt64) async {
        guard gen == generation else { return }
        let stats = await pipeline.tickTelemetry()
        guard gen == generation else { return }

        if stats.isClockStarted {
            loadingSince = nil
        } else if !userPaused, !isInterrupted, let since = loadingSince, ContinuousClock.now - since >= startupTimeout {
            Telemetry.log(.warn, .live, "twitch.native.startup_timeout", data: diagnosticData(reason: "startup timeout"))
            failSession(gen: gen, reason: "startup timeout")
            return
        }

        if stats.isStalled, !userPaused, !isInterrupted {
            stallRecoveries += 1
            Telemetry.log(.warn, .live, "twitch.native.stall_recovery", data: ["attempt": .int(stallRecoveries)])
            if stallRecoveries <= 2 {
                // Re-resolve fresh GQL/Usher URLs on stall recovery so a dead/frozen Weaver edge isn't reused.
                jumpToLive(refreshStream: true)
            } else {
                failSession(gen: gen, reason: "playback stalled")
            }
            return
        }

        emit(.stats(stats))
    }
}
