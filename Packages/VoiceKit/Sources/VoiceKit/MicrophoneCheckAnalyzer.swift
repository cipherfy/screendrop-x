//
//  MicrophoneCheckAnalyzer.swift
//  Screendrop
//
//  Turns a few seconds of room and a few seconds of speech into plain
//  advice about gain, noise, and hum. Foundation only, so the voice tools
//  can check it against the voice bank.
//

import Foundation

public nonisolated struct MicrophoneCheckResult: Sendable, Equatable {
    public struct Finding: Sendable, Equatable, Identifiable {
        public enum Severity: Sendable { case good, advice, problem }

        public let severity: Severity
        public let title: String
        public let detail: String

        public var id: String { title }
    }

    public var speechPeakDBFS: Double
    public var speechLUFS: Double?
    public var noiseFloorDBFS: Double
    public var signalToNoiseDB: Double?
    public var clippedSamples: Int
    public var humDB: Double
    public var findings: [Finding]

    public var isReady: Bool { !findings.contains { $0.severity == .problem } }
}

public nonisolated enum MicrophoneCheckAnalyzer {
    /// Peaks between -12 and -6 dBFS while speaking: headroom for a laugh,
    /// level well above the noise.
    public static let idealPeak: ClosedRange<Double> = -12...(-6)

    public static func evaluate(silence: [Float], speech: [Float], sampleRate: Double) -> MicrophoneCheckResult {
        let speechPeak = VoiceAnalyzer.decibels(amplitude: Double(speech.map(abs).max() ?? 0))
        let lufs = LoudnessMeter.measure(channels: [speech], sampleRate: sampleRate).integrated
        let noise = noiseFloor(silence, sampleRate: sampleRate)
        let speechLevel = VoiceAnalyzer.measure(channels: [speech], sampleRate: sampleRate).speechLevelDBFS
        let snr = noise > VoiceAnalyzer.silenceDB + 10 ? speechLevel - noise : nil
        let clipped = speech.reduce(0) { $0 + (abs($1) >= 0.999 ? 1 : 0) }
        let hum = humRatio(silence, sampleRate: sampleRate)

        var findings: [MicrophoneCheckResult.Finding] = []
        if speechPeak < -45 {
            findings.append(.init(severity: .problem, title: "No voice detected",
                                  detail: "Check the right microphone is selected and not muted. On a QuadCast, a touch on top mutes it; speak into the side with the logo."))
        } else {
            if clipped > 0 || speechPeak > -1 {
                findings.append(.init(severity: .problem, title: "Too loud: the voice clips",
                                      detail: "Lower the microphone's gain until peaks sit between -12 and -6 dBFS. Clipping cannot be repaired later."))
            } else if speechPeak > idealPeak.upperBound {
                findings.append(.init(severity: .advice, title: "A little hot",
                                      detail: String(format: "Peaks reach %.0f dBFS. Lower the gain slightly to keep room for louder moments.", speechPeak)))
            } else if speechPeak < -24 {
                findings.append(.init(severity: .problem, title: "Too quiet",
                                      detail: String(format: "Peaks only reach %.0f dBFS. Raise the gain, or move a hand's width from the microphone.", speechPeak)))
            } else if speechPeak < idealPeak.lowerBound {
                findings.append(.init(severity: .advice, title: "A little quiet",
                                      detail: String(format: "Peaks reach %.0f dBFS. Raising the gain a touch keeps the voice further above the noise.", speechPeak)))
            } else {
                findings.append(.init(severity: .good, title: "Level is right",
                                      detail: String(format: "Peaks at %.0f dBFS.", speechPeak)))
            }

            if noise > -45 {
                findings.append(.init(severity: .problem, title: "Noisy room",
                                      detail: String(format: "The room sits at %.0f dBFS between words. Turn off fans or move away from the computer; Isolate in Studio will help.", noise)))
            } else if noise > -55 {
                findings.append(.init(severity: .advice, title: "Some background noise",
                                      detail: String(format: "%.0f dBFS between words. Isolate in Studio will clean it up.", noise)))
            } else {
                findings.append(.init(severity: .good, title: "Quiet room",
                                      detail: String(format: "%.0f dBFS between words.", noise)))
            }

            if let snr, snr < 25 {
                findings.append(.init(severity: .advice, title: "Voice close to the noise",
                                      detail: String(format: "%.0f dB between voice and room. Get closer to the microphone or raise its gain.", snr)))
            }
        }

        if hum > 0.5, noise > -70 {
            findings.append(.init(severity: .advice, title: "Mains hum",
                                  detail: "Most of the noise is 50/60 Hz hum. Try another USB port, unplug nearby chargers, or avoid USB hubs."))
        }

        return MicrophoneCheckResult(
            speechPeakDBFS: speechPeak,
            speechLUFS: lufs,
            noiseFloorDBFS: noise,
            signalToNoiseDB: snr,
            clippedSamples: clipped,
            humDB: hum,
            findings: findings
        )
    }

    /// Median 50 ms RMS of the silent part: the room, not a cough in it.
    public static func noiseFloor(_ samples: [Float], sampleRate: Double) -> Double {
        let block = max(1, Int(sampleRate * 0.05))
        guard samples.count >= block else { return VoiceAnalyzer.silenceDB }
        let levels = stride(from: 0, through: samples.count - block, by: block).map { start -> Double in
            var sum = 0.0
            for index in start..<(start + block) { sum += Double(samples[index] * samples[index]) }
            return VoiceAnalyzer.decibels(amplitude: (sum / Double(block)).squareRoot())
        }
        return VoiceAnalyzer.percentile(levels, 0.5) ?? VoiceAnalyzer.silenceDB
    }

    /// Share of the silent part's energy at 50, 60, 100, 120, 150, and
    /// 180 Hz (mains and its harmonics), from 0 to 1.
    public static func humRatio(_ samples: [Float], sampleRate: Double) -> Double {
        guard samples.count > Int(sampleRate * 0.5) else { return 0 }
        let total = samples.reduce(0.0) { $0 + Double($1 * $1) }
        guard total > 0 else { return 0 }
        let n = Double(samples.count)
        var tonal = 0.0
        for frequency in [50.0, 60, 100, 120, 150, 180] {
            var re = 0.0, im = 0.0
            for (index, value) in samples.enumerated() {
                let phase = 2 * .pi * frequency * Double(index) / sampleRate
                re += Double(value) * cos(phase)
                im += Double(value) * sin(phase)
            }
            // Power of a sinusoid at this frequency, as a share of the total.
            tonal += 2 * (re * re + im * im) / n
        }
        return min(1, tonal / total)
    }
}
