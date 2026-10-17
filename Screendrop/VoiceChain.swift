//
//  VoiceChain.swift
//  Screendrop
//
//  The narration channel strip: high-pass, five-band EQ, a dynamic low
//  band for proximity effect, compressor, de-esser, and oversampled
//  saturation. It runs inside the voice track's processing tap (see
//  RecordingAudioProcessing), so playback and every export hear the same
//  chain, sample for sample.
//
//  Everything here is plain values and fixed-size buffers allocated up
//  front: the render thread never allocates, locks, or touches ARC.
//

import Foundation

// MARK: - Settings

nonisolated struct VoiceChainSettings: Codable, Sendable, Equatable {
    nonisolated enum FilterKind: String, Codable, Sendable {
        case lowShelf
        case peak
        case highShelf
    }

    struct HighPass: Codable, Sendable, Equatable {
        var isEnabled = true
        var frequency = 80.0
        /// 24 dB per octave instead of 12.
        var isSteep = false
    }

    /// A gain of 0 dB leaves the band out of the sound entirely.
    struct Band: Codable, Sendable, Equatable {
        var kind: FilterKind
        var frequency: Double
        var gainDB = 0.0
        var q = 0.7
    }

    /// Cuts a band only while it is loud: proximity boom from leaning in.
    struct DynamicBand: Codable, Sendable, Equatable {
        var isEnabled = false
        var frequency = 160.0
        var q = 1.0
        var thresholdDB = -30.0
        var rangeDB = 6.0
    }

    struct DeEsser: Codable, Sendable, Equatable {
        var isEnabled = false
        var frequency = 6_500.0
        var thresholdDB = -32.0
        var rangeDB = 8.0
    }

    /// Gentle downward expander: lowers what falls under the threshold, so
    /// the room between words does not rise with the compressor.
    struct Expander: Codable, Sendable, Equatable {
        var isEnabled = false
        var thresholdDB = -45.0
        var ratio = 2.0
        var rangeDB = 8.0
        var releaseMilliseconds = 150.0
    }

    struct Compressor: Codable, Sendable, Equatable {
        var isEnabled = false
        var thresholdDB = -24.0
        var ratio = 3.0
        var kneeDB = 6.0
        var attackMilliseconds = 10.0
        var releaseMilliseconds = 100.0
        var makeupDB = 0.0
    }

    /// Soft saturation, run at four times the sample rate so its harmonics
    /// do not fold back as aliasing. Warmth biases the curve for even
    /// harmonics, the tube-like part of "character".
    struct Saturation: Codable, Sendable, Equatable {
        var isEnabled = false
        var driveDB = 6.0
        var mix = 0.3
        var warmth = 0.3
    }

    /// Level into the chain, so thresholds mean the same thing for a quiet
    /// and a hot microphone. Loudness analysis will set it.
    var inputTrimDB = 0.0
    var highPass = HighPass()
    var lowShelf = Band(kind: .lowShelf, frequency: 150)
    var lowMid = Band(kind: .peak, frequency: 300, q: 1.2)
    var mid = Band(kind: .peak, frequency: 900, q: 1.4)
    var presence = Band(kind: .peak, frequency: 4_500, q: 1.4)
    var highShelf = Band(kind: .highShelf, frequency: 10_000)
    var dynamicLow = DynamicBand()
    var expander = Expander()
    var deEsser = DeEsser()
    var compressor = Compressor()
    var saturation = Saturation()

    init() {}

    var bands: [Band] { [lowShelf, lowMid, mid, presence, highShelf] }
}

// MARK: Presets

