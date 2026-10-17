//
//  VoiceMetersView.swift
//  Screendrop
//
//  Live meters for the voice while Studio plays: input and output peak,
//  gain reduction per dynamics stage, and short-term loudness against the
//  profile's target. The voice tap publishes values per buffer; this view
//  samples them at display rate and applies meter ballistics.
//

import SwiftUI

struct VoiceMetersView: View {
    let meters: RecordingAudioMeters
    var targetLUFS: Double?

    @State private var ballistics = MeterBallistics()

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30)) { context in
            let reading = ballistics.update(meters.snapshot(), at: context.date)
            VStack(alignment: .leading, spacing: 5) {
                LevelMeterRow(label: "In", decibels: reading.inputDB)
                LevelMeterRow(label: "Out", decibels: reading.outputDB)
                HStack(spacing: 6) {
                    ReductionMeter(label: "Exp", decibels: reading.expanderDB)
                    ReductionMeter(label: "Comp", decibels: reading.compressorDB)
                    ReductionMeter(label: "De-ess", decibels: reading.deEsserDB)
                    ReductionMeter(label: "Limit", decibels: reading.limiterDB)
                }
                loudnessRow(reading.shortTermLUFS)
            }
            .font(.inspectorLabel)
            .monospacedDigit()
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Voice meters")
    }

    private func loudnessRow(_ lufs: Double?) -> some View {
        HStack(spacing: 6) {
            Text("Loudness")
                .foregroundStyle(.secondary)
            Spacer(minLength: 4)
            Text(lufs.map { String(format: "%.1f LUFS", $0) } ?? "– LUFS")
                .foregroundStyle(loudnessTint(lufs))
            if let targetLUFS {
                Text(String(format: "target %.0f", targetLUFS))
                    .foregroundStyle(.tertiary)
            }
        }
        .help("Short-term loudness of the processed voice (3 s window)")
    }

    private func loudnessTint(_ lufs: Double?) -> Color {
        guard let lufs, let targetLUFS else { return .primary }
        return abs(lufs - targetLUFS) <= 2 ? .green : .primary
    }
}

/// Peak hold with a fall of 20 dB per second, gain reduction that releases
/// at 30 dB per second, and silence once the tap stops publishing.
final class MeterBallistics {
    struct Reading {
        var inputDB = -120.0
        var outputDB = -120.0
        var expanderDB = 0.0
        var compressorDB = 0.0
        var deEsserDB = 0.0
        var limiterDB = 0.0
        var shortTermLUFS: Double?
    }

    private var reading = Reading()
    private var lastSequence: UInt32 = 0
    private var lastChange = Date.distantPast
    private var lastUpdate = Date.distantPast

    func update(_ snapshot: RecordingAudioMeters.Snapshot, at date: Date) -> Reading {
        let elapsed = min(0.25, max(0, date.timeIntervalSince(lastUpdate)))
        lastUpdate = date
        if snapshot.sequence != lastSequence {
            lastSequence = snapshot.sequence
            lastChange = date
        }
        let isLive = date.timeIntervalSince(lastChange) < 0.3
        let fall = 20 * elapsed
        let recover = 30 * elapsed

        func peak(_ displayed: Double, _ new: Double) -> Double {
            max(isLive ? new : -120, displayed - fall)
        }
        func reduction(_ displayed: Double, _ new: Double) -> Double {
            min(isLive ? new : 0, min(0, displayed + recover))
        }

        reading.inputDB = peak(reading.inputDB, snapshot.inputPeakDB)
        reading.outputDB = peak(reading.outputDB, snapshot.outputPeakDB)
        reading.expanderDB = reduction(reading.expanderDB, snapshot.expanderDB)
        reading.compressorDB = reduction(reading.compressorDB, snapshot.compressorDB)
        reading.deEsserDB = reduction(reading.deEsserDB, snapshot.deEsserDB)
        reading.limiterDB = reduction(reading.limiterDB, snapshot.limiterDB)
        reading.shortTermLUFS = isLive ? snapshot.shortTermLUFS : nil
        return reading
    }
}

/// A horizontal peak meter from -60 to 0 dBFS: green up to -18, amber to
/// -6, red above.
struct LevelMeterRow: View {
    let label: String
    let decibels: Double

    var body: some View {
        HStack(spacing: 6) {
            Text(label)
                .foregroundStyle(.secondary)
                .frame(width: 26, alignment: .leading)
            Canvas { context, size in
                let floor = -60.0
                func x(_ db: Double) -> CGFloat { size.width * CGFloat((min(0, max(floor, db)) - floor) / -floor) }
                let track = Path(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: size.height / 2)
                context.fill(track, with: .color(.primary.opacity(0.08)))
                context.clip(to: track)
                let zones: [(Double, Double, Color)] = [(floor, -18, .green), (-18, -6, .yellow), (-6, 0, .red)]
                for (low, high, color) in zones where decibels > low {
                    let rect = CGRect(x: x(low), y: 0, width: x(min(high, decibels)) - x(low), height: size.height)
                    context.fill(Path(rect), with: .color(color.opacity(0.85)))
                }
            }
            .frame(height: 6)
            Text(decibels > -119 ? String(format: "%.0f", decibels) : "–")
                .frame(width: 26, alignment: .trailing)
        }
    }
}

/// Gain reduction from 0 down to -20 dB, drawn from the right.
private struct ReductionMeter: View {
    let label: String
    let decibels: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Canvas { context, size in
                let fraction = CGFloat(min(20, max(0, -decibels)) / 20)
                let track = Path(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: size.height / 2)
                context.fill(track, with: .color(.primary.opacity(0.08)))
                context.clip(to: track)
                let width = size.width * fraction
                context.fill(Path(CGRect(x: size.width - width, y: 0, width: width, height: size.height)), with: .color(.orange.opacity(0.85)))
            }
            .frame(height: 5)
            HStack(spacing: 2) {
                Text(label).foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Text(decibels < -0.05 ? String(format: "%.1f", decibels) : "0")
            }
            .lineLimit(1)
            .minimumScaleFactor(0.7)
        }
        .help("\(label) gain reduction")
    }
}
