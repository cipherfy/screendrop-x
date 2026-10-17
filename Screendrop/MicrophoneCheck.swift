//
//  MicrophoneCheck.swift
//  Screendrop
//
//  A ten-second check of the selected microphone before recording: a
//  moment of silence for the room, a few seconds of speech for the level,
//  then plain advice. Gain staging is the one thing no processing can fix
//  afterwards, so it is worth catching here. Audio stays in memory and is
//  discarded when the panel closes.
//

import AVFoundation
import AppKit
import Synchronization
import SwiftUI

// MARK: - Capture

/// Runs the check against one microphone through AVCapture, the same path
/// the recorder uses, so it hears exactly what a recording would.
@Observable
final class MicrophoneCheckSession {
    enum Phase: Equatable {
        case ready
        case silence
        case speech
        case finished(MicrophoneCheckResult)
        case failed(String)
    }

    static let silenceSeconds = 2.5
    static let speechSeconds = 6.0
    static let sampleRate = 48_000.0
    static let script = "Hi, in this tutorial I'll show you how to set up your first project, step by step."

    let deviceID: String
    let deviceName: String
    private(set) var phase: Phase = .ready
    private(set) var progress = 0.0
    private(set) var levelDB = -120.0

    private let capture = MicrophoneCheckCapture()
    private var timer: Timer?
    private var phaseStart = Date()

    init(deviceID: String) {
        self.deviceID = deviceID
        deviceName = RecordingDeviceCatalog.microphone(withID: deviceID)?.localizedName ?? "Microphone"
    }

    func start() {
        stop()
        guard let device = RecordingDeviceCatalog.microphone(withID: deviceID) else {
            phase = .failed("The microphone is no longer connected.")
            return
        }
        do {
            try capture.start(device: device, sampleRate: Self.sampleRate)
        } catch {
            phase = .failed(error.localizedDescription)
            return
        }
        phase = .silence
        phaseStart = Date()
        progress = 0
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        capture.stop()
    }

    private func tick() {
        levelDB = capture.takePeakDB()
        let elapsed = Date().timeIntervalSince(phaseStart)
        switch phase {
        case .silence:
            progress = min(1, elapsed / Self.silenceSeconds)
            if elapsed >= Self.silenceSeconds {
                capture.markBoundary()
                phase = .speech
                phaseStart = Date()
                progress = 0
            }
        case .speech:
            progress = min(1, elapsed / Self.speechSeconds)
            if elapsed >= Self.speechSeconds {
                let (silence, speech) = capture.takeSamples()
                stop()
                levelDB = -120
                // Drop the first 300 ms of each part: the click of starting
                // and the breath before the first word.
                let trim = Int(Self.sampleRate * 0.3)
                phase = .finished(MicrophoneCheckAnalyzer.evaluate(
                    silence: Array(silence.dropFirst(trim)),
                    speech: Array(speech.dropFirst(trim)),
                    sampleRate: Self.sampleRate
                ))
            }
        default:
            break
        }
    }
}

/// The capture side: an AVCaptureSession delivering mono float at 48 kHz
/// to a queue, collected under a mutex.
nonisolated private final class MicrophoneCheckCapture: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {
    private struct Buffer {
        var samples: [Float] = []
        var boundary: Int?
        var peak: Float = 0
    }

    private let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "com.screendrop.microphone-check", qos: .userInitiated)
    private let buffer = Mutex(Buffer())

    func start(device: AVCaptureDevice, sampleRate: Double) throws {
        buffer.withLock { $0 = Buffer() }
        session.beginConfiguration()
        session.inputs.forEach(session.removeInput)
        session.outputs.forEach(session.removeOutput)
        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input) else { throw CocoaError(.featureUnsupported) }
        session.addInput(input)
        let output = AVCaptureAudioDataOutput()
        output.audioSettings = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]
        output.setSampleBufferDelegate(self, queue: queue)
        guard session.canAddOutput(output) else { throw CocoaError(.featureUnsupported) }
        session.addOutput(output)
        session.commitConfiguration()
        queue.async { [self] in session.startRunning() }
    }

    func stop() {
        queue.async { [self] in if session.isRunning { session.stopRunning() } }
    }

    func markBoundary() {
        buffer.withLock { $0.boundary = $0.samples.count }
    }

    func takePeakDB() -> Double {
        let peak = buffer.withLock { buffer -> Float in
            let value = buffer.peak
            buffer.peak = 0
            return value
        }
        return VoiceAnalyzer.decibels(amplitude: Double(peak))
    }

    func takeSamples() -> (silence: [Float], speech: [Float]) {
        buffer.withLock { buffer in
            let boundary = buffer.boundary ?? buffer.samples.count
            let result = (Array(buffer.samples[..<boundary]), Array(buffer.samples[boundary...]))
            buffer = Buffer()
            return result
        }
    }

    nonisolated func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let block = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }
        let length = CMBlockBufferGetDataLength(block)
        var chunk = [Float](repeating: 0, count: length / MemoryLayout<Float>.size)
        chunk.withUnsafeMutableBytes { _ = CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: $0.baseAddress!) }
        let peak = chunk.map(abs).max() ?? 0
        buffer.withLock { buffer in
            buffer.samples += chunk
            buffer.peak = max(buffer.peak, peak)
        }
    }
}