nonisolated extension VoiceChainSettings {
    nonisolated enum Preset: String, CaseIterable, Identifiable, Sendable {
        case neutral
        case usbCondenser

        var id: Self { self }

        var title: String {
            switch self {
            case .neutral: "Neutral"
            case .usbCondenser: "USB Condenser"
            }
        }

        var help: String {
            switch self {
            case .neutral:
                "A gentle high-pass and the limiter, nothing else"
            case .usbCondenser:
                "Starting point for a USB condenser at a desk: less room and harshness, more body, compression, and light saturation"
            }
        }

        var settings: VoiceChainSettings {
            switch self {
            case .neutral: VoiceChainSettings()
            case .usbCondenser: .usbCondenser
            }
        }
    }

    /// Every stage off: the chain passes the voice through untouched.
    static var flat: VoiceChainSettings {
        var settings = VoiceChainSettings()
        settings.highPass.isEnabled = false
        return settings
    }

    /// The starting curve for a USB condenser (HyperX QuadCast class) a
    /// hand's width from the mouth, at a desk in an untreated room.
    static var usbCondenser: VoiceChainSettings {
        var settings = VoiceChainSettings()
        settings.highPass = HighPass(isEnabled: true, frequency: 90, isSteep: true)
        // Body as a bell rather than a shelf: lift the voice, not the room.
        settings.lowShelf = Band(kind: .peak, frequency: 150, gainDB: 2, q: 0.9)
        settings.lowMid = Band(kind: .peak, frequency: 300, gainDB: -2.5, q: 1.2)
        settings.presence = Band(kind: .peak, frequency: 5_000, gainDB: -2, q: 2)
        settings.highShelf = Band(kind: .highShelf, frequency: 11_000, gainDB: 1, q: 0.7)
        settings.dynamicLow = DynamicBand(isEnabled: true, frequency: 140, q: 1, thresholdDB: -28, rangeDB: 4)
        settings.expander = Expander(isEnabled: true, thresholdDB: -40, ratio: 2, rangeDB: 8, releaseMilliseconds: 150)
        settings.deEsser = DeEsser(isEnabled: true, frequency: 6_500, thresholdDB: -30, rangeDB: 6)
        settings.compressor = Compressor(
            isEnabled: true, thresholdDB: -22, ratio: 3, kneeDB: 6,
            attackMilliseconds: 12, releaseMilliseconds: 100, makeupDB: 4
        )
        settings.saturation = Saturation(isEnabled: true, driveDB: 6, mix: 0.25, warmth: 0.35)
        return settings
    }

    var matchingPreset: Preset? {
        Preset.allCases.first { $0.settings == self }
    }
}

// MARK: Tolerant decoding

// Every field falls back to its default, so projects saved before a field
// existed (or by a later build with fields this one lacks) still open.
nonisolated extension KeyedDecodingContainer {
    func value<T: Decodable>(_ key: Key, default fallback: T) -> T {
        ((try? decodeIfPresent(T.self, forKey: key)) ?? nil) ?? fallback
    }
}

nonisolated extension VoiceChainSettings {
    private enum CodingKeys: String, CodingKey {
        case inputTrimDB, highPass, lowShelf, lowMid, mid, presence, highShelf
        case dynamicLow, expander, deEsser, compressor, saturation
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = VoiceChainSettings()
        inputTrimDB = c.value(.inputTrimDB, default: defaults.inputTrimDB)
        highPass = c.value(.highPass, default: defaults.highPass)
        lowShelf = c.value(.lowShelf, default: defaults.lowShelf)
        lowMid = c.value(.lowMid, default: defaults.lowMid)
        mid = c.value(.mid, default: defaults.mid)
        presence = c.value(.presence, default: defaults.presence)
        highShelf = c.value(.highShelf, default: defaults.highShelf)
        dynamicLow = c.value(.dynamicLow, default: defaults.dynamicLow)
        expander = c.value(.expander, default: defaults.expander)
        deEsser = c.value(.deEsser, default: defaults.deEsser)
        compressor = c.value(.compressor, default: defaults.compressor)
        saturation = c.value(.saturation, default: defaults.saturation)
    }
}

nonisolated extension VoiceChainSettings.HighPass {
    private enum CodingKeys: String, CodingKey { case isEnabled, frequency, isSteep }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Self()
        self.init(
            isEnabled: c.value(.isEnabled, default: d.isEnabled),
            frequency: c.value(.frequency, default: d.frequency),
            isSteep: c.value(.isSteep, default: d.isSteep)
        )
    }
}

