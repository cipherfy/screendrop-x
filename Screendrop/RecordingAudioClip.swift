//
//  RecordingAudioClip.swift
//  Screendrop
//
//  Music and sound placed under a Studio recording. Unlike everything that
//  sits over the picture, audio clips live on the finished video's clock:
//  a soundtrack belongs to the cut, so trimming the recording never
//  chops a song in two.
//
//  Each clip is its own track in the playback and export compositions,
//  mixed with the recording's audio through one shared set of mix
//  parameters (volume and fades), so what plays is what exports.
//

import AVFoundation
import Foundation
import UniformTypeIdentifiers

nonisolated struct RecordingAudioClip: Identifiable, Codable, Equatable, Hashable, Sendable {
    static let minimumDuration: TimeInterval = 0.1
    static let fadeRange: ClosedRange<TimeInterval> = 0...5

    var id = UUID()
    /// The copy inside the project's media folder.
    var fileName: String
    var displayName: String
    /// Where it starts in the edited video.
    var start: TimeInterval
    /// The stretch of the file that plays.
    var trimStart: TimeInterval = 0
    var trimEnd: TimeInterval
    /// The file's own length, the most a trim can open up to.
    var fileDuration: TimeInterval
    /// 0...1.
    var volume: Double = 1
    var fadeIn: TimeInterval = 0
    var fadeOut: TimeInterval = 0

    var duration: TimeInterval { trimEnd - trimStart }
    var end: TimeInterval { start + duration }

    init(fileName: String, displayName: String, start: TimeInterval, fileDuration: TimeInterval) {
        self.fileName = fileName
        self.displayName = displayName
        self.start = start
        self.fileDuration = fileDuration
        trimEnd = fileDuration
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        fileName = try container.decode(String.self, forKey: .fileName)
        displayName = try container.decodeIfPresent(String.self, forKey: .displayName) ?? fileName
        start = try container.decode(TimeInterval.self, forKey: .start)
        trimStart = try container.decodeIfPresent(TimeInterval.self, forKey: .trimStart) ?? 0
        trimEnd = try container.decode(TimeInterval.self, forKey: .trimEnd)
        fileDuration = try container.decodeIfPresent(TimeInterval.self, forKey: .fileDuration) ?? trimEnd
        volume = try container.decodeIfPresent(Double.self, forKey: .volume) ?? 1
        fadeIn = try container.decodeIfPresent(TimeInterval.self, forKey: .fadeIn) ?? 0
        fadeOut = try container.decodeIfPresent(TimeInterval.self, forKey: .fadeOut) ?? 0
    }

    static func canImport(_ url: URL) -> Bool {
        guard let type = UTType(filenameExtension: url.pathExtension) else { return false }
        return type.conforms(to: .audio)
    }
}

/// An audio file's track, resolved once. The asset is kept with it: a
/// track only weakly holds its asset, and once the asset goes the track
/// inserts nothing.
nonisolated struct RecordingAudioFileTrack: @unchecked Sendable {
    let asset: AVURLAsset
    let track: AVAssetTrack

    static func load(url: URL) async -> RecordingAudioFileTrack? {
        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: .audio).first else { return nil }
        return RecordingAudioFileTrack(asset: asset, track: track)
    }
}

/// A clip with its file's audio track resolved, ready to compose.
nonisolated struct RecordingAudioClipSource: @unchecked Sendable {
    let clip: RecordingAudioClip
    let file: RecordingAudioFileTrack

    var track: AVAssetTrack { file.track }

    static func load(_ clip: RecordingAudioClip, in directory: URL) async -> RecordingAudioClipSource? {
        guard let file = await RecordingAudioFileTrack.load(url: directory.appendingPathComponent(clip.fileName)) else {
            return nil
        }
        return RecordingAudioClipSource(clip: clip, file: file)
    }
}

