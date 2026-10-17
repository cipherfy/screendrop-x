//
//  VoiceMeasurement.swift
//  Screendrop
//
//  Loudness (ITU-R BS.1770-4 / EBU R128), true peak, noise floor, and
//  spectral balance for narration audio. Foundation and Accelerate only,
//  so the voice bank tool (scripts/voice-bank.swift) compiles this file
//  as-is and measures exactly what the app measures.
//

import Accelerate
import Foundation

nonisolated struct VoiceMeasurement: Codable, Sendable {
    struct Band: Codable, Sendable {
        let name: String
        let lowHz: Double
        let highHz: Double
        /// Energy per octave relative to the 100 Hz-10 kHz average, in dB.
        /// Zero everywhere would be a pink-balanced voice.
        let levelDB: Double
    }

    struct SpectrumPoint: Codable, Sendable {
        let centerHz: Double
        let levelDB: Double
    }

    var sampleRate: Double
    var channelCount: Int
    var duration: Double
    /// Nil when nothing in the file clears the -70 LUFS absolute gate.
    var integratedLUFS: Double?
    var momentaryMaxLUFS: Double?
    var shortTermMaxLUFS: Double?
    var loudnessRangeLU: Double?
    var samplePeakDBFS: Double
    var truePeakDBTP: Double
    /// 95th percentile of 50 ms RMS blocks: how loud speech sits.
    var speechLevelDBFS: Double
    /// 10th percentile of 50 ms RMS blocks: the room between words.
    var noiseFloorDBFS: Double
    /// Samples inside runs of three or more at full scale.
    var clippedSamples: Int
    var dcOffset: Double
    var bands: [Band]
    var thirdOctave: [SpectrumPoint]

    /// Nil when the pauses are digital silence, where the ratio means nothing.
    var signalToNoiseDB: Double? {
        noiseFloorDBFS > -140 ? speechLevelDBFS - noiseFloorDBFS : nil
    }
}

nonisolated enum VoiceAnalyzer {
    static let silenceDB = -150.0

    /// `channels` holds one non-interleaved sample array per channel.
    static func measure(channels: [[Float]], sampleRate: Double) -> VoiceMeasurement {
        let frameCount = channels.map(\.count).min() ?? 0
        let mono = mixdown(channels, frameCount: frameCount)
        let loudness = LoudnessMeter.measure(channels: channels, sampleRate: sampleRate)
        let levels = blockLevels(mono, sampleRate: sampleRate)
        let spectrum = SpectrumAnalyzer.measure(mono, sampleRate: sampleRate)

        let samplePeak = channels.map { channel in
            channel.isEmpty ? 0 : Double(vDSP.maximumMagnitude(channel))
        }.max() ?? 0
        let truePeak = channels.map { TruePeakMeter.peak($0, sampleRate: sampleRate) }.max() ?? 0

        return VoiceMeasurement(
            sampleRate: sampleRate,
            channelCount: channels.count,
            duration: Double(frameCount) / sampleRate,
            integratedLUFS: loudness.integrated,
            momentaryMaxLUFS: loudness.momentaryMax,
            shortTermMaxLUFS: loudness.shortTermMax,
            loudnessRangeLU: loudness.range,
            samplePeakDBFS: decibels(amplitude: samplePeak),
            truePeakDBTP: decibels(amplitude: max(truePeak, samplePeak)),
            speechLevelDBFS: percentile(levels, 0.95) ?? silenceDB,
            noiseFloorDBFS: percentile(levels, 0.10) ?? silenceDB,
            clippedSamples: channels.map(clippedSampleCount).reduce(0, +),
            dcOffset: mono.isEmpty ? 0 : Double(vDSP.mean(mono)),
            bands: spectrum.bands,
            thirdOctave: spectrum.thirdOctave
        )
    }

    static func decibels(amplitude: Double) -> Double {
        amplitude > 0 ? max(silenceDB, 20 * log10(amplitude)) : silenceDB
    }

    static func decibels(power: Double) -> Double {
        power > 0 ? max(silenceDB, 10 * log10(power)) : silenceDB
    }

    static func percentile(_ values: [Double], _ fraction: Double) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let index = Int((Double(sorted.count - 1) * fraction).rounded())
        return sorted[min(sorted.count - 1, max(0, index))]
    }

    private static func mixdown(_ channels: [[Float]], frameCount: Int) -> [Float] {
        guard let first = channels.first else { return [] }
        guard channels.count > 1 else { return Array(first.prefix(frameCount)) }
        var mix = [Float](repeating: 0, count: frameCount)
        for channel in channels {
            mix = vDSP.add(mix, channel.prefix(frameCount))
        }
        return vDSP.multiply(1 / Float(channels.count), mix)
    }

    /// 50 ms RMS levels in dBFS, the resolution at which gaps between
    /// words show up as noise floor rather than averaging into speech.
    private static func blockLevels(_ mono: [Float], sampleRate: Double) -> [Double] {
        let block = max(1, Int(sampleRate * 0.05))
        guard mono.count >= block else { return [] }
        return stride(from: 0, through: mono.count - block, by: block).map { start in
            let rms = vDSP.rootMeanSquare(mono[start..<(start + block)])
            return decibels(amplitude: Double(rms))
        }
    }

    private static func clippedSampleCount(_ channel: [Float]) -> Int {
        var total = 0
        var run = 0
        for sample in channel {
            if abs(sample) >= 0.999 {
                run += 1
            } else {
                if run >= 3 { total += run }
                run = 0
            }
        }
        return run >= 3 ? total + run : total
    }
}

