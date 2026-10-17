import AVFoundation
import Foundation

// Compile with the meter and the profile code it reads target curves for:
//
//   xcrun swiftc -O Screendrop/VoiceMeasurement.swift Screendrop/VoiceChain.swift \
//     Screendrop/RecordingAudioProcessing.swift Screendrop/VoiceProfile.swift \
//     scripts/voice-bank.swift -o build/voice-bank/bin/voice-bank
//
// Measures narration files and builds degraded variants of a clean take so
// voice processing can be checked against known problems without a test
// target. scripts/voice-bank/generate.sh drives the whole bank.
@main
struct VoiceBank {
    static func main() throws {
        var arguments = Array(CommandLine.arguments.dropFirst())
        guard !arguments.isEmpty else { usage() }
        let command = arguments.removeFirst()
        switch command {
        case "analyze": try analyze(arguments)
        case "compare": try compare(arguments)
        case "degrade": try degrade(arguments)
        case "tone": try tone(arguments)
        case "target": try target(arguments)
        default: usage()
        }
    }

    static func usage() -> Never {
        print("""
        usage:
          voice-bank analyze <file>... [--json <out.json>]
          voice-bank compare <baseline.json> <current.json>
          voice-bank degrade <clean.wav> <output-dir> [--lufs <target>]
          voice-bank tone <sine-1k|intersample> <out.wav>
          voice-bank target <reference>...
        """)
        exit(2)
    }

    // MARK: Analyze

    struct Entry: Codable {
        let file: String
        let measurement: VoiceMeasurement
    }

    static func analyze(_ arguments: [String]) throws {
        var files: [String] = []
        var jsonPath: String?
        var iterator = arguments.makeIterator()
        while let argument = iterator.next() {
            if argument == "--json" { jsonPath = iterator.next() } else { files.append(argument) }
        }
        guard !files.isEmpty else { usage() }

        var entries: [Entry] = []
        for path in files {
            let audio = try AudioData.read(path)
            let measurement = VoiceAnalyzer.measure(channels: audio.channels, sampleRate: audio.sampleRate)
            entries.append(Entry(file: URL(fileURLWithPath: path).lastPathComponent, measurement: measurement))
        }

        printSummary(entries)
        printBands(entries)

        if let jsonPath {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(entries).write(to: URL(fileURLWithPath: jsonPath))
            print("\nwrote \(jsonPath)")
        }
    }

    static func printSummary(_ entries: [Entry]) {
        let width = max(4, entries.map(\.file.count).max() ?? 0)
        print(pad("file", width) + "   LUFS-I  LRA   M-max  S-max  peak   TP     speech noise  SNR   clip")
        for entry in entries {
            let m = entry.measurement
            print(pad(entry.file, width)
                  + "  " + num(m.integratedLUFS, 7)
                  + num(m.loudnessRangeLU, 5)
                  + num(m.momentaryMaxLUFS, 7)
                  + num(m.shortTermMaxLUFS, 7)
                  + num(m.samplePeakDBFS, 7)
                  + num(m.truePeakDBTP, 7)
                  + num(m.speechLevelDBFS, 7)
                  + num(m.noiseFloorDBFS, 7)
                  + num(m.signalToNoiseDB, 6)
                  + String(m.clippedSamples).leftPadded(6))
        }
    }

    static func printBands(_ entries: [Entry]) {
        let width = max(4, entries.map(\.file.count).max() ?? 0)
        let names = SpectrumAnalyzer.voiceBands.map(\.name)
        print("\nspectral balance (dB per octave vs. 100 Hz-10 kHz average)")
        print(pad("file", width) + "  " + names.map { String($0.prefix(6)).leftPadded(7) }.joined())
        for entry in entries {
            let levels = Dictionary(uniqueKeysWithValues: entry.measurement.bands.map { ($0.name, $0.levelDB) })
            print(pad(entry.file, width) + "  " + names.map { num(levels[$0], 7) }.joined())
        }
    }

    // MARK: Compare

    /// Differences beyond these are reported; a file newly over -1 dBTP or
    /// with more clipping than before is a failure.
    static let tolerances: [(label: String, limit: Double, value: (VoiceMeasurement) -> Double?)] = [
        ("LUFS-I", 0.5, { $0.integratedLUFS }),
        ("LRA", 1.0, { $0.loudnessRangeLU }),
        ("true peak", 0.5, { $0.truePeakDBTP }),
        ("noise floor", 1.0, { $0.noiseFloorDBFS }),
        ("SNR", 1.0, { $0.signalToNoiseDB })
    ]

