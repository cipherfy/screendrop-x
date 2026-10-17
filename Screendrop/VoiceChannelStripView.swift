//
//  VoiceChannelStripView.swift
//  Screendrop
//
//  Every stage of the voice chain, by hand. The first edit turns the
//  profile's chain into a custom one (the loudness target still applies);
//  Reset to Profile hands control back. The curve on top is the static
//  EQ's actual response, computed from the coefficients the chain runs.
//

import SwiftUI
import VoiceKit

struct VoiceChannelStripView: View {
    let model: RecordingStudioModel

    private var chain: VoiceChainSettings { model.voiceChain }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Channel Strip")
                    .font(.dsHeadline)
                Spacer()
                if model.isVoiceChainCustom {
                    Button("Reset to Profile") { model.resetVoiceChainToProfile() }
                        .controlSize(.small)
                }
            }
            Text(model.isVoiceChainCustom
                 ? "Custom chain. Profile changes will not alter it until you reset."
                 : "Following the voice profile. Any change here makes the chain custom.")
                .font(.inspectorLabel)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            EQResponseCurve(chain: chain)
                .frame(height: 110)

            VoiceMetersView(meters: model.voiceMeters, targetLUFS: model.voiceProfile.loudnessTarget.lufs)

            ScrollView {
                VStack(alignment: .leading, spacing: InspectorMetrics.rowSpacing) {
                    section("Input") {
                        slider("Trim", \.inputTrimDB, -18...18, .decibels)
                    }
                    section("High-Pass", isOn: \.highPass.isEnabled) {
                        slider("Frequency", \.highPass.frequency, 40...200, .hertz)
                        toggle("24 dB/oct", \.highPass.isSteep)
                    }
                    section("EQ") {
                        band("Body", \.lowShelf, 60...400)
                        band("Mud", \.lowMid, 150...800)
                        band("Presence", \.mid, 1_000...8_000)
                        band("Harshness", \.presence, 2_000...10_000)
                        band("Air", \.highShelf, 5_000...16_000)
                    }
                    VStack(alignment: .leading, spacing: InspectorMetrics.rowSpacing) {
                        InspectorToggleRow(
                            "Match Target EQ",
                            isOn: Binding(
                                get: { model.voiceProfile.matchesTarget },
                                set: { model.setMatchesTarget($0) }
                            )
                        )
                        .font(.inspectorLabel.weight(.semibold))
                        .help("Measures the voice's balance and gently corrects it toward a reference narration curve")
                    }
                    .padding(.top, 4)
                    if model.voiceProfile.matchesTarget {
                        slider("250 Hz", \.match.gain250, -6...4.5, .decibels)
                        slider("500 Hz", \.match.gain500, -6...4.5, .decibels)
                        slider("1 kHz", \.match.gain1k, -6...4.5, .decibels)
                        slider("2 kHz", \.match.gain2k, -6...4.5, .decibels)
                        slider("4 kHz", \.match.gain4k, -6...4.5, .decibels)
                        slider("8 kHz", \.match.gain8k, -6...4.5, .decibels)
                    }
                    section("Proximity", isOn: \.dynamicLow.isEnabled) {
                        slider("Frequency", \.dynamicLow.frequency, 80...300, .hertz)
                        slider("Threshold", \.dynamicLow.thresholdDB, -60...0, .decibels)
                        slider("Range", \.dynamicLow.rangeDB, 0...12, .decibels)
                    }
                    section("Expander", isOn: \.expander.isEnabled) {
                        slider("Threshold", \.expander.thresholdDB, -70...(-20), .decibels)
                        slider("Ratio", \.expander.ratio, 1...4, .decimal(fractionDigits: 1))
                        slider("Range", \.expander.rangeDB, 0...20, .decibels)
                        slider("Release", \.expander.releaseMilliseconds, 20...500, .milliseconds)
                    }
                    section("Compressor", isOn: \.compressor.isEnabled) {
                        slider("Threshold", \.compressor.thresholdDB, -40...0, .decibels)
                        slider("Ratio", \.compressor.ratio, 1...10, .decimal(fractionDigits: 1))
                        slider("Knee", \.compressor.kneeDB, 0...12, .decibels)
                        slider("Attack", \.compressor.attackMilliseconds, 1...50, .milliseconds)
                        slider("Release", \.compressor.releaseMilliseconds, 20...500, .milliseconds)
                        slider("Makeup", \.compressor.makeupDB, 0...18, .decibels)
                    }
                    section("De-Esser", isOn: \.deEsser.isEnabled) {
                        slider("Frequency", \.deEsser.frequency, 3_000...10_000, .hertz)
                        slider("Threshold", \.deEsser.thresholdDB, -60...0, .decibels)
                        slider("Range", \.deEsser.rangeDB, 0...15, .decibels)
                    }
                    section("Saturation", isOn: \.saturation.isEnabled) {
                        slider("Drive", \.saturation.driveDB, 0...24, .decibels)
                        slider("Mix", \.saturation.mix, 0...1, .percent())
                        slider("Warmth", \.saturation.warmth, 0...1, .percent())
                    }
                }
                .padding(.trailing, 4)
            }
            .frame(maxHeight: 360)
        }
        .padding(16)
        .frame(width: 340)
        .disabled(!model.voiceProcessingEnabled)
    }

    // MARK: Building blocks

    @ViewBuilder
    private func section<Content: View>(
        _ title: String,
        isOn: WritableKeyPath<VoiceChainSettings, Bool>? = nil,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: InspectorMetrics.rowSpacing) {
            if let isOn {
                InspectorToggleRow(title, isOn: boolBinding(isOn))
                    .font(.inspectorLabel.weight(.semibold))
            } else {
                Text(title)
                    .font(.inspectorLabel.weight(.semibold))
            }
            if isOn.map({ chain[keyPath: $0] }) ?? true {
                content()
            }
        }
        .padding(.top, 4)
    }

    private func band(_ title: String, _ path: WritableKeyPath<VoiceChainSettings, VoiceChainSettings.Band>, _ range: ClosedRange<Double>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            slider(title, path.appending(path: \.gainDB), -12...12, .decibels)
            HStack(spacing: 6) {
                slider("Freq", path.appending(path: \.frequency), range, .hertz)
                slider("Q", path.appending(path: \.q), 0.3...4, .decimal(fractionDigits: 1))
            }
        }
    }

    private func slider(
        _ title: String,
        _ path: WritableKeyPath<VoiceChainSettings, Double>,
        _ range: ClosedRange<Double>,
        _ format: InspectorValueFormat
    ) -> some View {
        InspectorSlider(
            title,
            value: Binding(
                get: { CGFloat(model.voiceChain[keyPath: path]) },
                set: { value in model.editVoiceChain { $0[keyPath: path] = Double(value) } }
            ),
            range: CGFloat(range.lowerBound)...CGFloat(range.upperBound),
            format: format
        )
    }

    private func toggle(_ title: String, _ path: WritableKeyPath<VoiceChainSettings, Bool>) -> some View {
        InspectorToggleRow(title, isOn: boolBinding(path))
    }

    private func boolBinding(_ path: WritableKeyPath<VoiceChainSettings, Bool>) -> Binding<Bool> {
        Binding(
            get: { model.voiceChain[keyPath: path] },
            set: { value in model.editVoiceChain { $0[keyPath: path] = value } }
        )
    }
}

