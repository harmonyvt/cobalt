@preconcurrency import AVFoundation
import CoreGraphics
import CoreMedia
import Foundation
import ImageIO
import UniformTypeIdentifiers

// Off-main rolling 60-second H.264/AAC ring buffer + continuous passthrough recorder + synchronized chat recorder.
//
// Hooks directly into `TwitchNativeEngine.setSampleTap(_:)` so zero re-encoding happens during live watch,
// instant 30s/60s clips flush to MP4 in milliseconds, and continuous recordings stream straight to disk.

public enum TwitchClipRecorderError: Error, Sendable, Equatable {
    case noBufferedVideo
    case alreadyRecording
    case alreadySaving
    case notRecording
    case missingFormatDescription
    case writerFailed(String)
}

public actor TwitchClipRecorder {
    public static let maxRollingSeconds: Double = 60.0
    /// Reduced rolling buffer duration in Low Power Mode to cut memory & Jetsam risk while idle.
    public static let lowPowerRollingSeconds: Double = 20.0
    /// Keep slightly more than 60 s in memory so trimming on IDR keyframe boundaries always leaves >= 60 s available.
    private static let trimHighWaterSeconds: Double = 66.0
    private static let lowPowerTrimHighWaterSeconds: Double = 24.0
    /// Studio Editor's maximum clip duration (10 minutes).
    public static let maxRecordingSeconds: Double = 600.0
    private static let timescale90k: Double = Double(MPEGTSDemuxer.timescale)

    private struct BufferedVideo {
        let frame: DemuxedVideoFrame
        let wallTime: Date
    }

    private struct BufferedAudio {
        let frame: DemuxedAudioFrame
        let wallTime: Date
    }

    private struct BufferedChat {
        var line: TwitchChatLine
        var paint: SevenTvPaint?
        var sevenTvBadge: ChatBadge?
        /// Approximate stream wall time (adjusted by live stream delay so chat aligns with video frames).
        let anchoredTime: Date
    }

    private struct ChatGapInterval {
        let start: Date
        var end: Date?
    }

    private struct ActiveRecording {
        let id: String
        let channel: String
        let destinationDir: URL
        let videoFileName: String
        let videoURL: URL
        let chatFileName: String
        let thumbnailFileName: String
        let startedAt: Date
        var videoFrames: [BufferedVideo] = []
        var audioFrames: [BufferedAudio] = []
        var startPTS90k: Int64?
        var latestPTS90k: Int64?
        var firstWallTime: Date?
    }

    private var channel: String?
    private var videoRing: [BufferedVideo] = []
    private var audioRing: [BufferedAudio] = []
    private var latestSPS: Data?
    private var latestPPS: Data?
    private var lastDelaySeconds: Double = 0
    private var lowPowerMode = false

    // Chat rolling buffer & disconnect gap tracker
    private var chatRing: [BufferedChat] = []
    private var seenChatIDs: Set<String> = []
    private var chatGaps: [ChatGapInterval] = []
    private var chatWasConnected = false
    private var activeGapIndex: Int?
    private var lastBackfillCosmeticCounts: (Int, Int) = (0, 0)

    // Continuous recording session (when user taps Record)
    private var recording: ActiveRecording?
    private var isSaving = false
    private var savingKind: TwitchClipKind?

    // Ordered FIFO sample ingestion stream (avoids out-of-order Task-per-chunk delivery)
    private let sampleContinuation: AsyncStream<([DemuxedSample], Date)>.Continuation

    // Throttled state publisher
    public nonisolated let states: AsyncStream<TwitchClipCaptureState>
    private let stateContinuation: AsyncStream<TwitchClipCaptureState>.Continuation
    private var lastPublishTime: Date = .distantPast
    private var lastPublishedState: TwitchClipCaptureState?

    private var effectiveMaxRollingSeconds: Double {
        lowPowerMode ? Self.lowPowerRollingSeconds : Self.maxRollingSeconds
    }

    private var effectiveTrimHighWaterSeconds: Double {
        lowPowerMode ? Self.lowPowerTrimHighWaterSeconds : Self.trimHighWaterSeconds
    }

    public init() {
        (states, stateContinuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(1))
        let (sampleStream, sampleCont) = AsyncStream.makeStream(
            of: ([DemuxedSample], Date).self,
            bufferingPolicy: .bufferingNewest(600)
        )
        self.sampleContinuation = sampleCont
        Task { [weak self] in
            for await (samples, wall) in sampleStream {
                guard let self else { break }
                await self.ingestSamples(samples, now: wall)
            }
        }
    }

    deinit {
        sampleContinuation.finish()
        stateContinuation.finish()
    }

    /// Synchronously enqueues demuxed samples onto the recorder's FIFO stream without spawning per-chunk Tasks.
    public nonisolated func enqueueSamples(_ samples: [DemuxedSample], now: Date = Date()) {
        guard !samples.isEmpty else { return }
        sampleContinuation.yield((samples, now))
    }

    // MARK: - Session & Input Feeding

    /// Shrinks the idle rolling ring buffer in Low Power Mode without ever interrupting an active recording.
    public func setLowPowerMode(_ enabled: Bool) {
        guard lowPowerMode != enabled else { return }
        lowPowerMode = enabled
        if enabled && recording == nil {
            trimRollingBuffers()
        }
        publishState(force: true)
    }

    /// Resets the rolling buffer for a new channel (cancelling any in-flight recording cleanly).
    public func reset(for channel: String?) {
        let clean = channel?.lowercased()
        guard clean != self.channel else { return }
        self.channel = clean
        videoRing.removeAll(keepingCapacity: false)
        audioRing.removeAll(keepingCapacity: false)
        chatRing.removeAll(keepingCapacity: false)
        seenChatIDs.removeAll(keepingCapacity: false)
        chatGaps.removeAll(keepingCapacity: false)
        chatWasConnected = false
        activeGapIndex = nil
        lastBackfillCosmeticCounts = (0, 0)
        latestSPS = nil
        latestPPS = nil
        recording = nil
        isSaving = false
        savingKind = nil
        lastPublishedState = nil
        publishState(force: true)
    }

    /// Updates the latest estimated live broadcast delay so incoming chat timestamps align cleanly with video frames.
    public func updateStreamDelay(_ delay: Double?) {
        if let delay, delay.isFinite, delay >= 0, delay <= 60 {
            lastDelaySeconds = delay
        }
    }

    /// Feeds demuxed H.264/AAC samples directly from `TwitchNativeEngine`.
    public func ingestSamples(_ samples: [DemuxedSample], now: Date = Date()) {
        guard !samples.isEmpty else { return }
        for sample in samples {
            switch sample {
            case .video(let frame):
                if let sps = frame.sps { latestSPS = sps }
                if let pps = frame.pps { latestPPS = pps }
                let resolved = DemuxedVideoFrame(
                    avccData: frame.avccData,
                    pts90k: frame.pts90k,
                    dts90k: frame.dts90k,
                    isKeyframe: frame.isKeyframe,
                    sps: frame.sps ?? latestSPS,
                    pps: frame.pps ?? latestPPS
                )
                let item = BufferedVideo(frame: resolved, wallTime: now)
                videoRing.append(item)
                appendToActiveRecording(video: item)

            case .audio(let frame):
                let item = BufferedAudio(frame: frame, wallTime: now)
                audioRing.append(item)
                appendToActiveRecording(audio: item)
            }
        }
        trimRollingBuffers()
        publishState(force: false, now: now)
    }

    /// Feeds live `TwitchChatSnapshot` updates (tracking new messages, late-loaded 7TV emote/paint/badge backfills,
    /// moderator deletions, and chat reconnect gaps).
    public func ingestChatSnapshot(_ snapshot: TwitchChatSnapshot, now: Date = Date()) {
        guard let ch = channel, snapshot.channel.lowercased() == ch else { return }

        // Track chat disconnects as gaps so drafts can warn the owner where chat dropped while video stayed whole.
        switch snapshot.status {
        case .joined:
            chatWasConnected = true
            if let idx = activeGapIndex, idx < chatGaps.count {
                chatGaps[idx].end = now
                activeGapIndex = nil
            }
        case .reconnecting, .failed, .connecting:
            if chatWasConnected, activeGapIndex == nil {
                chatGaps.append(ChatGapInterval(start: now, end: nil))
                activeGapIndex = chatGaps.count - 1
            }
        case .idle:
            break
        }

        // Capture unseen messages and update already-seen lines in place when 7TV emotes/paints/badges backfill
        // or a moderator deletes a line.
        let cutoff = now.addingTimeInterval(-(Self.maxRecordingSeconds + 120))
        var ringIndexByID: [String: Int] = [:]
        ringIndexByID.reserveCapacity(chatRing.count)
        for (idx, item) in chatRing.enumerated() {
            ringIndexByID[item.line.id] = idx
        }

        var deletedIDs: Set<String> = []
        for line in snapshot.lines {
            let loginKey = line.login.lowercased()
            let paint = snapshot.paints[loginKey]
            let sevenTvBadge = snapshot.sevenTvBadges[loginKey]

            if seenChatIDs.contains(line.id) {
                if let idx = ringIndexByID[line.id] {
                    if line.deleted {
                        deletedIDs.insert(line.id)
                    } else {
                        chatRing[idx].line = line
                        if let paint { chatRing[idx].paint = paint }
                        if let sevenTvBadge { chatRing[idx].sevenTvBadge = sevenTvBadge }
                    }
                }
                continue
            }

            seenChatIDs.insert(line.id)
            if case .system = line.kind { continue }
            guard !line.deleted else { continue }
            // Ignore old Robotty recent-messages history fetched before watching started.
            if line.timestamp < now.addingTimeInterval(-90) { continue }
            // Chat messages arrive live over IRC while video lags by `lastDelaySeconds`.
            // Anchor chat to the moment it arrived on stream clock (`now`) so playback syncs cleanly.
            let anchor = max(cutoff, line.timestamp)
            ringIndexByID[line.id] = chatRing.count
            chatRing.append(BufferedChat(line: line, paint: paint, sevenTvBadge: sevenTvBadge, anchoredTime: anchor))
        }

        if !deletedIDs.isEmpty {
            chatRing.removeAll { deletedIDs.contains($0.line.id) }
        }

        // Backfill late-arriving 7TV paints/badges only when new cosmetics arrived since the previous backfill pass.
        let cosmeticCounts = (snapshot.paints.count, snapshot.sevenTvBadges.count)
        if cosmeticCounts != lastBackfillCosmeticCounts && (!snapshot.paints.isEmpty || !snapshot.sevenTvBadges.isEmpty) {
            lastBackfillCosmeticCounts = cosmeticCounts
            for idx in chatRing.indices {
                if chatRing[idx].paint != nil && chatRing[idx].sevenTvBadge != nil { continue }
                let loginKey = chatRing[idx].line.login.lowercased()
                if chatRing[idx].paint == nil, let paint = snapshot.paints[loginKey] {
                    chatRing[idx].paint = paint
                }
                if chatRing[idx].sevenTvBadge == nil, let badge = snapshot.sevenTvBadges[loginKey] {
                    chatRing[idx].sevenTvBadge = badge
                }
            }
        }

        // Keep chat ring bounded (at least 120 s when idle, or full recording span when recording).
        let retainCutoff: Date
        if let rec = recording {
            retainCutoff = rec.startedAt.addingTimeInterval(-30)
        } else {
            retainCutoff = now.addingTimeInterval(-120)
        }
        if chatRing.count > 1200 {
            chatRing.removeAll { $0.anchoredTime < retainCutoff }
        }
        if chatGaps.count > 40 {
            chatGaps.removeAll { ($0.end ?? now) < retainCutoff }
            activeGapIndex = chatGaps.lastIndex { $0.end == nil }
        }
        publishState(force: false, now: now)
    }

    // MARK: - Rolling Buffer Queries

    /// Current buffered span in seconds (from first IDR keyframe to latest video frame, capped at `effectiveMaxRollingSeconds`).
    public func bufferedSeconds() -> Double {
        guard let firstIDR = videoRing.first(where: { $0.frame.isKeyframe }),
              let last = videoRing.last else { return 0 }
        let span = Double(last.frame.pts90k - firstIDR.frame.pts90k) / Self.timescale90k
        guard span.isFinite, span > 0 else { return 0 }
        return min(effectiveMaxRollingSeconds, span)
    }

    public func currentState(now: Date = Date()) -> TwitchClipCaptureState {
        let recSeconds: Double
        let recChatCount: Int
        if let rec = recording {
            if let s = rec.startPTS90k, let e = rec.latestPTS90k, e > s {
                recSeconds = Double(e - s) / Self.timescale90k
            } else {
                recSeconds = max(0, now.timeIntervalSince(rec.startedAt))
            }
            let startWall = rec.firstWallTime ?? rec.startedAt
            recChatCount = chatRing.count(where: { $0.anchoredTime >= startWall })
        } else {
            recSeconds = 0
            recChatCount = 0
        }
        return TwitchClipCaptureState(
            channel: channel,
            bufferedSeconds: floor(bufferedSeconds()),
            maxBufferSeconds: effectiveMaxRollingSeconds,
            isRecording: recording != nil,
            recordingSeconds: floor(recSeconds),
            recordingChatCount: recChatCount,
            isSaving: isSaving,
            savingKind: savingKind
        )
    }

    // MARK: - Instant Clip (Last 30s / 60s)

    /// Flushes the last `requestedSeconds` (e.g. 30 or 60) from the rolling buffer into a passthrough MP4 + `.chat.json` draft.
    public func saveInstantClip(
        requestedSeconds: Double,
        channel: String,
        title: String? = nil,
        destinationDir: URL,
        now: Date = Date()
    ) async throws -> TwitchClipSaveResult {
        guard !isSaving else {
            throw TwitchClipRecorderError.alreadySaving
        }
        guard let lastVideo = videoRing.last else {
            throw TwitchClipRecorderError.noBufferedVideo
        }
        let targetTicks = Int64(max(1, min(effectiveMaxRollingSeconds, requestedSeconds)) * Self.timescale90k)
        let targetStartPTS = lastVideo.frame.pts90k - targetTicks

        // Pick the IDR keyframe closest to (and at or before) targetStartPTS, falling back to the earliest IDR in the ring.
        let idrIndices = videoRing.indices.filter { videoRing[$0].frame.isKeyframe }
        guard let firstIDRIdx = idrIndices.first else {
            throw TwitchClipRecorderError.noBufferedVideo
        }
        let chosenStartIdx = idrIndices.last(where: { videoRing[$0].frame.pts90k <= targetStartPTS }) ?? firstIDRIdx
        let sliceVideo = Array(videoRing[chosenStartIdx...])
        guard sliceVideo.count >= 2 else {
            throw TwitchClipRecorderError.noBufferedVideo
        }

        let startBase = min(sliceVideo[0].frame.dts90k, sliceVideo[0].frame.pts90k)
        let endPTS = sliceVideo[sliceVideo.count - 1].frame.pts90k
        let actualDuration = max(0.5, Double(endPTS - sliceVideo[0].frame.pts90k) / Self.timescale90k)
        let wasPartial = actualDuration < requestedSeconds - 1.5

        let sliceAudio = audioRing.filter { $0.frame.pts90k >= startBase && $0.frame.pts90k <= endPTS }
        let startWall = sliceVideo[0].wallTime
        let endWall = sliceVideo[sliceVideo.count - 1].wallTime

        isSaving = true
        savingKind = .clip
        publishState(force: true, now: now)
        defer {
            isSaving = false
            savingKind = nil
            publishState(force: true, now: Date())
        }

        let draft = try await writeDraftFiles(
            kind: .clip,
            channel: channel.lowercased(),
            title: title,
            videoFrames: sliceVideo,
            audioFrames: sliceAudio,
            startPTS90k: startBase,
            duration: actualDuration,
            startWall: startWall,
            endWall: endWall,
            destinationDir: destinationDir,
            now: now
        )
        return TwitchClipSaveResult(draft: draft, wasPartialBuffer: wasPartial, requestedSeconds: requestedSeconds)
    }

    // MARK: - Continuous Recording (+ Chat)

    /// Begins recording incoming video, audio, and chat until `stopRecording` is called.
    public func startRecording(channel: String, destinationDir: URL, now: Date = Date()) throws {
        guard !isSaving else { throw TwitchClipRecorderError.alreadySaving }
        guard recording == nil else { throw TwitchClipRecorderError.alreadyRecording }
        let id = Self.mintDraftID()
        var rec = ActiveRecording(
            id: id,
            channel: channel.lowercased(),
            destinationDir: destinationDir,
            videoFileName: "\(id).mp4",
            videoURL: destinationDir.appendingPathComponent("\(id).mp4"),
            chatFileName: "\(id).chat.json",
            thumbnailFileName: "\(id).jpg",
            startedAt: now
        )

        // Seed from the most recent IDR keyframe in the rolling buffer (within 4.5s, covering both 2s and 4s GOPs)
        // so recording starts cleanly with zero waiting and zero black frames!
        if let lastIDRIdx = videoRing.lastIndex(where: { $0.frame.isKeyframe }),
           let lastFrame = videoRing.last,
           Double(lastFrame.frame.pts90k - videoRing[lastIDRIdx].frame.pts90k) / Self.timescale90k <= 4.5 {
            let seedVideo = Array(videoRing[lastIDRIdx...])
            let seedStartBase = min(seedVideo[0].frame.dts90k, seedVideo[0].frame.pts90k)
            let seedAudio = audioRing.filter { $0.frame.pts90k >= seedStartBase }
            rec.videoFrames = seedVideo
            rec.audioFrames = seedAudio
            rec.startPTS90k = seedStartBase
            rec.latestPTS90k = seedVideo.last?.frame.pts90k
            rec.firstWallTime = seedVideo[0].wallTime
        }

        recording = rec
        publishState(force: true, now: now)
    }

    /// Stops an active continuous recording and flushes the captured MP4 + `.chat.json` + thumbnail to disk.
    public func stopRecording(title: String? = nil, now: Date = Date()) async throws -> TwitchClipSaveResult {
        guard !isSaving else { throw TwitchClipRecorderError.alreadySaving }
        guard let rec = recording else { throw TwitchClipRecorderError.notRecording }
        recording = nil

        guard rec.videoFrames.count >= 2, let startPTS = rec.startPTS90k, let endPTS = rec.latestPTS90k else {
            publishState(force: true, now: now)
            throw TwitchClipRecorderError.noBufferedVideo
        }

        let actualDuration = max(0.5, Double(endPTS - startPTS) / Self.timescale90k)
        let startWall = rec.firstWallTime ?? rec.startedAt
        let endWall = rec.videoFrames.last?.wallTime ?? now

        isSaving = true
        savingKind = .recording
        publishState(force: true, now: now)
        defer {
            isSaving = false
            savingKind = nil
            publishState(force: true, now: Date())
        }

        let draft = try await writeDraftFiles(
            idOverride: rec.id,
            kind: .recording,
            channel: rec.channel,
            title: title,
            videoFrames: rec.videoFrames,
            audioFrames: rec.audioFrames,
            startPTS90k: startPTS,
            duration: actualDuration,
            startWall: startWall,
            endWall: endWall,
            destinationDir: rec.destinationDir,
            now: now
        )
        return TwitchClipSaveResult(draft: draft, wasPartialBuffer: false, requestedSeconds: nil)
    }

    /// Cancels an active recording without writing a draft.
    public func cancelRecording() {
        recording = nil
        publishState(force: true)
    }

    // MARK: - Private Helpers

    private func appendToActiveRecording(video item: BufferedVideo) {
        guard var rec = recording else { return }
        if rec.startPTS90k == nil {
            guard item.frame.isKeyframe else { return }
            rec.startPTS90k = min(item.frame.dts90k, item.frame.pts90k)
            rec.firstWallTime = item.wallTime
        }
        guard let startPTS = rec.startPTS90k else { return }
        let elapsed = Double(item.frame.pts90k - startPTS) / Self.timescale90k
        if elapsed > Self.maxRecordingSeconds {
            recording = rec
            return
        }
        rec.videoFrames.append(item)
        rec.latestPTS90k = item.frame.pts90k
        recording = rec
    }

    private func appendToActiveRecording(audio item: BufferedAudio) {
        guard var rec = recording, let startPTS = rec.startPTS90k else { return }
        guard item.frame.pts90k >= startPTS else { return }
        let elapsed = Double(item.frame.pts90k - startPTS) / Self.timescale90k
        if elapsed <= Self.maxRecordingSeconds {
            rec.audioFrames.append(item)
            recording = rec
        }
    }

    private func trimRollingBuffers() {
        guard let last = videoRing.last else { return }
        let keepFromPTS = last.frame.pts90k - Int64(effectiveTrimHighWaterSeconds * Self.timescale90k)
        // Find the latest IDR keyframe at or before keepFromPTS so the rolling ring always begins on a clean IDR.
        if let trimIdx = videoRing.lastIndex(where: { $0.frame.isKeyframe && $0.frame.pts90k <= keepFromPTS }), trimIdx > 0 {
            let newStartPTS = videoRing[trimIdx].frame.pts90k
            videoRing.removeFirst(trimIdx)
            audioRing.removeAll { $0.frame.pts90k < newStartPTS }
        }
    }

    private func publishState(force: Bool, now: Date = Date()) {
        if !force && now.timeIntervalSince(lastPublishTime) < 1.0 { return }
        let next = currentState(now: now)
        if !force, next == lastPublishedState { return }
        lastPublishTime = now
        lastPublishedState = next
        stateContinuation.yield(next)
    }

    private func writeDraftFiles(
        idOverride: String? = nil,
        kind: TwitchClipKind,
        channel: String,
        title: String?,
        videoFrames: [BufferedVideo],
        audioFrames: [BufferedAudio],
        startPTS90k: Int64,
        duration: Double,
        startWall: Date,
        endWall: Date,
        destinationDir: URL,
        now: Date
    ) async throws -> TwitchClipDraft {
        let fm = FileManager.default
        try fm.createDirectory(at: destinationDir, withIntermediateDirectories: true)

        let id = idOverride ?? Self.mintDraftID()
        let videoFileName = "\(id).mp4"
        let chatFileName = "\(id).chat.json"
        let thumbFileName = "\(id).jpg"
        let videoURL = destinationDir.appendingPathComponent(videoFileName)
        let chatURL = destinationDir.appendingPathComponent(chatFileName)
        let thumbURL = destinationDir.appendingPathComponent(thumbFileName)

        // 1. Write passthrough MP4 (zero re-encoding!)
        let dimensions = try await Self.writePassthroughMP4(
            videoFrames: videoFrames.map(\.frame),
            audioFrames: audioFrames.map(\.frame),
            basePTS90k: startPTS90k,
            to: videoURL
        )

        // 2. Build time-synced chat log & disconnect gaps for [startWall, endWall]
        let spanWall = max(0.001, endWall.timeIntervalSince(startWall))
        let scaleToMedia = duration / spanWall
        var entries: [RecordedChatEntry] = []
        for item in chatRing where item.anchoredTime >= startWall && item.anchoredTime <= endWall.addingTimeInterval(0.5) {
            let rel = max(0, min(duration, item.anchoredTime.timeIntervalSince(startWall) * scaleToMedia))
            if let entry = RecordedChatEntry(
                line: item.line,
                clipRelativeSeconds: rel,
                paint: item.paint,
                sevenTvBadge: item.sevenTvBadge
            ) {
                entries.append(entry)
            }
        }

        var gaps: [RecordedChatGap] = []
        for g in chatGaps {
            let gStart = max(startWall, g.start)
            let gEnd = min(endWall, g.end ?? endWall)
            guard gEnd > gStart else { continue }
            let relStart = max(0, min(duration, gStart.timeIntervalSince(startWall) * scaleToMedia))
            let relEnd = max(relStart, min(duration, gEnd.timeIntervalSince(startWall) * scaleToMedia))
            if relEnd - relStart >= 1.0 {
                gaps.append(RecordedChatGap(start: relStart, end: relEnd))
            }
        }

        let chatLog = RecordedChatLog(channel: channel, duration: duration, entries: entries, gaps: gaps)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let chatData = try encoder.encode(chatLog)
        try chatData.write(to: chatURL, options: .atomic)

        // 3. Extract thumbnail JPEG off main (best-effort)
        let wroteThumb = await Self.generateThumbnail(videoURL: videoURL, to: thumbURL, duration: duration)

        let cleanTitle = (title?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 }
            ?? Self.defaultTitle(channel: channel, kind: kind, duration: duration)

        return TwitchClipDraft(
            id: id,
            channel: channel,
            title: cleanTitle,
            kind: kind,
            createdAt: now,
            updatedAt: now,
            duration: (duration * 1000).rounded() / 1000,
            width: dimensions.w,
            height: dimensions.h,
            videoFileName: videoFileName,
            chatFileName: chatFileName,
            thumbnailFileName: wroteThumb ? thumbFileName : nil,
            chatLineCount: entries.count,
            chatGaps: gaps,
            density: chatLog.densityBuckets(maxBuckets: 48),
            isFresh: true
        )
    }

    /// Writes compressed AVCC H.264 + AAC frames into a standard `.mp4` container using `AVAssetWriter` passthrough.
    /// Zero re-encoding: runs in a few milliseconds even for 60s of 1080p60 video.
    public static func writePassthroughMP4(
        videoFrames: [DemuxedVideoFrame],
        audioFrames: [DemuxedAudioFrame],
        basePTS90k: Int64,
        to url: URL
    ) async throws -> PixelSize {
        guard let firstWithParamSets = videoFrames.first(where: { $0.sps != nil && $0.pps != nil }),
              let sps = firstWithParamSets.sps,
              let pps = firstWithParamSets.pps,
              let videoFormat = TwitchSampleBufferFactory.videoFormatDescription(sps: sps, pps: pps)
        else {
            throw TwitchClipRecorderError.missingFormatDescription
        }

        let dims = CMVideoFormatDescriptionGetDimensions(videoFormat)
        let size = PixelSize(w: max(2, Int(dims.width)), h: max(2, Int(dims.height)))

        let fm = FileManager.default
        if fm.fileExists(atPath: url.path) {
            try? fm.removeItem(at: url)
        }

        let writer: AVAssetWriter
        do {
            writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        } catch {
            throw TwitchClipRecorderError.writerFailed(error.localizedDescription)
        }
        writer.shouldOptimizeForNetworkUse = true

        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: nil, sourceFormatHint: videoFormat)
        videoInput.expectsMediaDataInRealTime = false
        guard writer.canAdd(videoInput) else {
            throw TwitchClipRecorderError.writerFailed("cannot add passthrough video track")
        }
        writer.add(videoInput)

        guard let firstKeyIdx = videoFrames.firstIndex(where: { $0.isKeyframe }) else {
            throw TwitchClipRecorderError.noBufferedVideo
        }
        let effectiveBase90k = min(
            basePTS90k,
            min(videoFrames[firstKeyIdx].dts90k, videoFrames[firstKeyIdx].pts90k)
        )

        // Pre-normalize monotonic rebased video frames (preserving B-frame PTS >= DTS offsets).
        struct NormalizedVideo {
            let avccData: Data
            let pts90k: Int64
            let dts90k: Int64
            let isKeyframe: Bool
            let sps: Data?
            let pps: Data?
        }
        var preparedVideo: [NormalizedVideo] = []
        preparedVideo.reserveCapacity(videoFrames.count - firstKeyIdx)
        var lastDTS: Int64 = Int64.min
        for raw in videoFrames[firstKeyIdx...] {
            let rebasedPTS = raw.pts90k - effectiveBase90k
            var rebasedDTS = raw.dts90k - effectiveBase90k
            if rebasedPTS < 0 { continue }
            if rebasedDTS < 0 { rebasedDTS = max(0, rebasedPTS) }
            if rebasedDTS <= lastDTS {
                rebasedDTS = lastDTS + 1
            }
            let safePTS = max(rebasedPTS, rebasedDTS)
            preparedVideo.append(NormalizedVideo(
                avccData: raw.avccData,
                pts90k: safePTS,
                dts90k: rebasedDTS,
                isKeyframe: raw.isKeyframe,
                sps: raw.sps,
                pps: raw.pps
            ))
            lastDTS = rebasedDTS
        }
        guard !preparedVideo.isEmpty else {
            throw TwitchClipRecorderError.noBufferedVideo
        }

        // Pre-normalize monotonic rebased audio frames.
        var preparedAudio: [DemuxedAudioFrame] = []
        preparedAudio.reserveCapacity(audioFrames.count)
        var lastAudioPTS: Int64 = Int64.min
        for raw in audioFrames {
            let rebasedPTS = raw.pts90k - effectiveBase90k
            guard rebasedPTS >= 0, rebasedPTS > lastAudioPTS, !raw.aacData.isEmpty else { continue }
            preparedAudio.append(DemuxedAudioFrame(
                aacData: raw.aacData,
                pts90k: rebasedPTS,
                sampleRate: raw.sampleRate,
                channels: raw.channels,
                audioObjectType: raw.audioObjectType,
                audioSpecificConfig: raw.audioSpecificConfig
            ))
            lastAudioPTS = rebasedPTS
        }

        var audioInput: AVAssetWriterInput?
        var audioFormat: CMAudioFormatDescription?
        if let firstAudio = preparedAudio.first,
           !firstAudio.audioSpecificConfig.isEmpty,
           let fmt = TwitchSampleBufferFactory.audioFormatDescription(
               sampleRate: firstAudio.sampleRate,
               channels: firstAudio.channels,
               audioObjectType: firstAudio.audioObjectType,
               audioSpecificConfig: firstAudio.audioSpecificConfig
           ) {
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: nil, sourceFormatHint: fmt)
            input.expectsMediaDataInRealTime = false
            if writer.canAdd(input) {
                writer.add(input)
                audioInput = input
                audioFormat = fmt
            }
        }

        guard writer.startWriting() else {
            throw TwitchClipRecorderError.writerFailed(writer.error?.localizedDescription ?? "startWriting failed")
        }
        writer.startSession(atSourceTime: .zero)

        // Interleave video and audio in chronological order so AVAssetWriter never stalls waiting on the other track.
        var currentFormat = videoFormat
        var currentSPS = sps
        var currentPPS = pps
        var appendedVideo = 0
        var vIdx = 0
        var aIdx = 0
        var vDone = preparedVideo.isEmpty
        var aDone = (audioInput == nil) || preparedAudio.isEmpty
        if vDone { videoInput.markAsFinished() }
        if aDone, let audioInput { audioInput.markAsFinished() }

        func appendNextVideo() -> Bool {
            guard vIdx < preparedVideo.count else { return false }
            let item = preparedVideo[vIdx]
            vIdx += 1
            if let newSPS = item.sps, let newPPS = item.pps, (newSPS != currentSPS || newPPS != currentPPS),
               let nextFmt = TwitchSampleBufferFactory.videoFormatDescription(sps: newSPS, pps: newPPS) {
                currentFormat = nextFmt
                currentSPS = newSPS
                currentPPS = newPPS
            }
            let frame = DemuxedVideoFrame(
                avccData: item.avccData,
                pts90k: item.pts90k,
                dts90k: item.dts90k,
                isKeyframe: item.isKeyframe,
                sps: currentSPS,
                pps: currentPPS
            )
            guard let sb = TwitchSampleBufferFactory.videoSampleBuffer(frame: frame, formatDescription: currentFormat) else {
                return true
            }
            if videoInput.append(sb) {
                appendedVideo += 1
            }
            return true
        }

        func appendNextAudio(_ input: AVAssetWriterInput, format: CMAudioFormatDescription) -> Bool {
            guard aIdx < preparedAudio.count else { return false }
            let item = preparedAudio[aIdx]
            aIdx += 1
            guard let sb = TwitchSampleBufferFactory.audioSampleBuffer(frame: item, formatDescription: format) else {
                return true
            }
            _ = input.append(sb)
            return true
        }

        var stalledTicks = 0
        let maxStalledTicks = 2_500 // 5 seconds safety cap at 2 ms/tick

        while writer.status == .writing && (!vDone || !aDone) {
            var progressed = false
            let vTime: Int64 = vDone ? .max : preparedVideo[vIdx].dts90k
            let aTime: Int64 = aDone ? .max : preparedAudio[aIdx].pts90k
            let preferVideo = vTime <= aTime

            if preferVideo {
                if !vDone && videoInput.isReadyForMoreMediaData {
                    progressed = appendNextVideo()
                } else if !aDone, let audioInput, let audioFormat, audioInput.isReadyForMoreMediaData {
                    progressed = appendNextAudio(audioInput, format: audioFormat)
                }
            } else {
                if !aDone, let audioInput, let audioFormat, audioInput.isReadyForMoreMediaData {
                    progressed = appendNextAudio(audioInput, format: audioFormat)
                } else if !vDone && videoInput.isReadyForMoreMediaData {
                    progressed = appendNextVideo()
                }
            }

            if !vDone && vIdx >= preparedVideo.count {
                videoInput.markAsFinished()
                vDone = true
                progressed = true
            }
            if !aDone && aIdx >= preparedAudio.count {
                audioInput?.markAsFinished()
                aDone = true
                progressed = true
            }

            if progressed {
                stalledTicks = 0
            } else {
                stalledTicks += 1
                if stalledTicks >= maxStalledTicks {
                    writer.cancelWriting()
                    throw TwitchClipRecorderError.writerFailed("AVAssetWriter stalled while writing tracks")
                }
                try? await Task.sleep(for: .milliseconds(2))
            }
        }

        if !vDone { videoInput.markAsFinished() }
        if !aDone { audioInput?.markAsFinished() }

        await writer.finishWriting()
        guard writer.status == .completed, appendedVideo > 0 else {
            let msg = writer.error?.localizedDescription ?? "passthrough MP4 finish failed (status: \(writer.status.rawValue))"
            throw TwitchClipRecorderError.writerFailed(msg)
        }
        return size
    }

    private static func generateThumbnail(videoURL: URL, to thumbURL: URL, duration: Double) async -> Bool {
        let asset = AVURLAsset(url: videoURL)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 640, height: 360)
        let time = CMTime(seconds: max(0, min(duration * 0.45, max(0, duration - 0.1))), preferredTimescale: 600)
        do {
            let (cgImage, _) = try await generator.image(at: time)
            guard let dest = CGImageDestinationCreateWithURL(thumbURL as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else {
                return false
            }
            let props: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: 0.82]
            CGImageDestinationAddImage(dest, cgImage, props as CFDictionary)
            return CGImageDestinationFinalize(dest)
        } catch {
            return false
        }
    }

    private static func defaultTitle(channel: String, kind: TwitchClipKind, duration: Double) -> String {
        let secs = max(1, Int(duration.rounded()))
        let mins = secs / 60
        let rem = secs % 60
        let clock = String(format: "%d:%02d", mins, rem)
        return kind == .clip ? "\(channel) · \(secs) s clip" : "\(channel) · \(clock) recording"
    }

    private static func mintDraftID() -> String {
        let alphabet = Array("ABCDEFGHJKLMNPQRSTUVWXYZabcdefghkmnpqrstuvwxyz23456789")
        var out = "tw"
        out.reserveCapacity(16)
        for _ in 0..<14 {
            out.append(alphabet[Int.random(in: 0..<alphabet.count)])
        }
        return out
    }
}