nonisolated extension VoiceChainSettings.Band {
    private enum CodingKeys: String, CodingKey { case kind, frequency, gainDB, q }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            kind: c.value(.kind, default: .peak),
            frequency: c.value(.frequency, default: 1_000),
            gainDB: c.value(.gainDB, default: 0),
            q: c.value(.q, default: 0.7)
        )
    }
}

nonisolated extension VoiceChainSettings.DynamicBand {
    private enum CodingKeys: String, CodingKey { case isEnabled, frequency, q, thresholdDB, rangeDB }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Self()
        self.init(
            isEnabled: c.value(.isEnabled, default: d.isEnabled),
            frequency: c.value(.frequency, default: d.frequency),
            q: c.value(.q, default: d.q),
            thresholdDB: c.value(.thresholdDB, default: d.thresholdDB),
            rangeDB: c.value(.rangeDB, default: d.rangeDB)
        )
    }
}

nonisolated extension VoiceChainSettings.Expander {
    private enum CodingKeys: String, CodingKey { case isEnabled, thresholdDB, ratio, rangeDB, releaseMilliseconds }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Self()
        self.init(
            isEnabled: c.value(.isEnabled, default: d.isEnabled),
            thresholdDB: c.value(.thresholdDB, default: d.thresholdDB),
            ratio: c.value(.ratio, default: d.ratio),
            rangeDB: c.value(.rangeDB, default: d.rangeDB),
            releaseMilliseconds: c.value(.releaseMilliseconds, default: d.releaseMilliseconds)
        )
    }
}

nonisolated extension VoiceChainSettings.DeEsser {
    private enum CodingKeys: String, CodingKey { case isEnabled, frequency, thresholdDB, rangeDB }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Self()
        self.init(
            isEnabled: c.value(.isEnabled, default: d.isEnabled),
            frequency: c.value(.frequency, default: d.frequency),
            thresholdDB: c.value(.thresholdDB, default: d.thresholdDB),
            rangeDB: c.value(.rangeDB, default: d.rangeDB)
        )
    }
}

nonisolated extension VoiceChainSettings.Compressor {
    private enum CodingKeys: String, CodingKey {
        case isEnabled, thresholdDB, ratio, kneeDB, attackMilliseconds, releaseMilliseconds, makeupDB
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Self()
        self.init(
            isEnabled: c.value(.isEnabled, default: d.isEnabled),
            thresholdDB: c.value(.thresholdDB, default: d.thresholdDB),
            ratio: c.value(.ratio, default: d.ratio),
            kneeDB: c.value(.kneeDB, default: d.kneeDB),
            attackMilliseconds: c.value(.attackMilliseconds, default: d.attackMilliseconds),
            releaseMilliseconds: c.value(.releaseMilliseconds, default: d.releaseMilliseconds),
            makeupDB: c.value(.makeupDB, default: d.makeupDB)
        )
    }
}

nonisolated extension VoiceChainSettings.Saturation {
    private enum CodingKeys: String, CodingKey { case isEnabled, driveDB, mix, warmth }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Self()
        self.init(
            isEnabled: c.value(.isEnabled, default: d.isEnabled),
            driveDB: c.value(.driveDB, default: d.driveDB),
            mix: c.value(.mix, default: d.mix),
            warmth: c.value(.warmth, default: d.warmth)
        )
    }
}

// MARK: - Processor

