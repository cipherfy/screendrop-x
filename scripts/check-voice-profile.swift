import AVFoundation
import Foundation

// Compile with everything the voice profile touches:
//
//   xcrun swiftc -O Screendrop/VoiceProfile.swift Screendrop/RecordingVoiceAnalysis.swift \
//     Screendrop/RecordingVoiceIsolation.swift Screendrop/RecordingAudioProcessing.swift \
//     Screendrop/VoiceChain.swift Screendrop/VoiceMeasurement.swift scripts/check-voice-profile.swift \
//     -o build/check-voice-profile
//   build/check-voice-profile build/voice-bank/variants
//
// Checks how profiles resolve into a chain, that match EQ recovers a known
// coloration and moves voices toward the target curve, that normalization
// lands on its loudness target, and reports the whole pipeline (isolation,
// chain, match EQ, loudness) on the voice bank.

/// The one rule of RecordingSession isolation relies on.
enum RecordingSession {
    static func isSessionDirectory(_ url: URL) -> Bool {
        url.pathExtension == "screendroprec"
            && FileManager.default.fileExists(atPath: url.appendingPathComponent("screen.mov").path)
    }
}

@main
struct VoiceProfileCheck {
    static let rate = 48_000.0

    static func main() async throws {
        setvbuf(stdout, nil, _IONBF, 0)
        guard CommandLine.arguments.count == 2 else {
            print("usage: check-voice-profile <voice bank variants directory>")
            exit(2)
        }
        let variants = URL(fileURLWithPath: CommandLine.arguments[1])
        let paulina = try read(variants.appendingPathComponent("paulina-clean.wav"))
        let eddy = try read(variants.appendingPathComponent("eddy-clean.wav"))

        try checkResolver(paulina)
        try checkFundamental(paulina: paulina, eddy: eddy)
        try checkMatchRecovery(paulina)
        try checkMatchMovesTowardTarget(variants)
        try checkNormalization(variants)
        try checkCoding()
        try await reportPipeline(variants)
        print("all voice profile checks passed")
    }

    // MARK: Resolver

    static func checkResolver(_ voice: [Float]) throws {
        let analysis = try RecordingVoiceAnalysis.analyze(voice, sourceKey: "microphone")
        var profile = VoiceProfileSettings(character: .broadcast, intensity: 1, matchesTarget: false)
        var chain = VoiceProfileResolver.chain(for: profile, analysis: analysis)
        precondition(chain.highPass.isEnabled && chain.highPass.frequency == 80 && !chain.highPass.isSteep)
        precondition(chain.dynamicLow.isEnabled && chain.deEsser.isEnabled && chain.expander.isEnabled, "base corrections for every voice")
        precondition(chain.lowMid.gainDB == -1 && chain.presence.gainDB == 0, "broadcast mud only; no static harshness cut")
        precondition(chain.compressor.isEnabled && chain.compressor.ratio == 3 && chain.saturation.isEnabled)
        precondition(chain.match == VoiceChainSettings.MatchEQ(), "match EQ off leaves the bells flat")

        profile.matchesTarget = true
        chain = VoiceProfileResolver.chain(for: profile, analysis: analysis)
        precondition(chain.match != VoiceChainSettings.MatchEQ(), "match EQ must be computed")

        profile.intensity = 0
        chain = VoiceProfileResolver.chain(for: profile, analysis: analysis)
        precondition(!chain.compressor.isEnabled && !chain.saturation.isEnabled && chain.mid.gainDB == 0 && chain.highShelf.gainDB == 0)
        precondition(chain.expander.isEnabled && chain.deEsser.isEnabled, "base corrections do not scale")

        profile.intensity = 0.5
        chain = VoiceProfileResolver.chain(for: profile, analysis: analysis)
        precondition(chain.compressor.ratio == 2 && abs(chain.mid.gainDB - 1.25) < 1e-9 && abs(chain.saturation.mix - 0.125) < 1e-9)

        let defaults = VoiceProfileSettings()
        precondition(defaults.character == .clear && defaults.matchesTarget && defaults.loudnessTarget == .platforms)
        precondition(VoiceProfileResolver.chain(for: defaults, analysis: nil).inputTrimDB == 0)
        precondition(RecordingAudioSettings.projectDefault.voiceIsolation.amount == 75)

        var quiet = analysis
        quiet.integratedLUFS = -32
        precondition(VoiceProfileResolver.inputTrimDB(for: quiet) == 6)
        quiet.integratedLUFS = -60
        precondition(VoiceProfileResolver.inputTrimDB(for: quiet) == 18)
        print("ok  profiles resolve: base corrections fixed, character scales with intensity, match EQ on by default, trim brings takes to -26 LUFS; projects start at 75% isolation and -14 LUFS")
    }

