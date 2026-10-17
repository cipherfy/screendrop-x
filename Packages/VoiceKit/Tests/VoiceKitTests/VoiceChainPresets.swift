import VoiceKit

// Fixed chains the tests check against. The app resolves its chain from a
// voice profile, so these live here rather than in VoiceKit.
extension VoiceChainSettings {
    enum Preset: CaseIterable {
        case neutral
        case usbCondenser

        var settings: VoiceChainSettings {
            switch self {
            case .neutral: VoiceChainSettings()
            case .usbCondenser: .usbCondenser
            }
        }
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
