//
//  RecordingVoiceController.swift
//  Screendrop
//
//  Studio's voice: track gains, the voice processing switch, the chain,
//  voice isolation, the voice profile and its analysis, and the meters.
//  RecordingStudioModel owns one and forwards what it needs; the engine
//  itself lives in the VoiceKit package.
//

import AVFoundation
import Foundation
import Observation
import VoiceKit

/// What the voice needs to know about the project that owns it.
@MainActor
protocol RecordingVoiceHost: AnyObject {
    var isLoaded: Bool { get }
    var session: RecordingSession? { get }
    var manifest: CaptureManifest? { get }
    var replacementAudio: RecordingReplacementAudio? { get }
    /// A voice setting changed and the project should be saved.
    func voiceSettingsDidChange()
    /// The isolated narration came or went; playback must be rebuilt.
    func voiceSourceDidChange()
}

@MainActor
@Observable
final class RecordingVoiceController {
    @ObservationIgnored weak var host: RecordingVoiceHost?

    init() {
        // The app's own rule for project packages, not the engine's copy.
        RecordingVoiceIsolation.isProjectDirectory = RecordingSession.isSessionDirectory
    }

    /// Narration and system audio gains in dB, shared by playback and
    /// every export; 0 preserves the source.
    var voiceGainDB: CGFloat = 0 {
        didSet {
            audioSettingsDidChange()
            // Moving the slider by hand takes the level back from the
            // loudness target.
            if !isApplyingDocument, !isApplyingAutomaticGain, voiceGainDB != oldValue,
               voiceProfile.loudnessTarget != .off {
                voiceProfile.loudnessTarget = .off
            }
        }
    }
    var systemGainDB: CGFloat = 0 {
        didSet { audioSettingsDidChange() }
    }
    /// Off is the "before" of an A/B: the voice with its gain alone.
    var voiceProcessingEnabled = true {
        didSet { audioSettingsDidChange() }
    }
    /// The narration channel strip.
    var voiceChain = VoiceChainSettings() {
        didSet { audioSettingsDidChange() }
    }

    /// Share of the isolated voice, in percent; 0 is off. Changing it
    /// renders the narration again (about 90x real time).
    var voiceIsolationAmount = VoiceIsolationSettings.projectDefault.amount {
        didSet {
            guard voiceIsolationAmount != oldValue else { return }
            audioSettingsDidChange()
            refreshIsolation()
        }
    }
    /// Render progress while the isolated narration is being prepared.
    private(set) var voiceIsolationProgress: Double?
    private(set) var voiceIsolationError: String?
    /// The master with its narration swapped for the isolated render.
    private(set) var isolatedSourceAsset: AVAsset?
    @ObservationIgnored private var voiceIsolationTask: Task<Void, Never>?

    /// Isolation works on a recorded microphone inside a project package;
    /// an imported soundtrack is assumed to be cleaned already.
    var canIsolateVoice: Bool {
        host?.session != nil && recordedAudioRoles.contains(.voice) && host?.replacementAudio == nil
    }

    /// What the voice should sound like. The chain follows from it and
    /// the take's analysis; with a loudness target, so does the voice gain.
    var voiceProfile = VoiceProfileSettings() {
        didSet {
            guard voiceProfile != oldValue else { return }
            audioSettingsDidChange()
            guard !isApplyingDocument else { return }
            VoiceProfileStore.remember(voiceProfile, forMicrophone: host?.manifest?.microphoneDeviceID)
            refreshProfile(after: .milliseconds(400))
        }
    }
    /// Live levels and gain reduction from the voice tap.
    var voiceMeters: RecordingAudioMeters { audioParameters.meters }

    var isVoiceChainCustom: Bool { voiceProfile.customChain != nil }