    static func checkFundamental(paulina: [Float], eddy: [Float]) throws {
        let high = (try RecordingVoiceAnalysis.analyze(paulina, sourceKey: "microphone").fundamentalHz) ?? 0
        let low = (try RecordingVoiceAnalysis.analyze(eddy, sourceKey: "microphone").fundamentalHz) ?? 0
        precondition(low < high, "a male voice must read lower than a female one")
        print(String(format: "ok  fundamental: Eddy %.0f Hz, Paulina %.0f Hz; the body band follows the voice", low, high))
    }

    // MARK: Match EQ

    static func checkMatchRecovery(_ voice: [Float]) throws {
        // Color the voice with a known resonance and a dull top, and check
        // match EQ moves the right octaves the right way.
        var colored = VoiceChainSettings.flat
        colored.mid = .init(kind: .peak, frequency: 1_000, gainDB: 6, q: 1.4)
        colored.highShelf = .init(kind: .highShelf, frequency: 3_000, gainDB: -5, q: 0.7)
        let original = VoiceProfileResolver.matchEQ(measured: try RecordingVoiceAnalysis.analyze(voice, sourceKey: "a").thirdOctave)
        let shifted = VoiceProfileResolver.matchEQ(measured: try RecordingVoiceAnalysis.analyze(run(voice, colored), sourceKey: "b").thirdOctave)
        let delta = zip(shifted.gains, original.gains).map { $0 - $1 }
        precondition(delta[2] < -2, "match must cut the added 1 kHz resonance (\(delta[2]))")
        precondition(delta[4] > 1.5 && delta[5] > 1.5, "match must lift the dulled top (\(delta[4]), \(delta[5]))")

        var extreme = VoiceChainSettings.flat
        extreme.mid = .init(kind: .peak, frequency: 1_000, gainDB: 24, q: 1)
        let limited = VoiceProfileResolver.matchEQ(measured: try RecordingVoiceAnalysis.analyze(run(voice, extreme), sourceKey: "c").thirdOctave)
        precondition(limited.gains.allSatisfy { $0 <= VoiceProfileResolver.matchBoostLimitDB && $0 >= -VoiceProfileResolver.matchCutLimitDB })
        print(String(format: "ok  match EQ answers a +6 dB 1 kHz resonance and a -5 dB top with %+.1f dB at 1 kHz, %+.1f / %+.1f dB at 4 / 8 kHz; never beyond -6 / +4.5 dB",
                     delta[2], delta[4], delta[5]))
    }

    static func checkMatchMovesTowardTarget(_ directory: URL) throws {
        print("    distance to the target curve (RMS dB over 250 Hz-8 kHz), before -> after match EQ:")
        for name in ["paulina-usb-condenser-desk", "monica-usb-condenser-desk", "eddy-usb-condenser-desk", "paulina-harsh", "paulina-thin", "paulina-boomy"] {
            let voice = try read(directory.appendingPathComponent("\(name).wav"))
            let analysis = try RecordingVoiceAnalysis.analyze(voice, sourceKey: "m")
            var chain = VoiceChainSettings.flat
            chain.match = VoiceProfileResolver.matchEQ(measured: analysis.thirdOctave)
            let before = distanceToTarget(analysis.thirdOctave)
            let after = distanceToTarget(try RecordingVoiceAnalysis.analyze(run(voice, chain), sourceKey: "m").thirdOctave)
            precondition(after < before, "\(name): match EQ moved away from the target")
            print("      " + name.padding(toLength: 28, withPad: " ", startingAt: 0) + String(format: " %4.1f -> %4.1f dB   [%@]", before, after,
                         chain.match.gains.map { String(format: "%+.1f", $0) }.joined(separator: " ")))
        }
        print("ok  match EQ moves every take closer to the target")
    }

    // MARK: Loudness

