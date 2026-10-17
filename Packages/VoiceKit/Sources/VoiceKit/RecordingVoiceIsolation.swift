//
//  RecordingVoiceIsolation.swift
//  Screendrop
//
//  Removes room, noise, and typing from the narration with Apple's
//  on-device voice isolation (AUSoundIsolation, high-quality model). The
//  model is too heavy for a playback tap, so the narration track is
//  rendered once into the project package, and playback and every export
//  swap it in for the microphone track. The recorded master is never
//  touched; turning isolation off simply stops using the render.
//
//  The voice chain still runs on the isolated track, so isolation comes
//  first and the EQ, dynamics, and limiter work on the cleaned voice.
//

import AVFoundation
import AudioToolbox
import Synchronization

public nonisolated enum RecordingVoiceIsolation {
    public enum IsolationError: LocalizedError {
        case unavailable
        case noNarrationTrack
        case renderFailed(String)

        public var errorDescription: String? {
            switch self {
            case .unavailable: "Voice isolation is not available on this Mac."
            case .noNarrationTrack: "This recording has no microphone track to isolate."
            case .renderFailed(let reason): "Voice isolation failed: \(reason)"
            }
        }
    }

    /// Bumped when the render changes, so stale files are not reused.
    private static let renderVersion = 1
    private static let filePrefix = "voice-isolated"
    private static let sampleRate = 48_000.0

    // MARK: Files

    public static func renderURL(in directory: URL, settings: VoiceIsolationSettings) -> URL {
        directory.appendingPathComponent("\(filePrefix)-hq-v\(renderVersion)-\(settings.amount).caf")
    }

    /// Recognizes a project package, the only place a render can be kept.
    /// The default is Screendrop's rule (a `.screendroprec` folder holding
    /// `screen.mov`); the app installs `RecordingSession.isSessionDirectory`
    /// so the package never has to know about sessions.
    public static var isProjectDirectory: @Sendable (URL) -> Bool {
        get { projectDirectoryRule.withLock { $0 } }
        set { projectDirectoryRule.withLock { $0 = newValue } }
    }

    private static let projectDirectoryRule = Mutex<@Sendable (URL) -> Bool> { url in
        url.pathExtension == "screendroprec"
            && FileManager.default.fileExists(atPath: url.appendingPathComponent("screen.mov").path)
    }

    /// The package that holds `screen.mov`, when there is one; bare movies
    /// opened from disk have nowhere to keep a render.
    public static func projectDirectory(forScreenURL screenURL: URL) -> URL? {
        let directory = screenURL.deletingLastPathComponent()
        return isProjectDirectory(directory) ? directory : nil
    }

    /// Keeps one render: the one in use.
    public static func removeRenders(in directory: URL, keeping kept: URL?) {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        for name in names where name.hasPrefix(filePrefix) && name != kept?.lastPathComponent {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
        }
    }

    // MARK: Assets

    /// The recording as exports should read it: with isolation on, the
    /// microphone track comes from the render (rendering it first if it is
    /// missing), everything else from the master.
    public static func sourceAsset(screenURL: URL, settings: VoiceIsolationSettings) async throws -> AVAsset {
        guard settings.isEnabled, let directory = projectDirectory(forScreenURL: screenURL) else {
            return AVURLAsset(url: screenURL)
        }
        let url = renderURL(in: directory, settings: settings)
        if !FileManager.default.fileExists(atPath: url.path) {
            try await render(screenURL: screenURL, to: url, settings: settings) { _ in }
        }
        return try await asset(screenURL: screenURL, isolatedURL: url)
    }

    /// A composition of the master with its mono narration track replaced
    /// by `isolatedURL`, at the same position on the timeline.
    public static func asset(screenURL: URL, isolatedURL: URL?) async throws -> AVAsset {
        let source = AVURLAsset(url: screenURL)
        guard let isolatedURL else { return source }
        let isolated = AVURLAsset(url: isolatedURL)
        guard let isolatedTrack = try await isolated.loadTracks(withMediaType: .audio).first else {
            return source
        }
        let isolatedDuration = try await isolated.load(.duration)

        let composition = AVMutableComposition()
        var replaced = false
        for track in try await source.load(.tracks) {
            guard let target = composition.addMutableTrack(
                withMediaType: track.mediaType,
                preferredTrackID: kCMPersistentTrackID_Invalid
            ) else { continue }
            let range = try await track.load(.timeRange)
            if !replaced, track.mediaType == .audio, try await channelCount(of: track) == 1 {
                let duration = CMTimeMinimum(range.duration, isolatedDuration)
                try target.insertTimeRange(CMTimeRange(start: .zero, duration: duration), of: isolatedTrack, at: range.start)
                replaced = true
            } else {
                try target.insertTimeRange(range, of: track, at: range.start)
                target.preferredTransform = try await track.load(.preferredTransform)
            }
        }
        return replaced ? composition : source
    }

    private static func channelCount(of track: AVAssetTrack) async throws -> UInt32 {
        try await track.load(.formatDescriptions)
            .compactMap { $0.audioStreamBasicDescription?.mChannelsPerFrame }
            .max() ?? 0
    }

    // MARK: Render

    /// Runs the narration track through AUSoundIsolation offline and writes
    /// a 32-bit float mono file aligned sample for sample with the source
    /// (the unit's latency is measured and removed). Written to a temporary
    /// file and moved into place, so a cancelled or failed render never
    /// leaves a partial file behind.
    public static func render(
        screenURL: URL,
        to outputURL: URL,
        settings: VoiceIsolationSettings,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        let asset = AVURLAsset(url: screenURL)
        var narration: AVAssetTrack?
        for track in try await asset.loadTracks(withMediaType: .audio) where try await channelCount(of: track) == 1 {
            narration = track
            break
        }
        guard let narration else { throw IsolationError.noNarrationTrack }
        let duration = try await narration.load(.timeRange).duration.seconds
        let expectedFrames = max(1, duration * sampleRate)

        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: narration, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ])
        output.alwaysCopiesSampleData = false
        reader.add(output)

        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1) else {
            throw IsolationError.renderFailed("unsupported format")
        }
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        let unit = AVAudioUnitEffect(audioComponentDescription: AudioComponentDescription(
            componentType: kAudioUnitType_Effect,
            componentSubType: kAudioUnitSubType_AUSoundIsolation,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0,
            componentFlagsMask: 0
        ))
        engine.attach(player)
        engine.attach(unit)
        engine.connect(player, to: unit, format: format)
        engine.connect(unit, to: engine.mainMixerNode, format: format)
        let maximumFrames: AVAudioFrameCount = 4_096
        try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: maximumFrames)

        let audioUnit = unit.audioUnit
        guard AudioUnitSetParameter(
            audioUnit, kAUSoundIsolationParam_SoundToIsolate, kAudioUnitScope_Global, 0,
            AudioUnitParameterValue(kAUSoundIsolationSoundType_HighQualityVoice), 0
        ) == noErr else {
            throw IsolationError.unavailable
        }
        AudioUnitSetParameter(
            audioUnit, kAUSoundIsolationParam_WetDryMixPercent, kAudioUnitScope_Global, 0,
            AudioUnitParameterValue(settings.amount), 0
        )
        try engine.start()
        defer { engine.stop() }
        let latency = Int((unit.auAudioUnit.latency * sampleRate).rounded())

        let temporaryURL = outputURL.deletingLastPathComponent()
            .appendingPathComponent(".\(outputURL.lastPathComponent).\(UUID().uuidString).tmp")
        defer { try? FileManager.default.removeItem(at: temporaryURL) }
        let file = try AVAudioFile(
            forWriting: temporaryURL,
            settings: format.settings,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
        guard let rendered = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: maximumFrames) else {
            throw IsolationError.renderFailed("could not allocate buffers")
        }

        var toSkip = latency
        var inputFrames = 0
        var renderedFrames = 0
        var writtenFrames = 0

        func renderFrames(_ count: Int) throws {
            var remaining = count
            while remaining > 0 {
                let frames = AVAudioFrameCount(min(Int(maximumFrames), remaining))
                guard try engine.renderOffline(frames, to: rendered) == .success else {
                    throw IsolationError.renderFailed("the isolation unit stopped rendering")
                }
                remaining -= Int(rendered.frameLength)
                // Drop the unit's latency, so the output lines up with the
                // input; and never write past the input's length.
                let skip = min(toSkip, Int(rendered.frameLength))
                toSkip -= skip
                let keep = min(Int(rendered.frameLength) - skip, inputFrames - writtenFrames)
                guard keep > 0, let data = rendered.floatChannelData else { continue }
                guard let slice = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(keep)) else { continue }
                slice.frameLength = AVAudioFrameCount(keep)
                slice.floatChannelData![0].update(from: data[0] + skip, count: keep)
                try file.write(from: slice)
                writtenFrames += keep
            }
        }

        guard reader.startReading() else {
            throw reader.error ?? IsolationError.renderFailed("could not read the narration")
        }
        while let sampleBuffer = output.copyNextSampleBuffer() {
            try Task.checkCancellation()
            guard let block = CMSampleBufferGetDataBuffer(sampleBuffer) else { continue }
            let frames = CMSampleBufferGetNumSamples(sampleBuffer)
            guard frames > 0, let input = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)) else { continue }
            input.frameLength = AVAudioFrameCount(frames)
            CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: frames * 4, destination: input.floatChannelData![0])
            player.scheduleBuffer(input, completionHandler: nil)
            if !player.isPlaying { player.play() }
            inputFrames += frames
            // The unit pulls input ahead of the output it is asked for. Keep
            // two blocks queued beyond what is rendered, or the player fills the
            // gap with silence and the narration comes out late.
            let pending = inputFrames - renderedFrames - 2 * Int(maximumFrames)
            let blocks = max(0, pending) / Int(maximumFrames)
            if blocks > 0 {
                try renderFrames(blocks * Int(maximumFrames))
                renderedFrames += blocks * Int(maximumFrames)
            }
            progress(min(0.99, Double(inputFrames) / expectedFrames))
        }
        if reader.status == .failed {
            throw reader.error ?? IsolationError.renderFailed("could not read the narration")
        }
        // The rest of the input, then what the unit still holds.
        try renderFrames(inputFrames - renderedFrames + latency)
        file.close()

        try? FileManager.default.removeItem(at: outputURL)
        try FileManager.default.moveItem(at: temporaryURL, to: outputURL)
        progress(1)
    }
}
