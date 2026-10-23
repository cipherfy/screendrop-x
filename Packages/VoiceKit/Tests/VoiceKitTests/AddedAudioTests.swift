import AVFoundation
import CoreMedia
import Foundation
import Testing
import VoiceKit
import VoiceKitTestSupport

// Studio can place audio of its own (music, effects) next to the
// recording. Each added clip keeps the volume and fades its own mix
// parameters give it, and joins the mix through an `.added` tap that only
// keeps it in time. This renders narration plus a music track the way the
// export does and checks the music keeps its level whatever the voice and
// system settings, the voice still gets its own processing, and the two
// stay aligned to the frame.
@Suite("Added audio")
struct AddedAudioTests {
    static let rate = AudioBench.rate

    @Test func musicKeepsItsVolumeAndStaysInTime() async throws {
        let seconds = 4.0
        let voice = AudioBench.sine(300, levelDB: -20, seconds: seconds)
        let music = AudioBench.sine(1_000, levelDB: -20, seconds: seconds)
        let musicVolume: Float = 0.5

        try await AudioBench.withTemporaryDirectory(named: "screendrop-added-audio-check") { directory in
            let movie = directory.appendingPathComponent("recording.mov")
            try await AudioBench.writeMovie(to: movie, tracks: [.float([voice]), .float([music, music])])
            let asset = AVURLAsset(url: movie)
            let tracks = try await asset.loadTracks(withMediaType: .audio)
            let voiceTrack = try #require(tracks.first { $0.formatDescriptions.count > 0 && Self.channels($0) == 1 })
            let musicTrack = try #require(tracks.first { Self.channels($0) == 2 })

            func render(_ settings: RecordingAudioSettings) async throws -> [Float] {
                let parameters = RecordingAudioParameters(settings)
                var inputs: [AVAudioMixInputParameters] = RecordingAudioProcessing.inputParameters(
                    tracks: [voiceTrack], roles: [.voice], parameters: parameters
                )
                // The clip's own parameters, as Studio's clip mixer makes them.
                let clip = AVMutableAudioMixInputParameters(track: musicTrack)
                clip.setVolume(musicVolume, at: .zero)
                RecordingAudioProcessing.joinAdded(clip, parameters: parameters)
                inputs.append(clip)
                let mix = AVMutableAudioMix()
                mix.inputParameters = inputs

                let reader = try AVAssetReader(asset: asset)
                let output = AVAssetReaderAudioMixOutput(audioTracks: tracks, audioSettings: RecordingAudioProcessing.mixOutputSettings)
                output.audioMix = mix
                reader.add(output)
                try #require(reader.startReading())
                var limiter = PeakLimiter(sampleRate: Self.rate, channelCount: 2, ceilingDB: RecordingAudioProcessing.ceilingDB)
                var left: [Float] = []
                while let buffer = output.copyNextSampleBuffer() {
                    let limited = try RecordingAudioProcessing.limitMix(buffer, with: &limiter)
                    guard let block = CMSampleBufferGetDataBuffer(limited) else { continue }
                    let length = CMBlockBufferGetDataLength(block)
                    var interleaved = [Float](repeating: 0, count: length / 4)
                    interleaved.withUnsafeMutableBytes {
                        _ = CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: $0.baseAddress!)
                    }
                    left += stride(from: 0, to: interleaved.count, by: 2).map { interleaved[$0] }
                }
                #expect(reader.status == .completed)
                return left
            }

            // Flat voice chain at 0 dB: the render is the voice plus the music
            // at its own volume, both delayed by the same latency.
            let flat = try await render(RecordingAudioSettings(voiceChain: .flat))
            let latency = RecordingAudioProcessing.tapLatency(sampleRate: Self.rate)
                + PeakLimiter.lookaheadFrames(sampleRate: Self.rate)
            let expected = zip(voice, music).map { $0 + $1 * musicVolume }
            let error = AudioBench.errorRatio(reference: expected, decoded: Array(flat.dropFirst(latency)), ignoringLast: 1_024)
            #expect(error < -60, "voice and music must sum in time (\(error) dB)")

            // The music's level is its own: system muted, voice boosted.
            let musicLevel = AudioBench.level(flat, at: 1_000)
            let voiceLevel = AudioBench.level(flat, at: 300)
            let changed = try await render(RecordingAudioSettings(voiceGainDB: 6, systemGainDB: -60, voiceChain: .flat))
            let musicShift = AudioBench.level(changed, at: 1_000) - musicLevel
            let voiceShift = AudioBench.level(changed, at: 300) - voiceLevel
            #expect(abs(musicShift) < 0.05, "system and voice settings moved the music by \(musicShift) dB")
            #expect(abs(voiceShift - 6) < 0.1, "voice +6 dB moved the voice by \(voiceShift) dB")

            let musicGain = musicLevel - AudioBench.level(music, at: 1_000)
            #expect(abs(musicGain - 20 * log10(Double(musicVolume))) < 0.1, "music volume came out at \(musicGain) dB")
            print(String(format: "voice and music aligned (difference %.0f dB); music at %.2f dB of its own volume, unmoved by voice and system settings (%.2f dB); voice +6 dB reads %+.2f dB",
                         error, musicGain, musicShift, voiceShift))
        }
    }

    static func channels(_ track: AVAssetTrack) -> UInt32 {
        (track.formatDescriptions as? [CMFormatDescription] ?? [])
            .compactMap { $0.audioStreamBasicDescription?.mChannelsPerFrame }.max() ?? 0
    }
}