/// Runs the chain on up to two channels. Create it off the render thread
/// (it allocates); `process` never does.
nonisolated struct VoiceChainProcessor {
    static let maximumChannels = 2

    /// Frames of delay the chain adds, the same with any settings, so
    /// switching stages or bypass never moves the voice in time.
    static var latency: Int { Oversampler.latency }

    let sampleRate: Double
    let channelCount: Int

    private var settingsVersion = -1
    private var settings = VoiceChainSettings()
    private var inputTrim: Double = 1

    // Filters, `channel * count + stage`.
    private var highPass: [Biquad]
    private var bands: [Biquad]
    private var dynamicFilter: [Biquad]
    private var deEssFilter: [Biquad]
    private var saturators: [Oversampler]
    private var dcBlockers: [DCBlocker]
    /// Stands in for the oversampler while saturation is off.
    private var cleanDelay: DelayLine
    /// The unprocessed voice, delayed to line up with the chain.
    private var dryDelay: DelayLine

    private var dynamicDetector: EnvelopeFollower
    private var deEssDetector: EnvelopeFollower
    private var expanderGainDB: Double = 0
    private var expanderPeak: Double = 0
    private var expanderHold: Double = 0
    private var expanderRelease: Double = 0
    private let expanderAttack: Double
    /// The detector must fall from speech to room level within a short
    /// pause; the gain's release is what keeps the closing gentle.
    private let expanderDetectorRelease: Double
    private var compressorGainDB: Double = 0
    /// Decoupled peak detector: a release-only stage, then attack.
    private var compressorPeak: Double = 0
    private var compressorLevel: Double = 0
    private var compressorAttack: Double = 0
    private var compressorRelease: Double = 0

    // Level-matched bypass.
    private var wetPower: Double = 0
    private var dryPower: Double = 0
    private var matchGain: Double = 1
    private var wetAmount: Double = 1
    private let powerSmoothing: Double
    private let fastSmoothing: Double

    init(sampleRate: Double, channelCount: Int) {
        self.sampleRate = sampleRate
        self.channelCount = min(Self.maximumChannels, max(1, channelCount))
        let channels = self.channelCount
        highPass = Array(repeating: Biquad(), count: channels * 2)
        bands = Array(repeating: Biquad(), count: channels * 5)
        dynamicFilter = Array(repeating: Biquad(), count: channels)
        deEssFilter = Array(repeating: Biquad(), count: channels)
        saturators = Array(repeating: Oversampler(), count: channels)
        dcBlockers = Array(repeating: DCBlocker(sampleRate: sampleRate), count: channels)
        cleanDelay = DelayLine(frames: Oversampler.latency, channels: channels)
        dryDelay = DelayLine(frames: Oversampler.latency, channels: channels)
        dynamicDetector = EnvelopeFollower(sampleRate: sampleRate, attackMilliseconds: 5, releaseMilliseconds: 80)
        deEssDetector = EnvelopeFollower(sampleRate: sampleRate, attackMilliseconds: 0.5, releaseMilliseconds: 50)
        expanderAttack = exp(-1 / (0.002 * sampleRate))
        expanderDetectorRelease = exp(-1 / (0.02 * sampleRate))
        powerSmoothing = exp(-1 / (1.5 * sampleRate))
        fastSmoothing = exp(-1 / (0.02 * sampleRate))
    }

    /// Recomputes coefficients when the settings change; filter state is
    /// kept, so a moving control does not restart the filters.
    mutating func apply(_ newSettings: VoiceChainSettings, version: Int) {
        guard version != settingsVersion else { return }
        settingsVersion = version
        settings = newSettings
        inputTrim = pow(10, newSettings.inputTrimDB / 20)

        let rate = sampleRate
        let hp = newSettings.highPass
        let hpCoefficients: [Biquad.Coefficients] = hp.isSteep
            ? [.highPass(rate, hp.frequency, q: 0.5412), .highPass(rate, hp.frequency, q: 1.3066)]
            : [.highPass(rate, hp.frequency, q: 0.7071), .identity]
        let bandCoefficients = newSettings.bands.map { band -> Biquad.Coefficients in
            guard band.gainDB != 0 else { return .identity }
            switch band.kind {
            case .lowShelf: return .lowShelf(rate, band.frequency, q: band.q, gainDB: band.gainDB)
            case .peak: return .peak(rate, band.frequency, q: band.q, gainDB: band.gainDB)
            case .highShelf: return .highShelf(rate, band.frequency, q: band.q, gainDB: band.gainDB)
            }
        }
        let dynamic = Biquad.Coefficients.bandPass(rate, newSettings.dynamicLow.frequency, q: newSettings.dynamicLow.q)
        let sibilance = Biquad.Coefficients.bandPass(rate, newSettings.deEsser.frequency, q: 1.5)

        for channel in 0..<channelCount {
            for stage in 0..<2 { highPass[channel * 2 + stage].coefficients = hp.isEnabled ? hpCoefficients[stage] : .identity }
            for stage in 0..<5 { bands[channel * 5 + stage].coefficients = bandCoefficients[stage] }
            dynamicFilter[channel].coefficients = dynamic
            deEssFilter[channel].coefficients = sibilance
        }
        expanderRelease = exp(-1 / (max(1, newSettings.expander.releaseMilliseconds) / 1_000 * rate))
        let compressor = newSettings.compressor
        compressorAttack = exp(-1 / (max(0.1, compressor.attackMilliseconds) / 1_000 * rate))
        compressorRelease = exp(-1 / (max(1, compressor.releaseMilliseconds) / 1_000 * rate))
    }

    /// Processes in place. `enabled` false plays the dry voice, matched
    /// to the processed level, with a short crossfade either way.
    mutating func process(
        frameCount: Int,
        enabled: Bool,
        read: (Int, Int) -> Float,
        write: (Int, Int, Float) -> Void
    ) {
        let channels = channelCount
        let s = settings
        let compressor = s.compressor
        let saturation = s.saturation
        let drive = pow(10, saturation.driveDB / 20)
        let bias = saturation.warmth * 0.5
        let biasSlope = 1 - tanh(bias) * tanh(bias)
        let dynamicThreshold = s.dynamicLow.thresholdDB
        let deEssThreshold = s.deEsser.thresholdDB
        let wetTarget = enabled ? 1.0 : 0.0

        // Two channels at most, so scratch fits on the stack.
        var wet: (Double, Double) = (0, 0)
        var dry: (Double, Double) = (0, 0)

        for frame in 0..<frameCount {
            // Input, trimmed; the dry copy waits out the chain's latency.
            for channel in 0..<channels {
                let x = Double(read(frame, channel)) * inputTrim
                set(&wet, channel, x)
                set(&dry, channel, Double(dryDelay.push(Float(x), channel: channel)))
            }
            dryDelay.advance()

            // Static filters.
            for channel in 0..<channels {
                var x = get(wet, channel)
                x = highPass[channel * 2].process(x)
                x = highPass[channel * 2 + 1].process(x)
                for stage in 0..<5 { x = bands[channel * 5 + stage].process(x) }
                set(&wet, channel, x)
            }

            // Dynamic low band: y = x + (g - 1) * bandpass(x) is a bell of
            // depth g at the band, so the cut follows the band's level.
            if s.dynamicLow.isEnabled {
                var band: (Double, Double) = (0, 0)
                var level = 0.0
                for channel in 0..<channels {
                    let b = dynamicFilter[channel].process(get(wet, channel))
                    set(&band, channel, b)
                    level = max(level, abs(b))
                }
                let envelope = dynamicDetector.process(level)
                let over = decibels(envelope) - dynamicThreshold
                let cut = over > 0 ? min(s.dynamicLow.rangeDB, over * (1 - 1 / 3.0)) : 0
                let gain = pow(10, -cut / 20)
                for channel in 0..<channels {
                    set(&wet, channel, get(wet, channel) + (gain - 1) * get(band, channel))
                }
            }

            // Expander: under the threshold, each dB down becomes `ratio` dB
            // down, never more than the range. It opens in 2 ms and closes
            // over the release, so word endings are not chopped.
            if s.expander.isEnabled {
                var level = 0.0
                for channel in 0..<channels { level = max(level, abs(get(wet, channel))) }
                expanderPeak = max(level, level + (expanderPeak - level) * expanderDetectorRelease)
                let under = s.expander.thresholdDB - decibels(expanderPeak)
                let target = under > 0 ? -min(s.expander.rangeDB, under * (max(1, s.expander.ratio) - 1)) : 0
                let coefficient = target > expanderGainDB ? expanderAttack : expanderRelease
                expanderGainDB = target + (expanderGainDB - target) * coefficient
                let gain = pow(10, expanderGainDB / 20)
                for channel in 0..<channels { set(&wet, channel, get(wet, channel) * gain) }
            }

            // Compressor: feed-forward, soft knee. The detector holds the
            // waveform's peaks (release), then follows them (attack), so a
            // steady tone compresses by exactly the static curve.
            if compressor.isEnabled {
                var level = 0.0
                for channel in 0..<channels { level = max(level, abs(get(wet, channel))) }
                compressorPeak = max(level, level + (compressorPeak - level) * compressorRelease)
                compressorLevel = compressorPeak + (compressorLevel - compressorPeak) * compressorAttack
                compressorGainDB = compressionGain(decibels(compressorLevel), compressor)
                let gain = pow(10, (compressorGainDB + compressor.makeupDB) / 20)
                for channel in 0..<channels { set(&wet, channel, get(wet, channel) * gain) }
            }

            // De-esser: the same split-band bell, keyed by sibilance.
            if s.deEsser.isEnabled {
                var band: (Double, Double) = (0, 0)
                var level = 0.0
                for channel in 0..<channels {
                    let b = deEssFilter[channel].process(get(wet, channel))
                    set(&band, channel, b)
                    level = max(level, abs(b))
                }
                let envelope = deEssDetector.process(level)
                let over = decibels(envelope) - deEssThreshold
                let cut = over > 0 ? min(s.deEsser.rangeDB, over * (1 - 1 / 4.0)) : 0
                let gain = pow(10, -cut / 20)
                for channel in 0..<channels {
                    set(&wet, channel, get(wet, channel) + (gain - 1) * get(band, channel))
                }
            }

            // Saturation at 4x, or an equal delay when it is off.
            for channel in 0..<channels {
                let x = get(wet, channel)
                let y: Double
                if saturation.isEnabled {
                    let mix = saturation.mix
                    let shaped = saturators[channel].process(x) { v in
                        let curve = (tanh(drive * v + bias) - tanh(bias)) / (drive * biasSlope)
                        return v + mix * (curve - v)
                    }
                    y = dcBlockers[channel].process(shaped)
                } else {
                    y = Double(cleanDelay.push(Float(x), channel: channel))
                }
                set(&wet, channel, y)
            }
            cleanDelay.advance()

            // Level matching: both paths' power, tracked over ~1.5 s, sets
            // the dry gain, so A/B compares the sound, not the loudness.
            var wetSum = 0.0
            var drySum = 0.0
            for channel in 0..<channels {
                wetSum += get(wet, channel) * get(wet, channel)
                drySum += get(dry, channel) * get(dry, channel)
            }
            wetPower = wetSum + (wetPower - wetSum) * powerSmoothing
            dryPower = drySum + (dryPower - drySum) * powerSmoothing
            if dryPower > 1e-9, wetPower > 1e-9 {
                let ratio = min(4, max(0.25, sqrt(wetPower / dryPower)))
                matchGain = ratio + (matchGain - ratio) * fastSmoothing
            }
            wetAmount = wetTarget + (wetAmount - wetTarget) * fastSmoothing

            for channel in 0..<channels {
                let output = wetAmount * get(wet, channel) + (1 - wetAmount) * matchGain * get(dry, channel)
                write(frame, channel, Float(output))
            }
        }
    }

    /// Current compressor gain reduction in dB (zero or negative).
    var compressorReductionDB: Double { compressorGainDB }

    private func compressionGain(_ input: Double, _ c: VoiceChainSettings.Compressor) -> Double {
        let over = input - c.thresholdDB
        let knee = max(0, c.kneeDB)
        let slope = 1 / max(1, c.ratio) - 1
        if 2 * over < -knee {
            return 0
        } else if knee > 0, 2 * abs(over) <= knee {
            let x = over + knee / 2
            return slope * x * x / (2 * knee)
        } else {
            return slope * over
        }
    }

    private func decibels(_ value: Double) -> Double {
        20 * log10(max(1e-9, value))
    }

    private func get(_ pair: (Double, Double), _ channel: Int) -> Double {
        channel == 0 ? pair.0 : pair.1
    }

    private func set(_ pair: inout (Double, Double), _ channel: Int, _ value: Double) {
        if channel == 0 { pair.0 = value } else { pair.1 = value }
    }
}

