//
//  AudioBench.swift
//  VoiceKitTestSupport
//
//  What the tests and the bench tools share: reading and writing audio
//  files, writing movies the way the recorder does, reading tracks back,
//  test signals, running the chain offline, and finding the voice bank.
//

import AVFoundation
import CoreMedia
import Foundation
import VoiceKit

public enum AudioBench {
    public static let rate = 48_000.0

    // MARK: Voice bank

    /// `build/voice-bank/variants`, written by scripts/voice-bank/generate.sh,
    /// or the folder in the VOICE_BANK environment variable.
    public static let variants: URL = {
        if let path = ProcessInfo.processInfo.environment["VOICE_BANK"] {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        // Sources/VoiceKitTestSupport/AudioBench.swift -> repository root.
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { root.deleteLastPathComponent() }
        return root.appendingPathComponent("build/voice-bank/variants", isDirectory: true)
    }()

    public static var isVoiceBankAvailable: Bool {
        FileManager.default.fileExists(atPath: variants.appendingPathComponent("paulina-clean.wav").path)
    }

    public static let voiceBankMissing = "voice bank not found; run scripts/voice-bank/generate.sh (or set VOICE_BANK)"

    public static func bankTake(_ name: String) throws -> [Float] {
        try readMono(variants.appendingPathComponent("\(name).wav"))
    }

    // MARK: Files

    /// The first channel of a file, as stored.
    public static func readMono(_ url: URL) throws -> [Float] {
        let buffer = try AVAudioFile(forReading: url).readAll()
        return Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
    }

    /// Every channel of a file, with its sample rate.
    public static func readChannels(_ url: URL) throws -> (channels: [[Float]], sampleRate: Double) {
        let file = try AVAudioFile(forReading: url)
        let buffer = try file.readAll()
        guard let data = buffer.floatChannelData else { throw CocoaError(.fileReadCorruptFile) }
        let frames = Int(buffer.frameLength)
        let channels = (0..<Int(file.processingFormat.channelCount)).map { channel in
            Array(UnsafeBufferPointer(start: data[channel], count: frames))
        }
        return (channels, file.processingFormat.sampleRate)
    }

    /// Any audio file, mixed to mono and resampled to 48 kHz.
    public static func readConverted(_ url: URL) throws -> [Float] {
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

    /// 24-bit PCM WAV, the format a lossless narration capture would use.
    public static func writeWAV(channels: [[Float]], sampleRate: Double = rate, to url: URL) throws {
        try? FileManager.default.removeItem(at: url)
        let file = try AVAudioFile(forWriting: url, settings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: sampleRate, AVNumberOfChannelsKey: channels.count,
            AVLinearPCMBitDepthKey: 24, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false
        ], commonFormat: .pcmFormatFloat32, interleaved: false)
        let frames = channels.map(\.count).min() ?? 0
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(frames)),
              let data = buffer.floatChannelData else {
            throw CocoaError(.fileWriteUnknown)
        }
        buffer.frameLength = AVAudioFrameCount(frames)
        for (index, channel) in channels.enumerated() {
            channel.withUnsafeBufferPointer { data[index].update(from: $0.baseAddress!, count: frames) }
        }
        try file.write(from: buffer)
    }

    // MARK: Movies

    /// One audio track of a movie written by `writeMovie`.
    public struct MovieTrack {
        public var channels: [[Float]]
        public var settings: [String: Any]
        /// Where the track's first sample lands on the movie's timeline.
        public var startFrame: Int

        public init(channels: [[Float]], settings: [String: Any], startFrame: Int = 0) {
            self.channels = channels
            self.settings = settings
            self.startFrame = startFrame
        }

        /// 32-bit float PCM, which the writer stores untouched.
        public static func float(_ channels: [[Float]], startFrame: Int = 0) -> MovieTrack {
            MovieTrack(channels: channels, settings: [
                AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: rate, AVNumberOfChannelsKey: channels.count,
                AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true,
                AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false
            ], startFrame: startFrame)
        }
    }

