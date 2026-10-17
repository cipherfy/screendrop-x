import AVFoundation
import Foundation
import Testing
import VoiceKit
import VoiceKitTestSupport

// Checks each stage of the voice chain against signals with known answers,
// then runs the voice bank's USB-condenser takes through the USB Condenser
// preset and reports what changed.
@Suite("Voice chain")
struct VoiceChainTests {
    static let rate = AudioBench.rate
    static let latency = VoiceChainProcessor.latency

    // MARK: Stages

    @Test func flatChainIsTransparent() {
        let input = AudioBench.noise(seconds: 2, level: 0.3)
        let output = run(input, .flat)
        let error = AudioBench.errorRatio(reference: input, decoded: output)
        #expect(error < -120, "flat chain must be transparent (\(error) dB)")
        // An impulse lands on the same frame through the oversampler, the
        // delay that replaces it, and the bypass path.
        var impulse = [Float](repeating: 0, count: 4_800)
        impulse[1_000] = 0.5
        var oversampled = VoiceChainSettings.flat
        oversampled.saturation = .init(isEnabled: true, driveDB: 0, mix: 0, warmth: 0)
        for (label, settings, enabled) in [("delay", VoiceChainSettings.flat, true),
                                           ("oversampler", oversampled, true),
                                           ("bypass", VoiceChainSettings.flat, false)] {
            let response = run(impulse, settings, enabled: enabled)
            let peak = response.indices.max { abs(response[$0]) < abs(response[$1]) }!
            #expect(peak == 1_000, "\(label) path is off by \(peak - 1_000) frames")
        }
    }

    @Test func highPass() {
        var gentle = VoiceChainSettings.flat
        gentle.highPass = .init(isEnabled: true, frequency: 80, isSteep: false)
        expectNear(gainDB(of: gentle, frequency: 40), -12.3, 0.2, "12 dB/oct high-pass an octave below 80 Hz")
        expectNear(gainDB(of: gentle, frequency: 1_000), 0, 0.05, "high-pass passband at 1 kHz")

        var steep = VoiceChainSettings.flat
        steep.highPass = .init(isEnabled: true, frequency: 90, isSteep: true)
        expectNear(gainDB(of: steep, frequency: 45), -24.1, 0.3, "24 dB/oct high-pass an octave below 90 Hz")
    }

    @Test func equalizer() {
        var settings = VoiceChainSettings.flat
        settings.presence = .init(kind: .peak, frequency: 4_500, gainDB: 6, q: 1.4)
        settings.lowShelf = .init(kind: .lowShelf, frequency: 150, gainDB: 4, q: 0.7)
        settings.lowMid = .init(kind: .peak, frequency: 300, gainDB: -3, q: 1.2)
        expectNear(gainDB(of: settings, frequency: 4_500), 6, 0.15, "presence bell")
        expectNear(gainDB(of: settings, frequency: 40), 4, 0.4, "low shelf below its corner")
        expectNear(gainDB(of: settings, frequency: 300), -3, 0.3, "mud cut")
    }

    @Test func compressor() {
        var settings = VoiceChainSettings.flat
        settings.compressor = .init(isEnabled: true, thresholdDB: -24, ratio: 3, kneeDB: 0,
                                    attackMilliseconds: 5, releaseMilliseconds: 50, makeupDB: 0)
        expectNear(AudioBench.peakDB(run(AudioBench.sine(1_000, levelDB: -6), settings)), -18, 1,
                   "3:1 at -24 dB: -6 dBFS in reads about -18 out")
        expectNear(AudioBench.peakDB(run(AudioBench.sine(1_000, levelDB: -30), settings)), -30, 0.1,
                   "below threshold is untouched")
    }

    @Test func expander() {
        var settings = VoiceChainSettings.flat
        settings.expander = .init(isEnabled: true, thresholdDB: -45, ratio: 2, rangeDB: 8, releaseMilliseconds: 150)
        expectNear(AudioBench.peakDB(run(AudioBench.sine(300, levelDB: -20), settings)), -20, 0.1, "expander leaves speech level alone")
        expectNear(AudioBench.peakDB(run(AudioBench.sine(300, levelDB: -50), settings)), -55, 0.5,
                   "2:1 expander: 5 dB under the threshold goes 5 dB further down")
        expectNear(AudioBench.peakDB(run(AudioBench.sine(300, levelDB: -70), settings)), -78, 0.5, "expander stops at its range")
    }

    @Test func deEsser() {
        var settings = VoiceChainSettings.flat
        settings.deEsser = .init(isEnabled: true, frequency: 6_500, thresholdDB: -32, rangeDB: 8)
        expectNear(AudioBench.peakDB(run(AudioBench.sine(6_500, levelDB: -10), settings)), -18, 1,
                   "de-esser cuts a loud 6.5 kHz tone by its full range")
        expectNear(AudioBench.peakDB(run(AudioBench.sine(500, levelDB: -10), settings)), -10, 0.3, "de-esser leaves 500 Hz alone")
    }