    /// Edits the chain by hand. The first edit freezes the resolved chain
    /// as the starting point; from then on the profile stops resolving it.
    func editVoiceChain(_ edit: (inout VoiceChainSettings) -> Void) {
        var chain = voiceProfile.customChain ?? voiceChain
        edit(&chain)
        voiceProfile.customChain = chain
    }

    func resetVoiceChainToProfile() {
        voiceProfile.customChain = nil
    }

    /// Match EQ on or off. A custom chain keeps its own match gains, so it
    /// gets the measured ones back (or flat ones) here too.
    func setMatchesTarget(_ matches: Bool) {
        voiceProfile.matchesTarget = matches
        guard voiceProfile.customChain != nil else { return }
        editVoiceChain { chain in
            chain.match = matches
                ? voiceAnalysis.map { VoiceProfileResolver.matchEQ(measured: $0.thirdOctave) } ?? .init()
                : .init()
        }
    }

    /// The narration's measured loudness and balance, saved with the project.
    private(set) var voiceAnalysis: VoiceAnalysisResult?
    /// What the profile did, or what it is doing, for the inspector.
    private(set) var voiceProfileStatus: String?
    private(set) var isOptimizingVoice = false
    @ObservationIgnored private var voiceProfileTask: Task<Void, Never>?
    @ObservationIgnored private var isApplyingAutomaticGain = false
    @ObservationIgnored private var isApplyingDocument = false
    @ObservationIgnored private var isTornDown = false
    /// What the recording's own tracks carry, for the inspector.
    var recordedAudioRoles: Set<RecordingAudioRole> = []
    /// Read by the playback taps on the audio thread.
    @ObservationIgnored private let audioParameters = RecordingAudioParameters()

    var audioSettings: RecordingAudioSettings {
        RecordingAudioSettings(
            voiceGainDB: Double(voiceGainDB),
            systemGainDB: Double(systemGainDB),
            voiceProcessingEnabled: voiceProcessingEnabled,
            voiceChain: voiceChain,
            voiceIsolation: VoiceIsolationSettings(amount: voiceIsolationAmount),
            voiceProfile: voiceProfile
        )
    }

    /// An imported soundtrack stands in for all the recorded audio and is
    /// treated as narration.
    /// The audio at a glance, for the inspector's folded section: the
    /// character and where loudness lands, or the voice gain when no target
    /// is set; the system gain when there is no narration.
    var summary: String {
        guard hasVoiceAudio else {
            return InspectorValueFormat.decibels.displayString(for: systemGainDB)
        }
        let level = voiceProfile.loudnessTarget.lufs.map { String(format: "%.0f LUFS", $0) }
            ?? InspectorValueFormat.decibels.displayString(for: voiceGainDB)
        return "\(voiceProfile.character.title) · \(level)"
    }

    var hasVoiceAudio: Bool {
        host?.replacementAudio != nil || recordedAudioRoles.contains(.voice)
    }

    var hasSystemAudio: Bool {
        host?.replacementAudio == nil && recordedAudioRoles.contains(.system)
    }

    private func audioSettingsDidChange() {
        audioParameters.update(audioSettings)
        // While a document is applied, the model is not saving anyway.
        guard !isApplyingDocument else { return }
        host?.voiceSettingsDidChange()
    }

    // MARK: Project

    /// Gives a player item's tracks their taps. Settings reach them through
    /// `audioParameters`, so this runs only when the item is rebuilt, never
    /// while a slider drags.
    /// The recording's tracks through VoiceKit; clips added in Studio keep
    /// their own volume and fades.
    func installPlaybackAudioMix(
        on item: AVPlayerItem,
        clips: [RecordingAudioClip],
        clipTrackIDs: [UUID: CMPersistentTrackID]
    ) {
        let clipTracks = Set(clipTrackIDs.values)
        let tracks = item.asset.tracks(withMediaType: .audio).filter { !clipTracks.contains($0.trackID) }
        item.audioMix = RecordingVoiceMix.mix(
            recordingTracks: tracks,
            roles: RecordingAudioProcessing.rolesSynchronously(for: tracks, isReplacement: host?.replacementAudio != nil),
            clips: clips,
            clipTrackIDs: clipTrackIDs,
            parameters: audioParameters
        )
    }

