import AVFoundation
import CoreMedia
import Foundation
import Testing
import VoiceKit
import VoiceKitTestSupport

// Writes a narration file the way ScreenRecordingWriter does (fragmented
// .mov, stereo AAC system track, mono microphone track) with the current
// lossless microphone settings and with the previous AAC 96 kbps ones,
// then reads it back through the paths Studio uses: track detection for
// transcription, the gain mix for playback and export, and the M4A export
// that feeds the speech transcriber.
@Suite("Microphone capture", .enabled(if: AudioBench.isVoiceBankAvailable, Comment(rawValue: AudioBench.voiceBankMissing)))
struct MicrophoneCaptureTests {
    static let sampleRate = AudioBench.rate

    /// Must match ScreenRecordingWriter.microphoneAudioSettings.
    static let losslessSettings: [String: Any] = [
        AVFormatIDKey: kAudioFormatLinearPCM,
        AVSampleRateKey: 48_000,
        AVNumberOfChannelsKey: 1,
        AVLinearPCMBitDepthKey: 24,
        AVLinearPCMIsFloatKey: false,
        AVLinearPCMIsBigEndianKey: false,
        AVLinearPCMIsNonInterleaved: false
    ]

    static let previousSettings: [String: Any] = [
        AVFormatIDKey: kAudioFormatMPEG4AAC,
        AVSampleRateKey: 48_000,
        AVNumberOfChannelsKey: 1,
        AVEncoderBitRateKey: 96_000
    ]

    static let systemSettings: [String: Any] = [
        AVFormatIDKey: kAudioFormatMPEG4AAC,
        AVSampleRateKey: 48_000,
        AVNumberOfChannelsKey: 2,
        AVEncoderBitRateKey: 192_000
    ]

    @Test func losslessCaptureReadsBackThroughStudio() async throws {
        let source = try AudioBench.bankTake("paulina-clean")
        try await AudioBench.withTemporaryDirectory(named: "screendrop-mic-check") { directory in
            let lossless = directory.appendingPathComponent("lossless.mov")
            let previous = directory.appendingPathComponent("aac96.mov")
            try await Self.writeMovie(to: lossless, narration: source, microphoneSettings: Self.losslessSettings)
            try await Self.writeMovie(to: previous, narration: source, microphoneSettings: Self.previousSettings)

            // 1. The microphone track is lossless 24-bit mono.
            let asset = AVURLAsset(url: lossless)
            let tracks = try await asset.loadTracks(withMediaType: .audio)
            try #require(tracks.count == 2, "expected system and microphone tracks")
            let microphone = try await Self.narrationTrack(in: tracks)
            let description = try await microphone.load(.formatDescriptions).first?.audioStreamBasicDescription
            #expect(description?.mFormatID == kAudioFormatLinearPCM, "microphone track must be LPCM")
            #expect(description?.mBitsPerChannel == 24, "microphone track must be 24-bit")
            #expect(description?.mChannelsPerFrame == 1, "microphone track must stay mono")
            #expect(description?.mSampleRate == Self.sampleRate)

            // 2. Transcription's rule (the mono track is narration) still holds.
            let systemTrack = try #require(tracks.first { $0 != microphone })
            let systemChannels = try await systemTrack.load(.formatDescriptions).first?.audioStreamBasicDescription?.mChannelsPerFrame
            #expect(systemChannels == 2)

            // 3. The capture is bit-transparent to 24-bit, unlike AAC.
            let decoded = try await AudioBench.readTrack(microphone, of: asset)
            let previousAsset = AVURLAsset(url: previous)
            let decodedPrevious = try await AudioBench.readTrack(
                try await Self.narrationTrack(in: previousAsset.loadTracks(withMediaType: .audio)),
                of: previousAsset
            )
            let losslessError = AudioBench.errorRatio(reference: source, decoded: decoded)
            let previousError = AudioBench.errorRatio(reference: source, decoded: decodedPrevious)
            #expect(losslessError < -130, "lossless capture must be within 24-bit quantization")
            print(String(format: "deviation from source: lossless %.1f dB, previous AAC 96 kbps %.1f dB", losslessError, previousError))

            // 4. Playback and export read it through the per-track taps.
            for gain in [0.0, -6.0, 6.0] {
                let mixed = try await Self.readMix(asset: asset, tracks: tracks, voiceGainDB: gain)
                #expect(mixed.count >= source.count - 1024, "mix output is truncated")
            }

            // 5. The narration M4A export transcription relies on still works.
            let composition = AVMutableComposition()
            let compositionTrack = try #require(composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid))
            let range = try await microphone.load(.timeRange)
            try compositionTrack.insertTimeRange(range, of: microphone, at: range.start)
            let export = try #require(AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetAppleM4A))
            let narrationURL = directory.appendingPathComponent("narration.m4a")
            try await export.export(to: narrationURL, as: .m4a)
            let narrationDuration = try await AVURLAsset(url: narrationURL).load(.duration).seconds
            #expect(abs(narrationDuration - Double(source.count) / Self.sampleRate) < 0.1)

            // 5b. Measured loudness survives capture unchanged.
            let before = VoiceAnalyzer.measure(channels: [source], sampleRate: Self.sampleRate)
            let after = VoiceAnalyzer.measure(channels: [decoded], sampleRate: Self.sampleRate)
            #expect(abs((before.integratedLUFS ?? 0) - (after.integratedLUFS ?? 0)) < 0.05)

            let sizes = try [lossless, previous].map { try FileManager.default.attributesOfItem(atPath: $0.path)[.size] as! Int }
            let minutes = Double(source.count) / Self.sampleRate / 60
            print(String(format: "file size per minute: lossless %.1f MB, previous %.1f MB (both include system audio)",
                         Double(sizes[0]) / minutes / 1_000_000, Double(sizes[1]) / minutes / 1_000_000))
        }
    }

