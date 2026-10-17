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
    var voiceChain = VoiceChainSettings()
    /// Rendered ahead of playback rather than in the tap; see
    /// RecordingVoiceIsolation.
    var voiceIsolation = VoiceIsolationSettings()
    /// The profile the voice chain was resolved from; nil in projects saved
    /// before profiles, whose chain stands as it was saved.
    var voiceProfile: VoiceProfileSettings?

    init(
        voiceGainDB: Double = 0,
        systemGainDB: Double = 0,
        voiceProcessingEnabled: Bool = true,
        voiceChain: VoiceChainSettings = VoiceChainSettings(),
        voiceIsolation: VoiceIsolationSettings = VoiceIsolationSettings(),
        voiceProfile: VoiceProfileSettings? = nil
    ) {
        self.voiceGainDB = voiceGainDB
        self.systemGainDB = systemGainDB
        self.voiceProcessingEnabled = voiceProcessingEnabled
        self.voiceChain = voiceChain
        self.voiceIsolation = voiceIsolation
        self.voiceProfile = voiceProfile
    }

    private enum CodingKeys: String, CodingKey {
        case voiceGainDB, systemGainDB, voiceProcessingEnabled, voiceChain, voiceIsolation, voiceProfile
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            voiceGainDB: c.value(.voiceGainDB, default: 0),
            systemGainDB: c.value(.systemGainDB, default: 0),
            voiceProcessingEnabled: c.value(.voiceProcessingEnabled, default: true),
            voiceChain: c.value(.voiceChain, default: VoiceChainSettings()),
            voiceIsolation: c.value(.voiceIsolation, default: VoiceIsolationSettings()),
            voiceProfile: c.value(.voiceProfile, default: nil)
        )
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
            voiceProcessingEnabled: voiceProcessingEnabled,
            voiceChain: voiceChain,
            voiceIsolation: voiceIsolation,
            voiceProfile: voiceProfile
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

/// Voice isolation is rendered ahead of playback rather than run in a
/// tap; see RecordingVoiceIsolation.
nonisolated struct VoiceIsolationSettings: Codable, Sendable, Equatable {
    /// How much of the isolated voice replaces the original, in percent.
    /// The blend is linear, so 75% lowers the room by about 12 dB and 90% by
    /// about 20 dB; keeping a little can sound more natural than none.
    static let amounts = [0, 75, 90, 100]

    var amount = 0

    var isEnabled: Bool { amount > 0 }

    init(amount: Int = 0) {
        self.amount = min(100, max(0, amount))
    }

    private enum CodingKeys: String, CodingKey { case amount }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(amount: c.value(.amount, default: 0))
    }
}

