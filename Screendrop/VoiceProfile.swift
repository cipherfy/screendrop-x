//
//  VoiceProfile.swift
//  Screendrop
//
//  How someone describes the voice they want: which microphone recorded
//  it, a character, how strongly to apply it, whether to match a target
//  balance, and a delivery loudness. VoiceProfileResolver turns that, plus
//  an analysis of the take, into the concrete VoiceChainSettings the tap
//  runs. Pure values and functions, so they can be checked offline.
//

import Foundation

// MARK: - Profile

nonisolated struct VoiceProfileSettings: Codable, Sendable, Equatable {
    nonisolated enum Microphone: String, Codable, CaseIterable, Identifiable, Sendable {
        case generic
        case usbCondenser

        var id: Self { self }

        var title: String {
            switch self {
            case .generic: "Generic"
            case .usbCondenser: "USB Condenser"
            }
        }

        var help: String {
            switch self {
            case .generic:
                "A gentle high-pass and de-esser, for most microphones"
            case .usbCondenser:
                "For a USB condenser at a desk: steeper high-pass, proximity control, a stronger de-esser, and an expander for the room between words"
            }
        }
    }

    nonisolated enum Character: String, Codable, CaseIterable, Identifiable, Sendable {
        case clear
        case broadcast
        case warm
        case bright

        var id: Self { self }

        var title: String {
            switch self {
            case .clear: "Clear"
            case .broadcast: "Broadcast"
            case .warm: "Warm"
            case .bright: "Bright"
            }
        }

        var help: String {
            switch self {
            case .clear: "Close to neutral, tuned for intelligibility: light compression, a touch of presence"
            case .broadcast: "Radio voice: more body and presence, firmer compression, light saturation"
            case .warm: "Fuller low mids, softer highs, warmer saturation; intimate and relaxed"
            case .bright: "Less mud, more presence and air; for dark voices or dark microphones"
            }
        }
    }

    nonisolated enum LoudnessTarget: String, Codable, CaseIterable, Identifiable, Sendable {
        case off
        case podcast
        case platforms

        var id: Self { self }

        var lufs: Double? {
            switch self {
            case .off: nil
            case .podcast: -16
            case .platforms: -14
            }
        }

        var title: String {
            switch self {
            case .off: "Off"
            case .podcast: "-16 LUFS"
            case .platforms: "-14 LUFS"
            }
        }

        var help: String {
            switch self {
            case .off: "Leave the voice level to the Voice slider"
            case .podcast: "Spoken-word standard (Apple Podcasts, AES); a comfortable level for tutorials"
            case .platforms: "Where YouTube and Spotify normalize; louder, with less headroom"
            }
        }
    }

    var microphone: Microphone = .generic
    var character: Character = .clear
    /// 0...1: how strongly the character is applied. The microphone's
    /// corrections and the match EQ do not scale with it.
    var intensity = 0.6
    var matchesTarget = true
    var loudnessTarget: LoudnessTarget = .podcast
    /// A chain edited by hand in the channel strip. While set, it stands in
    /// for the resolved chain; the loudness target still applies.
    var customChain: VoiceChainSettings?

    init(
        microphone: Microphone = .generic,
        character: Character = .clear,
        intensity: Double = 0.6,
        matchesTarget: Bool = true,
        loudnessTarget: LoudnessTarget = .podcast,
        customChain: VoiceChainSettings? = nil
    ) {
        self.microphone = microphone
        self.character = character
        self.intensity = min(1, max(0, intensity))
        self.matchesTarget = matchesTarget
        self.loudnessTarget = loudnessTarget
        self.customChain = customChain
    }

    private enum CodingKeys: String, CodingKey {
        case microphone, character, intensity, matchesTarget, loudnessTarget, customChain
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Self()
        self.init(
            microphone: c.value(.microphone, default: d.microphone),
            character: c.value(.character, default: d.character),
            intensity: c.value(.intensity, default: d.intensity),
            matchesTarget: c.value(.matchesTarget, default: d.matchesTarget),
            loudnessTarget: c.value(.loudnessTarget, default: d.loudnessTarget),
            customChain: c.value(.customChain, default: nil)
        )
    }
}

// MARK: - Analysis

/// What the take sounds like before processing, measured once per source
/// (the microphone track, or an isolation render of it).
nonisolated struct VoiceAnalysisResult: Codable, Sendable, Equatable {
    /// Which audio was measured: "microphone" or "isolated-<amount>".
    var sourceKey: String
    var integratedLUFS: Double?
    var speechLevelDBFS: Double
    var noiseFloorDBFS: Double
    var fundamentalHz: Double?
    var thirdOctave: [VoiceMeasurement.SpectrumPoint]

    static func sourceKey(for isolation: VoiceIsolationSettings) -> String {
        isolation.isEnabled ? "isolated-\(isolation.amount)" : "microphone"
    }
}

