import AVFoundation
import Foundation

// Compile with the voice code:
//
//   xcrun swiftc -O Screendrop/VoiceProfile.swift Screendrop/RecordingVoiceAnalysis.swift \
//     Screendrop/RecordingVoiceIsolation.swift Screendrop/RecordingAudioProcessing.swift \
//     Screendrop/VoiceChain.swift Screendrop/VoiceMeasurement.swift scripts/render-voice-ab.swift \
//     -o build/render-voice-ab
//   build/render-voice-ab <recording.screendroprec | audio file> <output folder>
//
// Renders a narration through each character, the way Studio would at its
// defaults (isolation 75% for a project, match EQ, intensity 60%, -14 LUFS),
// so they can be compared by ear. Writes WAVs to the output folder only; a
// project package is read, never changed.

/// The one rule of RecordingSession isolation relies on.
enum RecordingSession {
    static func isSessionDirectory(_ url: URL) -> Bool {
        url.pathExtension == "screendroprec"
            && FileManager.default.fileExists(atPath: url.appendingPathComponent("screen.mov").path)
    }
}

@main
struct RenderVoiceAB {
    static let rate = 48_000.0

    static func main() async throws {
        setvbuf(stdout, nil, _IONBF, 0)
        guard CommandLine.arguments.count == 3 else {
            print("usage: render-voice-ab <recording.screendroprec | audio file> <output folder>")
            exit(2)
        }
        let source = URL(fileURLWithPath: CommandLine.arguments[1])
        let folder = URL(fileURLWithPath: CommandLine.arguments[2])
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let name = source.deletingPathExtension().lastPathComponent

        let voice: [Float]
        if source.pathExtension == "screendroprec" {
            // Isolation is rendered to a temporary file, not into the package.
            let screen = source.appendingPathComponent("screen.mov")
            let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("ab-\(UUID().uuidString).caf")
            defer { try? FileManager.default.removeItem(at: temporary) }
            print("isolating the narration at 75%…")
            try await RecordingVoiceIsolation.render(screenURL: screen, to: temporary, settings: .projectDefault) { _ in }
            voice = try readFile(temporary)
        } else {
            voice = try readFile(source)
        }
        print(String(format: "%.1f s of narration", Double(voice.count) / rate))

        let analysis = try RecordingVoiceAnalysis.analyze(voice, sourceKey: "ab")
        var versions: [(String, VoiceChainSettings)] = [
            ("clear", VoiceProfileResolver.chain(for: VoiceProfileSettings(character: .clear), analysis: analysis)),
            ("broadcast", VoiceProfileResolver.chain(for: VoiceProfileSettings(character: .broadcast), analysis: analysis))
        ]
        versions.insert(("broadcast-previous", previousBroadcast(analysis)), at: 1)

        for (label, chain) in versions {
            let gain = try RecordingVoiceAnalysis.normalizationGain(voice, chain: chain, targetLUFS: -14) ?? 0
            let output = render(voice, chain, gainDB: gain)
            let url = folder.appendingPathComponent("\(name)-\(label).wav")
            try write(output, to: url)
            let m = VoiceAnalyzer.measure(channels: [output], sampleRate: rate)
            print("  " + label.padding(toLength: 20, withPad: " ", startingAt: 0)
                  + String(format: "%.1f LUFS, %.1f dBTP, LRA %.1f  ->  ", m.integratedLUFS ?? 0, m.truePeakDBTP, m.loudnessRangeLU ?? 0)
                  + url.lastPathComponent)
        }
        print("done; all three sit at -14 LUFS, so they can be compared directly")
    }

    /// Broadcast as it was before it was rebuilt from the references, with
    /// the saturation filter fixed, for a fair comparison.
    static func previousBroadcast(_ analysis: VoiceAnalysisResult) -> VoiceChainSettings {
        var chain = VoiceProfileResolver.chain(for: VoiceProfileSettings(character: .clear), analysis: analysis)
        let intensity = 0.6
        let body = min(250, max(100, (analysis.fundamentalHz ?? 150) * 1.1))
        chain.lowShelf = .init(kind: .peak, frequency: body, gainDB: 2.5 * intensity, q: 0.9)
        chain.lowMid = .init(kind: .peak, frequency: 300, gainDB: -1 * intensity, q: 1.2)
        chain.mid = .init(kind: .peak, frequency: 3_500, gainDB: 2.5 * intensity, q: 1)
        chain.highShelf = .init(kind: .highShelf, frequency: 10_000, gainDB: 1.5 * intensity, q: 0.7)
        chain.compressor = .init(isEnabled: true, thresholdDB: -24, ratio: 1 + 2 * intensity, kneeDB: 6,
                                 attackMilliseconds: 10, releaseMilliseconds: 100, makeupDB: 4 * intensity)
        chain.saturation = .init(isEnabled: true, driveDB: 6, mix: 0.25 * intensity, warmth: 0.3)
        chain.match = VoiceProfileResolver.matchEQ(measured: analysis.thirdOctave)
        return chain
    }

    /// The voice tap offline: chain, fader, true-peak limiter.
    static func render(_ input: [Float], _ chain: VoiceChainSettings, gainDB: Double) -> [Float] {
        var processor = VoiceChainProcessor(sampleRate: rate, channelCount: 1)
        processor.apply(chain, version: 1)
        var buffer = input
        buffer.withUnsafeMutableBufferPointer { pointer in
            var start = 0
            while start < pointer.count {
                let count = min(4_096, pointer.count - start)
                processor.process(frameCount: count, enabled: true,
                                  read: { frame, _ in pointer[start + frame] },
                                  write: { frame, _, value in pointer[start + frame] = value })
                start += count
            }
        }
        let linear = Float(pow(10, gainDB / 20))
        buffer = buffer.map { $0 * linear }
        var limiter = PeakLimiter(sampleRate: rate, channelCount: 1, ceilingDB: -1, detectsTruePeak: true)
        buffer.withUnsafeMutableBufferPointer { limiter.process(interleaved: $0.baseAddress!, frameCount: $0.count) }
        return buffer
    }

    /// Any audio file, mixed to mono and resampled to 48 kHz.
    static func readFile(_ url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let target = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1)!
        guard let converter = AVAudioConverter(from: file.processingFormat, to: target) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        var samples: [Float] = []
        let chunk = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 65_536)!
        var finished = false
        while !finished {
            let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: 65_536)!
            var error: NSError?
            converter.convert(to: out, error: &error) { _, status in
                do {
                    try file.read(into: chunk, frameCount: min(chunk.frameCapacity, AVAudioFrameCount(max(0, file.length - file.framePosition))))
                } catch {
                    status.pointee = .endOfStream
                    return nil
                }
                if chunk.frameLength == 0 {
                    status.pointee = .endOfStream
                    return nil
                }
                status.pointee = .haveData
                return chunk
            }
            if let error { throw error }
            samples += UnsafeBufferPointer(start: out.floatChannelData![0], count: Int(out.frameLength))
            if out.frameLength == 0 { finished = true }
        }
        return samples
    }

    static func write(_ samples: [Float], to url: URL) throws {
        try? FileManager.default.removeItem(at: url)
        let file = try AVAudioFile(forWriting: url, settings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: rate, AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 24, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false
        ], commonFormat: .pcmFormatFloat32, interleaved: false)
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(samples.count))!
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { buffer.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
        try file.write(from: buffer)
    }
}
