import AVFoundation
import CoreMedia
import Foundation

// Pitch in the preview (APP-API-CONTRACT 31.16): the composition can scale time but not shift pitch, so a clip with a pitch plays
// a pre-shifted copy of its source range instead of the source's sound. The copy is made in two steps, off the main actor:
//
// 1. `AVAssetReader` decodes the clip's `in...out` of the source's first audio track to LPCM (48 kHz, stereo, float) into a
//    temporary .caf. The sources are .mp4/.mov videos, which `AVAudioFile` cannot open, and the reader also gives exactly the
//    range wanted whatever the codec, so this one route works for every source.
// 2. `AVAudioEngine` in offline manual rendering plays that file through `AVAudioUnitTimePitch` (pitch in cents, rate 1) and
//    writes the result (16-bit LPCM .caf, the same length as the input; the unit's reported latency is dropped from the front).
//
// The copy is kept in the source cache's folder under a name made of (item, in, out, pitch), so the LRU trim and any clear of the
// folder take it with the sources.

/// What a pre-shifted copy is made from: one library file's source range at one pitch. Times in milliseconds (the timeline's own
/// resolution), pitch in half semitones, so equal clips give equal keys.
public struct EditPitchKey: Hashable, Sendable {
    public let item: String
    public let inMs: Int
    public let outMs: Int
    /// The pitch times 2 (-24...24).
    public let halfSteps: Int

    public init(item: String, in inPoint: Double, out: Double, pitch: Double) {
        self.item = item
        self.inMs = Int((inPoint * 1_000).rounded())
        self.outMs = Int((out * 1_000).rounded())
        let p = EditJSON.pitch(pitch)
        self.halfSteps = p.isFinite ? Int((p * 2).rounded()) : 0
    }

    /// nil for a clip with no pitch.
    public init?(clip: EditClip) {
        let key = EditPitchKey(item: clip.item, in: clip.`in`, out: clip.out, pitch: clip.pitch)
        guard key.halfSteps != 0 else { return nil }
        self = key
    }

    /// nil for an overlay with no pitch.
    public init?(overlay: EditOverlay) {
        let key = EditPitchKey(item: overlay.item, in: overlay.`in`, out: overlay.out, pitch: overlay.pitch)
        guard key.halfSteps != 0 else { return nil }
        self = key
    }

    public var inSeconds: Double { Double(inMs) / 1_000 }
    public var outSeconds: Double { Double(outMs) / 1_000 }
    public var semitones: Double { Double(halfSteps) / 2 }

    /// `pitch-<item>-<in ms>-<out ms>-<half steps>.caf` (the half steps may be negative: `-5`).
    public var fileName: String { "pitch-\(item)-\(inMs)-\(outMs)-\(halfSteps).caf" }
}

public enum EditPitchShifter {
    static let sampleRate = 48_000.0
    static let channels: AVAudioChannelCount = 2
    static let chunk: AVAudioFrameCount = 4_096

    /// Writes `source`'s audio from `inPoint` to `out` (seconds), shifted by `semitones`, to `dest` (a .caf). Heavy: call it from a
    /// detached task. Honours task cancellation. Throws `EditError.other("no audio")` when the range has no sound.
    public static func render(source: URL, in inPoint: Double, out: Double, semitones: Double, to dest: URL) async throws {
        let fm = FileManager.default
        let base = dest.deletingPathExtension().lastPathComponent
        let folder = dest.deletingLastPathComponent()
        let extracted = folder.appendingPathComponent("\(base).src.caf")
        let partial = folder.appendingPathComponent("\(base).tmp.caf")
        defer {
            try? fm.removeItem(at: extracted)
            try? fm.removeItem(at: partial)
        }
        try? fm.removeItem(at: extracted)
        try? fm.removeItem(at: partial)
        let frames = try await extract(from: source, in: inPoint, out: out, to: extracted)
        guard frames > 0 else { throw EditError.other("no audio") }
        try Task.checkCancellation()
        try shift(file: extracted, semitones: semitones, to: partial)
        try Task.checkCancellation()
        if fm.fileExists(atPath: dest.path) { try? fm.removeItem(at: dest) }
        try fm.moveItem(at: partial, to: dest)
    }

