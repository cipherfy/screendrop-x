import AVFoundation
import Foundation
import VoiceKit
import VoiceKitTestSupport

//   swift run -c release --package-path Packages/VoiceKit render-voice-ab \
//     <recording.screendroprec | audio file> <output folder>
//
// Renders a narration through each character, the way Studio would at its
// defaults (isolation 75% for a project, match EQ, intensity 60%, -14 LUFS),
// so they can be compared by ear. Writes WAVs to the output folder only; a
// project package is read, never changed.

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
            voice = try AudioBench.readConverted(temporary)
        } else {
            voice = try AudioBench.readConverted(source)
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
            try AudioBench.writeWAV(channels: [output], to: url)
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

    /// The voice tap offline, in 4096-frame buffers: chain, fader,
    /// true-peak limiter.
    static func render(_ input: [Float], _ chain: VoiceChainSettings, gainDB: Double) -> [Float] {
        AudioBench.render(input, chain, gainDB: gainDB, blockSize: 4_096, alignsLatency: false)
    }
}