// MARK: - Building blocks

/// Transposed direct form II biquad in double precision, so low corners
/// at 48 kHz stay stable and quiet.
nonisolated struct Biquad {
    struct Coefficients {
        var b0 = 1.0, b1 = 0.0, b2 = 0.0, a1 = 0.0, a2 = 0.0

        static let identity = Coefficients()

        private static func normalized(_ b0: Double, _ b1: Double, _ b2: Double,
                                       _ a0: Double, _ a1: Double, _ a2: Double) -> Coefficients {
            Coefficients(b0: b0 / a0, b1: b1 / a0, b2: b2 / a0, a1: a1 / a0, a2: a2 / a0)
        }

        // RBJ Audio EQ Cookbook.
        static func highPass(_ rate: Double, _ frequency: Double, q: Double) -> Coefficients {
            let w = 2 * .pi * min(frequency, rate * 0.49) / rate
            let alpha = sin(w) / (2 * q), c = cos(w)
            return normalized((1 + c) / 2, -(1 + c), (1 + c) / 2, 1 + alpha, -2 * c, 1 - alpha)
        }

        /// Constant 0 dB peak gain.
        static func bandPass(_ rate: Double, _ frequency: Double, q: Double) -> Coefficients {
            let w = 2 * .pi * min(frequency, rate * 0.49) / rate
            let alpha = sin(w) / (2 * q), c = cos(w)
            return normalized(alpha, 0, -alpha, 1 + alpha, -2 * c, 1 - alpha)
        }

        static func peak(_ rate: Double, _ frequency: Double, q: Double, gainDB: Double) -> Coefficients {
            let a = pow(10, gainDB / 40)
            let w = 2 * .pi * min(frequency, rate * 0.49) / rate
            let alpha = sin(w) / (2 * q), c = cos(w)
            return normalized(1 + alpha * a, -2 * c, 1 - alpha * a, 1 + alpha / a, -2 * c, 1 - alpha / a)
        }

        static func lowShelf(_ rate: Double, _ frequency: Double, q: Double, gainDB: Double) -> Coefficients {
            let a = pow(10, gainDB / 40)
            let w = 2 * .pi * min(frequency, rate * 0.49) / rate
            let alpha = sin(w) / (2 * q), c = cos(w), s = 2 * sqrt(a) * alpha
            return normalized(
                a * ((a + 1) - (a - 1) * c + s), 2 * a * ((a - 1) - (a + 1) * c), a * ((a + 1) - (a - 1) * c - s),
                (a + 1) + (a - 1) * c + s, -2 * ((a - 1) + (a + 1) * c), (a + 1) + (a - 1) * c - s
            )
        }

        static func highShelf(_ rate: Double, _ frequency: Double, q: Double, gainDB: Double) -> Coefficients {
            let a = pow(10, gainDB / 40)
            let w = 2 * .pi * min(frequency, rate * 0.49) / rate
            let alpha = sin(w) / (2 * q), c = cos(w), s = 2 * sqrt(a) * alpha
            return normalized(
                a * ((a + 1) + (a - 1) * c + s), -2 * a * ((a - 1) + (a + 1) * c), a * ((a + 1) + (a - 1) * c - s),
                (a + 1) - (a - 1) * c + s, 2 * ((a - 1) - (a + 1) * c), (a + 1) - (a - 1) * c - s
            )
        }
    }

    var coefficients = Coefficients.identity
    private var z1 = 0.0
    private var z2 = 0.0

    mutating func process(_ x: Double) -> Double {
        let c = coefficients
        let y = c.b0 * x + z1
        z1 = c.b1 * x - c.a1 * y + z2
        z2 = c.b2 * x - c.a2 * y
        return y
    }
}

