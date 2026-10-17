import AVFoundation
import CoreMedia
import Foundation

// Compile with RecordingAudioProcessing.swift, VoiceChain.swift, and VoiceMeasurement.swift:
//
//   xcrun swiftc -O Screendrop/RecordingAudioProcessing.swift Screendrop/VoiceChain.swift Screendrop/VoiceMeasurement.swift \
//     scripts/check-microphone-capture.swift -o build/check-microphone-capture
//   build/check-microphone-capture build/voice-bank/variants/paulina-clean.wav
//
// Writes a narration file the way ScreenRecordingWriter does (fragmented
// .mov, stereo AAC system track, mono microphone track) with the current
// lossless microphone settings and with the previous AAC 96 kbps ones,
// then reads it back through the paths Studio uses: track detection for
// transcription, the gain mix for playback and export, and the M4A export
// that feeds the speech transcriber.
@main
struct MicrophoneCaptureCheck {
    static let sampleRate = 48_000.0

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

    static func main() async throws {
        guard CommandLine.arguments.count == 2 else {
            print("usage: check-microphone-capture <mono narration.wav>")
            exit(2)
        }
        let source = try readMono(URL(fileURLWithPath: CommandLine.arguments[1]))
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("screendrop-mic-check-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let lossless = directory.appendingPathComponent("lossless.mov")
        let previous = directory.appendingPathComponent("aac96.mov")
        try await writeMovie(to: lossless, narration: source, microphoneSettings: losslessSettings)
        try await writeMovie(to: previous, narration: source, microphoneSettings: previousSettings)

        // 1. The microphone track is lossless 24-bit mono.
        let asset = AVURLAsset(url: lossless)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        precondition(tracks.count == 2, "expected system and microphone tracks")
        let microphone = try await narrationTrack(in: tracks)
        let description = try await microphone.load(.formatDescriptions).first?.audioStreamBasicDescription
        precondition(description?.mFormatID == kAudioFormatLinearPCM, "microphone track must be LPCM")
        precondition(description?.mBitsPerChannel == 24, "microphone track must be 24-bit")
        precondition(description?.mChannelsPerFrame == 1, "microphone track must stay mono")
        precondition(description?.mSampleRate == sampleRate)
        print("ok  microphone track is LPCM 24-bit mono 48 kHz")

        // 2. Transcription's rule (the mono track is narration) still holds.
        let systemTrack = tracks.first { $0 != microphone }!
        let systemChannels = try await systemTrack.load(.formatDescriptions).first?.audioStreamBasicDescription?.mChannelsPerFrame
        precondition(systemChannels == 2)
        print("ok  transcription picks the mono track as narration")

        // 3. The capture is bit-transparent to 24-bit, unlike AAC.
        let decoded = try await readTrack(microphone, of: asset)
        let previousAsset = AVURLAsset(url: previous)
        let decodedPrevious = try await readTrack(
            try await narrationTrack(in: previousAsset.loadTracks(withMediaType: .audio)),
            of: previousAsset
        )
        let losslessError = errorRatio(reference: source, decoded: decoded)
        let previousError = errorRatio(reference: source, decoded: decodedPrevious)
        precondition(losslessError < -130, "lossless capture must be within 24-bit quantization")
        print(String(format: "ok  deviation from source: lossless %.1f dB, previous AAC 96 kbps %.1f dB", losslessError, previousError))

        // 4. Playback and export read it through the per-track taps.
        for gain in [0.0, -6.0, 6.0] {
            let mixed = try await readMix(asset: asset, tracks: tracks, voiceGainDB: gain)
            precondition(mixed.count >= source.count - 1024, "mix output is truncated")
            print(String(format: "ok  processing mix at voice %+.0f dB reads %d stereo frames", gain, mixed.count))
        }

        // 5. The narration M4A export transcription relies on still works.
        let composition = AVMutableComposition()
        let compositionTrack = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)!
        let range = try await microphone.load(.timeRange)
        try compositionTrack.insertTimeRange(range, of: microphone, at: range.start)
        let export = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetAppleM4A)!
        let narrationURL = directory.appendingPathComponent("narration.m4a")
        try await export.export(to: narrationURL, as: .m4a)
        let narrationDuration = try await AVURLAsset(url: narrationURL).load(.duration).seconds
        precondition(abs(narrationDuration - Double(source.count) / sampleRate) < 0.1)
        print("ok  narration exports to M4A for transcription")

        // 5b. Measured loudness survives capture unchanged.
        let before = VoiceAnalyzer.measure(channels: [source], sampleRate: sampleRate)
        let after = VoiceAnalyzer.measure(channels: [decoded], sampleRate: sampleRate)
        precondition(abs((before.integratedLUFS ?? 0) - (after.integratedLUFS ?? 0)) < 0.05)
        print(String(format: "ok  loudness %.2f LUFS before and %.2f after capture", before.integratedLUFS ?? 0, after.integratedLUFS ?? 0))