// MARK: - Target curve

/// The long-term balance match EQ pulls toward, as third-octave levels
/// relative to their own average over 200 Hz-8 kHz. Below 200 Hz a voice's
/// own fundamental decides what sounds right, so the curve stops there.
///
/// The default is the average of the voice bank's clean studio voices
/// (Paulina, Mónica, Eddy). It is a starting point: rebuild it from
/// narration you like with `voice-bank target <files>`.
nonisolated enum VoiceTargetCurve {
    static let range: ClosedRange<Double> = 200...8_000

    static let points: [VoiceMeasurement.SpectrumPoint] = [
        .init(centerHz: 250.0, levelDB: 10.1),
        .init(centerHz: 315.0, levelDB: 13.4),
        .init(centerHz: 396.9, levelDB: 10.2),
        .init(centerHz: 500.0, levelDB: 8.5),
        .init(centerHz: 630.0, levelDB: 4.7),
        .init(centerHz: 793.7, levelDB: 2.9),
        .init(centerHz: 1000.0, levelDB: -0.2),
        .init(centerHz: 1259.9, levelDB: -3.0),
        .init(centerHz: 1587.4, levelDB: -3.1),
        .init(centerHz: 2000.0, levelDB: -2.6),
        .init(centerHz: 2519.8, levelDB: -3.4),
        .init(centerHz: 3174.8, levelDB: -4.2),
        .init(centerHz: 4000.0, levelDB: -6.2),
        .init(centerHz: 5039.7, levelDB: -7.6),
        .init(centerHz: 6349.6, levelDB: -10.1),
        .init(centerHz: 8000.0, levelDB: -9.3),
    ]
}

// MARK: - Resolver

