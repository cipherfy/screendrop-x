//
//  RecordingAudioProcessing.swift
//  Screendrop
//
//  Per-track audio processing shared by Studio playback and every export
//  path, so what plays is what renders. Each audio track gets its own
//  processing tap: narration (the mono microphone track, or an imported
//  replacement) and system audio carry separate gains, and the voice runs
//  through its processing chain. Exports also limit the summed mix, which
//  no single track's tap can see.
//

import AVFoundation
import AudioToolbox
import MediaToolbox
import Synchronization

/// What a recorded audio track carries. The recorder writes system audio
/// as stereo and the microphone as mono, so channel count tells them apart.
nonisolated enum RecordingAudioRole: Sendable {
    case voice
    case system
}

/// The project's audio settings, saved in the project document.
nonisolated struct RecordingAudioSettings: Codable, Sendable, Equatable {
    static let voiceGainRange: ClosedRange<Double> = -24...24
    /// The bottom of the range mutes system audio.
    static let systemGainRange: ClosedRange<Double> = -60...12

    var voiceGainDB: Double = 0
    var systemGainDB: Double = 0
    /// Off leaves the voice with its gain alone, the "before" side of an
    /// A/B comparison. Exports follow it, so they match what was heard.
    var voiceProcessingEnabled: Bool = true

    init(voiceGainDB: Double = 0, systemGainDB: Double = 0, voiceProcessingEnabled: Bool = true) {
        self.voiceGainDB = voiceGainDB
        self.systemGainDB = systemGainDB
        self.voiceProcessingEnabled = voiceProcessingEnabled
    }

    /// Projects saved with one linear volume (0...2) for everything.
    init(legacyVolume volume: Double) {
        let decibels = volume.isFinite && volume > 0 ? 20 * log10(min(2, volume)) : Self.systemGainRange.lowerBound
        self.init(voiceGainDB: max(Self.voiceGainRange.lowerBound, decibels), systemGainDB: decibels)
    }

    var normalized: Self {
        Self(
            voiceGainDB: Self.clamp(voiceGainDB, to: Self.voiceGainRange),
            systemGainDB: Self.clamp(systemGainDB, to: Self.systemGainRange),
            voiceProcessingEnabled: voiceProcessingEnabled
        )
    }

    func linearGain(for role: RecordingAudioRole) -> Float {
        switch role {
        case .voice:
            Float(pow(10, voiceGainDB / 20))
        case .system:
            systemGainDB <= Self.systemGainRange.lowerBound ? 0 : Float(pow(10, systemGainDB / 20))
        }
    }

    private static func clamp(_ value: Double, to range: ClosedRange<Double>) -> Double {
        value.isFinite ? min(range.upperBound, max(range.lowerBound, value)) : 0
    }
}

/// Settings as the audio threads read them. Studio updates these while
/// playback runs; taps pick changes up on their next buffer and glide to
/// them, so dragging a slider never rebuilds the player item or clicks.
nonisolated final class RecordingAudioParameters: Sendable {
    private let voiceGain: Atomic<UInt32>
    private let systemGain: Atomic<UInt32>
    private let processing: Atomic<Bool>

    init(_ settings: RecordingAudioSettings = RecordingAudioSettings()) {
        let normalized = settings.normalized
        voiceGain = Atomic(normalized.linearGain(for: .voice).bitPattern)
        systemGain = Atomic(normalized.linearGain(for: .system).bitPattern)
        processing = Atomic(normalized.voiceProcessingEnabled)
    }

    func update(_ settings: RecordingAudioSettings) {
        let normalized = settings.normalized
        voiceGain.store(normalized.linearGain(for: .voice).bitPattern, ordering: .relaxed)
        systemGain.store(normalized.linearGain(for: .system).bitPattern, ordering: .relaxed)
        processing.store(normalized.voiceProcessingEnabled, ordering: .relaxed)
    }

    func gain(for role: RecordingAudioRole) -> Float {
        switch role {
        case .voice: Float(bitPattern: voiceGain.load(ordering: .relaxed))
        case .system: Float(bitPattern: systemGain.load(ordering: .relaxed))
        }
    }

    var isVoiceProcessingEnabled: Bool {
        processing.load(ordering: .relaxed)
    }
}