    /// The format both steps work in: 48 kHz stereo float32, interleaved (what the reader hands out).
    static var interleavedFormat: AVAudioFormat? {
        AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: channels, interleaved: true)
    }

    /// Step 1: the range as LPCM in a .caf. Returns the frames written.
    static func extract(from source: URL, in inPoint: Double, out: Double, to dest: URL) async throws -> Int64 {
        let asset = AVURLAsset(url: source)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else { throw EditError.other("no audio") }
        guard let format = interleavedFormat else { throw EditError.other("audio format") }
        let reader = try AVAssetReader(asset: asset)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: Int(channels),
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw EditError.other("audio reader") }
        reader.add(output)
        let start = CMTime(value: Int64((max(0, inPoint) * 1_000).rounded()), timescale: 1_000)
        let length = CMTime(value: Int64((max(0, out - inPoint) * 1_000).rounded()), timescale: 1_000)
        reader.timeRange = CMTimeRange(start: start, duration: length)
        guard reader.startReading() else { throw EditError.other("audio reader") }
        defer { if reader.status == .reading { reader.cancelReading() } }

        let file = try AVAudioFile(forWriting: dest, settings: format.settings, commonFormat: .pcmFormatFloat32, interleaved: true)
        var written: Int64 = 0
        while let sample = output.copyNextSampleBuffer() {
            if Task.isCancelled { throw CancellationError() }
            let n = CMSampleBufferGetNumSamples(sample)
            guard n > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(n)) else { continue }
            buffer.frameLength = AVAudioFrameCount(n)
            let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
                sample, at: 0, frameCount: Int32(n), into: buffer.mutableAudioBufferList)
            guard status == noErr else { throw EditError.other("audio copy \(status)") }
            try file.write(from: buffer)
            written += Int64(n)
        }
        if reader.status == .failed { throw EditError.other("audio reader") }
        return written
    }

    /// Step 2: `file` through a time-pitch unit, offline, into `dest` (16-bit LPCM, the same number of frames as `file`).
    static func shift(file url: URL, semitones: Double, to dest: URL) throws {
        let input = try AVAudioFile(forReading: url)
        let format = input.processingFormat                      // deinterleaved float32, 48 kHz, stereo
        let total = input.length
        guard total > 0 else { throw EditError.other("no audio") }

        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        let pitch = AVAudioUnitTimePitch()
        pitch.pitch = Float(semitones * 100)
        pitch.rate = 1
        engine.attach(player)
        engine.attach(pitch)
        engine.connect(player, to: pitch, format: format)
        engine.connect(pitch, to: engine.mainMixerNode, format: format)
        try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: chunk)
        try engine.start()
        defer {
            player.stop()
            engine.stop()
        }
        player.scheduleFile(input, at: nil, completionHandler: nil)
        player.play()

        let renderFormat = engine.manualRenderingFormat
        guard let buffer = AVAudioPCMBuffer(pcmFormat: renderFormat, frameCapacity: engine.manualRenderingMaximumFrameCount) else {
            throw EditError.other("audio buffer")
        }
        let outSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: renderFormat.sampleRate,
            AVNumberOfChannelsKey: Int(renderFormat.channelCount),
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        let output = try AVAudioFile(
            forWriting: dest, settings: outSettings, commonFormat: renderFormat.commonFormat,
            interleaved: renderFormat.isInterleaved)

        // the unit's delay, dropped from the front so the sound stays on the picture
        let latency = pitch.latency.isFinite ? max(0, pitch.latency) : 0
        let skip = AVAudioFramePosition((latency * renderFormat.sampleRate).rounded())
        var rendered: AVAudioFramePosition = 0
        var written: AVAudioFramePosition = 0
        var idle = 0
        while written < total {
            if Task.isCancelled { throw CancellationError() }
            let want = min(AVAudioFramePosition(buffer.frameCapacity), total + skip - rendered)
            guard want > 0 else { break }
            let status = try engine.renderOffline(AVAudioFrameCount(want), to: buffer)
            switch status {
            case .success:
                let got = AVAudioFramePosition(buffer.frameLength)
                guard got > 0 else {
                    idle += 1
                    if idle > 64 { throw EditError.other("audio render stalled") }
                    continue
                }
                idle = 0
                let from = max(0, skip - rendered)               // frames of this buffer still inside the latency
                rendered += got
                guard from < got else { continue }
                let keep = min(got - from, total - written)
                if from == 0 && keep == got {
                    try output.write(from: buffer)
                } else if let part = slice(buffer, from: from, count: keep) {
                    try output.write(from: part)
                } else {
                    throw EditError.other("audio buffer")
                }
                written += keep
            case .insufficientDataFromInputNode, .cannotDoInCurrentContext:
                idle += 1
                if idle > 64 { throw EditError.other("audio render stalled") }
            case .error:
                throw EditError.other("audio render")
            @unknown default:
                throw EditError.other("audio render")
            }
        }
    }

    /// `count` frames of a deinterleaved float buffer from `from`, copied into a buffer of their own.
    static func slice(_ buffer: AVAudioPCMBuffer, from: AVAudioFramePosition, count: AVAudioFramePosition) -> AVAudioPCMBuffer? {
        guard count > 0, let source = buffer.floatChannelData,
              let part = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: AVAudioFrameCount(count)),
              let target = part.floatChannelData else { return nil }
        let channelCount = Int(buffer.format.channelCount)
        let stride = buffer.stride                               // 1 for deinterleaved
        guard stride == 1 else { return nil }
        for ch in 0..<channelCount {
            target[ch].update(from: source[ch] + Int(from), count: Int(count))
        }
        part.frameLength = AVAudioFrameCount(count)
        return part
    }
}