/// Settings as the audio threads read them. Studio updates these while
/// playback runs; taps pick changes up on their next buffer and glide to
/// them, so dragging a slider never rebuilds the player item or clicks.
nonisolated final class RecordingAudioParameters: Sendable {
    private let voiceGain: Atomic<UInt32>
    private let systemGain: Atomic<UInt32>
    private let processing: Atomic<Bool>
    /// The chain is too large for an atomic, so it sits behind a mutex the
    /// render thread only ever tries: if Studio holds it that instant, the
    /// tap keeps its current settings for one more buffer.
    private let chain: Mutex<(settings: VoiceChainSettings, version: Int)>
    /// Filled by the voice tap during playback; exports ignore it.
    let meters = RecordingAudioMeters()

    init(_ settings: RecordingAudioSettings = RecordingAudioSettings()) {
        let normalized = settings.normalized
        voiceGain = Atomic(normalized.linearGain(for: .voice).bitPattern)
        systemGain = Atomic(normalized.linearGain(for: .system).bitPattern)
        processing = Atomic(normalized.voiceProcessingEnabled)
        chain = Mutex((normalized.voiceChain, 0))
    }

    func update(_ settings: RecordingAudioSettings) {
        let normalized = settings.normalized
        voiceGain.store(normalized.linearGain(for: .voice).bitPattern, ordering: .relaxed)
        systemGain.store(normalized.linearGain(for: .system).bitPattern, ordering: .relaxed)
        processing.store(normalized.voiceProcessingEnabled, ordering: .relaxed)
        chain.withLock { current in
            if current.settings != normalized.voiceChain {
                current = (normalized.voiceChain, current.version + 1)
            }
        }
    }

    /// Nil when Studio is writing at this instant; never blocks.
    func voiceChainIfAvailable() -> (settings: VoiceChainSettings, version: Int)? {
        chain.withLockIfAvailable { $0 }
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

/// What the voice tap is doing, for Studio's meters. The tap stores after
/// every buffer; Studio reads at display rate. Plain atomics, no locks.
nonisolated final class RecordingAudioMeters: Sendable {
    struct Snapshot: Equatable, Sendable {
        var inputPeakDB = -120.0
        var outputPeakDB = -120.0
        var expanderDB = 0.0
        var compressorDB = 0.0
        var deEsserDB = 0.0
        var limiterDB = 0.0
        var shortTermLUFS: Double?
        /// Changes with every buffer, so a reader can tell playback stopped.
        var sequence: UInt32 = 0
    }

    private let inputPeak = Atomic<UInt32>(0)
    private let outputPeak = Atomic<UInt32>(0)
    private let expander = Atomic<UInt32>(0)
    private let compressor = Atomic<UInt32>(0)
    private let deEsser = Atomic<UInt32>(0)
    private let limiter = Atomic<UInt32>(0)
    private let loudness = Atomic<UInt32>(Float.nan.bitPattern)
    private let sequence = Atomic<UInt32>(0)

    func store(
        inputPeak: Float, outputPeak: Float,
        expanderDB: Float, compressorDB: Float, deEsserDB: Float, limiterDB: Float,
        shortTermLUFS: Float?
    ) {
        self.inputPeak.store(inputPeak.bitPattern, ordering: .relaxed)
        self.outputPeak.store(outputPeak.bitPattern, ordering: .relaxed)
        expander.store(expanderDB.bitPattern, ordering: .relaxed)
        compressor.store(compressorDB.bitPattern, ordering: .relaxed)
        deEsser.store(deEsserDB.bitPattern, ordering: .relaxed)
        limiter.store(limiterDB.bitPattern, ordering: .relaxed)
        loudness.store((shortTermLUFS ?? .nan).bitPattern, ordering: .relaxed)
        sequence.add(1, ordering: .relaxed)
    }

    func snapshot() -> Snapshot {
        func value(_ atomic: borrowing Atomic<UInt32>) -> Double {
            Double(Float(bitPattern: atomic.load(ordering: .relaxed)))
        }
        func decibels(_ linear: Double) -> Double { linear > 0 ? max(-120, 20 * log10(linear)) : -120 }
        let lufs = value(loudness)
        return Snapshot(
            inputPeakDB: decibels(value(inputPeak)),
            outputPeakDB: decibels(value(outputPeak)),
            expanderDB: value(expander),
            compressorDB: value(compressor),
            deEsserDB: value(deEsser),
            limiterDB: value(limiter),
            shortTermLUFS: lufs.isNaN ? nil : lufs,
            sequence: sequence.load(ordering: .relaxed)
        )
    }
}

/// Short-term loudness (EBU R128: K-weighted, 3 s window) for the render
/// thread: fixed buffers, updated every 100 ms.
nonisolated struct ShortTermLoudness {
    private var filters: [KWeightingFilter]
    private var segments: [Double]
    private let segmentLength: Int
    private var segmentIndex = 0
    private var filledSegments = 0
    private var accumulated = 0.0
    private var accumulatedFrames = 0
    private(set) var lufs: Double?

    init(sampleRate: Double, channelCount: Int) {
        filters = Array(repeating: KWeightingFilter(sampleRate: sampleRate), count: max(1, channelCount))
        segments = [Double](repeating: 0, count: 30)
        segmentLength = max(1, Int(sampleRate * 0.1))
    }

    mutating func process(frameCount: Int, read: (Int, Int) -> Float) {
        for frame in 0..<frameCount {
            for channel in filters.indices {
                let y = filters[channel].process(Double(read(frame, channel)))
                accumulated += y * y
            }
            accumulatedFrames += 1
            if accumulatedFrames == segmentLength {
                segments[segmentIndex] = accumulated
                segmentIndex = (segmentIndex + 1) % segments.count
                filledSegments = min(segments.count, filledSegments + 1)
                accumulated = 0
                accumulatedFrames = 0
                // Reported once the window holds at least 400 ms.
                if filledSegments >= 4 {
                    var sum = 0.0
                    for index in 0..<filledSegments { sum += segments[index] }
                    let meanSquare = sum / Double(filledSegments * segmentLength)
                    lufs = meanSquare > 0 ? -0.691 + 10 * log10(meanSquare) : nil
                }
            }
        }
    }
}

nonisolated enum RecordingAudioProcessing {
    /// Ceiling for every limiter: 1 dB under full scale.
    static let ceilingDB = -1.0

    /// Frames every tap delays its track by: the voice chain's oversampling
    /// plus the limiter's look-ahead. System audio is delayed the same, so
    /// the tracks stay aligned.
    static func tapLatency(sampleRate: Double) -> Int {
        VoiceChainProcessor.latency + PeakLimiter.lookaheadFrames(sampleRate: sampleRate)
    }

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
            limiter.process(interleaved: pointer.baseAddress!, frameCount: frameCount)
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
        var chain: VoiceChainProcessor?
        var systemDelay: DelayLine?
        var loudness: ShortTermLoudness?

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
                let channels = Int(description.mChannelsPerFrame)
                context.limiter = PeakLimiter(
                    sampleRate: description.mSampleRate,
                    channelCount: channels,
                    ceilingDB: RecordingAudioProcessing.ceilingDB,
                    detectsTruePeak: true
                )
                switch context.role {
                case .voice:
                    var chain = VoiceChainProcessor(sampleRate: description.mSampleRate, channelCount: channels)
                    if let current = context.parameters.voiceChainIfAvailable() {
                        chain.apply(current.settings, version: current.version)
                    }
                    context.chain = chain
                    context.loudness = ShortTermLoudness(sampleRate: description.mSampleRate, channelCount: channels)
                case .system:
                    context.systemDelay = DelayLine(frames: VoiceChainProcessor.latency, channels: channels)
                }
            },
            unprepare: { tap in
                let context = Unmanaged<TapContext>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue()
                context.limiter = nil
                context.chain = nil
                context.systemDelay = nil
                context.loudness = nil
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

        let isInterleaved = format.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0
        let channels = Int(format.mChannelsPerFrame)
        guard frameCount > 0,
              isInterleaved ? buffers.count >= 1 : buffers.count >= channels else { return }
        let interleavedData = buffers[0].mData?.assumingMemoryBound(to: Float.self)

        @inline(__always) func read(_ frame: Int, _ channel: Int) -> Float {
            if isInterleaved { return interleavedData?[frame * channels + channel] ?? 0 }
            return buffers[channel].mData?.assumingMemoryBound(to: Float.self)[frame] ?? 0
        }
        @inline(__always) func write(_ frame: Int, _ channel: Int, _ value: Float) {
            if isInterleaved { interleavedData?[frame * channels + channel] = value; return }
            buffers[channel].mData?.assumingMemoryBound(to: Float.self)[frame] = value
        }

        var inputPeak: Float = 0
        if context.role == .voice {
            for frame in 0..<frameCount {
                for channel in 0..<channels { inputPeak = max(inputPeak, abs(read(frame, channel))) }
            }
        }

        // 1. The voice chain, or for system audio an equal delay.
        switch context.role {
        case .voice:
            if let current = context.parameters.voiceChainIfAvailable() {
                context.chain?.apply(current.settings, version: current.version)
            }
            context.chain?.process(
                frameCount: frameCount,
                enabled: context.parameters.isVoiceProcessingEnabled,
                read: read,
                write: write
            )
        case .system:
            if context.systemDelay != nil {
                for frame in 0..<frameCount {
                    for channel in 0..<channels {
                        write(frame, channel, context.systemDelay!.push(read(frame, channel), channel: channel))
                    }
                    context.systemDelay!.advance()
                }
            }
        }

        // 2. The fader, gliding toward its target identically on every
        // channel so the stereo image holds.
        var gain = context.currentGain
        let smoothing = context.gainSmoothing
        for frame in 0..<frameCount {
            gain = target + (gain - target) * smoothing
            for channel in 0..<channels { write(frame, channel, read(frame, channel) * gain) }
        }
        context.currentGain = gain

        // 3. The true-peak limiter, on every track, so nothing clips on its
        // own; the export limiter then guards the sum.
        context.limiter?.process(frameCount: frameCount, read: read, write: write)

        // 4. Meters, for the voice.
        if context.role == .voice {
            var outputPeak: Float = 0
            for frame in 0..<frameCount {
                for channel in 0..<channels { outputPeak = max(outputPeak, abs(read(frame, channel))) }
            }
            context.loudness?.process(frameCount: frameCount, read: read)
            context.parameters.meters.store(
                inputPeak: inputPeak,
                outputPeak: outputPeak,
                expanderDB: Float(context.chain?.expanderReductionDB ?? 0),
                compressorDB: Float(context.chain?.compressorReductionDB ?? 0),
                deEsserDB: Float(context.chain?.deEsserReductionDB ?? 0),
                limiterDB: Float(context.limiter?.gainReductionDB ?? 0),
                shortTermLUFS: context.loudness?.lufs.map(Float.init)
            )
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

/// Look-ahead true-peak limiter, linked across channels. Gain reduction
/// starts before a peak arrives (the signal is delayed by the look-ahead)
/// and recovers smoothly, instead of flattening the waveform the way the
/// old hard clip at full scale did. With `detectsTruePeak` it also sees the
/// peaks between samples, through 4x interpolation with a passband nearly
/// to Nyquist (wider than the saturation oversampler needs). A final clamp at the ceiling catches the rare
/// sample the envelope does not fully reach.
///
/// The look-ahead delays the track by 3 ms whether or not it is limiting,
/// so nothing shifts in time when settings change.
nonisolated struct PeakLimiter {
    let ceiling: Float
    /// The envelope aims 0.1 dB under the ceiling, so it lands before the
    /// clamp has to act; a clamped sample would itself overshoot between
    /// samples.
    private let target: Float
    private let channelCount: Int
    private let lookahead: Int
    private let attack: Float
    private let release: Float
    private let detectsTruePeak: Bool
    private var delay: [Float]
    private var position = 0
    /// Recent input per channel, for inter-sample peak interpolation.
    private var history: [Float]
    private var historyPosition = 0
    private let historyLength: Int
    private var heldGain: Float = 1
    private var holdRemaining = 0
    private var gain: Float = 1
    /// Interpolation runs only while a sample within the kernel's reach is
    /// above half the target. Below that, the points between samples cannot
    /// reach the target either, and most of a voice never comes close: this
    /// skips nine tenths of the work.
    private let interpolationThreshold: Float
    private var interpolationWindow = 0

    /// Interpolates up to 22 kHz at 48 kHz, so high-frequency inter-sample
    /// peaks are not underestimated.
    static let detectionKernel = Oversampler.makeKernel(length: 97, cutoff: 0.92)

    static func lookaheadFrames(sampleRate: Double, milliseconds: Double = 3) -> Int {
        max(1, Int(sampleRate * milliseconds / 1_000))
    }

    init(
        sampleRate: Double,
        channelCount: Int,
        ceilingDB: Double = -1,
        detectsTruePeak: Bool = false,
        lookaheadMilliseconds: Double = 3,
        releaseMilliseconds: Double = 80
    ) {
        ceiling = Float(pow(10, ceilingDB / 20))
        target = Float(pow(10, (ceilingDB - 0.1) / 20))
        interpolationThreshold = target * 0.5
        self.channelCount = max(1, channelCount)
        self.detectsTruePeak = detectsTruePeak
        lookahead = Self.lookaheadFrames(sampleRate: sampleRate, milliseconds: lookaheadMilliseconds)
        // Settles fully (to 0.1%) within the look-ahead window, less the
        // dozen frames true-peak detection runs behind.
        attack = Float(exp(-7 / Double(lookahead)))
        release = Float(exp(-1 / (sampleRate * releaseMilliseconds / 1_000)))
        delay = [Float](repeating: 0, count: lookahead * self.channelCount)
        historyLength = (Self.detectionKernel.count + Oversampler.factor - 1) / Oversampler.factor
        history = [Float](repeating: 0, count: historyLength * self.channelCount)
    }

    /// Current gain reduction, in dB (zero or negative).
    var gainReductionDB: Double { 20 * log10(Double(gain)) }

    mutating func reset() {
        for index in delay.indices { delay[index] = 0 }
        for index in history.indices { history[index] = 0 }
        position = 0
        historyPosition = 0
        interpolationWindow = 0
        heldGain = 1
        holdRemaining = 0
        gain = 1
    }

    mutating func process(interleaved samples: UnsafeMutablePointer<Float>, frameCount: Int) {
        let channels = channelCount
        process(frameCount: frameCount,
                read: { frame, channel in samples[frame * channels + channel] },
                write: { frame, channel, value in samples[frame * channels + channel] = value })
    }

    mutating func process(
        frameCount: Int,
        read: (Int, Int) -> Float,
        write: (Int, Int, Float) -> Void
    ) {
        for frame in 0..<frameCount {
            var peak: Float = 0
            for channel in 0..<channelCount {
                let x = read(frame, channel)
                peak = max(peak, abs(x))
                if detectsTruePeak {
                    history[historyPosition * channelCount + channel] = x
                    if abs(x) > interpolationThreshold { interpolationWindow = historyLength }
                }
            }
            if detectsTruePeak {
                if interpolationWindow > 0 {
                    for channel in 0..<channelCount {
                        peak = max(peak, interSamplePeak(channel: channel))
                    }
                    interpolationWindow -= 1
                }
                historyPosition += 1
                if historyPosition == historyLength { historyPosition = 0 }
            }
            let required: Float = peak > target ? target / peak : 1

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
                write(frame, channel, min(ceiling, max(-ceiling, delayed * gain)))
            }
            position += 1
            if position == lookahead { position = 0 }
        }
    }

    /// Largest magnitude of the three points interpolated between this
    /// sample and the previous ones (about twelve samples back, well inside
    /// the look-ahead).
    private func interSamplePeak(channel: Int) -> Float {
        let kernel = Self.detectionKernel
        let factor = Oversampler.factor
        var peak: Float = 0
        for phase in 1..<factor {
            var sum = 0.0
            var k = 0
            var tap = phase
            while tap < kernel.count {
                let index = (historyPosition - k + historyLength) % historyLength
                sum += kernel[tap] * Double(history[index * channelCount + channel])
                k += 1
                tap += factor
            }
            peak = max(peak, abs(Float(sum * Double(factor))))
        }
        return peak
    }
}