    @Test func dynamicLowBand() {
        var settings = VoiceChainSettings.flat
        settings.dynamicLow = .init(isEnabled: true, frequency: 140, q: 1, thresholdDB: -28, rangeDB: 4)
        expectNear(AudioBench.peakDB(run(AudioBench.sine(140, levelDB: -10), settings)), -14, 0.6, "dynamic band cuts loud 140 Hz by its range")
        expectNear(AudioBench.peakDB(run(AudioBench.sine(140, levelDB: -40), settings)), -40, 0.2, "dynamic band leaves quiet 140 Hz alone")
    }

    @Test func saturation() {
        func saturated(warmth: Double) -> VoiceChainSettings {
            var settings = VoiceChainSettings.flat
            settings.saturation = .init(isEnabled: true, driveDB: 12, mix: 1, warmth: warmth)
            return settings
        }
        let tone = AudioBench.sine(1_000, levelDB: -6)
        let odd = run(tone, saturated(warmth: 0))
        let warm = run(tone, saturated(warmth: 0.6))
        let thirdOdd = AudioBench.level(odd, at: 3_000) - AudioBench.level(odd, at: 1_000)
        let secondOdd = AudioBench.level(odd, at: 2_000) - AudioBench.level(odd, at: 1_000)
        let secondWarm = AudioBench.level(warm, at: 2_000) - AudioBench.level(warm, at: 1_000)
        #expect(thirdOdd > -40, "saturation must add harmonics")
        #expect(secondWarm > secondOdd + 20, "warmth must add even harmonics")

        // Aliasing: 9 kHz driven hard. Its 3rd, 5th, and 7th harmonics
        // (27, 45, 63 kHz) fold to 21, 3, and 15 kHz at 48 kHz.
        let high = AudioBench.sine(9_000, levelDB: -3)
        let oversampled = run(high, saturated(warmth: 0))
        let drive = pow(10, 12.0 / 20)
        let naive = high.map { Float(tanh(drive * Double($0)) / drive) }
        func aliases(_ signal: [Float]) -> Double {
            let fundamental = AudioBench.level(signal, at: 9_000)
            return [3_000.0, 15_000, 21_000].map { AudioBench.level(signal, at: $0) - fundamental }.max()!
        }
        let oversampledAlias = aliases(oversampled)
        let naiveAlias = aliases(naive)
        #expect(oversampledAlias < naiveAlias - 25, "oversampling must suppress aliasing")
        print(String(format: "aliasing from 9 kHz driven hard: %.0f dB with 4x oversampling, %.0f dB without", oversampledAlias, naiveAlias))

        // Passband: with saturation on, the oversampler's filters must not
        // dull the voice (small signal, so the curve itself stays linear).
        var gentle = VoiceChainSettings.flat
        gentle.saturation = .init(isEnabled: true, driveDB: 6, mix: 0.25, warmth: 0.3)
        var worst = 0.0
        var worstFrequency = 0.0
        for frequency in [1_000.0, 5_000, 8_000, 10_000, 12_000, 16_000, 18_000] {
            let input = AudioBench.sine(frequency, levelDB: -40)
            let change = AudioBench.rmsDB(run(input, gentle)) - AudioBench.rmsDB(input)
            if abs(change) > abs(worst) { worst = change; worstFrequency = frequency }
        }
        #expect(abs(worst) < 0.2, "saturation changes \(worstFrequency) Hz by \(worst) dB")
    }

    @Test func truePeakLimiter() {
        // fs/4 at 45 degrees: samples read 3 dB under the true crest.
        let crest: Float = 1.2
        let input = (0..<Int(Self.rate * 2)).map { crest * Float(sin(.pi / 2 * Double($0) + .pi / 4)) }
        func limited(truePeak: Bool) -> Double {
            var samples = input
            AudioBench.limit(&samples, truePeak: truePeak)
            return VoiceAnalyzer.decibels(amplitude: TruePeakMeter.peak(Array(samples.dropFirst(4_800)), sampleRate: Self.rate))
        }
        let sampleBased = limited(truePeak: false)
        let truePeak = limited(truePeak: true)
        #expect(truePeak <= -0.9, "true-peak limiter let \(truePeak) dBTP through")
        print(String(format: "limiter on inter-sample peaks: %.2f dBTP with true-peak detection, %.2f dBTP sample-based", truePeak, sampleBased))
    }

