//
//  RecordingVoiceAnalysis.swift
//  Screendrop
//
//  Measures the narration a project actually plays (the microphone track,
//  or its isolation render) and works out what the voice profile needs
//  from it: the analysis behind input trim and match EQ, and the voice
//  gain that lands the processed voice on its loudness target.
//
//  Everything runs offline, through the same chain and limiter code the
//  playback tap runs, on a sample of the narration: all of it up to three
//  minutes, or six 30-second stretches spread across a longer recording.
//  The sample represents the whole take (not just how it starts) and keeps
//  the work flat however long the recording is.
//

import AVFoundation

nonisolated enum RecordingVoiceAnalysis {
    static let sampleRate = 48_000.0

    enum AnalysisError: LocalizedError {
        case noNarration

        var errorDescription: String? {
            "This recording has no microphone narration to analyze."
        }
    }

    /// The narration as the voice tap will hear it, mono at 48 kHz:
    /// sampled as described above, stretches joined end to end.
    static func readVoice(screenURL: URL, isolation: VoiceIsolationSettings) async throws -> [Float] {
        let asset = try await RecordingVoiceIsolation.sourceAsset(screenURL: screenURL, settings: isolation)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        let roles = try await RecordingAudioProcessing.roles(for: tracks, isReplacement: false)
        guard let index = roles.firstIndex(of: .voice) else { throw AnalysisError.noNarration }
        let track = tracks[index]
        let range = try await track.load(.timeRange)

        var samples: [Float] = []
        samples.reserveCapacity(Int(min(range.duration.seconds, sampledSeconds) * sampleRate))
        for stretch in sampleRanges(of: range) {
            try await read(track, of: asset, range: stretch, into: &samples)
        }
        return samples
    }

    static let sampledSeconds = 180.0
    static let stretchCount = 6

    /// The whole range when short, otherwise evenly spaced stretches that
    /// include the very start and the very end.
    static func sampleRanges(of range: CMTimeRange) -> [CMTimeRange] {
        let duration = range.duration.seconds
        guard duration > sampledSeconds, duration.isFinite else { return [range] }
        let length = sampledSeconds / Double(stretchCount)
        let spacing = (duration - length) / Double(stretchCount - 1)
        return (0..<stretchCount).map { stretch in
            CMTimeRange(
                start: range.start + CMTime(seconds: Double(stretch) * spacing, preferredTimescale: 48_000),
                duration: CMTime(seconds: length, preferredTimescale: 48_000)
            )
        }
    }

    private static func read(_ track: AVAssetTrack, of asset: AVAsset, range: CMTimeRange, into samples: inout [Float]) async throws {
        let reader = try AVAssetReader(asset: asset)
        reader.timeRange = range
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ])
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? AnalysisError.noNarration }
        while let buffer = output.copyNextSampleBuffer() {
            try Task.checkCancellation()
            guard let block = CMSampleBufferGetDataBuffer(buffer) else { continue }
            let length = CMBlockBufferGetDataLength(block)
            let start = samples.count
            samples.append(contentsOf: repeatElement(0, count: length / MemoryLayout<Float>.size))
            samples.withUnsafeMutableBytes { bytes in
                _ = CMBlockBufferCopyDataBytes(
                    block, atOffset: 0, dataLength: length,
                    destination: bytes.baseAddress! + start * MemoryLayout<Float>.size
                )
            }
        }
        if reader.status == .failed { throw reader.error ?? AnalysisError.noNarration }
    }

    static func analyze(_ samples: [Float], sourceKey: String) throws -> VoiceAnalysisResult {
        let measurement = VoiceAnalyzer.measure(channels: [samples], sampleRate: sampleRate)
        return VoiceAnalysisResult(
            sourceKey: sourceKey,
            integratedLUFS: measurement.integratedLUFS,
            speechLevelDBFS: measurement.speechLevelDBFS,
            noiseFloorDBFS: measurement.noiseFloorDBFS,
            fundamentalHz: try fundamental(of: samples),
            thirdOctave: measurement.thirdOctave
        )
    }

    /// The voice's typical pitch: the median fundamental over voiced frames,
    /// found by normalized autocorrelation at 8 kHz (60-400 Hz), over at
    /// most the first two minutes. It places the body band, which belongs
    /// just above the fundamental and differs by an octave between voices.
    /// The spectrum cannot say this: in speech the first formant, not the
    /// fundamental, carries the most low-frequency energy.
    static func fundamental(of samples: [Float]) throws -> Double? {
        let factor = Int(sampleRate / 8_000)
        let rate = sampleRate / Double(factor)
        var decimated: [Float] = []
        decimated.reserveCapacity(min(samples.count, Int(sampleRate * 120)) / factor)
        // Two box filters before decimating keep 2.5 kHz content from
        // folding onto the pitch range.
        var index = 0
        let limit = min(samples.count, Int(sampleRate * 120)) - 2 * factor
        while index < limit {
            var sum: Float = 0
            for offset in 0..<(2 * factor) { sum += samples[index + offset] }
            decimated.append(sum / Float(2 * factor))
            index += factor
        }

        let frame = Int(rate * 0.04)
        let minimumLag = Int(rate / 400)
        let maximumLag = Int(rate / 60)
        guard decimated.count > frame + maximumLag else { return nil }

        let starts = Array(stride(from: 0, to: decimated.count - frame - maximumLag, by: frame / 2))
        let energies = starts.map { start in decimated[start..<start + frame].reduce(Float(0)) { $0 + $1 * $1 } }
        guard let loud = energies.max(), loud > 0 else { return nil }

        var pitches: [Double] = []
        for (start, energy) in zip(starts, energies) where energy > loud * 0.01 {
            try Task.checkCancellation()
            var bestLag = 0
            var best: Float = 0
            for lag in minimumLag...maximumLag {
                var dot: Float = 0
                var shifted: Float = 0
                for i in start..<(start + frame) {
                    dot += decimated[i] * decimated[i + lag]
                    shifted += decimated[i + lag] * decimated[i + lag]
                }
                let correlation = dot / max(1e-12, (energy * shifted).squareRoot())
                if correlation > best {
                    best = correlation
                    bestLag = lag
                }
            }
            if best > 0.6, bestLag > 0 { pitches.append(rate / Double(bestLag)) }
        }
        guard pitches.count >= 10 else { return nil }
        return pitches.sorted()[pitches.count / 2]
    }

    /// The voice gain, in dB, that puts the processed voice on `targetLUFS`
    /// as the tap renders it: chain, then fader, then the true-peak limiter.
    /// The chain runs once; the fader and limiter are refined until the
    /// loudness the limiter takes off has been added back. Nil when the
    /// voice is too quiet to measure.
    static func normalizationGain(
        _ samples: [Float],
        chain: VoiceChainSettings,
        targetLUFS: Double
    ) throws -> Double? {
        var processor = VoiceChainProcessor(sampleRate: sampleRate, channelCount: 1)
        processor.apply(chain, version: 1)
        var processed = samples
        try processed.withUnsafeMutableBufferPointer { pointer in
            var start = 0
            while start < pointer.count {
                try Task.checkCancellation()
                let count = min(4_096, pointer.count - start)
                processor.process(
                    frameCount: count, enabled: true,
                    read: { frame, _ in pointer[start + frame] },
                    write: { frame, _, value in pointer[start + frame] = value }
                )
                start += count
            }
        }
        guard let chainLoudness = LoudnessMeter.measure(channels: [processed], sampleRate: sampleRate).integrated else {
            return nil
        }

        // Each pass adds back what the limiter took. Voices with a high crest
        // factor, pushed hard toward -14 LUFS, need more than one.
        var gain = targetLUFS - chainLoudness
        for _ in 0..<5 {
            try Task.checkCancellation()
            var limiter = PeakLimiter(
                sampleRate: sampleRate, channelCount: 1,
                ceilingDB: RecordingAudioProcessing.ceilingDB, detectsTruePeak: true
            )
            let linear = Float(pow(10, gain / 20))
            var rendered = processed.map { $0 * linear }
            rendered.withUnsafeMutableBufferPointer { limiter.process(interleaved: $0.baseAddress!, frameCount: $0.count) }
            guard let loudness = LoudnessMeter.measure(channels: [rendered], sampleRate: sampleRate).integrated else { break }
            let miss = targetLUFS - loudness
            if abs(miss) < 0.1 { break }
            gain += miss
        }
        let range = RecordingAudioSettings.voiceGainRange
        return min(range.upperBound, max(range.lowerBound, (gain * 10).rounded() / 10))
    }
}

// MARK: - Per-microphone memory

/// The last voice profile chosen for each microphone, so a new recording
/// from the same microphone starts where the previous one was left.
nonisolated enum VoiceProfileStore {
    /// Versioned: profiles remembered before the microphone choice and the
    /// Warm and Bright characters went away start over from the defaults.
    private static func key(_ deviceID: String) -> String { "voiceProfile.v2.\(deviceID)" }

    static func profile(forMicrophone deviceID: String?) -> VoiceProfileSettings? {
        guard let deviceID,
              let data = UserDefaults.standard.data(forKey: key(deviceID)) else { return nil }
        return try? JSONDecoder().decode(VoiceProfileSettings.self, from: data)
    }

    static func remember(_ profile: VoiceProfileSettings, forMicrophone deviceID: String?) {
        guard let deviceID, let data = try? JSONEncoder().encode(profile) else { return }
        UserDefaults.standard.set(data, forKey: key(deviceID))
    }
}