/// The static EQ's magnitude response, 20 Hz to 20 kHz on a log axis,
/// ±18 dB, with octave gridlines.
struct EQResponseCurve: View {
    let chain: VoiceChainSettings

    var body: some View {
        Canvas { context, size in
            let minimum = log10(20.0), maximum = log10(20_000.0)
            let range = 18.0
            func x(_ hz: Double) -> CGFloat { size.width * CGFloat((log10(hz) - minimum) / (maximum - minimum)) }
            func y(_ db: Double) -> CGFloat { size.height * CGFloat(0.5 - min(range, max(-range, db)) / (2 * range)) }

            let background = Path(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: 8)
            context.fill(background, with: .color(.primary.opacity(0.05)))
            for hz in [31.25, 62.5, 125, 250, 500, 1_000, 2_000, 4_000, 8_000, 16_000] {
                var line = Path()
                line.move(to: CGPoint(x: x(hz), y: 0))
                line.addLine(to: CGPoint(x: x(hz), y: size.height))
                context.stroke(line, with: .color(.primary.opacity(0.07)), lineWidth: 1)
            }
            for db in [-12.0, -6, 0, 6, 12] {
                var line = Path()
                line.move(to: CGPoint(x: 0, y: y(db)))
                line.addLine(to: CGPoint(x: size.width, y: y(db)))
                context.stroke(line, with: .color(.primary.opacity(db == 0 ? 0.2 : 0.07)), lineWidth: 1)
            }

            var curve = Path()
            let steps = 160
            for step in 0...steps {
                let hz = pow(10, minimum + (maximum - minimum) * Double(step) / Double(steps))
                let point = CGPoint(x: x(hz), y: y(chain.responseDB(at: hz)))
                if step == 0 { curve.move(to: point) } else { curve.addLine(to: point) }
            }
            context.stroke(curve, with: .color(.accentColor), lineWidth: 2)

            for (hz, label) in [(100.0, "100"), (1_000.0, "1k"), (10_000.0, "10k")] {
                context.draw(Text(label).font(.system(size: 9)).foregroundStyle(.secondary),
                             at: CGPoint(x: x(hz), y: size.height - 7))
            }
        }
        .accessibilityLabel("EQ response curve")
    }
}
