import AVFoundation
import CoreMedia
import Foundation

// Compile with RecordingAudioProcessing.swift, VoiceChain.swift, VoiceProfile.swift, and VoiceMeasurement.swift:
//
//   xcrun swiftc -O Screendrop/RecordingAudioProcessing.swift Screendrop/VoiceChain.swift Screendrop/VoiceProfile.swift Screendrop/VoiceMeasurement.swift \
//     scripts/check-audio-processing.swift -o build/check-audio-processing
//   build/check-audio-processing build/voice-bank/variants/paulina-clean.wav
//
// Builds a recording with a mono narration track and a stereo system track
// and renders it the way the exporters do (per-track taps, float mix, mix
// limiter), checking gains, muting, the voice processing switch, the
// ceiling, and that live gain changes glide instead of clicking.
@main
struct AudioProcessingCheck {
    static let sampleRate = 48_000.0
    static let ceiling = Float(pow(10, RecordingAudioProcessing.ceilingDB / 20))

    static func main() async throws {
        setvbuf(stdout, nil, _IONBF, 0)
        guard CommandLine.arguments.count == 2 else {
            print("usage: check-audio-processing <mono narration.wav>")
            exit(2)
        }
        let voice = try readMono(URL(fileURLWithPath: CommandLine.arguments[1]))
        var random = SystemRandomNumberGenerator()
        // System audio: steady noise well under the voice.
        let system = (0..<voice.count).map { _ in Float.random(in: -0.02...0.02, using: &random) }

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("screendrop-processing-check-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let movie = directory.appendingPathComponent("recording.mov")
        try await writeMovie(to: movie, voice: voice, system: system)
        let asset = AVURLAsset(url: movie)
        let tracks = try await asset.loadTracks(withMediaType: .audio)

        // Roles follow channel count; a replacement is always narration.
        let roles = try await RecordingAudioProcessing.roles(for: tracks, isReplacement: false)
        precondition(Set(roles) == [.voice, .system], "expected one voice and one system track")
        let replacementRoles = try await RecordingAudioProcessing.roles(for: tracks, isReplacement: true)
        precondition(replacementRoles.allSatisfy { $0 == .voice })
        print("ok  mono track is voice, stereo track is system, replacements are voice")

        // Legacy single volume migrates to both gains.
        let legacy = RecordingAudioSettings(legacyVolume: 2)
        precondition(abs(legacy.voiceGainDB - 6.02) < 0.01 && abs(legacy.systemGainDB - 6.02) < 0.01)
        precondition(RecordingAudioSettings(legacyVolume: 0).linearGain(for: .system) == 0)
        print("ok  legacy volume 200% becomes +6.0 dB on both tracks, 0% mutes")

        // Unity, with the voice chain flat: the render is the plain sum,
        // delayed by the taps' latency and the mix limiter's look-ahead.
        let flat = RecordingAudioSettings(voiceChain: .flat)
        let unity = try await render(asset, tracks, flat)
        let lookahead = RecordingAudioProcessing.tapLatency(sampleRate: sampleRate)
            + PeakLimiter.lookaheadFrames(sampleRate: sampleRate)
        let sum = zip(voice, system).map(+)
        let unityError = errorRatio(reference: sum, decoded: Array(unity.dropFirst(lookahead)))
        precondition(unityError < -60, "unity render must match the sum (\(unityError) dB)")
        print(String(format: "ok  0 dB renders the sum of the tracks (difference %.0f dB, %.2f ms latency)", unityError, Double(lookahead) / sampleRate * 1_000))

        // System at the bottom of its range is muted.
        let muted = try await render(asset, tracks, RecordingAudioSettings(systemGainDB: -60, voiceChain: .flat))
        let mutedError = errorRatio(reference: voice, decoded: Array(muted.dropFirst(lookahead)))
        precondition(mutedError < -60, "muted system audio must leave the voice alone (\(mutedError) dB)")
        print(String(format: "ok  system at -60 dB is muted (difference from voice alone %.0f dB)", mutedError))

        // Voice gain moves the voice and only the voice.
        let base = loudness(try await render(asset, tracks, RecordingAudioSettings(systemGainDB: -60, voiceChain: .flat)))
        let boosted = loudness(try await render(asset, tracks, RecordingAudioSettings(voiceGainDB: 6, systemGainDB: -60, voiceChain: .flat)))
        precondition(abs(boosted - base - 6) < 0.2, "voice +6 dB moved loudness by \(boosted - base)")
        print(String(format: "ok  voice +6 dB raises loudness by %.2f LU", boosted - base))

        // Pushed hard: the ceiling holds with processing on and off, now on
        // true peak as well.
        for processing in [true, false] {
            let hot = try await render(asset, tracks, RecordingAudioSettings(voiceGainDB: 24, voiceProcessingEnabled: processing))
            let peak = hot.map(abs).max() ?? 0
            let atCeiling = hot.filter { abs($0) >= ceiling * 0.9999 }.count
            precondition(peak <= ceiling + 1e-6, "peak \(peak) is above the ceiling")
            let hotTruePeak = VoiceAnalyzer.measure(channels: [hot], sampleRate: sampleRate).truePeakDBTP
            precondition(hotTruePeak <= -0.9, "true peak \(hotTruePeak) dBTP is above the ceiling")
            let measured = VoiceAnalyzer.measure(channels: [hot], sampleRate: sampleRate)
            print(String(format: "ok  voice +24 dB, processing %@: peak %.2f dBFS, true peak %.2f dBTP, %d samples at the ceiling, %.1f LUFS",
                         processing ? "on " : "off", 20 * log10(Double(peak)), measured.truePeakDBTP, atCeiling,
                         measured.integratedLUFS ?? 0))
        }

        // The old hard clip on the same material, for comparison.
        let clipped = voice.map { min(1, max(-1, $0 * 15.85)) }
        let clippedAtFullScale = clipped.filter { abs($0) >= 0.9999 }.count
        print("    the previous hard clip at +24 dB flattened \(clippedAtFullScale) samples at full scale")

        // Live changes glide: no step larger than the program's own.
        let steady = (0..<Int(sampleRate * 30)).map { Float(0.1 * sin(2 * .pi * 220 * Double($0) / sampleRate)) }
        let toneMovie = directory.appendingPathComponent("tone.mov")
        try await writeMovie(to: toneMovie, voice: steady, system: [Float](repeating: 0, count: steady.count))
        let toneAsset = AVURLAsset(url: toneMovie)
        let toneTracks = try await toneAsset.loadTracks(withMediaType: .audio)
        let parameters = RecordingAudioParameters(RecordingAudioSettings(voiceChain: .flat))
        let switched = try await render(toneAsset, toneTracks, parameters: parameters) { buffer in
            // Jump the gain by 12 dB partway through, as a slider drag would.
            if buffer == 40 { parameters.update(RecordingAudioSettings(voiceGainDB: 12, voiceChain: .flat)) }
        }
        let maxStep = zip(switched.dropFirst(), switched).map { abs($0 - $1) }.max() ?? 0
        let naturalStep = Float(2 * .pi * 220 / sampleRate) * 0.1 * pow(10, 12 / 20)
        precondition(maxStep < naturalStep * 1.05, "gain change clicked (step \(maxStep))")
        // The reader renders ahead of what it hands out, so the change lands
        // somewhat after buffer 40; by the end it must have fully settled.
        let finalLevel = switched.suffix(4_800).map(abs).max() ?? 0
        let landed = 20 * log10(Double(finalLevel / 0.1))
        precondition(abs(landed - 12) < 0.2, "gain change landed at \(landed) dB, not +12 dB")
        print("ok  a +12 dB change during playback glides with no click and lands at +12 dB")

        print("all audio processing checks passed")
    }

    // MARK: Rendering, as the exporters do

    static func render(_ asset: AVAsset, _ tracks: [AVAssetTrack], _ settings: RecordingAudioSettings) async throws -> [Float] {
        try await render(asset, tracks, parameters: RecordingAudioParameters(settings), onBuffer: { _ in })
    }

    /// Returns the left channel of the limited mix.
    static func render(
        _ asset: AVAsset,
        _ tracks: [AVAssetTrack],
        parameters: RecordingAudioParameters,
        onBuffer: (Int) -> Void
    ) async throws -> [Float] {
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderAudioMixOutput(audioTracks: tracks, audioSettings: RecordingAudioProcessing.mixOutputSettings)
        output.audioMix = RecordingAudioProcessing.makeMix(
            tracks: tracks,
            roles: try await RecordingAudioProcessing.roles(for: tracks, isReplacement: false),
            parameters: parameters
        )
        reader.add(output)
        precondition(reader.startReading())
        var limiter = PeakLimiter(sampleRate: 48_000, channelCount: 2, ceilingDB: RecordingAudioProcessing.ceilingDB)
        var left: [Float] = []
        var index = 0
        while let buffer = output.copyNextSampleBuffer() {
            onBuffer(index)
            index += 1
            let limited = try RecordingAudioProcessing.limitMix(buffer, with: &limiter)
            guard let block = CMSampleBufferGetDataBuffer(limited) else { continue }
            let length = CMBlockBufferGetDataLength(block)
            var interleaved = [Float](repeating: 0, count: length / 4)
            interleaved.withUnsafeMutableBytes {
                _ = CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: $0.baseAddress!)
            }
            left += stride(from: 0, to: interleaved.count, by: 2).map { interleaved[$0] }
        }
        precondition(reader.status == .completed)
        return left
    }