nonisolated enum RecordingAudioClipMixer {
    /// Adds each clip as its own audio track, cut to the part that falls
    /// inside the video. Returns the composition track each clip landed on.
    @discardableResult
    static func insert(
        _ sources: [RecordingAudioClipSource],
        into composition: AVMutableComposition,
        videoDuration: TimeInterval
    ) -> [UUID: CMPersistentTrackID] {
        var trackIDs: [UUID: CMPersistentTrackID] = [:]
        for source in sources {
            let clip = source.clip
            let visibleStart = max(clip.start, 0)
            let visibleEnd = min(clip.end, videoDuration)
            guard visibleEnd - visibleStart >= 0.01,
                  let track = composition.addMutableTrack(
                      withMediaType: .audio,
                      preferredTrackID: kCMPersistentTrackID_Invalid
                  ) else { continue }
            let fileStart = clip.trimStart + (visibleStart - clip.start)
            let range = CMTimeRange(
                start: CMTime(seconds: fileStart, preferredTimescale: 600),
                duration: CMTime(seconds: visibleEnd - visibleStart, preferredTimescale: 600)
            )
            do {
                try track.insertTimeRange(range, of: source.track, at: CMTime(seconds: visibleStart, preferredTimescale: 600))
                trackIDs[clip.id] = track.trackID
            } catch {
                composition.removeTrack(track)
            }
        }
        return trackIDs
    }

    /// The mix for a composition holding the recording's audio and the
    /// clips: the recording at `recordingVolume`, each clip at its volume
    /// with its fades. Nil when nothing needs changing.
    static func mix(
        recordingTracks: [AVAssetTrack],
        recordingVolume: Double,
        clips: [RecordingAudioClip],
        trackIDs: [UUID: CMPersistentTrackID]
    ) -> AVAudioMix? {
        var parameters = RecordingAudioGain.inputParameters(tracks: recordingTracks, volume: recordingVolume)
        for clip in clips {
            guard let trackID = trackIDs[clip.id] else { continue }
            parameters.append(inputParameters(for: clip, trackID: trackID))
        }
        guard !parameters.isEmpty else { return nil }
        let mix = AVMutableAudioMix()
        mix.inputParameters = parameters
        return mix
    }

    private static func inputParameters(for clip: RecordingAudioClip, trackID: CMPersistentTrackID) -> AVMutableAudioMixInputParameters {
        let parameters = AVMutableAudioMixInputParameters()
        parameters.trackID = trackID
        let volume = Float(min(max(clip.volume, 0), 1))
        func time(_ seconds: TimeInterval) -> CMTime { CMTime(seconds: max(0, seconds), preferredTimescale: 600) }
        // Fades are squeezed into half the clip each, so they never cross.
        let fadeIn = min(clip.fadeIn, clip.duration / 2)
        let fadeOut = min(clip.fadeOut, clip.duration / 2)
        parameters.setVolume(volume, at: .zero)
        if fadeIn > 0 {
            parameters.setVolumeRamp(
                fromStartVolume: 0, toEndVolume: volume,
                timeRange: CMTimeRange(start: time(clip.start), duration: time(fadeIn))
            )
        }
        if fadeOut > 0 {
            parameters.setVolumeRamp(
                fromStartVolume: volume, toEndVolume: 0,
                timeRange: CMTimeRange(start: time(clip.end - fadeOut), duration: time(fadeOut))
            )
        }
        return parameters
    }
}

/// A coarse loudness outline of an audio file for the timeline.
nonisolated enum RecordingAudioPeaks {
    static let peaksPerSecond = 40

    /// Normalized 0...1 peaks, `peaksPerSecond` per second of audio.
    static func load(url: URL) async -> [Float] {
        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: .audio).first,
              let reader = try? AVAssetReader(asset: asset) else { return [] }
        let sampleRate = 8_000
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ])
        reader.add(output)
        guard reader.startReading() else { return [] }

        let samplesPerPeak = sampleRate / peaksPerSecond
        var peaks: [Float] = []
        var current: Int16 = 0
        var count = 0
        while let buffer = output.copyNextSampleBuffer() {
            if Task.isCancelled { reader.cancelReading(); return [] }
            guard let block = CMSampleBufferGetDataBuffer(buffer) else { continue }
            var length = 0
            var pointer: UnsafeMutablePointer<CChar>?
            guard CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &pointer) == noErr,
                  let pointer else { continue }
            pointer.withMemoryRebound(to: Int16.self, capacity: length / 2) { samples in
                for index in 0..<(length / 2) {
                    let magnitude = samples[index] == .min ? Int16.max : abs(samples[index])
                    current = max(current, magnitude)
                    count += 1
                    if count == samplesPerPeak {
                        peaks.append(Float(current) / Float(Int16.max))
                        current = 0
                        count = 0
                    }
                }
            }
        }
        if count > 0 { peaks.append(Float(current) / Float(Int16.max)) }
        // Quiet tracks still read: scale so the loudest peak fills the lane.
        if let loudest = peaks.max(), loudest > 0.01 {
            peaks = peaks.map { min(1, $0 / loudest) }
        }
        return peaks
    }
}