nonisolated enum RecordingAudioProcessing {
    /// Ceiling for every limiter: 1 dB under full scale.
    static let ceilingDB = -1.0

    // MARK: Roles

    /// A replacement soundtrack is the narration, whatever its layout.
    static func role(channelCount: UInt32, isReplacement: Bool) -> RecordingAudioRole {
        isReplacement || channelCount == 1 ? .voice : .system
    }

    static func roles(for tracks: [AVAssetTrack], isReplacement: Bool) async throws -> [RecordingAudioRole] {
        var roles: [RecordingAudioRole] = []
        for track in tracks {
            let descriptions = try await track.load(.formatDescriptions)
            roles.append(role(channelCount: channelCount(descriptions), isReplacement: isReplacement))
        }
        return roles
    }

    /// Synchronous, for rebuilding a player item while a trim handle drags;
    /// composition tracks answer without loading.
    static func rolesSynchronously(for tracks: [AVAssetTrack], isReplacement: Bool) -> [RecordingAudioRole] {
        tracks.map { track in
            role(channelCount: channelCount(track.formatDescriptions as? [CMFormatDescription] ?? []), isReplacement: isReplacement)
        }
    }

    private static func channelCount(_ descriptions: [CMFormatDescription]) -> UInt32 {
        descriptions.compactMap { $0.audioStreamBasicDescription?.mChannelsPerFrame }.max() ?? 0
    }

    // MARK: Mix

    /// One tap per track, all reading the same live parameters.
    static func makeMix(
        tracks: [AVAssetTrack],
        roles: [RecordingAudioRole],
        parameters: RecordingAudioParameters
    ) -> AVAudioMix? {
        guard !tracks.isEmpty, tracks.count == roles.count else { return nil }
        let mix = AVMutableAudioMix()
        mix.inputParameters = zip(tracks, roles).map { track, role in
            let input = AVMutableAudioMixInputParameters(track: track)
            input.audioTapProcessor = makeTap(role: role, parameters: parameters)
            return input
        }
        return mix
    }

    /// Reader settings for mixes the exporters limit before encoding.
    static var mixOutputSettings: [String: Any] {
        [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]
    }

    /// Limits a buffer of the summed mix (interleaved float, as
    /// `mixOutputSettings` reads it) and returns the limited copy.
    static func limitMix(_ sampleBuffer: CMSampleBuffer, with limiter: inout PeakLimiter) throws -> CMSampleBuffer {
        guard let format = CMSampleBufferGetFormatDescription(sampleBuffer),
              let description = format.audioStreamBasicDescription,
              description.mFormatFlags & kAudioFormatFlagIsFloat != 0,
              description.mBitsPerChannel == 32,
              description.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0,
              let source = CMSampleBufferGetDataBuffer(sampleBuffer) else {
            return sampleBuffer
        }
        let frameCount = CMSampleBufferGetNumSamples(sampleBuffer)
        let channels = Int(description.mChannelsPerFrame)
        let length = CMBlockBufferGetDataLength(source)
        guard length == frameCount * channels * MemoryLayout<Float>.size else { return sampleBuffer }

        var samples = [Float](repeating: 0, count: frameCount * channels)
        try samples.withUnsafeMutableBytes { bytes in
            try check(CMBlockBufferCopyDataBytes(source, atOffset: 0, dataLength: length, destination: bytes.baseAddress!))
        }
        samples.withUnsafeMutableBufferPointer { pointer in
            limiter.process(interleaved: pointer.baseAddress!, frameCount: frameCount, limiting: true)
        }

        var block: CMBlockBuffer?
        try check(CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: length,
            blockAllocator: kCFAllocatorDefault, customBlockSource: nil,
            offsetToData: 0, dataLength: length, flags: 0, blockBufferOut: &block
        ))
        guard let block else { return sampleBuffer }
        try samples.withUnsafeBytes { bytes in
            try check(CMBlockBufferReplaceDataBytes(
                with: bytes.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: length
            ))
        }
        var limited: CMSampleBuffer?
        try check(CMAudioSampleBufferCreateReadyWithPacketDescriptions(
            allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format,
            sampleCount: frameCount,
            presentationTimeStamp: CMSampleBufferGetPresentationTimeStamp(sampleBuffer),
            packetDescriptions: nil, sampleBufferOut: &limited
        ))
        return limited ?? sampleBuffer
    }

    private static func check(_ status: OSStatus) throws {
        guard status == noErr else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
    }

    // MARK: Tap

    private final class TapContext {
        let role: RecordingAudioRole
        let parameters: RecordingAudioParameters
        var format = AudioStreamBasicDescription()
        var currentGain: Float
        var gainSmoothing: Float = 0
        var limiter: PeakLimiter?

        init(role: RecordingAudioRole, parameters: RecordingAudioParameters) {
            self.role = role
            self.parameters = parameters
            currentGain = parameters.gain(for: role)
        }
    }

    private static func makeTap(role: RecordingAudioRole, parameters: RecordingAudioParameters) -> MTAudioProcessingTap? {
        let storage = Unmanaged.passRetained(TapContext(role: role, parameters: parameters)).toOpaque()
        var callbacks = MTAudioProcessingTapCallbacks(
            version: kMTAudioProcessingTapCallbacksVersion_0,
            clientInfo: storage,
            init: { _, clientInfo, tapStorage in tapStorage.pointee = clientInfo },
            finalize: { tap in
                Unmanaged<TapContext>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).release()
            },
            prepare: { tap, _, format in
                // Allocation happens here, never on the render thread.
                let context = Unmanaged<TapContext>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue()
                let description = format.pointee
                context.format = description
                context.gainSmoothing = Float(exp(-1 / (0.02 * description.mSampleRate)))
                context.limiter = PeakLimiter(
                    sampleRate: description.mSampleRate,
                    channelCount: Int(description.mChannelsPerFrame),
                    ceilingDB: RecordingAudioProcessing.ceilingDB
                )
            },
            unprepare: { tap in
                Unmanaged<TapContext>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue().limiter = nil
            },
            process: { tap, frames, _, buffers, framesOut, flagsOut in
                let status = MTAudioProcessingTapGetSourceAudio(tap, frames, buffers, flagsOut, nil, framesOut)
                guard status == noErr else { framesOut.pointee = 0; return }
                let context = Unmanaged<TapContext>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue()
                if flagsOut.pointee & MTAudioProcessingTapFlags(kMTAudioProcessingTapFlag_StartOfStream) != 0 {
                    context.limiter?.reset()
                }
                RecordingAudioProcessing.process(
                    UnsafeMutableAudioBufferListPointer(buffers),
                    frameCount: Int(framesOut.pointee),
                    context: context
                )
            }
        )
        var tap: MTAudioProcessingTap?
        let status = MTAudioProcessingTapCreate(
            kCFAllocatorDefault, &callbacks, kMTAudioProcessingTapCreationFlag_PostEffects, &tap
        )
        guard status == noErr else {
            Unmanaged<TapContext>.fromOpaque(storage).release()
            return nil
        }
        return tap
    }

    /// Render thread: no allocation, no locks.
    private static func process(
        _ buffers: UnsafeMutableAudioBufferListPointer,
        frameCount: Int,
        context: TapContext
    ) {
        let format = context.format
        let target = context.parameters.gain(for: context.role)
        let isFloat32 = format.mFormatFlags & kAudioFormatFlagIsFloat != 0 && format.mBitsPerChannel == 32

        guard isFloat32 else {
            // Taps are handed float; anything else gets plain gain.
            context.currentGain = target
            applyGainToIntegerSamples(buffers, format: format, gain: target)
            return
        }

        // Glide toward the target gain per frame, identically on every
        // channel so the stereo image holds.
        let isInterleaved = format.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0
        let channels = Int(format.mChannelsPerFrame)
        var gain = context.currentGain
        let smoothing = context.gainSmoothing
        for frame in 0..<frameCount {
            gain = target + (gain - target) * smoothing
            if isInterleaved {
                guard let data = buffers[0].mData?.assumingMemoryBound(to: Float.self) else { break }
                for channel in 0..<channels { data[frame * channels + channel] *= gain }
            } else {
                for buffer in buffers {
                    buffer.mData?.assumingMemoryBound(to: Float.self)[frame] *= gain
                }
            }
        }
        context.currentGain = gain

        // The voice chain. System audio is limited too, so a boosted track
        // never clips on its own; the export limiter then guards the sum.
        let limiting = context.role == .system || context.parameters.isVoiceProcessingEnabled
        if isInterleaved {
            if let data = buffers[0].mData?.assumingMemoryBound(to: Float.self) {
                context.limiter?.process(interleaved: data, frameCount: frameCount, limiting: limiting)
            }
        } else {
            context.limiter?.process(planar: buffers, frameCount: frameCount, limiting: limiting)
        }
    }

    private static func applyGainToIntegerSamples(
        _ buffers: UnsafeMutableAudioBufferListPointer,
        format: AudioStreamBasicDescription,
        gain: Float
    ) {
        guard format.mFormatFlags & kAudioFormatFlagIsSignedInteger != 0 else { return }
        for buffer in buffers {
            guard let data = buffer.mData else { continue }
            let bytes = Int(buffer.mDataByteSize)
            if format.mBitsPerChannel == 16 {
                let samples = data.assumingMemoryBound(to: Int16.self)
                for i in 0..<(bytes / 2) {
                    samples[i] = Int16(min(Float(Int16.max), max(Float(Int16.min), Float(samples[i]) * gain)))
                }
            } else if format.mBitsPerChannel == 32 {
                let samples = data.assumingMemoryBound(to: Int32.self)
                for i in 0..<(bytes / 4) {
                    samples[i] = Int32(min(Double(Int32.max), max(Double(Int32.min), Double(samples[i]) * Double(gain))))
                }
            }
        }
    }
}