        let sizes = try [lossless, previous].map { try FileManager.default.attributesOfItem(atPath: $0.path)[.size] as! Int }
        let minutes = Double(source.count) / sampleRate / 60
        print(String(format: "    file size per minute: lossless %.1f MB, previous %.1f MB (both include system audio)",
                     Double(sizes[0]) / minutes / 1_000_000, Double(sizes[1]) / minutes / 1_000_000))
        print("all microphone capture checks passed")
    }

    // MARK: Writing

    static func writeMovie(to url: URL, narration: [Float], microphoneSettings: [String: Any]) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        writer.movieFragmentInterval = CMTime(seconds: 2, preferredTimescale: 600)
        let system = AVAssetWriterInput(mediaType: .audio, outputSettings: systemSettings)
        let microphone = AVAssetWriterInput(mediaType: .audio, outputSettings: microphoneSettings)
        for input in [system, microphone] {
            input.expectsMediaDataInRealTime = false
            writer.add(input)
        }
        precondition(writer.startWriting(), "\(writer.error.map(String.init(describing:)) ?? "writer failed")")
        writer.startSession(atSourceTime: .zero)

        // ScreenCaptureKit hands over float buffers of about 1024 frames.
        let monoFormat = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
        let stereoFormat = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2)!
        let chunk = 1024
        for start in stride(from: 0, to: narration.count, by: chunk) {
            let slice = Array(narration[start..<min(start + chunk, narration.count)])
            let time = CMTime(value: CMTimeValue(start), timescale: CMTimeScale(sampleRate))
            let quietSystem = slice.map { $0 * 0.1 }
            while !microphone.isReadyForMoreMediaData || !system.isReadyForMoreMediaData {
                try await Task.sleep(nanoseconds: 1_000_000)
            }
            let microphoneBuffer = try sampleBuffer([slice], format: monoFormat, at: time)
            let systemBuffer = try sampleBuffer([quietSystem, quietSystem], format: stereoFormat, at: time)
            precondition(microphone.append(microphoneBuffer) && system.append(systemBuffer))
        }
        system.markAsFinished()
        microphone.markAsFinished()
        await writer.finishWriting()
        precondition(writer.status == .completed, "\(writer.error.map(String.init(describing:)) ?? "writer failed")")
    }

    static func sampleBuffer(_ channels: [[Float]], format: AVAudioFormat, at time: CMTime) throws -> CMSampleBuffer {
        let frames = channels[0].count
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))!
        buffer.frameLength = AVAudioFrameCount(frames)
        for (index, channel) in channels.enumerated() {
            channel.withUnsafeBufferPointer { buffer.floatChannelData![index].update(from: $0.baseAddress!, count: frames) }
        }
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: CMTimeScale(sampleRate)),
            presentationTimeStamp: time,
            decodeTimeStamp: .invalid
        )
        var result: CMSampleBuffer?
        var status = CMSampleBufferCreate(
            allocator: kCFAllocatorDefault, dataBuffer: nil, dataReady: false,
            makeDataReadyCallback: nil, refcon: nil,
            formatDescription: format.formatDescription, sampleCount: frames,
            sampleTimingEntryCount: 1, sampleTimingArray: &timing,
            sampleSizeEntryCount: 0, sampleSizeArray: nil, sampleBufferOut: &result
        )
        guard status == noErr, let result else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
        status = CMSampleBufferSetDataBufferFromAudioBufferList(
            result, blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault, flags: 0,
            bufferList: buffer.audioBufferList
        )
        guard status == noErr else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
        return result
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

    static let floatSettings: [String: Any] = [
        AVFormatIDKey: kAudioFormatLinearPCM,
        AVLinearPCMBitDepthKey: 32,
        AVLinearPCMIsFloatKey: true,
        AVLinearPCMIsBigEndianKey: false,
        AVLinearPCMIsNonInterleaved: false
    ]

    static func readTrack(_ track: AVAssetTrack, of asset: AVAsset) async throws -> [Float] {
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: floatSettings)
        reader.add(output)
        return drain(reader, output)
    }

    static func readMix(asset: AVAsset, tracks: [AVAssetTrack], voiceGainDB: Double) async throws -> [Float] {
        let reader = try AVAssetReader(asset: asset)
        var settings = floatSettings
        settings[AVSampleRateKey] = 48_000
        settings[AVNumberOfChannelsKey] = 2
        let output = AVAssetReaderAudioMixOutput(audioTracks: tracks, audioSettings: settings)
        output.audioMix = RecordingAudioProcessing.makeMix(
            tracks: tracks,
            roles: try await RecordingAudioProcessing.roles(for: tracks, isReplacement: false),
            parameters: RecordingAudioParameters(RecordingAudioSettings(voiceGainDB: voiceGainDB))
        )
        reader.add(output)
        let interleaved = drain(reader, output)
        return stride(from: 0, to: interleaved.count, by: 2).map { interleaved[$0] }
    }

    static func drain(_ reader: AVAssetReader, _ output: AVAssetReaderOutput) -> [Float] {
        precondition(reader.startReading(), "\(reader.error.map(String.init(describing:)) ?? "reader failed")")
        var samples: [Float] = []
        while let buffer = output.copyNextSampleBuffer(), let block = CMSampleBufferGetDataBuffer(buffer) {
            let length = CMBlockBufferGetDataLength(block)
            var chunk = [Float](repeating: 0, count: length / MemoryLayout<Float>.size)
            chunk.withUnsafeMutableBytes {
                _ = CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: $0.baseAddress!)
            }
            samples += chunk
        }
        precondition(reader.status == .completed, "\(reader.error.map(String.init(describing:)) ?? "reader failed")")
        return samples
    }

    static func readMono(_ url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        precondition(file.processingFormat.channelCount == 1 && file.processingFormat.sampleRate == sampleRate,
                     "use a mono 48 kHz file, such as build/voice-bank/variants/paulina-clean.wav")
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
        try file.read(into: buffer)
        return Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
    }

    /// Energy of the difference relative to the source, in dB.
    static func errorRatio(reference: [Float], decoded: [Float]) -> Double {
        let count = min(reference.count, decoded.count)
        var signal = 0.0
        var error = 0.0
        for index in 0..<count {
            let difference = Double(decoded[index] - reference[index])
            signal += Double(reference[index]) * Double(reference[index])
            error += difference * difference
        }
        return error > 0 ? 10 * log10(error / signal) : -200
    }
}
