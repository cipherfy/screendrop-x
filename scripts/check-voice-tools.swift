import AVFoundation
import Foundation

// Compile with the chain, the tap code, the meter, and the mic check:
//
//   xcrun swiftc -O Screendrop/VoiceChain.swift Screendrop/RecordingAudioProcessing.swift \
//     Screendrop/VoiceProfile.swift Screendrop/VoiceMeasurement.swift Screendrop/MicrophoneCheckAnalyzer.swift \
//     scripts/check-voice-tools.swift -o build/check-voice-tools
//   build/check-voice-tools build/voice-bank/variants
//
// Checks what Studio shows about the voice: the EQ curve against what the
// chain really does, the live meters against the offline meter, the gain
// reduction the chain reports, the custom chain, and the microphone check's
// advice for takes with known problems.
@main
struct VoiceToolsCheck {
    static let rate = 48_000.0

    static func main() throws {
        setvbuf(stdout, nil, _IONBF, 0)
        guard CommandLine.arguments.count == 2 else {
            print("usage: check-voice-tools <voice bank variants directory>")
            exit(2)
        }
        let variants = URL(fileURLWithPath: CommandLine.arguments[1])
        checkResponseCurve()
        checkShortTermLoudness()
        checkReductionReadouts()
        checkMeterSnapshot()
        checkCustomChain()
        try checkMicrophoneAdvice(variants)
        print("all voice tool checks passed")
    }

