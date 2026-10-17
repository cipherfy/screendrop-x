import AVFoundation
import Foundation

// Compile with the chain, the tap code, and the meter:
//
//   xcrun swiftc -O Screendrop/VoiceChain.swift Screendrop/RecordingAudioProcessing.swift Screendrop/VoiceProfile.swift \
//     Screendrop/VoiceMeasurement.swift scripts/check-voice-chain.swift -o build/check-voice-chain
//   build/check-voice-chain build/voice-bank/variants
//
// Checks each stage of the voice chain against signals with known answers,
// then runs the voice bank's USB-condenser takes through the USB Condenser
// preset and reports what changed.
@main
struct VoiceChainCheck {
    static let rate = 48_000.0
    static let latency = VoiceChainProcessor.latency

    static func main() throws {
        setvbuf(stdout, nil, _IONBF, 0)
        guard CommandLine.arguments.count == 2 else {
            print("usage: check-voice-chain <voice bank variants directory>")
            exit(2)
        }
        let variants = URL(fileURLWithPath: CommandLine.arguments[1])

        checkTransparency()
        checkHighPass()
        checkEqualizer()
        checkCompressor()
        checkExpander()
        checkDeEsser()
        checkDynamicLow()
        checkSaturation()
        checkTruePeakLimiter()
        try checkSettingsCoding()
        try checkBypass(variants.appendingPathComponent("paulina-usb-condenser-desk.wav"))
        try reportBank(variants)
        try checkPerformance(variants.appendingPathComponent("paulina-usb-condenser-desk.wav"))
        print("all voice chain checks passed")
    }

    // MARK: Stages

