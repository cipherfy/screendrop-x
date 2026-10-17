import AVFoundation
import Foundation
import Testing
import VoiceKit
import VoiceKitTestSupport

// Checks what Studio shows about the voice: the EQ curve against what the
// chain really does, the live meters against the offline meter, the gain
// reduction the chain reports, the custom chain, and the microphone check's
// advice for takes with known problems.
@Suite("Voice tools")
struct VoiceToolsTests {
    static let rate = AudioBench.rate

    /// The drawn curve must be what plays: compare it with sine gains
    /// measured through the processor for a busy chain.
    @Test func responseCurveMatchesTheChain() {
        var chain = VoiceChainSettings.usbCondenser
        chain.dynamicLow.isEnabled = false
        chain.expander.isEnabled = false
        chain.compressor.isEnabled = false
        chain.deEsser.isEnabled = false
        chain.saturation.isEnabled = false
        chain.match = .init(gains: [1, -2, 0.5, 2, -3, 1.5])
        var worst = 0.0
        for frequency in [60.0, 100, 150, 300, 700, 1_000, 2_500, 4_000, 5_000, 8_000, 12_000] {
            // RMS, not peak: near fs/4 the filters' phase shift moves the
            // samples off the crest, and a sampled peak would read low.
            let input = AudioBench.sine(frequency, levelDB: -20)
            let measured = AudioBench.rmsDB(Self.run(input, chain)) - AudioBench.rmsDB(input)
            worst = max(worst, abs(measured - chain.responseDB(at: frequency)))
        }
        #expect(worst < 0.1, "curve and chain disagree by \(worst) dB")
    }

    /// Live short-term loudness against the offline meter on the same tone.
    @Test func shortTermLoudness() {
        let tone = AudioBench.sine(1_000, levelDB: -20, seconds: 5)
        var meter = ShortTermLoudness(sampleRate: Self.rate, channelCount: 1)
        tone.withUnsafeBufferPointer { pointer in
            var start = 0
            while start < pointer.count {
                let count = min(512, pointer.count - start)
                meter.process(frameCount: count) { frame, _ in pointer[start + frame] }
                start += count
            }
        }
        let offline = LoudnessMeter.measure(channels: [tone], sampleRate: Self.rate).shortTermMax ?? 0
        let live = meter.lufs ?? 0
        #expect(abs(live - offline) < 0.05, "live \(live) vs offline \(offline)")
    }

    /// The meters read gain reduction from the processor; it must match the
    /// static curves.
    @Test func reductionReadouts() {
        var settings = VoiceChainSettings.flat
        settings.compressor = .init(isEnabled: true, thresholdDB: -24, ratio: 3, kneeDB: 0,
                                    attackMilliseconds: 5, releaseMilliseconds: 50, makeupDB: 0)
        var processor = VoiceChainProcessor(sampleRate: Self.rate, channelCount: 1)
        processor.apply(settings, version: 1)
        var tone = AudioBench.sine(1_000, levelDB: -6)
        tone.withUnsafeMutableBufferPointer { pointer in
            processor.process(frameCount: pointer.count, enabled: true,
                              read: { frame, _ in pointer[frame] },
                              write: { frame, _, value in pointer[frame] = value })
        }
        #expect(abs(processor.compressorReductionDB + 12) < 0.5, "compressor reports \(processor.compressorReductionDB)")
        #expect(processor.expanderReductionDB == 0 && processor.deEsserReductionDB == 0)

        var limiter = PeakLimiter(sampleRate: Self.rate, channelCount: 1, ceilingDB: -1, detectsTruePeak: true)
        var loud = AudioBench.sine(1_000, levelDB: 0)
        loud.withUnsafeMutableBufferPointer { limiter.process(interleaved: $0.baseAddress!, frameCount: $0.count) }
        #expect(abs(limiter.gainReductionDB + 1.1) < 0.2, "limiter reports \(limiter.gainReductionDB)")
    }

