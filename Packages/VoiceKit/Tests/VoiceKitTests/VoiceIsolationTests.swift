import AVFoundation
import Foundation
import Testing
import VoiceKit
import VoiceKitTestSupport

// Builds a project package around a noisy narration (starting half a
// second into the movie, beside a stereo system track) and checks the
// isolation render: alignment, how much room and noise it removes, partial
// amounts, the track swap, on-demand rendering for exports, and that a
// cancelled render leaves nothing behind.
@Suite("Voice isolation", .serialized, .enabled(if: AudioBench.isVoiceBankAvailable, Comment(rawValue: AudioBench.voiceBankMissing)))
struct VoiceIsolationTests {
    static let rate = AudioBench.rate
    static let offset = 0.5

    @Test func isolationRender() async throws {
        let rate = Self.rate
        let narration = try AudioBench.bankTake("paulina-usb-condenser-desk")
        let system = (0..<narration.count).map { Float(0.02 * sin(2 * .pi * 440 * Double($0) / rate)) }

        let package = FileManager.default.temporaryDirectory
            .appendingPathComponent("isolation-check-\(UUID().uuidString).screendroprec", isDirectory: true)
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: package) }
        let screenURL = package.appendingPathComponent("screen.mov")
        // A movie shaped like a recording: stereo system audio from zero,
        // the mono microphone track starting `offset` seconds in.
        try await AudioBench.writeMovie(to: screenURL, tracks: [
            .float([system, system]),
            .float([narration], startFrame: Int(Self.offset * rate))
        ])
        #expect(RecordingVoiceIsolation.projectDirectory(forScreenURL: screenURL) == package)

        // The narration as the movie holds it: read through the same path
        // the render reads, including any lead-in the writer recorded as an
        // empty edit before the microphone's first sample.
        let master = AVURLAsset(url: screenURL)
        let masterTracks = try await master.loadTracks(withMediaType: .audio)
        let masterRoles = try await RecordingAudioProcessing.roles(for: masterTracks, isReplacement: false)
        let masterVoice = masterTracks[try #require(masterRoles.firstIndex(of: .voice))]
        let masterVoiceStart = try await masterVoice.load(.timeRange).start.seconds
        let source = try await AudioBench.readTrack(masterVoice, of: master)

        // 1. Render at full strength: same length, aligned, cleaner.
        let full = VoiceIsolationSettings(amount: 100)
        let fullURL = RecordingVoiceIsolation.renderURL(in: package, settings: full)
        let started = Date()
        try await RecordingVoiceIsolation.render(screenURL: screenURL, to: fullURL, settings: full) { _ in }
        let elapsed = Date().timeIntervalSince(started)
        let isolated = try AudioBench.readMono(fullURL)
        #expect(abs(isolated.count - source.count) <= 1, "render length \(isolated.count) vs \(source.count)")
        let lag = Self.bestLag(source, isolated)
        #expect(lag == 0, "render is shifted by \(lag) frames")
        let before = VoiceAnalyzer.measure(channels: [source], sampleRate: rate)
        let after = VoiceAnalyzer.measure(channels: [isolated], sampleRate: rate)
        let gain = (after.signalToNoiseDB ?? 0) - (before.signalToNoiseDB ?? 0)
        #expect(gain > 10, "isolation improved SNR by only \(gain) dB")
        #expect(abs((after.integratedLUFS ?? 0) - (before.integratedLUFS ?? 0)) < 1.5, "isolation changed the level")
        print(String(format: "100%%: SNR %.1f -> %.1f dB, noise floor %.1f -> %.1f dBFS, %.1f -> %.1f LUFS, %.0fx real time",
                     before.signalToNoiseDB ?? 0, after.signalToNoiseDB ?? 0, before.noiseFloorDBFS, after.noiseFloorDBFS,
                     before.integratedLUFS ?? 0, after.integratedLUFS ?? 0, Double(source.count) / rate / elapsed))

        // 2. A partial amount lands in between.
        let half = VoiceIsolationSettings(amount: 50)
        let halfURL = RecordingVoiceIsolation.renderURL(in: package, settings: half)
        try await RecordingVoiceIsolation.render(screenURL: screenURL, to: halfURL, settings: half) { _ in }
        let halfSNR = VoiceAnalyzer.measure(channels: [try AudioBench.readMono(halfURL)], sampleRate: rate).signalToNoiseDB ?? 0
        #expect(halfSNR > (before.signalToNoiseDB ?? 0) && halfSNR < (after.signalToNoiseDB ?? 0))

        // 3. The swap: narration from the render at its original position,
        // system audio untouched, roles intact.
        let swapped = try await RecordingVoiceIsolation.asset(screenURL: screenURL, isolatedURL: fullURL)
        let tracks = try await swapped.loadTracks(withMediaType: .audio)
        let roles = try await RecordingAudioProcessing.roles(for: tracks, isReplacement: false)
        try #require(Set(roles) == [.voice, .system], "swap must keep one voice and one system track")
        let voiceTrack = tracks[roles.firstIndex(of: .voice)!]
        let systemTrack = tracks[roles.firstIndex(of: .system)!]
        let voiceRange = try await voiceTrack.load(.timeRange)
        #expect(abs(voiceRange.start.seconds - masterVoiceStart) < 0.0001, "narration moved to \(voiceRange.start.seconds) s")
        let swappedVoice = try await AudioBench.readTrack(voiceTrack, of: swapped)
        #expect(abs(swappedVoice.count - isolated.count) <= 1, "swapped narration length changed")
        #expect(AudioBench.errorRatio(reference: isolated, decoded: swappedVoice) < -100, "swapped narration is not the render")
        let swappedSystem = try await AudioBench.readTrack(systemTrack, of: swapped)
        #expect(AudioBench.errorRatio(reference: system, decoded: swappedSystem) < -100, "system audio changed")

        // 4. Exports render on demand when the file is missing, and reuse it.
        RecordingVoiceIsolation.removeRenders(in: package, keeping: nil)
        #expect(!FileManager.default.fileExists(atPath: fullURL.path))
        _ = try await RecordingVoiceIsolation.sourceAsset(screenURL: screenURL, settings: full)
        #expect(FileManager.default.fileExists(atPath: fullURL.path), "export path must render a missing file")
        let stamp = try FileManager.default.attributesOfItem(atPath: fullURL.path)[.modificationDate] as? Date
        _ = try await RecordingVoiceIsolation.sourceAsset(screenURL: screenURL, settings: full)
        let restamp = try FileManager.default.attributesOfItem(atPath: fullURL.path)[.modificationDate] as? Date
        #expect(stamp == restamp, "an existing render must be reused")
        let off = try await RecordingVoiceIsolation.sourceAsset(screenURL: screenURL, settings: VoiceIsolationSettings())
        #expect((off as? AVURLAsset)?.url == screenURL, "isolation off must read the master")

        // 5. A cancelled render leaves no file and no temporary behind.
        RecordingVoiceIsolation.removeRenders(in: package, keeping: nil)
        let task = Task {
            try await RecordingVoiceIsolation.render(screenURL: screenURL, to: fullURL, settings: full) { _ in }
        }
        try await Task.sleep(nanoseconds: 50_000_000)
        task.cancel()
        _ = await task.result
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: package.path).filter { $0 != "screen.mov" }
        #expect(leftovers.isEmpty, "cancelled render left \(leftovers)")
    }

    @Test func projectDirectoryRuleIsInjectable() {
        let saved = RecordingVoiceIsolation.isProjectDirectory
        defer { RecordingVoiceIsolation.isProjectDirectory = saved }
        let movie = URL(fileURLWithPath: "/tmp/anywhere/screen.mov")
        #expect(RecordingVoiceIsolation.projectDirectory(forScreenURL: movie) == nil)
        // Other suites keep rendering into real packages meanwhile.
        RecordingVoiceIsolation.isProjectDirectory = { $0.lastPathComponent == "anywhere" || saved($0) }
        #expect(RecordingVoiceIsolation.projectDirectory(forScreenURL: movie)?.lastPathComponent == "anywhere")
    }

    // MARK: Helpers

    /// Lag (in frames, -50...50) at which `b` best matches `a`.
    static func bestLag(_ a: [Float], _ b: [Float]) -> Int {
        let n = min(a.count, b.count, Int(rate * 10))
        var best = 0
        var bestValue = -Double.infinity
        for lag in -50...50 {
            var sum = 0.0
            for index in stride(from: 100, to: n - 100, by: 2) { sum += Double(a[index]) * Double(b[index + lag]) }
            if sum > bestValue { bestValue = sum; best = lag }
        }
        return best
    }
}