    static func compare(_ arguments: [String]) throws {
        guard arguments.count == 2 else { usage() }
        let decoder = JSONDecoder()
        let baseline = try decoder.decode([Entry].self, from: Data(contentsOf: URL(fileURLWithPath: arguments[0])))
        let current = try decoder.decode([Entry].self, from: Data(contentsOf: URL(fileURLWithPath: arguments[1])))
        let baselineByFile = Dictionary(uniqueKeysWithValues: baseline.map { ($0.file, $0.measurement) })

        var changes = 0
        var failures = 0
        for entry in current {
            let now = entry.measurement
            guard let before = baselineByFile[entry.file] else {
                print("+ \(entry.file): new file")
                continue
            }
            var lines: [String] = []
            for tolerance in tolerances {
                guard let old = tolerance.value(before), let new = tolerance.value(now) else { continue }
                if abs(new - old) > tolerance.limit {
                    lines.append("\(tolerance.label) \(fmt(old)) -> \(fmt(new)) (\(signed(new - old)))")
                }
            }
            let oldBands = Dictionary(uniqueKeysWithValues: before.bands.map { ($0.name, $0.levelDB) })
            for band in now.bands {
                if let old = oldBands[band.name], abs(band.levelDB - old) > 1 {
                    lines.append("\(band.name) \(fmt(old)) -> \(fmt(band.levelDB)) dB (\(signed(band.levelDB - old)))")
                }
            }
            // Only a regression fails: the "hot" variants are over on purpose.
            if now.truePeakDBTP > -1, before.truePeakDBTP <= -1 {
                lines.append("FAIL true peak \(fmt(now.truePeakDBTP)) dBTP is now above -1 dBTP")
                failures += 1
            }
            if now.clippedSamples > before.clippedSamples {
                lines.append("FAIL clipped samples \(before.clippedSamples) -> \(now.clippedSamples)")
                failures += 1
            }
            if !lines.isEmpty {
                changes += 1
                print("~ \(entry.file)")
                lines.forEach { print("    \($0)") }
            }
        }
        let missing = Set(baselineByFile.keys).subtracting(current.map(\.file))
        missing.sorted().forEach { print("- \($0): missing from current run") }

        print(changes == 0 && missing.isEmpty ? "no changes beyond tolerance" : "\(changes) file(s) changed")
        if failures > 0 {
            print("\(failures) failure(s)")
            exit(1)
        }
    }

    // MARK: Degrade

    /// Each variant reproduces a problem narration actually has, most of
    /// them typical of a USB condenser on a desk.
    static func degrade(_ arguments: [String]) throws {
        guard arguments.count >= 2 else { usage() }
        var targetLUFS = -26.0
        if let index = arguments.firstIndex(of: "--lufs"), index + 1 < arguments.count,
           let value = Double(arguments[index + 1]) {
            targetLUFS = value
        }
        let source = try AudioData.read(arguments[0])
        let outputDirectory = URL(fileURLWithPath: arguments[1])
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        let name = URL(fileURLWithPath: arguments[0]).deletingPathExtension().lastPathComponent
        let rate = source.sampleRate

        // A raw take sits well below delivery loudness.
        var clean = source.mono
        if let measured = LoudnessMeter.measure(channels: [clean], sampleRate: rate).integrated {
            clean = scaled(clean, decibels: targetLUFS - measured)
        }

        var random = SeededRandom(seed: 0x5C4EE4D0)
        let room = Reverb(sampleRate: rate).process(clean)
        let keyboard = Synth.keyboard(count: clean.count, sampleRate: rate, random: &random)
        let noise = Synth.pinkNoise(count: clean.count, rmsDB: -58, random: &random)
        let hum = Synth.hum(count: clean.count, sampleRate: rate, levelDB: -66)

        var harsh = clean
        var presencePeak = ShapingBiquad.peaking(sampleRate: rate, frequency: 5_000, q: 1.4, gainDB: 6)
        presencePeak.process(&harsh)

        var thin = clean
        var lowCut = ShapingBiquad.lowShelf(sampleRate: rate, frequency: 250, gainDB: -7)
        lowCut.process(&thin)

        var boomy = clean
        var proximity = ShapingBiquad.lowShelf(sampleRate: rate, frequency: 160, gainDB: 8)
        proximity.process(&boomy)

        var desk = Reverb(sampleRate: rate).process(harsh)
        desk = mix(desk, keyboard, noise, hum)

        let variants: [(String, [Float])] = [
            ("clean", clean),
            ("noisy", mix(clean, noise)),
            ("hum", mix(clean, hum)),
            ("keyboard", mix(clean, keyboard)),
            ("room", room),
            ("harsh", harsh),
            ("thin", thin),
            ("boomy", boomy),
            ("quiet", scaled(clean, decibels: -18)),
            ("hot", scaled(clean, decibels: 16).map { min(1, max(-1, $0)) }),
            ("usb-condenser-desk", desk)
        ]
        for (variant, samples) in variants {
            let url = outputDirectory.appendingPathComponent("\(name)-\(variant).wav")
            try AudioData.write(samples, sampleRate: rate, to: url)
            print(url.path)
        }
    }