    /// Writes audio tracks the way ScreenRecordingWriter does: buffers of
    /// `chunk` frames, appended to every track in turn.
    public static func writeMovie(
        to url: URL,
        tracks: [MovieTrack],
        chunk: Int = 1024,
        fragmentInterval: CMTime? = nil
    ) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        if let fragmentInterval { writer.movieFragmentInterval = fragmentInterval }
        let inputs = tracks.map { AVAssetWriterInput(mediaType: .audio, outputSettings: $0.settings) }
        for input in inputs {
            input.expectsMediaDataInRealTime = false
            writer.add(input)
        }
        guard writer.startWriting() else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
        writer.startSession(atSourceTime: .zero)
        let formats = tracks.map { AVAudioFormat(standardFormatWithSampleRate: rate, channels: AVAudioChannelCount($0.channels.count))! }
        let length = tracks.map { $0.channels[0].count }.max() ?? 0
        for start in stride(from: 0, to: length, by: chunk) {
            let buffers = try tracks.indices.map { index -> CMSampleBuffer? in
                let samples = tracks[index].channels
                guard start < samples[0].count else { return nil }
                let end = min(start + chunk, samples[0].count)
                let time = CMTime(value: CMTimeValue(start + tracks[index].startFrame), timescale: CMTimeScale(rate))
                return try sampleBuffer(samples.map { Array($0[start..<end]) }, format: formats[index], at: time)
            }
            while inputs.contains(where: { !$0.isReadyForMoreMediaData }) {
                try await Task.sleep(nanoseconds: 1_000_000)
            }
            for (input, buffer) in zip(inputs, buffers) {
                if let buffer, !input.append(buffer) { throw writer.error ?? CocoaError(.fileWriteUnknown) }
            }
        }
        inputs.forEach { $0.markAsFinished() }
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
    }

    public static func sampleBuffer(_ channels: [[Float]], format: AVAudioFormat, at time: CMTime) throws -> CMSampleBuffer {
        let frames = channels[0].count
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))!
        buffer.frameLength = AVAudioFrameCount(frames)
        for (index, channel) in channels.enumerated() {
            channel.withUnsafeBufferPointer { buffer.floatChannelData![index].update(from: $0.baseAddress!, count: frames) }
        }
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: CMTimeScale(rate)),
                                        presentationTimeStamp: time, decodeTimeStamp: .invalid)
        var result: CMSampleBuffer?
        var status = CMSampleBufferCreate(
            allocator: kCFAllocatorDefault, dataBuffer: nil, dataReady: false,
            makeDataReadyCallback: nil, refcon: nil, formatDescription: format.formatDescription,
            sampleCount: frames, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
            sampleSizeEntryCount: 0, sampleSizeArray: nil, sampleBufferOut: &result
        )
        guard status == noErr, let result else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
        status = CMSampleBufferSetDataBufferFromAudioBufferList(
            result, blockBufferAllocator: kCFAllocatorDefault, blockBufferMemoryAllocator: kCFAllocatorDefault,
            flags: 0, bufferList: buffer.audioBufferList
        )
        guard status == noErr else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
        return result
    }

    // MARK: Reading tracks

    public static let floatReadSettings: [String: Any] = [
        AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true,
        AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false
    ]

    /// The first channel of a track, as 32-bit float.
    public static func readTrack(_ track: AVAssetTrack, of asset: AVAsset) async throws -> [Float] {
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: floatReadSettings)
        reader.add(output)
        let (samples, channels) = try drain(reader, output)
        return channels == 1 ? samples : stride(from: 0, to: samples.count, by: channels).map { samples[$0] }
    }

    /// Every interleaved sample an output gives, and its channel count.
    public static func drain(_ reader: AVAssetReader, _ output: AVAssetReaderOutput) throws -> (samples: [Float], channels: Int) {
        guard reader.startReading() else { throw reader.error ?? CocoaError(.fileReadUnknown) }
        var samples: [Float] = []
        var channels = 1
        while let buffer = output.copyNextSampleBuffer(), let block = CMSampleBufferGetDataBuffer(buffer) {
            channels = Int(CMSampleBufferGetFormatDescription(buffer)?.audioStreamBasicDescription?.mChannelsPerFrame ?? 1)
            let length = CMBlockBufferGetDataLength(block)
            var chunk = [Float](repeating: 0, count: length / MemoryLayout<Float>.size)
            chunk.withUnsafeMutableBytes {
                _ = CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: $0.baseAddress!)
            }
            samples += chunk
        }
        guard reader.status == .completed else { throw reader.error ?? CocoaError(.fileReadUnknown) }
        return (samples, channels)
    }

    // MARK: The chain offline

    /// Runs the chain in `blockSize`-frame buffers, as a tap would (the
    /// whole signal in one call when nil). With `alignsLatency`, the
    /// output is shifted back so it lines up with the input.
    public static func run(
        _ input: [Float],
        _ settings: VoiceChainSettings,
        enabled: Bool = true,
        blockSize: Int? = 512,
        alignsLatency: Bool = true
    ) -> [Float] {
        var processor = VoiceChainProcessor(sampleRate: rate, channelCount: 1)
        processor.apply(settings, version: 1)
        let latency = alignsLatency ? VoiceChainProcessor.latency : 0
        var buffer = input + [Float](repeating: 0, count: latency)
        buffer.withUnsafeMutableBufferPointer { pointer in
            var start = 0
            while start < pointer.count {
                let count = min(blockSize ?? pointer.count, pointer.count - start)
                processor.process(
                    frameCount: count, enabled: enabled,
                    read: { frame, _ in pointer[start + frame] },
                    write: { frame, _, value in pointer[start + frame] = value }
                )
                start += count
            }
        }
        return Array(buffer.dropFirst(latency))
    }

    /// The voice tap offline: chain, fader, true-peak limiter.
    public static func render(
        _ input: [Float],
        _ chain: VoiceChainSettings,
        gainDB: Double,
        blockSize: Int = 512,
        alignsLatency: Bool = true
    ) -> [Float] {
        let linear = Float(pow(10, gainDB / 20))
        var output = run(input, chain, blockSize: blockSize, alignsLatency: alignsLatency).map { $0 * linear }
        limit(&output)
        return output
    }

    /// The tap's true-peak limiter at -1 dBTP, over a mono signal.
    public static func limit(_ samples: inout [Float], truePeak: Bool = true) {
        var limiter = PeakLimiter(sampleRate: rate, channelCount: 1, ceilingDB: -1, detectsTruePeak: truePeak)
        samples.withUnsafeMutableBufferPointer { limiter.process(interleaved: $0.baseAddress!, frameCount: $0.count) }
    }

    // MARK: Signals

    public static func sine(_ frequency: Double, levelDB: Double, seconds: Double = 2) -> [Float] {
        let amplitude = pow(10, levelDB / 20)
        return (0..<Int(rate * seconds)).map { Float(amplitude * sin(2 * .pi * frequency * Double($0) / rate)) }
    }

    public static func noise(seconds: Double, level: Float) -> [Float] {
        var generator = SystemRandomNumberGenerator()
        return (0..<Int(rate * seconds)).map { _ in Float.random(in: -level...level, using: &generator) }
    }

    public static func pink(seconds: Double, rmsDB: Double) -> [Float] {
        var generator = SystemRandomNumberGenerator()
        var b = [Float](repeating: 0, count: 6)
        let output = (0..<Int(rate * seconds)).map { _ -> Float in
            let white = Float.random(in: -1...1, using: &generator)
            b[0] = 0.99886 * b[0] + white * 0.0555179
            b[1] = 0.99332 * b[1] + white * 0.0750759
            b[2] = 0.96900 * b[2] + white * 0.1538520
            b[3] = 0.86650 * b[3] + white * 0.3104856
            b[4] = 0.55000 * b[4] + white * 0.5329522
            b[5] = -0.7616 * b[5] - white * 0.0168980
            return b.reduce(0, +) + white * 0.5362
        }
        let rms = (output.reduce(0) { $0 + $1 * $1 } / Float(output.count)).squareRoot()
        let gain = Float(pow(10, rmsDB / 20)) / rms
        return output.map { $0 * gain }
    }

    /// 60 Hz mains with its 2nd and 3rd harmonics.
    public static func hum(seconds: Double, levelDB: Double) -> [Float] {
        let level = pow(10, levelDB / 20)
        return (0..<Int(rate * seconds)).map { index in
            let t = Double(index) / rate
            return Float(level * (sin(2 * .pi * 60 * t) + 0.5 * sin(2 * .pi * 120 * t) + 0.3 * sin(2 * .pi * 180 * t)))
        }
    }

    // MARK: Measuring

    /// Steady-state RMS after the first half second.
    public static func rmsDB(_ signal: [Float]) -> Double {
        let steady = signal.dropFirst(Int(rate / 2))
        let meanSquare = steady.reduce(0.0) { $0 + Double($1 * $1) } / Double(steady.count)
        return VoiceAnalyzer.decibels(amplitude: meanSquare.squareRoot())
    }

    /// Steady-state peak after the first half second.
    public static func peakDB(_ signal: [Float]) -> Double {
        VoiceAnalyzer.decibels(amplitude: Double(signal.dropFirst(Int(rate / 2)).map(abs).max() ?? 0))
    }

    /// Hann-windowed single-bin DFT level, in dB.
    public static func level(_ signal: [Float], at frequency: Double) -> Double {
        let samples = Array(signal.dropFirst(Int(rate / 2)).prefix(Int(rate)))
        var re = 0.0, im = 0.0
        let n = Double(samples.count)
        for (index, value) in samples.enumerated() {
            let w = 0.5 - 0.5 * cos(2 * .pi * Double(index) / (n - 1))
            let phase = 2 * .pi * frequency * Double(index) / rate
            re += Double(value) * w * cos(phase)
            im += Double(value) * w * sin(phase)
        }
        return 10 * log10(max(1e-30, re * re + im * im))
    }

    public static func loudness(_ signal: [Float]) -> Double {
        VoiceAnalyzer.measure(channels: [signal], sampleRate: rate).integratedLUFS ?? -.infinity
    }

    /// Energy of the difference relative to the reference, in dB, leaving
    /// out the last `ignoringLast` frames.
    public static func errorRatio(reference: [Float], decoded: [Float], ignoringLast: Int = 0) -> Double {
        let count = min(reference.count, decoded.count) - ignoringLast
        var signal = 0.0, error = 0.0
        for index in 0..<count {
            let difference = Double(decoded[index] - reference[index])
            signal += Double(reference[index]) * Double(reference[index])
            error += difference * difference
        }
        return error > 0 ? 10 * log10(error / signal) : -200
    }

    /// RMS distance, in dB, between a spectrum's shape and the target curve
    /// over the curve's range (250 Hz to 8 kHz).
    public static func distanceToTarget(_ spectrum: [VoiceMeasurement.SpectrumPoint]) -> Double {
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

    /// A temporary folder, removed after `body`.
    public static func withTemporaryDirectory<T>(
        named name: String,
        _ body: (URL) async throws -> T
    ) async throws -> T {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        return try await body(directory)
    }
}

public extension AVAudioFile {
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