    /// A new recording, or one from before profiles: start from what this
    /// microphone used last time, or the defaults.
    func adoptMicrophoneProfile(unlessIn document: RecordingEditDocument?) {
        guard document?.audioSettings?.voiceProfile == nil else { return }
        applying {
            voiceProfile = VoiceProfileStore.profile(forMicrophone: host?.manifest?.microphoneDeviceID)
                ?? VoiceProfileSettings()
        }
    }

    /// Copies a stored project's audio onto the controller.
    func apply(_ document: RecordingEditDocument) {
        applying {
            let audio = document.resolvedAudioSettings
            voiceGainDB = CGFloat(audio.voiceGainDB)
            systemGainDB = CGFloat(audio.systemGainDB)
            voiceProcessingEnabled = audio.voiceProcessingEnabled
            voiceChain = audio.voiceChain
            voiceIsolationAmount = audio.voiceIsolation.amount
            if let profile = audio.voiceProfile {
                voiceProfile = profile
            }
            voiceAnalysis = document.voiceAnalysis
        }
    }

    func teardown() {
        isTornDown = true
        voiceIsolationTask?.cancel()
        voiceIsolationTask = nil
        isolatedSourceAsset = nil
        voiceProfileTask?.cancel()
        voiceProfileTask = nil
    }

    private func applying(_ body: () -> Void) {
        isApplyingDocument = true
        defer { isApplyingDocument = false }
        body()
    }

    // MARK: Voice isolation

    /// Brings playback in line with the isolation setting: uses the render
    /// in the package if it is there, renders it otherwise, or goes back to
    /// the master. Playback keeps running on what it has meanwhile.
    func refreshIsolation() {
        guard host?.isLoaded == true else { return }
        voiceIsolationTask?.cancel()
        voiceIsolationError = nil
        let settings = VoiceIsolationSettings(amount: voiceIsolationAmount)

        guard settings.isEnabled, canIsolateVoice, let session = host?.session else {
            voiceIsolationProgress = nil
            if isolatedSourceAsset != nil {
                isolatedSourceAsset = nil
                host?.voiceSourceDidChange()
            }
            refreshProfile()
            return
        }

        let screenURL = session.screenURL
        let directory = session.directoryURL
        let renderURL = RecordingVoiceIsolation.renderURL(in: directory, settings: settings)
        voiceIsolationTask = Task { [weak self] in
            do {
                if !FileManager.default.fileExists(atPath: renderURL.path) {
                    self?.voiceIsolationProgress = 0
                    // Off the main actor; cancelling this task cancels it.
                    let render = Task.detached(priority: .userInitiated) {
                        try await RecordingVoiceIsolation.render(
                            screenURL: screenURL, to: renderURL, settings: settings
                        ) { progress in
                            Task { @MainActor [weak self] in
                                guard self?.voiceIsolationProgress != nil else { return }
                                self?.voiceIsolationProgress = progress
                            }
                        }
                    }
                    try await withTaskCancellationHandler {
                        try await render.value
                    } onCancel: {
                        render.cancel()
                    }
                }
                try Task.checkCancellation()
                let asset = try await RecordingVoiceIsolation.asset(screenURL: screenURL, isolatedURL: renderURL)
                try Task.checkCancellation()
                guard let self, !self.isTornDown else { return }
                RecordingVoiceIsolation.removeRenders(in: directory, keeping: renderURL)
                self.voiceIsolationProgress = nil
                self.isolatedSourceAsset = asset
                self.host?.voiceSourceDidChange()
                // The voice changed, so its analysis and loudness do too.
                self.refreshProfile()
            } catch is CancellationError {
                return
            } catch {
                guard let self, !Task.isCancelled else { return }
                self.voiceIsolationProgress = nil
                self.voiceIsolationError = error.localizedDescription
            }
        }
    }

