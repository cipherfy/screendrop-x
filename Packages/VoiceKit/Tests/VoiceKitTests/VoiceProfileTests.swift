import AVFoundation
import Foundation
import Testing
import VoiceKit
import VoiceKitTestSupport

// Checks how profiles resolve into a chain, that match EQ recovers a known
// coloration and moves voices toward the target curve, that normalization
// lands on its loudness target, and reports the whole pipeline (isolation,
// chain, match EQ, loudness) on the voice bank.
@Suite("Voice profile")
struct VoiceProfileTests {
    static let rate = AudioBench.rate

    // MARK: Resolver

    @Test(.enabled(if: AudioBench.isVoiceBankAvailable, Comment(rawValue: AudioBench.voiceBankMissing)))
    func resolver() throws {
        let analysis = try RecordingVoiceAnalysis.analyze(try AudioBench.bankTake("paulina-clean"), sourceKey: "microphone")
        var profile = VoiceProfileSettings(character: .broadcast, intensity: 1, matchesTarget: false)
        var chain = VoiceProfileResolver.chain(for: profile, analysis: analysis)
        #expect(chain.highPass.isEnabled && chain.highPass.frequency == 80 && !chain.highPass.isSteep)
        #expect(chain.dynamicLow.isEnabled && chain.deEsser.isEnabled && chain.expander.isEnabled, "base corrections for every voice")
        #expect(chain.lowMid.gainDB == 0 && chain.presence.gainDB == 0, "no static mud or harshness cuts")
        #expect(chain.mid.frequency == 1_400 && chain.mid.gainDB == 1.5, "broadcast presence sits in the mids")
        #expect(chain.compressor.isEnabled && chain.compressor.ratio == 2.5 && chain.compressor.attackMilliseconds == 15)
        #expect(chain.saturation.isEnabled && chain.saturation.mix == 0.15)
        #expect(chain.match == VoiceChainSettings.MatchEQ(), "match EQ off leaves the bells flat")

        profile.matchesTarget = true
        chain = VoiceProfileResolver.chain(for: profile, analysis: analysis)
        #expect(chain.match != VoiceChainSettings.MatchEQ(), "match EQ must be computed")
        let clearMatch = VoiceProfileResolver.chain(for: VoiceProfileSettings(character: .clear), analysis: analysis).match
        #expect(clearMatch != chain.match, "each character matches its own target curve")

        profile.intensity = 0
        chain = VoiceProfileResolver.chain(for: profile, analysis: analysis)
        #expect(!chain.compressor.isEnabled && !chain.saturation.isEnabled && chain.mid.gainDB == 0 && chain.highShelf.gainDB == 0)
        #expect(chain.expander.isEnabled && chain.deEsser.isEnabled, "base corrections do not scale")

        profile.intensity = 0.5
        chain = VoiceProfileResolver.chain(for: profile, analysis: analysis)
        #expect(chain.compressor.ratio == 1.75 && abs(chain.mid.gainDB - 0.75) < 1e-9 && abs(chain.saturation.mix - 0.075) < 1e-9)

        let defaults = VoiceProfileSettings()
        #expect(defaults.character == .clear && defaults.matchesTarget && defaults.loudnessTarget == .platforms)
        #expect(VoiceProfileResolver.chain(for: defaults, analysis: nil).inputTrimDB == 0)
        #expect(RecordingAudioSettings.projectDefault.voiceIsolation.amount == 75)

        var quiet = analysis
        quiet.integratedLUFS = -32
        #expect(VoiceProfileResolver.inputTrimDB(for: quiet) == 6)
        quiet.integratedLUFS = -60
        #expect(VoiceProfileResolver.inputTrimDB(for: quiet) == 18)
    }

    @Test(.enabled(if: AudioBench.isVoiceBankAvailable, Comment(rawValue: AudioBench.voiceBankMissing)))
    func fundamental() throws {
        let high = (try RecordingVoiceAnalysis.analyze(try AudioBench.bankTake("paulina-clean"), sourceKey: "microphone").fundamentalHz) ?? 0
        let low = (try RecordingVoiceAnalysis.analyze(try AudioBench.bankTake("eddy-clean"), sourceKey: "microphone").fundamentalHz) ?? 0
        #expect(low < high, "a male voice must read lower than a female one")
        print(String(format: "fundamental: Eddy %.0f Hz, Paulina %.0f Hz", low, high))
    }

    // MARK: Match EQ