    static func checkNormalization(_ directory: URL) throws {
        var worst = 0.0
        var worstPeak = -100.0
        var runs = 0
        for name in ["paulina-usb-condenser-desk", "monica-usb-condenser-desk", "eddy-usb-condenser-desk", "paulina-quiet", "paulina-hot"] {
            let voice = try read(directory.appendingPathComponent("\(name).wav"))
            let analysis = try RecordingVoiceAnalysis.analyze(voice, sourceKey: "m")
            for character in VoiceProfileSettings.Character.allCases {
                for target in [VoiceProfileSettings.LoudnessTarget.podcast, .platforms] {
                    let profile = VoiceProfileSettings(character: character, intensity: 0.8, loudnessTarget: target)
                    let chain = VoiceProfileResolver.chain(for: profile, analysis: analysis)
                    guard let gain = try RecordingVoiceAnalysis.normalizationGain(voice, chain: chain, targetLUFS: target.lufs!) else {
                        print("FAIL \(name) could not be normalized")
                        exit(1)
                    }
                    let output = render(voice, chain, gainDB: gain)
                    let measured = VoiceAnalyzer.measure(channels: [output], sampleRate: rate)
                    let miss = abs((measured.integratedLUFS ?? 0) - target.lufs!)
                    if miss > 0.3 || measured.truePeakDBTP > -0.9 {
                        print(String(format: "FAIL %@ %@ %@: gain %+.1f dB -> %.2f LUFS, %.2f dBTP",
                                     name, character.rawValue, target.title, gain, measured.integratedLUFS ?? 0, measured.truePeakDBTP))
                    }
                    worst = max(worst, abs((measured.integratedLUFS ?? 0) - target.lufs!))
                    worstPeak = max(worstPeak, measured.truePeakDBTP)
                    runs += 1
                }
            }
        }
        precondition(worst <= 0.3, "normalization missed its target by \(worst) LU")
        precondition(worstPeak <= -0.9, "normalized output reached \(worstPeak) dBTP")
        print(String(format: "ok  normalization: %d takes x characters x targets land within %.2f LU of target, true peak at most %.2f dBTP", runs, worst, worstPeak))
    }