    static func checkTransparency() {
        let input = noise(seconds: 2, level: 0.3)
        let output = run(input, .flat)
        let error = errorRatio(reference: input, decoded: output)
        precondition(error < -120, "flat chain must be transparent (\(error) dB)")
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
            precondition(peak == 1_000, "\(label) path is off by \(peak - 1_000) frames")
        }
        print(String(format: "ok  flat chain is transparent (%.0f dB); delay, oversampler, and bypass all land at %d frames", error, latency))
    }

    static func checkHighPass() {
        var gentle = VoiceChainSettings.flat
        gentle.highPass = .init(isEnabled: true, frequency: 80, isSteep: false)
        let atCorner = gainDB(of: gentle, frequency: 40)
        let passband = gainDB(of: gentle, frequency: 1_000)
        expect(atCorner, -12.3, 0.2, "12 dB/oct high-pass an octave below 80 Hz")
        expect(passband, 0, 0.05, "high-pass passband at 1 kHz")

        var steep = VoiceChainSettings.flat
        steep.highPass = .init(isEnabled: true, frequency: 90, isSteep: true)
        expect(gainDB(of: steep, frequency: 45), -24.1, 0.3, "24 dB/oct high-pass an octave below 90 Hz")
        print(String(format: "ok  high-pass: %.1f dB at 40 Hz (12 dB/oct), %.1f dB at 45 Hz (24 dB/oct), %.2f dB at 1 kHz",
                     atCorner, gainDB(of: steep, frequency: 45), passband))
    }

    static func checkEqualizer() {
        var settings = VoiceChainSettings.flat
        settings.presence = .init(kind: .peak, frequency: 4_500, gainDB: 6, q: 1.4)
        settings.lowShelf = .init(kind: .lowShelf, frequency: 150, gainDB: 4, q: 0.7)
        settings.lowMid = .init(kind: .peak, frequency: 300, gainDB: -3, q: 1.2)
        let presence = gainDB(of: settings, frequency: 4_500)
        let shelf = gainDB(of: settings, frequency: 40)
        let mud = gainDB(of: settings, frequency: 300)
        expect(presence, 6, 0.15, "presence bell")
        expect(shelf, 4, 0.4, "low shelf below its corner")
        expect(mud, -3, 0.3, "mud cut")
        print(String(format: "ok  EQ: +%.2f dB at 4.5 kHz, %+.2f dB at 40 Hz (shelf), %+.2f dB at 300 Hz", presence, shelf, mud))
    }

    static func checkCompressor() {
        var settings = VoiceChainSettings.flat
        settings.compressor = .init(isEnabled: true, thresholdDB: -24, ratio: 3, kneeDB: 0,
                                    attackMilliseconds: 5, releaseMilliseconds: 50, makeupDB: 0)
        let loud = peakDB(run(sine(1_000, levelDB: -6), settings))
        let quiet = peakDB(run(sine(1_000, levelDB: -30), settings))
        expect(loud, -18, 1, "3:1 at -24 dB: -6 dBFS in reads about -18 out")
        expect(quiet, -30, 0.1, "below threshold is untouched")
        print(String(format: "ok  compressor 3:1 @ -24 dB: -6 dBFS in -> %.1f dBFS out, -30 dBFS in -> %.1f out", loud, quiet))
    }

    static func checkExpander() {
        var settings = VoiceChainSettings.flat
        settings.expander = .init(isEnabled: true, thresholdDB: -45, ratio: 2, rangeDB: 8, releaseMilliseconds: 150)
        let speech = peakDB(run(sine(300, levelDB: -20), settings))
        let room = peakDB(run(sine(300, levelDB: -50), settings))
        let silence = peakDB(run(sine(300, levelDB: -70), settings))
        expect(speech, -20, 0.1, "expander leaves speech level alone")
        expect(room, -55, 0.5, "2:1 expander: 5 dB under the threshold goes 5 dB further down")
        expect(silence, -78, 0.5, "expander stops at its range")
        print(String(format: "ok  expander 2:1 @ -45 dB: -20 -> %.1f, -50 -> %.1f, -70 -> %.1f (range 8 dB)", speech, room, silence))
    }

    static func checkDeEsser() {
        var settings = VoiceChainSettings.flat
        settings.deEsser = .init(isEnabled: true, frequency: 6_500, thresholdDB: -32, rangeDB: 8)
        let sibilant = peakDB(run(sine(6_500, levelDB: -10), settings))
        let voiced = peakDB(run(sine(500, levelDB: -10), settings))
        expect(sibilant, -18, 1, "de-esser cuts a loud 6.5 kHz tone by its full range")
        expect(voiced, -10, 0.3, "de-esser leaves 500 Hz alone")
        print(String(format: "ok  de-esser: 6.5 kHz at -10 dBFS -> %.1f, 500 Hz at -10 -> %.1f", sibilant, voiced))
    }

    static func checkDynamicLow() {
        var settings = VoiceChainSettings.flat
        settings.dynamicLow = .init(isEnabled: true, frequency: 140, q: 1, thresholdDB: -28, rangeDB: 4)
        let boom = peakDB(run(sine(140, levelDB: -10), settings))
        let soft = peakDB(run(sine(140, levelDB: -40), settings))
        expect(boom, -14, 0.6, "dynamic band cuts loud 140 Hz by its range")
        expect(soft, -40, 0.2, "dynamic band leaves quiet 140 Hz alone")
        print(String(format: "ok  dynamic low band: loud 140 Hz -> %.1f dB (cut 4), quiet -> %.1f dB (untouched)", boom, soft))
    }

    static func checkSaturation() {
        func saturated(warmth: Double) -> VoiceChainSettings {
            var settings = VoiceChainSettings.flat
            settings.saturation = .init(isEnabled: true, driveDB: 12, mix: 1, warmth: warmth)
            return settings
        }
        let tone = sine(1_000, levelDB: -6)
        let odd = run(tone, saturated(warmth: 0))
        let warm = run(tone, saturated(warmth: 0.6))
        let thirdOdd = level(odd, at: 3_000) - level(odd, at: 1_000)
        let secondOdd = level(odd, at: 2_000) - level(odd, at: 1_000)
        let secondWarm = level(warm, at: 2_000) - level(warm, at: 1_000)
        precondition(thirdOdd > -40, "saturation must add harmonics")
        precondition(secondWarm > secondOdd + 20, "warmth must add even harmonics")
        print(String(format: "ok  saturation: 3rd harmonic %.0f dB; 2nd harmonic %.0f dB plain, %.0f dB with warmth", thirdOdd, secondOdd, secondWarm))

        // Aliasing: 9 kHz driven hard. Its 3rd, 5th, and 7th harmonics
        // (27, 45, 63 kHz) fold to 21, 3, and 15 kHz at 48 kHz.
        let high = sine(9_000, levelDB: -3)
        let oversampled = run(high, saturated(warmth: 0))
        let drive = pow(10, 12.0 / 20)
        let naive = high.map { Float(tanh(drive * Double($0)) / drive) }
        func aliases(_ signal: [Float]) -> Double {
            let fundamental = level(signal, at: 9_000)
            return [3_000.0, 15_000, 21_000].map { level(signal, at: $0) - fundamental }.max()!
        }
        let oversampledAlias = aliases(oversampled)
        let naiveAlias = aliases(naive)
        precondition(oversampledAlias < naiveAlias - 25, "oversampling must suppress aliasing")
        print(String(format: "ok  aliasing from 9 kHz driven hard: %.0f dB with 4x oversampling, %.0f dB without", oversampledAlias, naiveAlias))
    }

    static func checkTruePeakLimiter() {
        // fs/4 at 45 degrees: samples read 3 dB under the true crest.
        let crest: Float = 1.2
        let input = (0..<Int(rate * 2)).map { crest * Float(sin(.pi / 2 * Double($0) + .pi / 4)) }
        func limited(truePeak: Bool) -> Double {
            var limiter = PeakLimiter(sampleRate: rate, channelCount: 1, ceilingDB: -1, detectsTruePeak: truePeak)
            var samples = input
            samples.withUnsafeMutableBufferPointer { limiter.process(interleaved: $0.baseAddress!, frameCount: $0.count) }
            return VoiceAnalyzer.decibels(amplitude: TruePeakMeter.peak(Array(samples.dropFirst(4_800)), sampleRate: rate))
        }
        let sampleBased = limited(truePeak: false)
        let truePeak = limited(truePeak: true)
        precondition(truePeak <= -0.9, "true-peak limiter let \(truePeak) dBTP through")
        print(String(format: "ok  limiter on inter-sample peaks: %.2f dBTP with true-peak detection, %.2f dBTP sample-based", truePeak, sampleBased))
    }

    static func checkSettingsCoding() throws {
        var settings = RecordingAudioSettings(voiceGainDB: 3)
        settings.voiceChain = .usbCondenser
        let decoded = try JSONDecoder().decode(RecordingAudioSettings.self, from: JSONEncoder().encode(settings))
        precondition(decoded == settings, "settings must round-trip")
        let phase3 = try JSONDecoder().decode(RecordingAudioSettings.self, from: Data(#"{"voiceGainDB":2,"systemGainDB":-6,"voiceProcessingEnabled":true}"#.utf8))
        precondition(phase3.voiceChain == VoiceChainSettings() && phase3.voiceGainDB == 2)
        let partial = try JSONDecoder().decode(VoiceChainSettings.self, from: Data(#"{"compressor":{"isEnabled":true,"ratio":4}}"#.utf8))
        precondition(partial.compressor.isEnabled && partial.compressor.ratio == 4 && partial.compressor.thresholdDB == -24)
        precondition(VoiceChainSettings.usbCondenser.matchingPreset == .usbCondenser && VoiceChainSettings().matchingPreset == .neutral)
        print("ok  settings round-trip; older and partial documents fill in defaults; presets are recognized")
    }

    // MARK: A/B

    static func checkBypass(_ url: URL) throws {
        let take = try readMono(url)
        let processed = run(take, .usbCondenser, enabled: true)
        let bypassed = run(take, .usbCondenser, enabled: false)
        let skip = Int(rate * 3)
        let wet = loudness(Array(processed.dropFirst(skip)))
        let dry = loudness(Array(bypassed.dropFirst(skip)))
        let raw = loudness(Array(take.dropFirst(skip)))
        precondition(abs(wet - dry) < 1, "bypass must match the processed loudness (\(wet) vs \(dry))")
        print(String(format: "ok  A/B: processed %.1f LUFS, bypass %.1f LUFS (raw take %.1f): level-matched within %.2f LU",
                     wet, dry, raw, abs(wet - dry)))
    }

    static func reportBank(_ directory: URL) throws {
        print("\nUSB Condenser preset on the bank's USB-condenser takes (fader 0 dB, true-peak limiter)")
        print("take                 LUFS-I     TP   SNR  | body warmth   mud presence sibilance (dB per octave)")
        for voice in ["paulina", "monica", "eddy"] {
            let url = directory.appendingPathComponent("\(voice)-usb-condenser-desk.wav")
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            let take = try readMono(url)
            var output = run(take, .usbCondenser)
            var limiter = PeakLimiter(sampleRate: rate, channelCount: 1, ceilingDB: -1, detectsTruePeak: true)
            output.withUnsafeMutableBufferPointer { limiter.process(interleaved: $0.baseAddress!, frameCount: $0.count) }
            for (label, signal) in [("before", take), ("after", output)] {
                let m = VoiceAnalyzer.measure(channels: [signal], sampleRate: rate)
                let bands = Dictionary(uniqueKeysWithValues: m.bands.map { ($0.name, $0.levelDB) })
                print(String(format: "%@ %@ %6.1f %6.1f %5.1f  | %5.1f %6.1f %5.1f %8.1f %9.1f",
                             voice.padding(toLength: 8, withPad: " ", startingAt: 0),
                             label.padding(toLength: 7, withPad: " ", startingAt: 0),
                             m.integratedLUFS ?? 0, m.truePeakDBTP, m.signalToNoiseDB ?? 0,
                             bands["body"] ?? 0, bands["warmth"] ?? 0, bands["mud"] ?? 0,
                             bands["presence"] ?? 0, bands["sibilance"] ?? 0))
                if label == "after" {
                    precondition(m.truePeakDBTP <= -0.9 && m.clippedSamples == 0, "processed take must stay under the ceiling")
                }
            }
        }
        print("")
    }

    static func checkPerformance(_ url: URL) throws {
        let take = try readMono(url)
        let start = Date()
        _ = run(take, .usbCondenser)
        let elapsed = Date().timeIntervalSince(start)
        let seconds = Double(take.count) / rate
        print(String(format: "ok  USB Condenser chain runs at %.0fx real time (%.1f s of audio in %.3f s, one core)", seconds / elapsed, seconds, elapsed))
    }

    // MARK: Helpers

    /// Runs the chain in 512-frame buffers, as a tap would, and removes its
    /// latency so the output lines up with the input.
    static func run(_ input: [Float], _ settings: VoiceChainSettings, enabled: Bool = true) -> [Float] {
        var processor = VoiceChainProcessor(sampleRate: rate, channelCount: 1)
        processor.apply(settings, version: 1)
        var buffer = input + [Float](repeating: 0, count: latency)
        buffer.withUnsafeMutableBufferPointer { pointer in
            var start = 0
            while start < pointer.count {
                let count = min(512, pointer.count - start)
                processor.process(
                    frameCount: count, enabled: enabled,
                    read: { frame, _ in pointer[start + frame] },
                    write: { frame, _, value in pointer[start + frame] = value }
                )
                start += count
            }
        }
        return Array(buffer.dropFirst(latency))
    }

    static func sine(_ frequency: Double, levelDB: Double, seconds: Double = 2) -> [Float] {
        let amplitude = pow(10, levelDB / 20)
        return (0..<Int(rate * seconds)).map { Float(amplitude * sin(2 * .pi * frequency * Double($0) / rate)) }
    }

    static func noise(seconds: Double, level: Float) -> [Float] {
        var generator = SystemRandomNumberGenerator()
        return (0..<Int(rate * seconds)).map { _ in Float.random(in: -level...level, using: &generator) }
    }

    /// Steady-state peak after the first half second.
    static func peakDB(_ signal: [Float]) -> Double {
        VoiceAnalyzer.decibels(amplitude: Double(signal.dropFirst(Int(rate / 2)).map(abs).max() ?? 0))
    }

    static func gainDB(of settings: VoiceChainSettings, frequency: Double) -> Double {
        peakDB(run(sine(frequency, levelDB: -20, seconds: 2), settings)) + 20
    }

    /// Hann-windowed single-bin DFT level, in dB.
    static func level(_ signal: [Float], at frequency: Double) -> Double {
        let samples = Array(signal.dropFirst(Int(rate / 2)).prefix(Int(rate)))
        var re = 0.0, im = 0.0
        let n = Double(samples.count)
        for (index, value) in samples.enumerated() {
            let w = 0.5 - 0.5 * cos(2 * .pi * Double(index) / (n - 1))
            let phase = 2 * .pi * frequency * Double(index) / rate
            re += Double(value) * w * cos(phase)
            im += Double(value) * w * sin(phase)
        }
        return 10 * log10(max(1e-30, re * re + im * im))
    }

    static func loudness(_ signal: [Float]) -> Double {
        VoiceAnalyzer.measure(channels: [signal], sampleRate: rate).integratedLUFS ?? -.infinity
    }

    static func errorRatio(reference: [Float], decoded: [Float]) -> Double {
        let count = min(reference.count, decoded.count)
        var signal = 0.0, error = 0.0
        for index in 0..<count {
            let difference = Double(decoded[index] - reference[index])
            signal += Double(reference[index] * reference[index])
            error += difference * difference
        }
        return error > 0 ? 10 * log10(error / signal) : -200
    }

    static func expect(_ value: Double, _ target: Double, _ tolerance: Double, _ what: String) {
        precondition(abs(value - target) <= tolerance, "\(what): expected \(target), got \(value)")
    }

    static func readMono(_ url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let buffer = try file.readAll()
        return Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
    }
}

extension AVAudioFile {
    /// Reads the whole file. A single `read(into:)` can stop short of the
    /// end, so this keeps reading until the file reports no more frames.
    func readAll() throws -> AVAudioPCMBuffer {
        let all = AVAudioPCMBuffer(pcmFormat: processingFormat, frameCapacity: AVAudioFrameCount(max(1, length)))!
        let chunk = AVAudioPCMBuffer(pcmFormat: processingFormat, frameCapacity: 65_536)!
        framePosition = 0
        while framePosition < length {
            try read(into: chunk, frameCount: min(chunk.frameCapacity, AVAudioFrameCount(length - framePosition)))
            guard chunk.frameLength > 0 else { break }
            for channel in 0..<Int(processingFormat.channelCount) {
                (all.floatChannelData![channel] + Int(all.frameLength))
                    .update(from: chunk.floatChannelData![channel], count: Int(chunk.frameLength))
            }
            all.frameLength += chunk.frameLength
        }
        return all
    }
}
