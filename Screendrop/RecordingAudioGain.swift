import AVFoundation
import AudioToolbox
import MediaToolbox

/// Shared by player items and both export paths. A processing tap supports
/// amplification above unity, unlike AVAudioMix's 0...1 volume parameter.
nonisolated enum RecordingAudioGain {
    static func normalized(_ volume: Double) -> Double {
        volume.isFinite ? min(2, max(0, volume)) : 1
    }

    static func makeMix(tracks: [AVAssetTrack], volume: Double) -> AVAudioMix? {
        let parameters = inputParameters(tracks: tracks, volume: volume)
        guard !parameters.isEmpty else { return nil }
        let mix = AVMutableAudioMix()
        mix.inputParameters = parameters
        return mix
    }

    /// The parameters that apply `volume` to each track; empty at unity,
    /// which needs none. Shared with mixes that carry other tracks too.
    static func inputParameters(tracks: [AVAssetTrack], volume: Double) -> [AVMutableAudioMixInputParameters] {
        let gain = Float(normalized(volume))
        guard gain != 1 else { return [] }
        return tracks.map { track in
            let parameters = AVMutableAudioMixInputParameters(track: track)
            if gain <= 1 {
                parameters.setVolume(gain, at: .zero)
            } else {
                parameters.audioTapProcessor = makeTap(gain: gain)
            }
            return parameters
        }
    }

    private final class State {
        let gain: Float
        var format = AudioStreamBasicDescription()
        init(gain: Float) { self.gain = gain }
    }

    private static func makeTap(gain: Float) -> MTAudioProcessingTap? {
        let storage = Unmanaged.passRetained(State(gain: gain)).toOpaque()
        var callbacks = MTAudioProcessingTapCallbacks(
            version: kMTAudioProcessingTapCallbacksVersion_0,
            clientInfo: storage,
            init: { _, clientInfo, tapStorage in tapStorage.pointee = clientInfo },
            finalize: { tap in
                Unmanaged<State>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).release()
            },
            prepare: { tap, _, format in
                let state = Unmanaged<State>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue()
                state.format = format.pointee
            },
            unprepare: nil,
            process: { tap, frames, _, buffers, framesOut, flagsOut in
                let status = MTAudioProcessingTapGetSourceAudio(tap, frames, buffers, flagsOut, nil, framesOut)
                guard status == noErr else { framesOut.pointee = 0; return }
                let state = Unmanaged<State>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue()
                let format = state.format
                for buffer in UnsafeMutableAudioBufferListPointer(buffers) {
                    guard let data = buffer.mData else { continue }
                    let bytes = Int(buffer.mDataByteSize)
                    if format.mFormatFlags & kAudioFormatFlagIsFloat != 0 {
                        if format.mBitsPerChannel == 32 {
                            let samples = data.assumingMemoryBound(to: Float.self)
                            for i in 0..<(bytes / 4) { samples[i] = min(1, max(-1, samples[i] * state.gain)) }
                        } else if format.mBitsPerChannel == 64 {
                            let samples = data.assumingMemoryBound(to: Double.self)
                            for i in 0..<(bytes / 8) { samples[i] = min(1, max(-1, samples[i] * Double(state.gain))) }
                        }
                    } else if format.mFormatFlags & kAudioFormatFlagIsSignedInteger != 0 {
                        if format.mBitsPerChannel == 16 {
                            let samples = data.assumingMemoryBound(to: Int16.self)
                            for i in 0..<(bytes / 2) {
                                samples[i] = Int16(min(Double(Int16.max), max(Double(Int16.min), Double(samples[i]) * Double(state.gain))))
                            }
                        } else if format.mBitsPerChannel == 32 {
                            let samples = data.assumingMemoryBound(to: Int32.self)
                            for i in 0..<(bytes / 4) {
                                samples[i] = Int32(min(Double(Int32.max), max(Double(Int32.min), Double(samples[i]) * Double(state.gain))))
                            }
                        }
                    }
                }
            }
        )
        var tap: MTAudioProcessingTap?
        let status = MTAudioProcessingTapCreate(kCFAllocatorDefault, &callbacks,
                                               kMTAudioProcessingTapCreationFlag_PostEffects, &tap)
        guard status == noErr else {
            Unmanaged<State>.fromOpaque(storage).release()
            return nil
        }
        return tap
    }
}