    @Test(.enabled(if: AudioBench.isVoiceBankAvailable, Comment(rawValue: AudioBench.voiceBankMissing)))
    func matchRecovery() throws {
        let voice = try AudioBench.bankTake("paulina-clean")
        // Color the voice with a known resonance and a dull top, and check
        // match EQ moves the right octaves the right way.
        var colored = VoiceChainSettings.flat
        colored.mid = .init(kind: .peak, frequency: 1_000, gainDB: 6, q: 1.4)
        colored.highShelf = .init(kind: .highShelf, frequency: 3_000, gainDB: -5, q: 0.7)
        let original = VoiceProfileResolver.matchEQ(measured: try RecordingVoiceAnalysis.analyze(voice, sourceKey: "a").thirdOctave)
        let shifted = VoiceProfileResolver.matchEQ(measured: try RecordingVoiceAnalysis.analyze(AudioBench.run(voice, colored), sourceKey: "b").thirdOctave)
        let delta = zip(shifted.gains, original.gains).map { $0 - $1 }
        #expect(delta[2] < -2, "match must cut the added 1 kHz resonance (\(delta[2]))")
        #expect(delta[4] > 1.5 && delta[5] > 1.5, "match must lift the dulled top (\(delta[4]), \(delta[5]))")

        var extreme = VoiceChainSettings.flat
        extreme.mid = .init(kind: .peak, frequency: 1_000, gainDB: 24, q: 1)
        let limited = VoiceProfileResolver.matchEQ(measured: try RecordingVoiceAnalysis.analyze(AudioBench.run(voice, extreme), sourceKey: "c").thirdOctave)
        #expect(limited.gains.allSatisfy { $0 <= VoiceProfileResolver.matchBoostLimitDB && $0 >= -VoiceProfileResolver.matchCutLimitDB })
    }

    @Test(.enabled(if: AudioBench.isVoiceBankAvailable, Comment(rawValue: AudioBench.voiceBankMissing)),
          arguments: ["paulina-usb-condenser-desk", "monica-usb-condenser-desk", "eddy-usb-condenser-desk",
                      "paulina-harsh", "paulina-thin", "paulina-boomy"])
    func matchMovesTowardTarget(_ name: String) throws {
        let voice = try AudioBench.bankTake(name)
        let analysis = try RecordingVoiceAnalysis.analyze(voice, sourceKey: "m")
        var chain = VoiceChainSettings.flat
        chain.match = VoiceProfileResolver.matchEQ(measured: analysis.thirdOctave)
        let before = AudioBench.distanceToTarget(analysis.thirdOctave)
        let after = AudioBench.distanceToTarget(try RecordingVoiceAnalysis.analyze(AudioBench.run(voice, chain), sourceKey: "m").thirdOctave)
        #expect(after < before, "\(name): match EQ moved away from the target")
        print(name.padding(toLength: 28, withPad: " ", startingAt: 0) + String(format: " distance to target %4.1f -> %4.1f dB   [%@]", before, after,
                     chain.match.gains.map { String(format: "%+.1f", $0) }.joined(separator: " ")))
    }

    // MARK: Loudness