    // MARK: Target

    /// Averages the third-octave balance of reference narrations you like
    /// into a target curve for match EQ, printed as Swift to paste into
    /// VoiceTargetCurve. Each file weighs the same; bands a file does not
    /// reach (a narrowband voice above 8 kHz) are averaged over the rest.
    static func target(_ arguments: [String]) throws {
        guard !arguments.isEmpty else { usage() }
        var sums: [Double: (total: Double, count: Int)] = [:]
        for path in arguments {
            let audio = try AudioData.read(path)
            let measurement = VoiceAnalyzer.measure(channels: [audio.mono], sampleRate: audio.sampleRate)
            for point in measurement.thirdOctave where point.levelDB > -60 {
                sums[point.centerHz, default: (0, 0)].total += point.levelDB
                sums[point.centerHz, default: (0, 0)].count += 1
            }
        }
        let range = VoiceTargetCurve.range
        let points = sums.keys.sorted()
            .filter { range.contains($0) }
            .map { (centerHz: $0, levelDB: sums[$0]!.total / Double(sums[$0]!.count)) }
        guard !points.isEmpty else { print("no usable spectrum"); exit(1) }
        let mean = points.map(\.levelDB).reduce(0, +) / Double(points.count)
        print("// From: \(arguments.map { URL(fileURLWithPath: $0).lastPathComponent }.joined(separator: ", "))")
        print("static let points: [VoiceMeasurement.SpectrumPoint] = [")
        for point in points {
            print(String(format: "    .init(centerHz: %.1f, levelDB: %.1f),", point.centerHz, point.levelDB - mean))
        }
        print("]")
    }

    // MARK: Tone

    /// Signals with known answers, for checking the meters themselves.
    static func tone(_ arguments: [String]) throws {
        guard arguments.count == 2 else { usage() }
        let rate = 48_000.0
        let count = Int(rate * 20)
        let url = URL(fileURLWithPath: arguments[1])
        switch arguments[0] {
        case "sine-1k":
            // EBU Tech 3341 case 1: 1 kHz at -23 dBFS in both channels
            // reads -23.0 LUFS.
            let amplitude = Float(pow(10, -23.0 / 20))
            let sine = (0..<count).map { amplitude * Float(sin(2 * .pi * 1_000 * Double($0) / rate)) }
            try AudioData.write(channels: [sine, sine], sampleRate: rate, to: url)
        case "intersample":
            // fs/4 at 45 degrees: every sample lands at 0.707 of the true
            // crest, so sample peak reads about 3 dB under true peak.
            let sine = (0..<count).map { 0.5 * Float(sin(.pi / 2 * Double($0) + .pi / 4)) }
            try AudioData.write(channels: [sine], sampleRate: rate, to: url)
        default:
            usage()
        }
        print(url.path)
    }

    // MARK: Helpers

    static func scaled(_ samples: [Float], decibels: Double) -> [Float] {
        let gain = Float(pow(10, decibels / 20))
        return samples.map { $0 * gain }
    }

    static func mix(_ layers: [Float]...) -> [Float] {
        var output = layers[0]
        for layer in layers.dropFirst() {
            for index in 0..<min(output.count, layer.count) { output[index] += layer[index] }
        }
        return output
    }

    static func pad(_ text: String, _ width: Int) -> String {
        text.count >= width ? text : text + String(repeating: " ", count: width - text.count)
    }

    static func num(_ value: Double?, _ width: Int) -> String {
        guard let value, value > VoiceAnalyzer.silenceDB else { return "-".leftPadded(width) }
        return String(format: "%.1f", value).leftPadded(width)
    }

    static func fmt(_ value: Double) -> String { String(format: "%.1f", value) }
    static func signed(_ value: Double) -> String { String(format: "%+.1f", value) }
}

extension String {
    func leftPadded(_ width: Int) -> String {
        count >= width ? self : String(repeating: " ", count: width - count) + self
    }
}

// MARK: - Audio files

struct AudioData {
    let channels: [[Float]]
    let sampleRate: Double