// MARK: - Loudness

nonisolated enum LoudnessMeter {
    struct Result: Sendable {
        var integrated: Double?
        var momentaryMax: Double?
        var shortTermMax: Double?
        var range: Double?
    }

    /// Channel weights are 1.0 for mono and stereo, so a mono file reads
    /// about 3 LU lower than the same signal as dual-mono stereo.
    static func measure(channels: [[Float]], sampleRate: Double) -> Result {
        let segmentLength = Int((sampleRate * 0.1).rounded())
        let frameCount = channels.map(\.count).min() ?? 0
        guard segmentLength > 0, frameCount >= segmentLength * 4 else { return Result() }
        let segmentCount = frameCount / segmentLength

        // Sum of K-weighted squares per 100 ms segment, across channels.
        // Momentary (400 ms) and short-term (3 s) windows are sums of these.
        var segments = [Double](repeating: 0, count: segmentCount)
        for channel in channels {
            var filter = KWeightingFilter(sampleRate: sampleRate)
            for segment in 0..<segmentCount {
                var sum = 0.0
                let start = segment * segmentLength
                for index in start..<(start + segmentLength) {
                    let y = filter.process(Double(channel[index]))
                    sum += y * y
                }
                segments[segment] += sum
            }
        }

        let momentary = windows(segments, length: 4, segmentLength: segmentLength)
        let shortTerm = windows(segments, length: 30, segmentLength: segmentLength)

        var result = Result()
        result.momentaryMax = momentary.max().map(loudness)
        result.shortTermMax = shortTerm.max().map(loudness)

        // Integrated: absolute gate at -70 LUFS, then a relative gate 10 LU
        // below the loudness of what survived.
        let absoluteGated = momentary.filter { loudness($0) > -70 }
        if !absoluteGated.isEmpty {
            let relativeGate = loudness(mean(absoluteGated)) - 10
            let gated = absoluteGated.filter { loudness($0) > relativeGate }
            if !gated.isEmpty {
                result.integrated = loudness(mean(gated))
            }
        }

        // Loudness range (EBU Tech 3342): spread between the 10th and 95th
        // percentiles of short-term loudness, relative gate 20 LU.
        let shortTermGated = shortTerm.filter { loudness($0) > -70 }
        if !shortTermGated.isEmpty {
            let relativeGate = loudness(mean(shortTermGated)) - 20
            let values = shortTermGated.map(loudness).filter { $0 > relativeGate }
            if let low = VoiceAnalyzer.percentile(values, 0.10),
               let high = VoiceAnalyzer.percentile(values, 0.95) {
                result.range = high - low
            }
        }
        return result
    }

    private static func windows(_ segments: [Double], length: Int, segmentLength: Int) -> [Double] {
        guard segments.count >= length else { return [] }
        let samples = Double(length * segmentLength)
        var running = segments[0..<length].reduce(0, +)
        var powers = [running / samples]
        for end in length..<segments.count {
            running += segments[end] - segments[end - length]
            powers.append(running / samples)
        }
        return powers
    }

    private static func loudness(_ meanSquare: Double) -> Double {
        meanSquare > 0 ? -0.691 + 10 * log10(meanSquare) : -.infinity
    }

    private static func mean(_ values: [Double]) -> Double {
        values.reduce(0, +) / Double(values.count)
    }
}

