import AVFoundation
import Foundation

// Compile with the isolation, tap, chain, and meter sources:
//
//   xcrun swiftc -O Screendrop/RecordingVoiceIsolation.swift Screendrop/RecordingAudioProcessing.swift \
//     Screendrop/VoiceChain.swift Screendrop/VoiceMeasurement.swift scripts/check-voice-isolation.swift \
//     -o build/check-voice-isolation
//   build/check-voice-isolation build/voice-bank/variants/paulina-usb-condenser-desk.wav
//
// Builds a project package around a noisy narration (starting half a
// second into the movie, beside a stereo system track) and checks the
// isolation render: alignment, how much room and noise it removes, partial
// amounts, the track swap, on-demand rendering for exports, and that a
// cancelled render leaves nothing behind.

/// The one rule of RecordingSession that isolation relies on, without
/// compiling the rest of the app.
enum RecordingSession {
    static func isSessionDirectory(_ url: URL) -> Bool {
        url.pathExtension == "screendroprec"
            && FileManager.default.fileExists(atPath: url.appendingPathComponent("screen.mov").path)
    }
}

@main
struct VoiceIsolationCheck {
    static let rate = 48_000.0
    static let offset = 0.5

    static func main() async throws {
        setvbuf(stdout, nil, _IONBF, 0)
        guard CommandLine.arguments.count == 2 else {
            print("usage: check-voice-isolation <mono narration.wav>")
            exit(2)
        }
        let narration = try readMono(URL(fileURLWithPath: CommandLine.arguments[1]))
        let system = (0..<narration.count).map { Float(0.02 * sin(2 * .pi * 440 * Double($0) / rate)) }

        let package = FileManager.default.temporaryDirectory
            .appendingPathComponent("isolation-check-\(UUID().uuidString).screendroprec", isDirectory: true)
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: package) }
        let screenURL = package.appendingPathComponent("screen.mov")
        try await writeMovie(to: screenURL, narration: narration, system: system)
        precondition(RecordingVoiceIsolation.projectDirectory(forScreenURL: screenURL) == package)

        // The narration as the movie holds it: read through the same path
        // the render reads, including any lead-in the writer recorded as an
        // empty edit before the microphone's first sample.
        let master = AVURLAsset(url: screenURL)
        let masterTracks = try await master.loadTracks(withMediaType: .audio)
        let masterRoles = try await RecordingAudioProcessing.roles(for: masterTracks, isReplacement: false)
        let masterVoice = masterTracks[masterRoles.firstIndex(of: .voice)!]
        let masterVoiceStart = try await masterVoice.load(.timeRange).start.seconds
        let source = try await readTrack(masterVoice, of: master)

        // 1. Render at full strength: same length, aligned, cleaner.
        let full = VoiceIsolationSettings(amount: 100)
        let fullURL = RecordingVoiceIsolation.renderURL(in: package, settings: full)
        let started = Date()
        try await RecordingVoiceIsolation.render(screenURL: screenURL, to: fullURL, settings: full) { _ in }
        let elapsed = Date().timeIntervalSince(started)
        let isolated = try readMono(fullURL)
        precondition(abs(isolated.count - source.count) <= 1, "render length \(isolated.count) vs \(source.count)")
        let lag = bestLag(source, isolated)
        precondition(lag == 0, "render is shifted by \(lag) frames")
        let before = VoiceAnalyzer.measure(channels: [source], sampleRate: rate)
        let after = VoiceAnalyzer.measure(channels: [isolated], sampleRate: rate)
        let gain = (after.signalToNoiseDB ?? 0) - (before.signalToNoiseDB ?? 0)
        precondition(gain > 10, "isolation improved SNR by only \(gain) dB")
        precondition(abs((after.integratedLUFS ?? 0) - (before.integratedLUFS ?? 0)) < 1.5, "isolation changed the level")
        print(String(format: "ok  100%%: aligned to the frame, SNR %.1f -> %.1f dB, noise floor %.1f -> %.1f dBFS, %.1f -> %.1f LUFS, %.0fx real time",
                     before.signalToNoiseDB ?? 0, after.signalToNoiseDB ?? 0, before.noiseFloorDBFS, after.noiseFloorDBFS,
                     before.integratedLUFS ?? 0, after.integratedLUFS ?? 0, Double(source.count) / rate / elapsed))

        // 2. A partial amount lands in between.
        let half = VoiceIsolationSettings(amount: 50)
        let halfURL = RecordingVoiceIsolation.renderURL(in: package, settings: half)
        try await RecordingVoiceIsolation.render(screenURL: screenURL, to: halfURL, settings: half) { _ in }
        let halfSNR = VoiceAnalyzer.measure(channels: [try readMono(halfURL)], sampleRate: rate).signalToNoiseDB ?? 0
        precondition(halfSNR > (before.signalToNoiseDB ?? 0) && halfSNR < (after.signalToNoiseDB ?? 0))
        print(String(format: "ok  50%%: SNR %.1f dB, between the original and full isolation", halfSNR))

        // 3. The swap: narration from the render at its original position,
        // system audio untouched, roles intact.
        let swapped = try await RecordingVoiceIsolation.asset(screenURL: screenURL, isolatedURL: fullURL)
        let tracks = try await swapped.loadTracks(withMediaType: .audio)
        let roles = try await RecordingAudioProcessing.roles(for: tracks, isReplacement: false)
        precondition(Set(roles) == [.voice, .system], "swap must keep one voice and one system track")
        let voiceTrack = tracks[roles.firstIndex(of: .voice)!]
        let systemTrack = tracks[roles.firstIndex(of: .system)!]
        let voiceRange = try await voiceTrack.load(.timeRange)
        precondition(abs(voiceRange.start.seconds - masterVoiceStart) < 0.0001, "narration moved to \(voiceRange.start.seconds) s")
        let swappedVoice = try await readTrack(voiceTrack, of: swapped)
        precondition(abs(swappedVoice.count - isolated.count) <= 1, "swapped narration length changed")
        precondition(errorRatio(isolated, swappedVoice) < -100, "swapped narration is not the render")
        let swappedSystem = try await readTrack(systemTrack, of: swapped)
        precondition(errorRatio(system, swappedSystem) < -100, "system audio changed")
        print(String(format: "ok  swap: the render replaces the narration at its original position (%.2f s); system audio is untouched", voiceRange.start.seconds))

        // 4. Exports render on demand when the file is missing, and reuse it.
        RecordingVoiceIsolation.removeRenders(in: package, keeping: nil)
        precondition(!FileManager.default.fileExists(atPath: fullURL.path))
        _ = try await RecordingVoiceIsolation.sourceAsset(screenURL: screenURL, settings: full)
        precondition(FileManager.default.fileExists(atPath: fullURL.path), "export path must render a missing file")
        let stamp = try FileManager.default.attributesOfItem(atPath: fullURL.path)[.modificationDate] as! Date
        _ = try await RecordingVoiceIsolation.sourceAsset(screenURL: screenURL, settings: full)
        let restamp = try FileManager.default.attributesOfItem(atPath: fullURL.path)[.modificationDate] as! Date
        precondition(stamp == restamp, "an existing render must be reused")
        let off = try await RecordingVoiceIsolation.sourceAsset(screenURL: screenURL, settings: VoiceIsolationSettings())
        precondition((off as? AVURLAsset)?.url == screenURL, "isolation off must read the master")
        print("ok  exports render a missing file once and reuse it; off reads the master")

        // 5. A cancelled render leaves no file and no temporary behind.
        RecordingVoiceIsolation.removeRenders(in: package, keeping: nil)
        let task = Task {
            try await RecordingVoiceIsolation.render(screenURL: screenURL, to: fullURL, settings: full) { _ in }
        }
        try await Task.sleep(nanoseconds: 50_000_000)
        task.cancel()
        _ = await task.result
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: package.path).filter { $0 != "screen.mov" }
        precondition(leftovers.isEmpty, "cancelled render left \(leftovers)")
        print("ok  a cancelled render leaves the package as it was")

        print("all voice isolation checks passed")
    }

    // MARK: Helpers

    /// A movie shaped like a recording: stereo system audio from zero, the
    /// mono microphone track starting `offset` seconds in.
    static func writeMovie(to url: URL, narration: [Float], system: [Float]) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        func settings(_ channels: Int) -> [String: Any] {
            [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: rate, AVNumberOfChannelsKey: channels,
             AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true,
             AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false]
        }
        let systemInput = AVAssetWriterInput(mediaType: .audio, outputSettings: settings(2))
        let voiceInput = AVAssetWriterInput(mediaType: .audio, outputSettings: settings(1))
        for input in [systemInput, voiceInput] {
            input.expectsMediaDataInRealTime = false
            writer.add(input)
        }
        precondition(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        let mono = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1)!
        let stereo = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2)!
        let shift = Int(offset * rate)
        for start in stride(from: 0, to: narration.count, by: 1024) {
            let end = min(start + 1024, narration.count)
            let systemSlice = Array(system[start..<end])
            let systemBuffer = try sampleBuffer([systemSlice, systemSlice], format: stereo,
                                                at: CMTime(value: CMTimeValue(start), timescale: CMTimeScale(rate)))
            let voiceBuffer = try sampleBuffer([Array(narration[start..<end])], format: mono,
                                               at: CMTime(value: CMTimeValue(start + shift), timescale: CMTimeScale(rate)))
            while !systemInput.isReadyForMoreMediaData || !voiceInput.isReadyForMoreMediaData {
                try await Task.sleep(nanoseconds: 1_000_000)
            }
            precondition(systemInput.append(systemBuffer) && voiceInput.append(voiceBuffer))
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
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: CMTimeScale(rate)),
                                        presentationTimeStamp: time, decodeTimeStamp: .invalid)
        var result: CMSampleBuffer?
        _ = CMSampleBufferCreate(allocator: kCFAllocatorDefault, dataBuffer: nil, dataReady: false,
                                 makeDataReadyCallback: nil, refcon: nil, formatDescription: format.formatDescription,
                                 sampleCount: frames, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
                                 sampleSizeEntryCount: 0, sampleSizeArray: nil, sampleBufferOut: &result)
        precondition(CMSampleBufferSetDataBufferFromAudioBufferList(
            result!, blockBufferAllocator: kCFAllocatorDefault, blockBufferMemoryAllocator: kCFAllocatorDefault,
            flags: 0, bufferList: buffer.audioBufferList) == noErr)
        return result!
    }

    static func readTrack(_ track: AVAssetTrack, of asset: AVAsset) async throws -> [Float] {
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false
        ])
        reader.add(output)
        precondition(reader.startReading())
        var samples: [Float] = []
        var channels = 1
        while let buffer = output.copyNextSampleBuffer(), let block = CMSampleBufferGetDataBuffer(buffer) {
            channels = Int(CMSampleBufferGetFormatDescription(buffer)?.audioStreamBasicDescription?.mChannelsPerFrame ?? 1)
            let length = CMBlockBufferGetDataLength(block)
            var chunk = [Float](repeating: 0, count: length / 4)
            chunk.withUnsafeMutableBytes { _ = CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: $0.baseAddress!) }
            samples += chunk
        }
        // First channel only.
        return channels == 1 ? samples : stride(from: 0, to: samples.count, by: channels).map { samples[$0] }
    }

    static func readMono(_ url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let buffer = try file.readAll()
        return Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
    }

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

    static func errorRatio(_ reference: [Float], _ decoded: [Float]) -> Double {
        let count = min(reference.count, decoded.count)
        var signal = 0.0, error = 0.0
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