nonisolated struct EnvelopeFollower {
    private let attack: Double
    private let release: Double
    private var value = 0.0

    init(sampleRate: Double, attackMilliseconds: Double, releaseMilliseconds: Double) {
        attack = exp(-1 / (attackMilliseconds / 1_000 * sampleRate))
        release = exp(-1 / (releaseMilliseconds / 1_000 * sampleRate))
    }

    mutating func process(_ level: Double) -> Double {
        value = level + (value - level) * (level > value ? attack : release)
        return value
    }
}

/// Removes the DC the warmth bias leaves behind (5 Hz corner).
nonisolated struct DCBlocker {
    private let pole: Double
    private var previousInput = 0.0
    private var previousOutput = 0.0

    init(sampleRate: Double) {
        pole = exp(-2 * .pi * 5 / sampleRate)
    }

    mutating func process(_ x: Double) -> Double {
        let y = x - previousInput + pole * previousOutput
        previousInput = x
        previousOutput = y
        return y
    }
}

nonisolated struct DelayLine {
    private var buffer: [Float]
    private let frames: Int
    private let channels: Int
    private var position = 0

    init(frames: Int, channels: Int) {
        self.frames = max(1, frames)
        self.channels = channels
        buffer = [Float](repeating: 0, count: self.frames * channels)
    }

    /// Stores this frame's sample and returns the one `frames` ago.
    mutating func push(_ value: Float, channel: Int) -> Float {
        let index = position * channels + channel
        let delayed = buffer[index]
        buffer[index] = value
        return delayed
    }

    /// Call once per frame, after every channel was pushed.
    mutating func advance() {
        position += 1
        if position == frames { position = 0 }
    }

    mutating func reset() {
        for index in buffer.indices { buffer[index] = 0 }
        position = 0
    }
}