/// BS.1770 pre-filter (high shelf) and RLB high-pass, with coefficients
/// derived for any sample rate rather than the tabulated 48 kHz values.
nonisolated struct KWeightingFilter {
    private var shelf: Biquad
    private var highPass: Biquad

    init(sampleRate: Double) {
        var k = tan(.pi * 1681.974450955533 / sampleRate)
        let q = 0.7071752369554196
        let vh = pow(10, 3.999843853973347 / 20)
        let vb = pow(vh, 0.4996667741545416)
        var a0 = 1 + k / q + k * k
        shelf = Biquad(
            b0: (vh + vb * k / q + k * k) / a0,
            b1: 2 * (k * k - vh) / a0,
            b2: (vh - vb * k / q + k * k) / a0,
            a1: 2 * (k * k - 1) / a0,
            a2: (1 - k / q + k * k) / a0
        )

        k = tan(.pi * 38.13547087602444 / sampleRate)
        let q2 = 0.5003270373238773
        a0 = 1 + k / q2 + k * k
        highPass = Biquad(
            b0: 1, b1: -2, b2: 1,
            a1: 2 * (k * k - 1) / a0,
            a2: (1 - k / q2 + k * k) / a0
        )
    }

    mutating func process(_ x: Double) -> Double {
        highPass.process(shelf.process(x))
    }

    private struct Biquad {
        let b0, b1, b2, a1, a2: Double
        var z1 = 0.0
        var z2 = 0.0

        init(b0: Double, b1: Double, b2: Double, a1: Double, a2: Double) {
            self.b0 = b0; self.b1 = b1; self.b2 = b2; self.a1 = a1; self.a2 = a2
        }

        mutating func process(_ x: Double) -> Double {
            let y = b0 * x + z1
            z1 = b1 * x - a1 * y + z2
            z2 = b2 * x - a2 * y
            return y
        }
    }
}

// MARK: - True peak

nonisolated enum TruePeakMeter {
    /// Peak of the signal reconstructed between samples, by polyphase
    /// windowed-sinc oversampling (4x below 96 kHz, as BS.1770 asks).
    static func peak(_ samples: [Float], sampleRate: Double) -> Double {
        guard !samples.isEmpty else { return 0 }
        let factor = sampleRate < 96_000 ? 4 : 2
        let tapsPerPhase = 24
        let length = factor * tapsPerPhase
        let center = Double(length - 1) / 2

        // Blackman-windowed sinc, cutoff at the original Nyquist.
        var kernel = (0..<length).map { n -> Float in
            let t = (Double(n) - center) / Double(factor)
            let sinc = t == 0 ? 1 : sin(.pi * t) / (.pi * t)
            let w = 0.42 - 0.5 * cos(2 * .pi * Double(n) / Double(length - 1))
                + 0.08 * cos(4 * .pi * Double(n) / Double(length - 1))
            return Float(sinc * w)
        }
        let gain = Float(factor) / kernel.reduce(0, +)
        kernel = vDSP.multiply(gain, kernel)

        let padded = [Float](repeating: 0, count: tapsPerPhase)
            + samples + [Float](repeating: 0, count: tapsPerPhase)
        var peak: Float = 0
        for phase in 0..<factor {
            // The kernel is symmetric, so reversing a phase yields its mirror
            // phase: the set of phases (and the peak) is the same whether
            // vDSP convolves or correlates.
            let taps = stride(from: phase, to: length, by: factor).map { kernel[$0] }
            let output = vDSP.convolve(padded, withKernel: taps)
            if !output.isEmpty {
                peak = max(peak, vDSP.maximumMagnitude(output))
            }
        }
        return Double(peak)
    }
}

// MARK: - Spectrum