    var mono: [Float] {
        guard channels.count > 1 else { return channels.first ?? [] }
        let count = channels.map(\.count).min() ?? 0
        return (0..<count).map { index in
            channels.reduce(0) { $0 + $1[index] } / Float(channels.count)
        }
    }

    static func read(_ path: String) throws -> AudioData {
        let file = try AVAudioFile(forReading: URL(fileURLWithPath: path))
        let format = file.processingFormat
        let buffer = try file.readAll()
        guard let data = buffer.floatChannelData else { throw CocoaError(.fileReadCorruptFile) }
        let frames = Int(buffer.frameLength)
        let channels = (0..<Int(format.channelCount)).map { channel in
            Array(UnsafeBufferPointer(start: data[channel], count: frames))
        }
        return AudioData(channels: channels, sampleRate: format.sampleRate)
    }

    static func write(_ samples: [Float], sampleRate: Double, to url: URL) throws {
        try write(channels: [samples], sampleRate: sampleRate, to: url)
    }

    /// 24-bit PCM WAV, the format a lossless narration capture would use.
    static func write(channels: [[Float]], sampleRate: Double, to url: URL) throws {
        try? FileManager.default.removeItem(at: url)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: channels.count,
            AVLinearPCMBitDepthKey: 24,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false
        ]
        let file = try AVAudioFile(
            forWriting: url, settings: settings,
            commonFormat: .pcmFormatFloat32, interleaved: false
        )
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
}

// MARK: - Degradation building blocks

/// SplitMix64, so every run of the bank produces identical files and the
/// baseline only moves when the code does.
struct SeededRandom {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }

    /// Uniform in -1...1.
    mutating func bipolar() -> Float {
        Float(Double(next() >> 11) / Double(1 << 53) * 2 - 1)
    }

    mutating func unit() -> Double {
        Double(next() >> 11) / Double(1 << 53)
    }
}

/// RBJ Audio EQ Cookbook biquads for shaping the degraded variants. The
/// app's own Biquad is double-precision TDF2 with live coefficients.
struct ShapingBiquad {
    var b0, b1, b2, a1, a2: Double
    var z1 = 0.0
    var z2 = 0.0

    static func peaking(sampleRate: Double, frequency: Double, q: Double, gainDB: Double) -> ShapingBiquad {
        let a = pow(10, gainDB / 40)
        let w = 2 * .pi * frequency / sampleRate
        let alpha = sin(w) / (2 * q)
        let a0 = 1 + alpha / a
        return ShapingBiquad(
            b0: (1 + alpha * a) / a0, b1: -2 * cos(w) / a0, b2: (1 - alpha * a) / a0,
            a1: -2 * cos(w) / a0, a2: (1 - alpha / a) / a0
        )
    }

    static func lowShelf(sampleRate: Double, frequency: Double, gainDB: Double) -> ShapingBiquad {
        let a = pow(10, gainDB / 40)
        let w = 2 * .pi * frequency / sampleRate
        let alpha = sin(w) / 2 * sqrt(2)
        let c = cos(w)
        let s = 2 * sqrt(a) * alpha
        let a0 = (a + 1) + (a - 1) * c + s
        return ShapingBiquad(
            b0: a * ((a + 1) - (a - 1) * c + s) / a0,
            b1: 2 * a * ((a - 1) - (a + 1) * c) / a0,
            b2: a * ((a + 1) - (a - 1) * c - s) / a0,
            a1: -2 * ((a - 1) + (a + 1) * c) / a0,
            a2: ((a + 1) + (a - 1) * c - s) / a0
        )
    }

    static func bandPass(sampleRate: Double, frequency: Double, q: Double) -> ShapingBiquad {
        let w = 2 * .pi * frequency / sampleRate
        let alpha = sin(w) / (2 * q)
        let a0 = 1 + alpha
        return ShapingBiquad(b0: alpha / a0, b1: 0, b2: -alpha / a0, a1: -2 * cos(w) / a0, a2: (1 - alpha) / a0)
    }

    mutating func process(_ x: Float) -> Float {
        let input = Double(x)
        let y = b0 * input + z1
        z1 = b1 * input - a1 * y + z2
        z2 = b2 * input - a2 * y
        return Float(y)
    }

    mutating func process(_ samples: inout [Float]) {
        for index in samples.indices { samples[index] = process(samples[index]) }
    }
}

/// A small, untreated room: Schroeder combs and all-passes, about 0.45 s
/// RT60, mixed in the way a condenser half a meter away hears a desk.
struct Reverb {
    let sampleRate: Double