/// 4x polyphase oversampling around a per-sample function: windowed-sinc
/// interpolation up, the function at the high rate, the same filter down.
/// A 49-tap kernel puts the round trip at exactly 12 frames.
nonisolated struct Oversampler {
    static let factor = 4
    static let kernel: [Double] = makeKernel(length: 49, cutoff: 0.45)
    static let latency = (kernel.count - 1) / factor
    private static let historyLength = (kernel.count + factor - 1) / factor

    private var input: [Double]
    private var inputPosition = 0
    private var output: [Double]
    private var outputPosition = 0

    /// Long enough to keep the decimation window intact while the three
    /// samples after its newest one are already written.
    private static let outputLength = kernel.count + factor - 1

    init() {
        input = [Double](repeating: 0, count: Self.historyLength)
        output = [Double](repeating: 0, count: Self.outputLength)
    }

    /// Blackman-windowed sinc with unity DC gain; `cutoff` is a fraction of
    /// the base-rate Nyquist.
    static func makeKernel(length: Int, cutoff: Double) -> [Double] {
        let center = Double(length - 1) / 2
        let fc = cutoff / Double(factor) / 2
        var taps = (0..<length).map { n -> Double in
            let t = Double(n) - center
            let sinc = t == 0 ? 2 * fc : sin(2 * .pi * fc * t) / (.pi * t)
            let w = 0.42 - 0.5 * cos(2 * .pi * Double(n) / Double(length - 1))
                + 0.08 * cos(4 * .pi * Double(n) / Double(length - 1))
            return sinc * w
        }
        let sum = taps.reduce(0, +)
        taps = taps.map { $0 / sum }
        return taps
    }

    mutating func process(_ x: Double, _ function: (Double) -> Double) -> Double {
        let kernel = Self.kernel
        let length = kernel.count
        let history = Self.historyLength
        input[inputPosition] = x

        for phase in 0..<Self.factor {
            // Upsampled value at 4n + phase: every factor-th tap meets a
            // real input sample (the rest are the zeros stuffed between).
            var sum = 0.0
            var k = 0
            var tap = phase
            while tap < length {
                let index = (inputPosition - k + history) % history
                sum += kernel[tap] * input[index]
                k += 1
                tap += Self.factor
            }
            output[outputPosition] = function(sum * Double(Self.factor))
            outputPosition += 1
            if outputPosition == Self.outputLength { outputPosition = 0 }
        }
        inputPosition += 1
        if inputPosition == history { inputPosition = 0 }

        // Decimate: filter the shaped stream and keep one sample in four,
        // the one aligned with this input (phase 0), so the round trip is
        // a whole number of frames.
        let outputLength = Self.outputLength
        let newest = (outputPosition - Self.factor + outputLength) % outputLength
        var index = (newest - (length - 1) + outputLength) % outputLength
        var result = 0.0
        for tap in stride(from: length - 1, through: 0, by: -1) {
            result += kernel[tap] * output[index]
            index += 1
            if index == outputLength { index = 0 }
        }
        return result
    }
}