    @Test func settingsCoding() throws {
        var settings = RecordingAudioSettings(voiceGainDB: 3)
        settings.voiceChain = .usbCondenser
        let decoded = try JSONDecoder().decode(RecordingAudioSettings.self, from: JSONEncoder().encode(settings))
        #expect(decoded == settings, "settings must round-trip")
        let phase3 = try JSONDecoder().decode(RecordingAudioSettings.self, from: Data(#"{"voiceGainDB":2,"systemGainDB":-6,"voiceProcessingEnabled":true}"#.utf8))
        #expect(phase3.voiceChain == VoiceChainSettings() && phase3.voiceGainDB == 2)
        let partial = try JSONDecoder().decode(VoiceChainSettings.self, from: Data(#"{"compressor":{"isEnabled":true,"ratio":4}}"#.utf8))
        #expect(partial.compressor.isEnabled && partial.compressor.ratio == 4 && partial.compressor.thresholdDB == -24)
        #expect(VoiceChainSettings.usbCondenser.matchingPreset == .usbCondenser && VoiceChainSettings().matchingPreset == .neutral)
    }

    // MARK: On the voice bank

    @Test(.enabled(if: AudioBench.isVoiceBankAvailable, Comment(rawValue: AudioBench.voiceBankMissing)))
    func bypassIsLevelMatched() throws {
        let take = try AudioBench.bankTake("paulina-usb-condenser-desk")
        let processed = run(take, .usbCondenser, enabled: true)
        let bypassed = run(take, .usbCondenser, enabled: false)
        let skip = Int(Self.rate * 3)
        let wet = AudioBench.loudness(Array(processed.dropFirst(skip)))
        let dry = AudioBench.loudness(Array(bypassed.dropFirst(skip)))
        #expect(abs(wet - dry) < 1, "bypass must match the processed loudness (\(wet) vs \(dry))")
        print(String(format: "A/B: processed %.1f LUFS, bypass %.1f LUFS: level-matched within %.2f LU", wet, dry, abs(wet - dry)))
    }

    @Test(.enabled(if: AudioBench.isVoiceBankAvailable, Comment(rawValue: AudioBench.voiceBankMissing)))
    func usbCondenserPresetOnTheBank() throws {
        var report = ["USB Condenser preset on the bank's USB-condenser takes (fader 0 dB, true-peak limiter)",
                      "take                 LUFS-I     TP   SNR  | body warmth   mud presence sibilance (dB per octave)"]
        for voice in ["paulina", "monica", "eddy"] {
            let take = try AudioBench.bankTake("\(voice)-usb-condenser-desk")
            var output = run(take, .usbCondenser)
            AudioBench.limit(&output)
            for (label, signal) in [("before", take), ("after", output)] {
                let m = VoiceAnalyzer.measure(channels: [signal], sampleRate: Self.rate)
                let bands = Dictionary(uniqueKeysWithValues: m.bands.map { ($0.name, $0.levelDB) })
                report.append(String(format: "%@ %@ %6.1f %6.1f %5.1f  | %5.1f %6.1f %5.1f %8.1f %9.1f",
                                     voice.padding(toLength: 8, withPad: " ", startingAt: 0),
                                     label.padding(toLength: 7, withPad: " ", startingAt: 0),
                                     m.integratedLUFS ?? 0, m.truePeakDBTP, m.signalToNoiseDB ?? 0,
                                     bands["body"] ?? 0, bands["warmth"] ?? 0, bands["mud"] ?? 0,
                                     bands["presence"] ?? 0, bands["sibilance"] ?? 0))
                if label == "after" {
                    #expect(m.truePeakDBTP <= -0.9 && m.clippedSamples == 0, "processed take must stay under the ceiling")
                }
            }
        }
        print(report.joined(separator: "\n"))
    }

    @Test(.enabled(if: AudioBench.isVoiceBankAvailable, Comment(rawValue: AudioBench.voiceBankMissing)))
    func performance() throws {
        let take = try AudioBench.bankTake("paulina-usb-condenser-desk")
        let start = Date()
        _ = run(take, .usbCondenser)
        let elapsed = Date().timeIntervalSince(start)
        let seconds = Double(take.count) / Self.rate
        print(String(format: "USB Condenser chain runs at %.0fx real time (%.1f s of audio in %.3f s, one core)", seconds / elapsed, seconds, elapsed))
    }

    // MARK: Helpers

    func run(_ input: [Float], _ settings: VoiceChainSettings, enabled: Bool = true) -> [Float] {
        AudioBench.run(input, settings, enabled: enabled)
    }

    func gainDB(of settings: VoiceChainSettings, frequency: Double) -> Double {
        AudioBench.peakDB(run(AudioBench.sine(frequency, levelDB: -20, seconds: 2), settings)) + 20
    }
}

func expectNear(
    _ value: Double, _ target: Double, _ tolerance: Double, _ what: String,
    sourceLocation: SourceLocation = #_sourceLocation
) {
    #expect(abs(value - target) <= tolerance, "\(what): expected \(target), got \(value)", sourceLocation: sourceLocation)
}