    func process(_ dry: [Float]) -> [Float] {
        let scale = sampleRate / 44_100
        let combDelays = [1116, 1188, 1277, 1356].map { Int(Double($0) * scale * 0.55) }
        let allPassDelays = [556, 441].map { Int(Double($0) * scale) }
        let rt60 = 0.45

        var wet = [Float](repeating: 0, count: dry.count)
        for delay in combDelays {
            let feedback = Float(pow(10, -3 * Double(delay) / sampleRate / rt60))
            var line = [Float](repeating: 0, count: delay)
            var position = 0
            var damped: Float = 0
            for index in dry.indices {
                let out = line[position]
                damped = out * 0.6 + damped * 0.4
                line[position] = dry[index] + damped * feedback
                position = (position + 1) % delay
                wet[index] += out * 0.25
            }
        }
        for delay in allPassDelays {
            var line = [Float](repeating: 0, count: delay)
            var position = 0
            for index in wet.indices {
                let buffered = line[position]
                let input = wet[index]
                line[position] = input + buffered * 0.5
                wet[index] = buffered - input * 0.5
                position = (position + 1) % delay
            }
        }
        let wetGain = Float(pow(10, -9.0 / 20))
        return zip(dry, wet).map { $0 + $1 * wetGain }
    }
}

enum Synth {
    /// Paul Kellet's refined pink filter over white noise.
    static func pinkNoise(count: Int, rmsDB: Double, random: inout SeededRandom) -> [Float] {
        var b = [Float](repeating: 0, count: 7)
        var output = [Float](repeating: 0, count: count)
        for index in 0..<count {
            let white = random.bipolar()
            b[0] = 0.99886 * b[0] + white * 0.0555179
            b[1] = 0.99332 * b[1] + white * 0.0750759
            b[2] = 0.96900 * b[2] + white * 0.1538520
            b[3] = 0.86650 * b[3] + white * 0.3104856
            b[4] = 0.55000 * b[4] + white * 0.5329522
            b[5] = -0.7616 * b[5] - white * 0.0168980
            output[index] = b[0] + b[1] + b[2] + b[3] + b[4] + b[5] + b[6] + white * 0.5362
            b[6] = white * 0.115926
        }
        let rms = sqrt(output.reduce(0) { $0 + $1 * $1 } / Float(max(1, count)))
        let gain = rms > 0 ? Float(pow(10, rmsDB / 20)) / rms : 0
        return output.map { $0 * gain }
    }

    /// 60 Hz mains hum with its first harmonics, as a USB ground loop or
    /// a nearby charger leaves it.
    static func hum(count: Int, sampleRate: Double, levelDB: Double) -> [Float] {
        let level = pow(10, levelDB / 20)
        let harmonics: [(Double, Double)] = [(60, 1), (120, 0.5), (180, 0.35), (300, 0.15)]
        return (0..<count).map { index in
            let t = Double(index) / sampleRate
            return Float(level * harmonics.reduce(0) { $0 + $1.1 * sin(2 * .pi * $1.0 * t) })
        }
    }

    /// Typing in bursts between sentences and under them: a bright click
    /// per key plus the thump the desk carries into the mic stand.
    static func keyboard(count: Int, sampleRate: Double, random: inout SeededRandom) -> [Float] {
        var output = [Float](repeating: 0, count: count)
        var time = 1.5
        let duration = Double(count) / sampleRate
        while time < duration - 1 {
            let burstEnd = time + 1.5 + random.unit() * 2
            while time < min(burstEnd, duration - 0.1) {
                let start = Int(time * sampleRate)
                let clickLength = Int(sampleRate * 0.006)
                let thumpLength = Int(sampleRate * 0.03)
                let level = Float(pow(10, (-24 - random.unit() * 6) / 20))
                var click = ShapingBiquad.bandPass(sampleRate: sampleRate, frequency: 2_800 + random.unit() * 1_500, q: 1.2)
                for offset in 0..<clickLength where start + offset < count {
                    let envelope = Float(exp(-Double(offset) / (sampleRate * 0.0012)))
                    output[start + offset] += click.process(random.bipolar()) * envelope * level * 4
                }
                for offset in 0..<thumpLength where start + offset < count {
                    let envelope = Float(exp(-Double(offset) / (sampleRate * 0.008)))
                    output[start + offset] += Float(sin(2 * .pi * 110 * Double(offset) / sampleRate)) * envelope * level * 0.6
                }
                time += 0.09 + random.unit() * 0.22
            }
            time += 3 + random.unit() * 4
        }
        return output
    }
}

extension AVAudioFile {
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