    @Test func meterSnapshot() {
        let meters = RecordingAudioMeters()
        let before = meters.snapshot()
        #expect(before.shortTermLUFS == nil && before.inputPeakDB == -120)
        meters.store(inputPeak: 0.5, outputPeak: 0.25, expanderDB: -3, compressorDB: -6, deEsserDB: -2,
                     limiterDB: -1, shortTermLUFS: -16)
        let after = meters.snapshot()
        #expect(abs(after.inputPeakDB + 6.02) < 0.01 && abs(after.outputPeakDB + 12.04) < 0.01)
        #expect(after.compressorDB == -6 && after.shortTermLUFS == -16 && after.sequence == before.sequence + 1)
    }

    @Test func customChain() {
        var profile = VoiceProfileSettings(character: .broadcast)
        var custom = VoiceProfileResolver.chain(for: profile, analysis: nil)
        custom.compressor.ratio = 6
        profile.customChain = custom
        #expect(VoiceProfileResolver.chain(for: profile, analysis: nil) == custom)
        profile.character = .clear
        #expect(VoiceProfileResolver.chain(for: profile, analysis: nil).compressor.ratio == 6, "a custom chain ignores the character")
        profile.customChain = nil
        #expect(VoiceProfileResolver.chain(for: profile, analysis: nil).compressor.ratio != 6)
    }

    // MARK: Microphone check

    @Test(.enabled(if: AudioBench.isVoiceBankAvailable, Comment(rawValue: AudioBench.voiceBankMissing)))
    func microphoneAdvice() throws {
        let take = try AudioBench.bankTake("paulina-clean")
        let hot = try AudioBench.bankTake("paulina-hot")
        let rate = Self.rate
        let speech = Array(take.prefix(Int(rate * 6)))
        let room = AudioBench.pink(seconds: 2.2, rmsDB: -72)
        func scaled(_ samples: [Float], peakDB: Double) -> [Float] {
            let peak = Double(samples.map(abs).max() ?? 1)
            let gain = Float(pow(10, peakDB / 20) / peak)
            return samples.map { $0 * gain }
        }
        let humRoom = zip(AudioBench.hum(seconds: 2.2, levelDB: -55), AudioBench.pink(seconds: 2.2, rmsDB: -80)).map(+)

        let cases: [(String, [Float], [Float], [String], Bool)] = [
            ("good take", room, scaled(speech, peakDB: -9), ["Level is right", "Quiet room"], true),
            ("quiet gain", room, scaled(speech, peakDB: -30), ["Too quiet"], false),
            ("clipping", room, Array(hot.prefix(Int(rate * 6))), ["Too loud: the voice clips"], false),
            ("hot but clean", room, scaled(speech, peakDB: -3), ["A little hot"], true),
            ("noisy room", AudioBench.pink(seconds: 2.2, rmsDB: -40), scaled(speech, peakDB: -9), ["Noisy room"], false),
            ("mains hum", humRoom, scaled(speech, peakDB: -9), ["Mains hum"], true),
            ("muted mic", AudioBench.pink(seconds: 2.2, rmsDB: -90), AudioBench.pink(seconds: 6, rmsDB: -85), ["No voice detected"], false)
        ]
        for (label, silence, voice, expected, ready) in cases {
            let result = MicrophoneCheckAnalyzer.evaluate(silence: silence, speech: voice, sampleRate: rate)
            let titles = result.findings.map(\.title)
            for title in expected {
                #expect(titles.contains(title), "\(label): expected “\(title)”, got \(titles)")
            }
            #expect(result.isReady == ready, "\(label): ready should be \(ready), got \(titles)")
        }
    }

    /// The whole signal in one call, unaligned, as the meters see it.
    static func run(_ input: [Float], _ settings: VoiceChainSettings) -> [Float] {
        AudioBench.run(input, settings, blockSize: nil, alignsLatency: false)
    }
}