    // MARK: Writing

    /// ScreenCaptureKit hands over float buffers of about 1024 frames; the
    /// system track carries the narration 20 dB down.
    static func writeMovie(to url: URL, narration: [Float], microphoneSettings: [String: Any]) async throws {
        let quietSystem = narration.map { $0 * 0.1 }
        try await AudioBench.writeMovie(
            to: url,
            tracks: [
                .init(channels: [quietSystem, quietSystem], settings: systemSettings),
                .init(channels: [narration], settings: microphoneSettings)
            ],
            fragmentInterval: CMTime(seconds: 2, preferredTimescale: 600)
        )
    }

    // MARK: Reading

    /// The rule RecordingTranscription uses: the mono track is narration.
    static func narrationTrack(in tracks: [AVAssetTrack]) async throws -> AVAssetTrack {
        for track in tracks {
            let channels = try await track.load(.formatDescriptions).first?.audioStreamBasicDescription?.mChannelsPerFrame
            if channels == 1 { return track }
        }
        return tracks.last!
    }

    static func readMix(asset: AVAsset, tracks: [AVAssetTrack], voiceGainDB: Double) async throws -> [Float] {
        let reader = try AVAssetReader(asset: asset)
        var settings = AudioBench.floatReadSettings
        settings[AVSampleRateKey] = 48_000
        settings[AVNumberOfChannelsKey] = 2
        let output = AVAssetReaderAudioMixOutput(audioTracks: tracks, audioSettings: settings)
        output.audioMix = RecordingAudioProcessing.makeMix(
            tracks: tracks,
            roles: try await RecordingAudioProcessing.roles(for: tracks, isReplacement: false),
            parameters: RecordingAudioParameters(RecordingAudioSettings(voiceGainDB: voiceGainDB))
        )
        reader.add(output)
        let interleaved = try AudioBench.drain(reader, output).samples
        return stride(from: 0, to: interleaved.count, by: 2).map { interleaved[$0] }
    }
}
