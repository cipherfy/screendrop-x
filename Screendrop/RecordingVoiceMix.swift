//
//  RecordingVoiceMix.swift
//  Screendrop
//
//  Joins Studio's added audio (music and effects on the Audio track) to the
//  VoiceKit mix. The recording's own tracks get VoiceKit's taps (the voice
//  chain for narration, the system gain for system audio); every added
//  clip keeps exactly the volume and fades upstream's RecordingAudioClipMixer
//  gives it, with a VoiceKit tap that only keeps it in time and limits it.
//  Shared by playback and the video export.
//

import AVFoundation
import VoiceKit

nonisolated enum RecordingVoiceMix {
    static func mix(
        recordingTracks: [AVAssetTrack],
        roles: [RecordingAudioRole],
        clips: [RecordingAudioClip],
        clipTrackIDs: [UUID: CMPersistentTrackID],
        parameters: RecordingAudioParameters
    ) -> AVAudioMix? {
        var inputs: [AVAudioMixInputParameters] = RecordingAudioProcessing.inputParameters(
            tracks: recordingTracks,
            roles: roles,
            parameters: parameters
        )
        // Upstream's mixer, asked for the clips alone, gives each its volume
        // and fades; nothing of the recording goes through it.
        let clipMix = RecordingAudioClipMixer.mix(recordingTracks: [], recordingVolume: 1, clips: clips, trackIDs: clipTrackIDs)
        for case let clipInput as AVMutableAudioMixInputParameters in clipMix?.inputParameters ?? [] {
            RecordingAudioProcessing.joinAdded(clipInput, parameters: parameters)
            inputs.append(clipInput)
        }
        guard !inputs.isEmpty else { return nil }
        let mix = AVMutableAudioMix()
        mix.inputParameters = inputs
        return mix
    }
}