nonisolated enum VoiceProfileResolver {
    /// The narration level the chain's thresholds are written for. Input
    /// trim brings every take here first.
    static let referenceLUFS = -26.0
    /// Match EQ corrects this share of the measured difference: enough to
    /// fix a microphone or a room, not enough to erase the voice.
    static let matchStrength = 0.7
    /// Cuts are safer than boosts: a boost also raises whatever noise
    /// lives in the band.
    static let matchCutLimitDB = 6.0
    static let matchBoostLimitDB = 4.5
    /// A band this far under the target is missing, not quiet (a dull or
    /// narrowband source); boosting it would only raise hiss.
    static let missingBandDB = 12.0

    static func inputTrimDB(for analysis: VoiceAnalysisResult) -> Double {
        guard let loudness = analysis.integratedLUFS else { return 0 }
        return min(18, max(-18, referenceLUFS - loudness))
    }

    /// Octave gains that pull `measured` toward the target curve, level
    /// neutral (the average difference is removed), each averaged over the
    /// three third-octaves around its center, scaled and limited. Bands with
    /// no content to speak of are left alone.
    static func matchEQ(
        measured: [VoiceMeasurement.SpectrumPoint],
        target: [VoiceMeasurement.SpectrumPoint] = VoiceTargetCurve.points
    ) -> VoiceChainSettings.MatchEQ {
        func key(_ hz: Double) -> Int { Int((log2(hz / 1_000) * 3).rounded()) }
        let targetByBand = Dictionary(target.map { (key($0.centerHz), $0.levelDB) }, uniquingKeysWith: { a, _ in a })
        var differences: [Int: Double] = [:]
        for point in measured where VoiceTargetCurve.range.contains(point.centerHz) && point.levelDB > -60 {
            if let target = targetByBand[key(point.centerHz)] {
                differences[key(point.centerHz)] = target - point.levelDB
            }
        }
        guard differences.count >= 8 else { return VoiceChainSettings.MatchEQ() }
        // Level-neutral against the bands that are really there.
        let sorted = differences.values.sorted()
        let median = sorted[sorted.count / 2]
        differences = differences.filter { $0.value - median <= missingBandDB }
        let mean = differences.values.reduce(0, +) / Double(differences.count)

        let gains = VoiceChainSettings.MatchEQ.centers.map { center -> Double in
            let band = key(center)
            let around = (band - 1...band + 1).compactMap { differences[$0] }
            guard !around.isEmpty else { return 0 }
            let average = around.reduce(0, +) / Double(around.count) - mean
            let gain = min(matchBoostLimitDB, max(-matchCutLimitDB, average * matchStrength))
            return (gain * 10).rounded() / 10
        }
        return VoiceChainSettings.MatchEQ(gains: gains)
    }

    /// The chain for a profile and (when there is one) an analysis.
    static func chain(for profile: VoiceProfileSettings, analysis: VoiceAnalysisResult?) -> VoiceChainSettings {
        if let custom = profile.customChain { return custom }
        var chain = VoiceChainSettings()
        let intensity = min(1, max(0, profile.intensity))
        let matching = profile.matchesTarget && analysis != nil
        chain.inputTrimDB = analysis.map(inputTrimDB(for:)) ?? 0

        // The microphone's corrections. With match EQ on, the measured
        // correction replaces the static mud and harshness cuts.
        var mudCut = 0.0
        var harshCut = 0.0
        switch profile.microphone {
        case .generic:
            chain.highPass = .init(isEnabled: true, frequency: 80, isSteep: false)
            chain.deEsser = .init(isEnabled: true, frequency: 6_500, thresholdDB: -30, rangeDB: 4)
        case .usbCondenser:
            chain.highPass = .init(isEnabled: true, frequency: 90, isSteep: true)
            chain.dynamicLow = .init(isEnabled: true, frequency: 140, q: 1, thresholdDB: -28, rangeDB: 4)
            chain.deEsser = .init(isEnabled: true, frequency: 6_500, thresholdDB: -30, rangeDB: 6)
            chain.expander = .init(isEnabled: true, thresholdDB: -40, ratio: 2, rangeDB: 8, releaseMilliseconds: 150)
            if !matching {
                mudCut = -2.5
                harshCut = -2
            }
        }

        // The character, scaled by intensity.
        let c = CharacterCurve(profile.character)
        let fundamental = analysis?.fundamentalHz ?? 150
        let body = min(250, max(100, fundamental * 1.1)) * c.bodyScale
        chain.lowShelf = .init(kind: .peak, frequency: body, gainDB: c.body * intensity, q: 0.9)
        chain.lowMid = .init(kind: .peak, frequency: 300, gainDB: mudCut + c.mud * intensity, q: 1.2)
        chain.mid = .init(kind: .peak, frequency: c.presenceHz, gainDB: c.presence * intensity, q: 1)
        chain.presence = .init(kind: .peak, frequency: 5_000, gainDB: harshCut, q: 2)
        chain.highShelf = .init(kind: .highShelf, frequency: c.airHz, gainDB: c.air * intensity, q: 0.7)

        if intensity > 0 {
            chain.compressor = .init(
                isEnabled: true,
                thresholdDB: c.threshold,
                ratio: 1 + (c.ratio - 1) * intensity,
                kneeDB: 6,
                attackMilliseconds: 10,
                releaseMilliseconds: 100,
                makeupDB: c.makeup * intensity
            )
        }
        if c.saturationMix * intensity > 0 {
            chain.saturation = .init(
                isEnabled: true,
                driveDB: c.saturationDrive,
                mix: c.saturationMix * intensity,
                warmth: c.saturationWarmth
            )
        }

        if matching, let analysis {
            chain.match = matchEQ(measured: analysis.thirdOctave)
        }
        return chain
    }

    /// Each character at full intensity.
    private struct CharacterCurve {
        var body = 0.0
        var bodyScale = 1.0
        var mud = 0.0
        var presence = 0.0
        var presenceHz = 3_200.0
        var air = 0.0
        var airHz = 10_000.0
        var ratio = 2.0
        var threshold = -26.0
        var makeup = 2.0
        var saturationDrive = 6.0
        var saturationMix = 0.0
        var saturationWarmth = 0.3

        init(_ character: VoiceProfileSettings.Character) {
            switch character {
            case .clear:
                body = 1; presence = 1.5; air = 1
            case .broadcast:
                body = 2.5; mud = -1; presence = 2.5; presenceHz = 3_500; air = 1.5
                ratio = 3; threshold = -24; makeup = 4
                saturationMix = 0.25
            case .warm:
                body = 3; bodyScale = 1.4; presence = 0.5; presenceHz = 3_000; air = -1.5; airHz = 9_000
                ratio = 2.5; threshold = -25; makeup = 3
                saturationDrive = 8; saturationMix = 0.35; saturationWarmth = 0.6
            case .bright:
                mud = -1.5; presence = 2; presenceHz = 4_000; air = 3
                ratio = 2.5; threshold = -25; makeup = 3
            }
        }
    }
}