    static func checkCoding() throws {
        let profile = VoiceProfileSettings(character: .broadcast, intensity: 0.3, matchesTarget: false, loudnessTarget: .podcast)
        let roundTrip = try JSONDecoder().decode(VoiceProfileSettings.self, from: JSONEncoder().encode(profile))
        precondition(roundTrip == profile)
        let partial = try JSONDecoder().decode(VoiceProfileSettings.self, from: Data(#"{"character":"broadcast"}"#.utf8))
        precondition(partial.character == .broadcast && partial.loudnessTarget == .platforms)
        // Profiles saved with a microphone choice or a removed character
        // still open, falling back to the defaults for what is gone.
        let older = try JSONDecoder().decode(VoiceProfileSettings.self, from: Data(#"{"microphone":"usbCondenser","character":"warm","intensity":0.4}"#.utf8))
        precondition(older.character == .clear && older.intensity == 0.4)
        let olderSettings = try JSONDecoder().decode(RecordingAudioSettings.self, from: Data(#"{"voiceGainDB":2}"#.utf8))
        precondition(olderSettings.voiceIsolation.amount == 75, "settings saved before isolation start at 75%")
        var settings = RecordingAudioSettings()
        settings.voiceProfile = profile
        let settingsRoundTrip = try JSONDecoder().decode(RecordingAudioSettings.self, from: JSONEncoder().encode(settings))
        precondition(settingsRoundTrip == settings)
        print("ok  profiles round-trip and fill in defaults; profiles from before this change still open")
    }

    // MARK: Pipeline report

    /// Raw take versus the full pipeline: isolation at 75%
    /// with Clear and Broadcast at 60%, match EQ, -16 LUFS.
    static func reportPipeline(_ directory: URL) async throws {
        print("\npipeline on the USB-condenser-at-a-desk takes, at the defaults: isolation 75%, match EQ, -14 LUFS, intensity 60%")
        print("take                   LUFS-I     TP   LRA    SNR  target dist  | time")
        for voice in ["paulina", "monica", "eddy"] {
            let source = directory.appendingPathComponent("\(voice)-usb-condenser-desk.wav")
            let raw = try read(source)
            row("\(voice) raw", raw, seconds: nil)

            let package = FileManager.default.temporaryDirectory
                .appendingPathComponent("profile-\(UUID().uuidString).screendroprec", isDirectory: true)
            try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: package) }
            let screenURL = package.appendingPathComponent("screen.mov")
            try await writeMonoMovie(raw, to: screenURL)

            for character in [VoiceProfileSettings.Character.clear, .broadcast] {
                let started = Date()
                let isolation = VoiceIsolationSettings.projectDefault
                let samples = try await RecordingVoiceAnalysis.readVoice(screenURL: screenURL, isolation: isolation)
                let analysis = try RecordingVoiceAnalysis.analyze(samples, sourceKey: VoiceAnalysisResult.sourceKey(for: isolation))
                let profile = VoiceProfileSettings(character: character, intensity: 0.6)
                let chain = VoiceProfileResolver.chain(for: profile, analysis: analysis)
                let gain = (try RecordingVoiceAnalysis.normalizationGain(samples, chain: chain, targetLUFS: -14)) ?? 0
                let elapsed = Date().timeIntervalSince(started)
                row("\(voice) \(character.rawValue)", render(samples, chain, gainDB: gain), seconds: elapsed)
            }
        }
        print("    (time: isolation render, analysis, and loudness pass for a 41 s take)\n")
    }

    static func row(_ label: String, _ signal: [Float], seconds: Double?) {
        let m = VoiceAnalyzer.measure(channels: [signal], sampleRate: rate)
        print(label.padding(toLength: 20, withPad: " ", startingAt: 0) + String(format: " %6.1f %6.1f %5.1f %6.1f %8.1f     | %@",
                     m.integratedLUFS ?? 0, m.truePeakDBTP, m.loudnessRangeLU ?? 0, m.signalToNoiseDB ?? 0,
                     distanceToTarget(m.thirdOctave), seconds.map { String(format: "%.1f s", $0) } ?? ""))
    }

    // MARK: Helpers

    static func distanceToTarget(_ spectrum: [VoiceMeasurement.SpectrumPoint]) -> Double {
        func key(_ hz: Double) -> Int { Int((log2(hz / 1_000) * 3).rounded()) }
        let target = Dictionary(VoiceTargetCurve.points.map { (key($0.centerHz), $0.levelDB) }, uniquingKeysWith: { a, _ in a })
        let pairs = spectrum.compactMap { point -> Double? in
            guard VoiceTargetCurve.range.contains(point.centerHz), let t = target[key(point.centerHz)] else { return nil }
            return t - point.levelDB
        }
        guard !pairs.isEmpty else { return 0 }
        let mean = pairs.reduce(0, +) / Double(pairs.count)
        return (pairs.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(pairs.count)).squareRoot()
    }

    static func run(_ input: [Float], _ settings: VoiceChainSettings) -> [Float] {
        var processor = VoiceChainProcessor(sampleRate: rate, channelCount: 1)
        processor.apply(settings, version: 1)
        var buffer = input + [Float](repeating: 0, count: VoiceChainProcessor.latency)
        buffer.withUnsafeMutableBufferPointer { pointer in
            var start = 0
            while start < pointer.count {
                let count = min(512, pointer.count - start)
                processor.process(frameCount: count, enabled: true,
                                  read: { frame, _ in pointer[start + frame] },
                                  write: { frame, _, value in pointer[start + frame] = value })
                start += count
            }
        }
        return Array(buffer.dropFirst(VoiceChainProcessor.latency))
    }

    /// The voice tap offline: chain, fader, true-peak limiter.
    static func render(_ input: [Float], _ chain: VoiceChainSettings, gainDB: Double) -> [Float] {
        let linear = Float(pow(10, gainDB / 20))
        var output = run(input, chain).map { $0 * linear }
        var limiter = PeakLimiter(sampleRate: rate, channelCount: 1, ceilingDB: -1, detectsTruePeak: true)
        output.withUnsafeMutableBufferPointer { limiter.process(interleaved: $0.baseAddress!, frameCount: $0.count) }
        return output
    }

    static func writeMonoMovie(_ samples: [Float], to url: URL) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: rate, AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 24, AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false
        ])
        input.expectsMediaDataInRealTime = false
        writer.add(input)
        precondition(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1)!
        for start in stride(from: 0, to: samples.count, by: 4_096) {
            let end = min(start + 4_096, samples.count)
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(end - start))!
            buffer.frameLength = AVAudioFrameCount(end - start)
            samples[start..<end].withUnsafeBufferPointer { buffer.floatChannelData![0].update(from: $0.baseAddress!, count: end - start) }
            var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: CMTimeScale(rate)),
                                            presentationTimeStamp: CMTime(value: CMTimeValue(start), timescale: CMTimeScale(rate)),
                                            decodeTimeStamp: .invalid)
            var sample: CMSampleBuffer?
            _ = CMSampleBufferCreate(allocator: kCFAllocatorDefault, dataBuffer: nil, dataReady: false, makeDataReadyCallback: nil,
                                     refcon: nil, formatDescription: format.formatDescription, sampleCount: end - start,
                                     sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleSizeEntryCount: 0,
                                     sampleSizeArray: nil, sampleBufferOut: &sample)
            precondition(CMSampleBufferSetDataBufferFromAudioBufferList(
                sample!, blockBufferAllocator: kCFAllocatorDefault, blockBufferMemoryAllocator: kCFAllocatorDefault,
                flags: 0, bufferList: buffer.audioBufferList) == noErr)
            while !input.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 1_000_000) }
            precondition(input.append(sample!))
        }
        input.markAsFinished()
        await writer.finishWriting()
        precondition(writer.status == .completed)
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