    @Test(.enabled(if: AudioBench.isVoiceBankAvailable, Comment(rawValue: AudioBench.voiceBankMissing)),
          arguments: ["paulina-usb-condenser-desk", "monica-usb-condenser-desk", "eddy-usb-condenser-desk", "paulina-quiet", "paulina-hot"])
    func normalization(_ name: String) throws {
        let voice = try AudioBench.bankTake(name)
        let analysis = try RecordingVoiceAnalysis.analyze(voice, sourceKey: "m")
        for character in VoiceProfileSettings.Character.allCases {
            for target in [VoiceProfileSettings.LoudnessTarget.podcast, .platforms] {
                let profile = VoiceProfileSettings(character: character, intensity: 0.8, loudnessTarget: target)
                let chain = VoiceProfileResolver.chain(for: profile, analysis: analysis)
                let lufs = try #require(target.lufs)
                let gain = try #require(try RecordingVoiceAnalysis.normalizationGain(voice, chain: chain, targetLUFS: lufs),
                                        "\(name) could not be normalized")
                let measured = VoiceAnalyzer.measure(channels: [AudioBench.render(voice, chain, gainDB: gain)], sampleRate: Self.rate)
                let miss = abs((measured.integratedLUFS ?? 0) - lufs)
                #expect(miss <= 0.3, "\(name) \(character.rawValue) \(target.title): gain \(gain) dB -> \(measured.integratedLUFS ?? 0) LUFS")
                #expect(measured.truePeakDBTP <= -0.9, "\(name) \(character.rawValue) \(target.title): \(measured.truePeakDBTP) dBTP")
            }
        }
    }

    @Test func coding() throws {
        let profile = VoiceProfileSettings(character: .broadcast, intensity: 0.3, matchesTarget: false, loudnessTarget: .podcast)
        let roundTrip = try JSONDecoder().decode(VoiceProfileSettings.self, from: JSONEncoder().encode(profile))
        #expect(roundTrip == profile)
        let partial = try JSONDecoder().decode(VoiceProfileSettings.self, from: Data(#"{"character":"broadcast"}"#.utf8))
        #expect(partial.character == .broadcast && partial.loudnessTarget == .platforms)
        // Profiles saved with a microphone choice or a removed character
        // still open, falling back to the defaults for what is gone.
        let older = try JSONDecoder().decode(VoiceProfileSettings.self, from: Data(#"{"microphone":"usbCondenser","character":"warm","intensity":0.4}"#.utf8))
        #expect(older.character == .clear && older.intensity == 0.4)
        let olderSettings = try JSONDecoder().decode(RecordingAudioSettings.self, from: Data(#"{"voiceGainDB":2}"#.utf8))
        #expect(olderSettings.voiceIsolation.amount == 75, "settings saved before isolation start at 75%")
        var settings = RecordingAudioSettings()
        settings.voiceProfile = profile
        let settingsRoundTrip = try JSONDecoder().decode(RecordingAudioSettings.self, from: JSONEncoder().encode(settings))
        #expect(settingsRoundTrip == settings)
    }

    // MARK: Pipeline report

    /// Raw take versus the full pipeline at the defaults: isolation 75%,
    /// Clear and Broadcast at 60%, match EQ, -14 LUFS.
    @Test(.enabled(if: AudioBench.isVoiceBankAvailable, Comment(rawValue: AudioBench.voiceBankMissing)))
    func pipelineReport() async throws {
        var report = ["pipeline on the USB-condenser-at-a-desk takes, at the defaults: isolation 75%, match EQ, -14 LUFS, intensity 60%",
                      "take                   LUFS-I     TP   LRA    SNR  target dist  | time"]
        for voice in ["paulina", "monica", "eddy"] {
            let raw = try AudioBench.bankTake("\(voice)-usb-condenser-desk")
            report.append(Self.row("\(voice) raw", raw, seconds: nil))

            let package = FileManager.default.temporaryDirectory
                .appendingPathComponent("profile-\(UUID().uuidString).screendroprec", isDirectory: true)
            try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: package) }
            let screenURL = package.appendingPathComponent("screen.mov")
            try await AudioBench.writeMovie(to: screenURL, tracks: [.init(channels: [raw], settings: [
                AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: Self.rate, AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 24, AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false
            ])], chunk: 4_096)

            for character in [VoiceProfileSettings.Character.clear, .broadcast] {
                let started = Date()
                let isolation = VoiceIsolationSettings.projectDefault
                let samples = try await RecordingVoiceAnalysis.readVoice(screenURL: screenURL, isolation: isolation)
                let analysis = try RecordingVoiceAnalysis.analyze(samples, sourceKey: VoiceAnalysisResult.sourceKey(for: isolation))
                let chain = VoiceProfileResolver.chain(for: VoiceProfileSettings(character: character, intensity: 0.6), analysis: analysis)
                let gain = (try RecordingVoiceAnalysis.normalizationGain(samples, chain: chain, targetLUFS: -14)) ?? 0
                let elapsed = Date().timeIntervalSince(started)
                report.append(Self.row("\(voice) \(character.rawValue)", AudioBench.render(samples, chain, gainDB: gain), seconds: elapsed))
            }
        }
        report.append("    (time: isolation render, analysis, and loudness pass for a 41 s take)")
        print(report.joined(separator: "\n"))
    }

    static func row(_ label: String, _ signal: [Float], seconds: Double?) -> String {
        let m = VoiceAnalyzer.measure(channels: [signal], sampleRate: rate)
        return label.padding(toLength: 20, withPad: " ", startingAt: 0) + String(format: " %6.1f %6.1f %5.1f %6.1f %8.1f     | %@",
                     m.integratedLUFS ?? 0, m.truePeakDBTP, m.loudnessRangeLU ?? 0, m.signalToNoiseDB ?? 0,
                     AudioBench.distanceToTarget(m.thirdOctave), seconds.map { String(format: "%.1f s", $0) } ?? "")
    }
}