    /// The drawn curve must be what plays: compare it with sine gains
    /// measured through the processor for a busy chain.
    static func checkResponseCurve() {
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
            let input = sine(frequency, -20)
            let measured = rmsDB(run(input, chain)) - rmsDB(input)
            worst = max(worst, abs(measured - chain.responseDB(at: frequency)))
        }
        precondition(worst < 0.1, "curve and chain disagree by \(worst) dB")
        print(String(format: "ok  EQ curve matches the chain's measured response within %.3f dB from 60 Hz to 12 kHz", worst))
    }

    /// Live short-term loudness against the offline meter on the same tone.
    static func checkShortTermLoudness() {
        let tone = sine(1_000, -20, seconds: 5)
        var meter = ShortTermLoudness(sampleRate: rate, channelCount: 1)
        tone.withUnsafeBufferPointer { pointer in
            var start = 0
            while start < pointer.count {
                let count = min(512, pointer.count - start)
                meter.process(frameCount: count) { frame, _ in pointer[start + frame] }
                start += count
            }
        }
        let offline = LoudnessMeter.measure(channels: [tone], sampleRate: rate).shortTermMax ?? 0
        let live = meter.lufs ?? 0
        precondition(abs(live - offline) < 0.05, "live \(live) vs offline \(offline)")
        print(String(format: "ok  live short-term loudness %.2f LUFS matches the offline meter (%.2f)", live, offline))
    }

    /// The meters read gain reduction from the processor; it must match the
    /// static curves.
    static func checkReductionReadouts() {
        var settings = VoiceChainSettings.flat
        settings.compressor = .init(isEnabled: true, thresholdDB: -24, ratio: 3, kneeDB: 0,
                                    attackMilliseconds: 5, releaseMilliseconds: 50, makeupDB: 0)
        var processor = VoiceChainProcessor(sampleRate: rate, channelCount: 1)
        processor.apply(settings, version: 1)
        var tone = sine(1_000, -6)
        tone.withUnsafeMutableBufferPointer { pointer in
            processor.process(frameCount: pointer.count, enabled: true,
                              read: { frame, _ in pointer[frame] },
                              write: { frame, _, value in pointer[frame] = value })
        }
        precondition(abs(processor.compressorReductionDB + 12) < 0.5, "compressor reports \(processor.compressorReductionDB)")
        precondition(processor.expanderReductionDB == 0 && processor.deEsserReductionDB == 0)

        var limiter = PeakLimiter(sampleRate: rate, channelCount: 1, ceilingDB: -1, detectsTruePeak: true)
        var loud = sine(1_000, 0)
        loud.withUnsafeMutableBufferPointer { limiter.process(interleaved: $0.baseAddress!, frameCount: $0.count) }
        precondition(abs(limiter.gainReductionDB + 1.1) < 0.2, "limiter reports \(limiter.gainReductionDB)")
        print(String(format: "ok  gain reduction readouts: compressor %.1f dB (3:1, 18 dB over), limiter %.1f dB on a full-scale tone",
                     processor.compressorReductionDB, limiter.gainReductionDB))
    }

    static func checkMeterSnapshot() {
        let meters = RecordingAudioMeters()
        let before = meters.snapshot()
        precondition(before.shortTermLUFS == nil && before.inputPeakDB == -120)
        meters.store(inputPeak: 0.5, outputPeak: 0.25, expanderDB: -3, compressorDB: -6, deEsserDB: -2,
                     limiterDB: -1, shortTermLUFS: -16)
        let after = meters.snapshot()
        precondition(abs(after.inputPeakDB + 6.02) < 0.01 && abs(after.outputPeakDB + 12.04) < 0.01)
        precondition(after.compressorDB == -6 && after.shortTermLUFS == -16 && after.sequence == before.sequence + 1)
        print("ok  meter snapshots carry levels, reductions, loudness, and a sequence that shows playback is live")
    }

    static func checkCustomChain() {
        var profile = VoiceProfileSettings(microphone: .usbCondenser, character: .broadcast)
        var custom = VoiceProfileResolver.chain(for: profile, analysis: nil)
        custom.compressor.ratio = 6
        profile.customChain = custom
        precondition(VoiceProfileResolver.chain(for: profile, analysis: nil) == custom)
        profile.character = .warm
        precondition(VoiceProfileResolver.chain(for: profile, analysis: nil).compressor.ratio == 6, "a custom chain ignores the character")
        profile.customChain = nil
        precondition(VoiceProfileResolver.chain(for: profile, analysis: nil).compressor.ratio != 6)
        print("ok  a custom chain stands in for the profile until reset")
    }

    // MARK: Microphone check

    static func checkMicrophoneAdvice(_ directory: URL) throws {
        let take = try read(directory.appendingPathComponent("paulina-clean.wav"))
        let hot = try read(directory.appendingPathComponent("paulina-hot.wav"))
        let speech = Array(take.prefix(Int(rate * 6)))
        let room = pink(seconds: 2.2, rmsDB: -72)
        func scaled(_ samples: [Float], peakDB: Double) -> [Float] {
            let peak = Double(samples.map(abs).max() ?? 1)
            let gain = Float(pow(10, peakDB / 20) / peak)
            return samples.map { $0 * gain }
        }

        let cases: [(String, [Float], [Float], [String], Bool)] = [
            ("good take", room, scaled(speech, peakDB: -9), ["Level is right", "Quiet room"], true),
            ("quiet gain", room, scaled(speech, peakDB: -30), ["Too quiet"], false),
            ("clipping", room, Array(hot.prefix(Int(rate * 6))), ["Too loud: the voice clips"], false),
            ("hot but clean", room, scaled(speech, peakDB: -3), ["A little hot"], true),
            ("noisy room", pink(seconds: 2.2, rmsDB: -40), scaled(speech, peakDB: -9), ["Noisy room"], false),
            ("mains hum", mix(hum(seconds: 2.2, levelDB: -55), pink(seconds: 2.2, rmsDB: -80)), scaled(speech, peakDB: -9), ["Mains hum"], true),
            ("muted mic", pink(seconds: 2.2, rmsDB: -90), pink(seconds: 6, rmsDB: -85), ["No voice detected"], false)
        ]
        for (label, silence, voice, expected, ready) in cases {
            let result = MicrophoneCheckAnalyzer.evaluate(silence: silence, speech: voice, sampleRate: rate)
            let titles = result.findings.map(\.title)
            for title in expected {
                precondition(titles.contains(title), "\(label): expected “\(title)”, got \(titles)")
            }
            precondition(result.isReady == ready, "\(label): ready should be \(ready), got \(titles)")
            print("    \(label.padding(toLength: 14, withPad: " ", startingAt: 0)) \(ready ? "ready" : "fix  ")  \(titles.joined(separator: " · "))")
        }
        print("ok  the microphone check gives the right advice for each problem")
    }

    // MARK: Helpers

    static func run(_ input: [Float], _ settings: VoiceChainSettings) -> [Float] {
        var processor = VoiceChainProcessor(sampleRate: rate, channelCount: 1)
        processor.apply(settings, version: 1)
        var buffer = input
        buffer.withUnsafeMutableBufferPointer { pointer in
            processor.process(frameCount: pointer.count, enabled: true,
                              read: { frame, _ in pointer[frame] },
                              write: { frame, _, value in pointer[frame] = value })
        }
        return buffer
    }

    static func sine(_ frequency: Double, _ levelDB: Double, seconds: Double = 2) -> [Float] {
        let amplitude = pow(10, levelDB / 20)
        return (0..<Int(rate * seconds)).map { Float(amplitude * sin(2 * .pi * frequency * Double($0) / rate)) }
    }

    static func rmsDB(_ signal: [Float]) -> Double {
        let steady = signal.dropFirst(Int(rate / 2))
        let meanSquare = steady.reduce(0.0) { $0 + Double($1 * $1) } / Double(steady.count)
        return VoiceAnalyzer.decibels(amplitude: meanSquare.squareRoot())
    }

    static func peakDB(_ signal: [Float]) -> Double {
        VoiceAnalyzer.decibels(amplitude: Double(signal.dropFirst(Int(rate / 2)).map(abs).max() ?? 0))
    }

    static func pink(seconds: Double, rmsDB: Double) -> [Float] {
        var generator = SystemRandomNumberGenerator()
        var b = [Float](repeating: 0, count: 6)
        var output = (0..<Int(rate * seconds)).map { _ -> Float in
            let white = Float.random(in: -1...1, using: &generator)
            b[0] = 0.99886 * b[0] + white * 0.0555179
            b[1] = 0.99332 * b[1] + white * 0.0750759
            b[2] = 0.96900 * b[2] + white * 0.1538520
            b[3] = 0.86650 * b[3] + white * 0.3104856
            b[4] = 0.55000 * b[4] + white * 0.5329522
            b[5] = -0.7616 * b[5] - white * 0.0168980
            return b.reduce(0, +) + white * 0.5362
        }
        let rms = (output.reduce(0) { $0 + $1 * $1 } / Float(output.count)).squareRoot()
        let gain = Float(pow(10, rmsDB / 20)) / rms
        output = output.map { $0 * gain }
        return output
    }

    static func hum(seconds: Double, levelDB: Double) -> [Float] {
        let level = pow(10, levelDB / 20)
        return (0..<Int(rate * seconds)).map { index in
            let t = Double(index) / rate
            return Float(level * (sin(2 * .pi * 60 * t) + 0.5 * sin(2 * .pi * 120 * t) + 0.3 * sin(2 * .pi * 180 * t)))
        }
    }

    static func mix(_ a: [Float], _ b: [Float]) -> [Float] {
        zip(a, b).map(+)
    }

    static func read(_ url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let all = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
        let chunk = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 65_536)!
        while file.framePosition < file.length {
            try file.read(into: chunk, frameCount: min(chunk.frameCapacity, AVAudioFrameCount(file.length - file.framePosition)))
            guard chunk.frameLength > 0 else { break }
            (all.floatChannelData![0] + Int(all.frameLength)).update(from: chunk.floatChannelData![0], count: Int(chunk.frameLength))
            all.frameLength += chunk.frameLength
        }
        return Array(UnsafeBufferPointer(start: all.floatChannelData![0], count: Int(all.frameLength)))
    }
}
