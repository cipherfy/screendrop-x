//
//  VoiceAudioControls.swift
//  Screendrop
//
//  The voice part of Studio's audio inspector: track gains, voice
//  isolation, the A/B switch, the voice profile, the channel strip, and
//  the meters. The inspector shows it in place of the original volume
//  slider.
//

import SwiftUI
import VoiceKit

struct VoiceAudioControls: View {
    @Bindable var voice: RecordingVoiceController
    @State private var isChannelStripPresented = false
    /// Meters stay folded away until asked for; the choice is remembered.
    @AppStorage("studioShowsVoiceMeters") private var showsVoiceMeters = false

    /// A group, so the rows sit directly in the inspector's own stack.
    var body: some View {
        Group {
            if voice.hasVoiceAudio {
                InspectorSlider(
                    "Voice",
                    value: $voice.voiceGainDB,
                    range: Self.range(RecordingAudioSettings.voiceGainRange),
                    format: .decibels
                )
            }
            if voice.hasSystemAudio {
                InspectorSlider(
                    "System Audio",
                    value: $voice.systemGainDB,
                    range: Self.range(RecordingAudioSettings.systemGainRange),
                    format: .decibels
                )
                .help("Drag to the bottom to mute system audio")
            }
            if voice.canIsolateVoice {
                InspectorRow("Isolate") {
                    InspectorSegmented(
                        options: VoiceIsolationSettings.amounts,
                        isSelected: { $0 == voice.voiceIsolationAmount },
                        onTap: { amount in voice.voiceIsolationAmount = amount },
                        label: { amount in
                            Text(amount == 0 ? "Off" : "\(amount)%")
                                .font(.inspectorSegment)
                                .lineLimit(1)
                        }
                    )
                }
                .help("Removes room, noise, and typing from the narration on this Mac. Lower amounts keep some of the room for a more natural sound.")

                if let progress = voice.voiceIsolationProgress {
                    InspectorHint("Isolating voice… \(Int(progress * 100))%")
                } else if let message = voice.voiceIsolationError {
                    InspectorHint(message, tint: .orange)
                }
            }

            if voice.hasVoiceAudio {
                InspectorToggleRow("Voice Processing", isOn: $voice.voiceProcessingEnabled)
                    .help("Turn off to hear the voice without processing, at the same loudness, then back on to compare")

                voiceProfileControls
                    .disabled(!voice.voiceProcessingEnabled)
            }
        }
    }

    /// Character, intensity, and loudness: the voice profile the chain is
    /// resolved from. Match EQ is always on; its switch lives in the channel
    /// strip with the rest of the detail.
    private var voiceProfileControls: some View {
        VStack(alignment: .leading, spacing: InspectorMetrics.rowSpacing) {
            Group {
                InspectorRow("Character") {
                    InspectorSegmented(
                        options: VoiceProfileSettings.Character.allCases,
                        isSelected: { $0 == voice.voiceProfile.character },
                        onTap: { voice.voiceProfile.character = $0 },
                        label: { option in
                            Text(option.title).font(.inspectorSegment).lineLimit(1).minimumScaleFactor(0.7).help(option.help)
                        }
                    )
                }
                InspectorSlider(
                    "Intensity",
                    value: Binding(
                        get: { CGFloat(voice.voiceProfile.intensity) },
                        set: { voice.voiceProfile.intensity = Double($0) }
                    ),
                    range: 0...1,
                    format: .percent()
                )
            }
            .disabled(voice.isVoiceChainCustom)

            InspectorRow("Loudness") {
                InspectorSegmented(
                    options: VoiceProfileSettings.LoudnessTarget.allCases,
                    isSelected: { $0 == voice.voiceProfile.loudnessTarget },
                    onTap: { voice.voiceProfile.loudnessTarget = $0 },
                    label: { option in
                        Text(option.title).font(.inspectorSegment).lineLimit(1).minimumScaleFactor(0.7).help(option.help)
                    }
                )
            }
            if let status = voice.voiceProfileStatus {
                InspectorHint(status)
            }
            if voice.isVoiceChainCustom {
                InspectorHint("Custom chain: the profile above is on hold", tint: .orange)
            }

            InspectorActionButton("Channel Strip…", systemImage: "slider.vertical.3") {
                isChannelStripPresented = true
            }
            .help("Every stage of the voice chain, with live meters and the EQ curve")
            .popover(isPresented: $isChannelStripPresented, arrowEdge: .leading) {
                VoiceChannelStripView(voice: voice)
            }

            DisclosureGroup(isExpanded: $showsVoiceMeters) {
                VoiceMetersView(meters: voice.voiceMeters, targetLUFS: voice.voiceProfile.loudnessTarget.lufs)
                    .padding(.top, 4)
            } label: {
                Text("Meters")
                    .font(.inspectorLabel)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private static func range(_ range: ClosedRange<Double>) -> ClosedRange<CGFloat> {
        CGFloat(range.lowerBound)...CGFloat(range.upperBound)
    }
}
