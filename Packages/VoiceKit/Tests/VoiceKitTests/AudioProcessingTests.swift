import AVFoundation
import CoreMedia
import Foundation
import Testing
import VoiceKit
import VoiceKitTestSupport

// Builds a recording with a mono narration track and a stereo system track
// and renders it the way the exporters do (per-track taps, float mix, mix
// limiter), checking gains, muting, the voice processing switch, the
// ceiling, and that live gain changes glide instead of clicking.
@Suite("Audio processing")
struct AudioProcessingTests {
    static let sampleRate = AudioBench.rate
    static let ceiling = Float(pow(10, RecordingAudioProcessing.ceilingDB / 20))

    @Test func settingsMigrateFromTheLegacyVolume() {
        let legacy = RecordingAudioSettings(legacyVolume: 2)
        #expect(abs(legacy.voiceGainDB - 6.02) < 0.01 && abs(legacy.systemGainDB - 6.02) < 0.01)
        #expect(RecordingAudioSettings(legacyVolume: 0).linearGain(for: .system) == 0)
    }

    @Test(.enabled(if: AudioBench.isVoiceBankAvailable, Comment(rawValue: AudioBench.voiceBankMissing)))
    func gainsMutingAndCeiling() async throws {
        let voice = try AudioBench.bankTake("paulina-clean")
        var random = SystemRandomNumberGenerator()
        // System audio: steady noise well under the voice.
        let system = (0..<voice.count).map { _ in Float.random(in: -0.02...0.02, using: &random) }

        try await AudioBench.withTemporaryDirectory(named: "screendrop-processing-check") { directory in
            let movie = directory.appendingPathComponent("recording.mov")
            try await AudioBench.writeMovie(to: movie, tracks: [.float([system, system]), .float([voice])])
            let asset = AVURLAsset(url: movie)
            let tracks = try await asset.loadTracks(withMediaType: .audio)

            // Roles follow channel count; a replacement is always narration.
            let roles = try await RecordingAudioProcessing.roles(for: tracks, isReplacement: false)
            #expect(Set(roles) == [.voice, .system], "expected one voice and one system track")
            let replacementRoles = try await RecordingAudioProcessing.roles(for: tracks, isReplacement: true)
            #expect(replacementRoles.allSatisfy { $0 == .voice })

            // Unity, with the voice chain flat: the render is the plain sum,
            // delayed by the taps' latency and the mix limiter's look-ahead.
            let unity = try await Self.render(asset, tracks, RecordingAudioSettings(voiceChain: .flat))
            let lookahead = RecordingAudioProcessing.tapLatency(sampleRate: Self.sampleRate)
                + PeakLimiter.lookaheadFrames(sampleRate: Self.sampleRate)
            let sum = zip(voice, system).map(+)
            let unityError = AudioBench.errorRatio(reference: sum, decoded: Array(unity.dropFirst(lookahead)), ignoringLast: 1_024)
            #expect(unityError < -60, "unity render must match the sum (\(unityError) dB)")
            print(String(format: "0 dB renders the sum of the tracks (difference %.0f dB, %.2f ms latency)",
                         unityError, Double(lookahead) / Self.sampleRate * 1_000))

            // System at the bottom of its range is muted.
            let muted = try await Self.render(asset, tracks, RecordingAudioSettings(systemGainDB: -60, voiceChain: .flat))
            let mutedError = AudioBench.errorRatio(reference: voice, decoded: Array(muted.dropFirst(lookahead)), ignoringLast: 1_024)
            #expect(mutedError < -60, "muted system audio must leave the voice alone (\(mutedError) dB)")

            // Voice gain moves the voice and only the voice.
            let base = AudioBench.loudness(try await Self.render(asset, tracks, RecordingAudioSettings(systemGainDB: -60, voiceChain: .flat)))
            let boosted = AudioBench.loudness(try await Self.render(
                asset, tracks, RecordingAudioSettings(voiceGainDB: 6, systemGainDB: -60, voiceChain: .flat)))
            #expect(abs(boosted - base - 6) < 0.2, "voice +6 dB moved loudness by \(boosted - base)")

            // Pushed hard: the ceiling holds with processing on and off, on
            // true peak as well.
            for processing in [true, false] {
                let hot = try await Self.render(asset, tracks, RecordingAudioSettings(voiceGainDB: 24, voiceProcessingEnabled: processing))
                let peak = hot.map(abs).max() ?? 0
                #expect(peak <= Self.ceiling + 1e-6, "peak \(peak) is above the ceiling")
                let measured = VoiceAnalyzer.measure(channels: [hot], sampleRate: Self.sampleRate)
                #expect(measured.truePeakDBTP <= -0.9, "true peak \(measured.truePeakDBTP) dBTP is above the ceiling")
                print(String(format: "voice +24 dB, processing %@: peak %.2f dBFS, true peak %.2f dBTP, %.1f LUFS",
                             processing ? "on " : "off", 20 * log10(Double(peak)), measured.truePeakDBTP, measured.integratedLUFS ?? 0))
            }
        }
    }