// MARK: - View

struct MicrophoneCheckView: View {
    let session: MicrophoneCheckSession
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Microphone Check").font(.dsHeadline)
                Text(session.deviceName).font(.inspectorLabel).foregroundStyle(.secondary)
            }

            switch session.phase {
            case .ready:
                Text("Ten seconds: first stay silent so the room can be measured, then read a line at your normal recording distance and volume. Nothing is saved.")
                    .fixedSize(horizontal: false, vertical: true)
            case .silence:
                instruction("Stay silent…", detail: "Measuring the room.")
            case .speech:
                instruction("Now read aloud:", detail: "“\(MicrophoneCheckSession.script)”")
            case .finished(let result):
                results(result)
            case .failed(let message):
                Label(message, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            }

            if session.phase == .silence || session.phase == .speech {
                ProgressView(value: session.progress)
                LevelMeterRow(label: "Level", decibels: session.levelDB)
            }

            Spacer(minLength: 0)
            HStack {
                Spacer()
                Button("Done") { onClose() }
                    .keyboardShortcut(.cancelAction)
                Button(session.phase == .ready ? "Start" : "Check Again") { session.start() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(session.phase == .silence || session.phase == .speech)
            }
        }
        .padding(20)
        .frame(width: 380, height: 420, alignment: .topLeading)
        .onAppear { AppActivationPolicy.enter() }
        .onDisappear {
            session.stop()
            AppActivationPolicy.leave()
        }
    }

    private func instruction(_ title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.title3.weight(.semibold))
            Text(detail).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func results(_ result: MicrophoneCheckResult) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(result.isReady ? "Ready to record" : "Worth fixing before you record",
                  systemImage: result.isReady ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                .font(.headline)
                .foregroundStyle(result.isReady ? .green : .orange)
            ForEach(result.findings) { finding in
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: symbol(finding.severity))
                        .foregroundStyle(tint(finding.severity))
                        .frame(width: 16)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(finding.title).font(.body.weight(.medium))
                        Text(finding.detail).font(.callout).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            Text(String(format: "Peak %.1f dBFS · voice %@ · room %.0f dBFS",
                        result.speechPeakDBFS,
                        result.speechLUFS.map { String(format: "%.1f LUFS", $0) } ?? "–",
                        result.noiseFloorDBFS))
                .font(.caption).foregroundStyle(.tertiary).monospacedDigit()
        }
    }

    private func symbol(_ severity: MicrophoneCheckResult.Finding.Severity) -> String {
        switch severity {
        case .good: "checkmark.circle.fill"
        case .advice: "info.circle.fill"
        case .problem: "exclamationmark.circle.fill"
        }
    }

    private func tint(_ severity: MicrophoneCheckResult.Finding.Severity) -> Color {
        switch severity {
        case .good: .green
        case .advice: .blue
        case .problem: .orange
        }
    }
}

// MARK: - Presenter

final class MicrophoneCheckPresenter: NSObject, NSWindowDelegate {
    static let shared = MicrophoneCheckPresenter()

    private var window: NSWindow?
    private var session: MicrophoneCheckSession?

    func present(deviceID: String) {
        close()
        let session = MicrophoneCheckSession(deviceID: deviceID)
        let window = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 420),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Microphone Check"
        window.isReleasedWhenClosed = false
        window.level = .floating
        window.delegate = self
        window.contentView = NSHostingView(rootView: MicrophoneCheckView(session: session) { [weak self] in
            self?.close()
        })
        window.center()
        self.window = window
        self.session = session
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func close() {
        session?.stop()
        window?.close()
        window = nil
        session = nil
    }

    func windowWillClose(_ notification: Notification) {
        session?.stop()
        window = nil
        session = nil
    }
}