nonisolated enum SpectrumAnalyzer {
    /// Bands named for what they do to a voice, which is how the EQ and
    /// the voice profiles talk about them.
    static let voiceBands: [(name: String, low: Double, high: Double)] = [
        ("rumble", 20, 80),
        ("body", 80, 160),
        ("warmth", 160, 300),
        ("mud", 300, 600),
        ("boxy", 600, 1_200),
        ("clarity", 1_200, 2_500),
        ("presence", 2_500, 5_000),
        ("sibilance", 5_000, 8_000),
        ("brilliance", 8_000, 12_000),
        ("air", 12_000, 20_000)
    ]

    /// Long-term average spectrum over speech frames only, so pauses and
    /// room tone do not pull the balance toward the noise.
    static func measure(
        _ mono: [Float],
        sampleRate: Double
    ) -> (bands: [VoiceMeasurement.Band], thirdOctave: [VoiceMeasurement.SpectrumPoint]) {
        let log2n: vDSP_Length = 13
        let size = 1 << Int(log2n)
        let half = size / 2
        let hop = size / 2
        guard mono.count >= size,
              let setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else {
            return ([], [])
        }
        defer { vDSP_destroy_fftsetup(setup) }

        let starts = Array(stride(from: 0, through: mono.count - size, by: hop))
        let frameLevels = starts.map { start in
            VoiceAnalyzer.decibels(amplitude: Double(vDSP.rootMeanSquare(mono[start..<(start + size)])))
        }
        let loud = VoiceAnalyzer.percentile(frameLevels, 0.95) ?? VoiceAnalyzer.silenceDB
        let threshold = max(loud - 30, -60)

        let window = vDSP.window(ofType: Float.self, usingSequence: .hanningDenormalized, count: size, isHalfWindow: false)
        var power = [Double](repeating: 0, count: half)
        var real = [Float](repeating: 0, count: half)
        var imaginary = [Float](repeating: 0, count: half)
        var activeFrames = 0

        for (start, level) in zip(starts, frameLevels) where level > threshold {
            let windowed = vDSP.multiply(mono[start..<(start + size)], window)
            real.withUnsafeMutableBufferPointer { realPointer in
                imaginary.withUnsafeMutableBufferPointer { imaginaryPointer in
                    var split = DSPSplitComplex(
                        realp: realPointer.baseAddress!,
                        imagp: imaginaryPointer.baseAddress!
                    )
                    windowed.withUnsafeBufferPointer { input in
                        input.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: half) {
                            vDSP_ctoz($0, 2, &split, 1, vDSP_Length(half))
                        }
                    }
                    vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                }
            }
            for bin in 1..<half {
                power[bin] += Double(real[bin] * real[bin] + imaginary[bin] * imaginary[bin])
            }
            activeFrames += 1
        }
        guard activeFrames > 0 else { return ([], []) }

        let binWidth = sampleRate / Double(size)
        func energy(_ low: Double, _ high: Double) -> Double? {
            let first = max(1, Int((low / binWidth).rounded(.up)))
            let last = min(half - 1, Int((high / binWidth).rounded(.down)))
            guard first <= last else { return nil }
            return power[first...last].reduce(0, +)
        }
        func perOctave(_ low: Double, _ high: Double) -> Double? {
            energy(low, high).map { $0 / log2(high / low) }
        }

        // Reference: the average energy per octave across 100 Hz-10 kHz.
        guard let reference = perOctave(100, min(10_000, sampleRate / 2)), reference > 0 else {
            return ([], [])
        }
        func relative(_ value: Double) -> Double {
            VoiceAnalyzer.decibels(power: value / reference)
        }

        let nyquist = sampleRate / 2
        let bands = voiceBands.compactMap { band -> VoiceMeasurement.Band? in
            let high = min(band.high, nyquist)
            guard band.low < high, let value = perOctave(band.low, high) else { return nil }
            return VoiceMeasurement.Band(name: band.name, lowHz: band.low, highHz: high, levelDB: relative(value))
        }

        let thirdOctave = (-17...13).compactMap { index -> VoiceMeasurement.SpectrumPoint? in
            let center = 1_000 * pow(2, Double(index) / 3)
            let low = center / pow(2, 1.0 / 6)
            let high = center * pow(2, 1.0 / 6)
            guard high <= nyquist, let value = perOctave(low, high) else { return nil }
            return VoiceMeasurement.SpectrumPoint(centerHz: (center * 10).rounded() / 10, levelDB: relative(value))
        }
        return (bands, thirdOctave)
    }
}