    @Test func liveGainChangesGlide() async throws {
        // Live changes glide: no step larger than the program's own.
        let rate = Self.sampleRate
        let steady = (0..<Int(rate * 30)).map { Float(0.1 * sin(2 * .pi * 220 * Double($0) / rate)) }
        try await AudioBench.withTemporaryDirectory(named: "screendrop-processing-glide") { directory in
            let movie = directory.appendingPathComponent("tone.mov")
            let silence = [Float](repeating: 0, count: steady.count)
            try await AudioBench.writeMovie(to: movie, tracks: [.float([silence, silence]), .float([steady])])
            let asset = AVURLAsset(url: movie)
            let tracks = try await asset.loadTracks(withMediaType: .audio)
            let parameters = RecordingAudioParameters(RecordingAudioSettings(voiceChain: .flat))
            let switched = try await Self.render(asset, tracks, parameters: parameters) { buffer in
                // Jump the gain by 12 dB partway through, as a slider drag would.
                if buffer == 40 { parameters.update(RecordingAudioSettings(voiceGainDB: 12, voiceChain: .flat)) }
            }
            let maxStep = zip(switched.dropFirst(), switched).map { abs($0 - $1) }.max() ?? 0
            let naturalStep = Float(2 * .pi * 220 / rate) * 0.1 * pow(10, 12 / 20)
            #expect(maxStep < naturalStep * 1.05, "gain change clicked (step \(maxStep))")
            // The reader renders ahead of what it hands out, so the change lands
            // somewhat after buffer 40; by the end it must have fully settled.
            let finalLevel = switched.suffix(4_800).map(abs).max() ?? 0
            let landed = 20 * log10(Double(finalLevel / 0.1))
            #expect(abs(landed - 12) < 0.2, "gain change landed at \(landed) dB, not +12 dB")
        }
    }

    // MARK: Rendering, as the exporters do

    static func render(_ asset: AVAsset, _ tracks: [AVAssetTrack], _ settings: RecordingAudioSettings) async throws -> [Float] {
        try await render(asset, tracks, parameters: RecordingAudioParameters(settings), onBuffer: { _ in })
    }

    /// Returns the left channel of the limited mix.
    static func render(
        _ asset: AVAsset,
        _ tracks: [AVAssetTrack],
        parameters: RecordingAudioParameters,
        onBuffer: (Int) -> Void
    ) async throws -> [Float] {
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderAudioMixOutput(audioTracks: tracks, audioSettings: RecordingAudioProcessing.mixOutputSettings)
        output.audioMix = RecordingAudioProcessing.makeMix(
            tracks: tracks,
            roles: try await RecordingAudioProcessing.roles(for: tracks, isReplacement: false),
            parameters: parameters
        )
        reader.add(output)
        try #require(reader.startReading())
        var limiter = PeakLimiter(sampleRate: 48_000, channelCount: 2, ceilingDB: RecordingAudioProcessing.ceilingDB)
        var left: [Float] = []
        var index = 0
        while let buffer = output.copyNextSampleBuffer() {
            onBuffer(index)
            index += 1
            let limited = try RecordingAudioProcessing.limitMix(buffer, with: &limiter)
            guard let block = CMSampleBufferGetDataBuffer(limited) else { continue }
            let length = CMBlockBufferGetDataLength(block)
            var interleaved = [Float](repeating: 0, count: length / 4)
            interleaved.withUnsafeMutableBytes {
                _ = CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: $0.baseAddress!)
            }
            left += stride(from: 0, to: interleaved.count, by: 2).map { interleaved[$0] }
        }
        #expect(reader.status == .completed)
        return left
    }
}