/// Look-ahead peak limiter, linked across channels. Gain reduction starts
/// before a peak arrives (the signal is delayed by the look-ahead) and
/// recovers smoothly, instead of flattening the waveform the way the old
/// hard clip at full scale did. A final clamp at the ceiling catches the
/// rare sample the envelope does not fully reach.
///
/// The look-ahead delays the track by 3 ms whether or not it is limiting,
/// so switching processing on and off never shifts timing.
nonisolated struct PeakLimiter {
    let ceiling: Float
    private let channelCount: Int
    private let lookahead: Int
    private let attack: Float
    private let release: Float
    private var delay: [Float]
    private var position = 0
    private var heldGain: Float = 1
    private var holdRemaining = 0
    private var gain: Float = 1

    init(
        sampleRate: Double,
        channelCount: Int,
        ceilingDB: Double = -1,
        lookaheadMilliseconds: Double = 3,
        releaseMilliseconds: Double = 80
    ) {
        ceiling = Float(pow(10, ceilingDB / 20))
        self.channelCount = max(1, channelCount)
        lookahead = max(1, Int(sampleRate * lookaheadMilliseconds / 1_000))
        // Settles within the look-ahead window.
        attack = Float(exp(-3 / Double(lookahead)))
        release = Float(exp(-1 / (sampleRate * releaseMilliseconds / 1_000)))
        delay = [Float](repeating: 0, count: lookahead * self.channelCount)
    }

    /// Current gain reduction, in dB (zero or negative).
    var gainReductionDB: Double { 20 * log10(Double(gain)) }

    mutating func reset() {
        for index in delay.indices { delay[index] = 0 }
        position = 0
        heldGain = 1
        holdRemaining = 0
        gain = 1
    }

    mutating func process(interleaved samples: UnsafeMutablePointer<Float>, frameCount: Int, limiting: Bool) {
        let channels = channelCount
        run(frameCount: frameCount, limiting: limiting,
            read: { frame, channel in samples[frame * channels + channel] },
            write: { frame, channel, value in samples[frame * channels + channel] = value })
    }

    mutating func process(planar buffers: UnsafeMutableAudioBufferListPointer, frameCount: Int, limiting: Bool) {
        guard buffers.count >= channelCount else { return }
        run(frameCount: frameCount, limiting: limiting,
            read: { frame, channel in buffers[channel].mData?.assumingMemoryBound(to: Float.self)[frame] ?? 0 },
            write: { frame, channel, value in buffers[channel].mData?.assumingMemoryBound(to: Float.self)[frame] = value })
    }

    private mutating func run(
        frameCount: Int,
        limiting: Bool,
        read: (Int, Int) -> Float,
        write: (Int, Int, Float) -> Void
    ) {
        for frame in 0..<frameCount {
            var peak: Float = 0
            for channel in 0..<channelCount {
                peak = max(peak, abs(read(frame, channel)))
            }
            let required: Float = limiting && peak > ceiling ? ceiling / peak : 1

            // Hold the deepest reduction for the look-ahead span so the
            // gain is already down when the peak leaves the delay line.
            if required <= heldGain {
                heldGain = required
                holdRemaining = lookahead
            } else if holdRemaining > 0 {
                holdRemaining -= 1
            } else {
                heldGain = required
            }
            gain = heldGain + (gain - heldGain) * (heldGain < gain ? attack : release)

            let offset = position * channelCount
            for channel in 0..<channelCount {
                let delayed = delay[offset + channel]
                delay[offset + channel] = read(frame, channel)
                var output = delayed * gain
                if limiting {
                    output = min(ceiling, max(-ceiling, output))
                }
                write(frame, channel, output)
            }
            position += 1
            if position == lookahead { position = 0 }
        }
    }
}
