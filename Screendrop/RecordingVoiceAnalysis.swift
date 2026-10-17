//
//  RecordingVoiceAnalysis.swift
//  Screendrop
//
//  Measures the narration a project actually plays (the microphone track,
//  or its isolation render) and works out what the voice profile needs
//  from it: the analysis behind input trim and match EQ, and the voice
//  gain that lands the processed voice on its loudness target.
//
//  Everything runs offline, on at most the first ten minutes of narration
//  (plenty for a long-term spectrum and integrated loudness), through the
//  same chain and limiter code the playback tap runs.
//

import AVFoundation

nonisolated enum RecordingVoiceAnalysis {
    static let maximumSeconds = 600.0
    static let sampleRate = 48_000.0

    enum AnalysisError: LocalizedError {
        case noNarration

        var errorDescription: String? {
            "This recording has no microphone narration to analyze."
        }
    }

    /// The narration as the voice tap will hear it, mono at 48 kHz.
    static func readVoice(screenURL: URL, isolation: VoiceIsolationSettings) async throws -> [Float] {
        let asset = try await RecordingVoiceIsolation.sourceAsset(screenURL: screenURL, settings: isolation)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        let roles = try await RecordingAudioProcessing.roles(for: tracks, isReplacement: false)
        guard let index = roles.firstIndex(of: .voice) else { throw AnalysisError.noNarration }

        let reader = try AVAssetReader(asset: asset)
        let range = try await tracks[index].load(.timeRange)
        reader.timeRange = CMTimeRange(
            start: range.start,
            duration: CMTimeMinimum(range.duration, CMTime(seconds: maximumSeconds, preferredTimescale: 600))
        )
        let output = AVAssetReaderTrackOutput(track: tracks[index], outputSettings: [
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

        var samples: [Float] = []
        samples.reserveCapacity(Int(min(range.duration.seconds, maximumSeconds) * sampleRate))
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
        return samples
    }

    static func analyze(_ samples: [Float], sourceKey: String) -> VoiceAnalysisResult {
        let measurement = VoiceAnalyzer.measure(channels: [samples], sampleRate: sampleRate)
        return VoiceAnalysisResult(
            sourceKey: sourceKey,
            integratedLUFS: measurement.integratedLUFS,
            speechLevelDBFS: measurement.speechLevelDBFS,
            noiseFloorDBFS: measurement.noiseFloorDBFS,
            fundamentalHz: fundamental(of: samples),
            thirdOctave: measurement.thirdOctave
        )
    }

    /// The voice's typical pitch: the median fundamental over voiced frames,
    /// found by normalized autocorrelation at 8 kHz (60-400 Hz), over at
    /// most the first two minutes. It places the body band, which belongs
    /// just above the fundamental and differs by an octave between voices.
    /// The spectrum cannot say this: in speech the first formant, not the
    /// fundamental, carries the most low-frequency energy.
    static func fundamental(of samples: [Float]) -> Double? {
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
    ) -> Double? {
        var processor = VoiceChainProcessor(sampleRate: sampleRate, channelCount: 1)
        processor.apply(chain, version: 1)
        var processed = samples
        processed.withUnsafeMutableBufferPointer { pointer in
            var start = 0
            while start < pointer.count {
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
    private static func key(_ deviceID: String) -> String { "voiceProfile.\(deviceID)" }

    static func profile(forMicrophone deviceID: String?) -> VoiceProfileSettings? {
        guard let deviceID,
              let data = UserDefaults.standard.data(forKey: key(deviceID)) else { return nil }
        return try? JSONDecoder().decode(VoiceProfileSettings.self, from: data)
    }

    static func remember(_ profile: VoiceProfileSettings, forMicrophone deviceID: String?) {
        guard let deviceID, let data = try? JSONEncoder().encode(profile) else { return }
        UserDefaults.standard.set(data, forKey: key(deviceID))
    }

    /// A starting profile for a microphone never seen before, guessed from
    /// its name.
    static func defaultProfile(microphoneName: String?) -> VoiceProfileSettings {
        let name = (microphoneName ?? "").lowercased()
        let condensers = ["quadcast", "solocast", "yeti", "at2020", "nt-usb", "snowball", "hyperx", "condenser"]
        let microphone: VoiceProfileSettings.Microphone =
            condensers.contains(where: name.contains) ? .usbCondenser : .generic
        return VoiceProfileSettings(microphone: microphone)
    }
}