    // MARK: Voice profile

    /// Resolves the chain from the profile, analyzing the narration the
    /// project plays if it has not been analyzed yet, and with a loudness
    /// target sets the voice gain that reaches it. Profile changes apply at
    /// once when the analysis is current; only the loudness pass (and a
    /// first analysis) runs in the background.
    private func refreshProfile(after delay: Duration = .zero) {
        guard let host, host.isLoaded else { return }
        voiceProfileTask?.cancel()
        let profile = voiceProfile

        guard let session = host.session, host.replacementAudio == nil, recordedAudioRoles.contains(.voice) else {
            // An imported soundtrack, or nothing recorded to measure.
            voiceChain = VoiceProfileResolver.chain(for: profile, analysis: nil)
            isOptimizingVoice = false
            voiceProfileStatus = nil
            return
        }

        let isolation = VoiceIsolationSettings(amount: voiceIsolationAmount)
        let key = VoiceAnalysisResult.sourceKey(for: isolation)
        let current = voiceAnalysis?.sourceKey == key ? voiceAnalysis : nil
        let target = profile.loudnessTarget.lufs
        if let current {
            voiceChain = VoiceProfileResolver.chain(for: profile, analysis: current)
            if target == nil {
                isOptimizingVoice = false
                voiceProfileStatus = Self.voiceSummary(current, gain: nil, target: nil)
                return
            }
        }

        let screenURL = session.screenURL
        isOptimizingVoice = true
        voiceProfileStatus = current == nil ? "Analyzing the voice…" : "Matching loudness…"
        voiceProfileTask = Task { [weak self] in
            do {
                if delay > .zero { try await Task.sleep(for: delay) }
                let work = Task.detached(priority: .userInitiated) { () throws -> (VoiceAnalysisResult, Double?) in
                    let samples = try await RecordingVoiceAnalysis.readVoice(screenURL: screenURL, isolation: isolation)
                    try Task.checkCancellation()
                    let analysis = try current ?? RecordingVoiceAnalysis.analyze(samples, sourceKey: key)
                    let chain = VoiceProfileResolver.chain(for: profile, analysis: analysis)
                    let gain = try target.flatMap {
                        try RecordingVoiceAnalysis.normalizationGain(samples, chain: chain, targetLUFS: $0)
                    }
                    return (analysis, gain)
                }
                let (analysis, gain) = try await withTaskCancellationHandler {
                    try await work.value
                } onCancel: {
                    work.cancel()
                }
                guard let self, !Task.isCancelled, !self.isTornDown else { return }
                self.voiceAnalysis = analysis
                self.voiceChain = VoiceProfileResolver.chain(for: profile, analysis: analysis)
                if let gain {
                    self.isApplyingAutomaticGain = true
                    self.voiceGainDB = CGFloat(gain)
                    self.isApplyingAutomaticGain = false
                }
                self.isOptimizingVoice = false
                self.voiceProfileStatus = Self.voiceSummary(analysis, gain: gain, target: target)
                self.host?.voiceSettingsDidChange()
            } catch is CancellationError {
                return
            } catch {
                guard let self, !Task.isCancelled else { return }
                self.isOptimizingVoice = false
                self.voiceProfileStatus = error.localizedDescription
            }
        }
    }

    private static func voiceSummary(_ analysis: VoiceAnalysisResult, gain: Double?, target: Double?) -> String {
        var parts: [String] = []
        if let loudness = analysis.integratedLUFS {
            parts.append(String(format: "Voice %.1f LUFS, trim %+.1f dB", loudness, VoiceProfileResolver.inputTrimDB(for: analysis)))
        }
        if let gain, let target {
            parts.append(String(format: "out %.0f LUFS (%+.1f dB)", target, gain))
        }
        return parts.joined(separator: " · ")
    }
}