    // MARK: Writing, as the recorder does

    static func writeMovie(to url: URL, voice: [Float], system: [Float]) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let systemInput = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false
        ])
        let voiceInput = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false
        ])
        for input in [systemInput, voiceInput] {
            input.expectsMediaDataInRealTime = false
            writer.add(input)
        }
        precondition(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        let mono = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
        let stereo = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2)!
        for start in stride(from: 0, to: voice.count, by: 1024) {
            let end = min(start + 1024, voice.count)
            let time = CMTime(value: CMTimeValue(start), timescale: CMTimeScale(sampleRate))
            let voiceBuffer = try sampleBuffer([Array(voice[start..<end])], format: mono, at: time)
            let systemSlice = Array(system[start..<end])
            let systemBuffer = try sampleBuffer([systemSlice, systemSlice], format: stereo, at: time)
            while !voiceInput.isReadyForMoreMediaData || !systemInput.isReadyForMoreMediaData {
                try await Task.sleep(nanoseconds: 1_000_000)
            }
            precondition(voiceInput.append(voiceBuffer) && systemInput.append(systemBuffer))
        }
        systemInput.markAsFinished()
        voiceInput.markAsFinished()
        await writer.finishWriting()
        precondition(writer.status == .completed)
    }

    static func sampleBuffer(_ channels: [[Float]], format: AVAudioFormat, at time: CMTime) throws -> CMSampleBuffer {
        let frames = channels[0].count
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))!
        buffer.frameLength = AVAudioFrameCount(frames)
        for (index, channel) in channels.enumerated() {
            channel.withUnsafeBufferPointer { buffer.floatChannelData![index].update(from: $0.baseAddress!, count: frames) }
        }
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: CMTimeScale(sampleRate)),
                                        presentationTimeStamp: time, decodeTimeStamp: .invalid)
        var result: CMSampleBuffer?
        _ = CMSampleBufferCreate(allocator: kCFAllocatorDefault, dataBuffer: nil, dataReady: false,
                                 makeDataReadyCallback: nil, refcon: nil, formatDescription: format.formatDescription,
                                 sampleCount: frames, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
                                 sampleSizeEntryCount: 0, sampleSizeArray: nil, sampleBufferOut: &result)
        let status = CMSampleBufferSetDataBufferFromAudioBufferList(
            result!, blockBufferAllocator: kCFAllocatorDefault, blockBufferMemoryAllocator: kCFAllocatorDefault,
            flags: 0, bufferList: buffer.audioBufferList)
        precondition(status == noErr)
        return result!
    }

    // MARK: Helpers

    static func readMono(_ url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        precondition(file.processingFormat.channelCount == 1 && file.processingFormat.sampleRate == sampleRate,
                     "use a mono 48 kHz file, such as build/voice-bank/variants/paulina-clean.wav")
        let buffer = try file.readAll()
        return Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
    }

    static func loudness(_ samples: [Float]) -> Double {
        VoiceAnalyzer.measure(channels: [samples], sampleRate: sampleRate).integratedLUFS ?? -.infinity
    }

    static func errorRatio(reference: [Float], decoded: [Float]) -> Double {
        let count = min(reference.count, decoded.count) - 1_024
        var signal = 0.0
        var error = 0.0
        for index in 0..<count {
            let difference = Double(decoded[index] - reference[index])
            signal += Double(reference[index] * reference[index])
            error += difference * difference
        }
        return error > 0 ? 10 * log10(error / signal) : -200
    }
}

extension AVAudioFile {
    /// Reads the whole file. A single `read(into:)` can stop short of the
    /// end, so this keeps reading until the file reports no more frames.
    func readAll() throws -> AVAudioPCMBuffer {
        let all = AVAudioPCMBuffer(pcmFormat: processingFormat, frameCapacity: AVAudioFrameCount(max(1, length)))!
        let chunk = AVAudioPCMBuffer(pcmFormat: processingFormat, frameCapacity: 65_536)!
        framePosition = 0
        while framePosition < length {
            try read(into: chunk, frameCount: min(chunk.frameCapacity, AVAudioFrameCount(length - framePosition)))
            guard chunk.frameLength > 0 else { break }
            for channel in 0..<Int(processingFormat.channelCount) {
                (all.floatChannelData![channel] + Int(all.frameLength))
                    .update(from: chunk.floatChannelData![channel], count: Int(chunk.frameLength))
            }
            all.frameLength += chunk.frameLength
        }
        return all
    }
}
