// Standalone, optimized benchmark; never launches Screendrop or reads a
// user recording. Compile with the production renderer, camera scaler,
// frame caches, and renamed pre-change versions; see export-performance.md.
import AVFoundation
import CoreGraphics
import CoreVideo
import Foundation
import Metal

@main
struct ExportReuseBenchmark {
    static let space = CGColorSpace(name: CGColorSpace.sRGB)!
    static let info = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue

    static func buffer(_ width: Int, _ height: Int, seed: Int = 0) -> CVPixelBuffer {
        var value: CVPixelBuffer?
        precondition(CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA,
            [kCVPixelBufferMetalCompatibilityKey: true, kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary,
            &value) == kCVReturnSuccess)
        let buffer = value!
        CVPixelBufferLockBaseAddress(buffer, [])
        let pixels = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        for y in 0..<height {
            for x in 0..<width {
                let p = y * stride + x * 4
                pixels[p] = UInt8((x * 17 + y * 3 + seed) % 256)
                pixels[p + 1] = UInt8((x / 5 + y * 7 + seed * 9) % 256)
                pixels[p + 2] = UInt8((x * 11 + y / 3 + seed * 13) % 256)
                pixels[p + 3] = 255
            }
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        return buffer
    }

    static func context(_ buffer: CVPixelBuffer) -> CGContext {
        CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: CVPixelBufferGetWidth(buffer),
            height: CVPixelBufferGetHeight(buffer), bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: space, bitmapInfo: info)!
    }

    static func image(_ buffer: CVPixelBuffer) -> CGImage {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        return context(buffer).makeImage()!
    }

    static func pixels(_ image: CGImage) -> Data {
        let c = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
            bytesPerRow: image.width * 4, space: space, bitmapInfo: info)!
        c.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return Data(bytes: c.data!, count: image.width * image.height * 4)
    }

    static func measure(iterations: Int = 24, _ work: () -> Void) -> Double {
        for _ in 0..<3 { autoreleasepool(invoking: work) }
        let start = CFAbsoluteTimeGetCurrent()
        for _ in 0..<iterations { autoreleasepool(invoking: work) }
        return (CFAbsoluteTimeGetCurrent() - start) * 1_000 / Double(iterations)
    }

    static func main() async throws {
        let device = MTLCreateSystemDefaultDevice()!
        let library = try await device.makeLibrary(
            source: String(contentsOfFile: "Screendrop/StudioMotionBlur.metal", encoding: .utf8), options: nil)
        print("Device: \(device.name)")
        try prefilterChecks(library: library)
        cameraChecks()
        frameCacheChecks()
        for codec in [AVVideoCodecType.h264, .hevc] {
            try await repeatedBufferEncoding(codec: codec)
        }
    }

    static func prefilterChecks(library: MTLLibrary) throws {
        let size = CGSize(width: 1920, height: 1080)
        let path = CGPath(roundedRect: CGRect(x: 25, y: 25, width: 1870, height: 1030),
                          cornerWidth: 24, cornerHeight: 24, transform: nil)
        let baseline = BaselineMetalScreenRenderer(canvasSize: size, backdrop: nil,
            cardPath: path, colorSpace: space, library: library)!
        let improved = StudioMetalScreenRenderer(canvasSize: size, backdrop: nil,
            cardPath: path, colorSpace: space, library: library)!
        let source = buffer(7680, 4320)
        let changed = buffer(7680, 4320, seed: 17)
        let a = buffer(1920, 1080), b = buffer(1920, 1080)
        // Repeated source, translation-only pan, size change, changed source,
        // and returning to the original source all need exactly equal bytes.
        let scales: [CGFloat] = [1.3, 1.3, 1.35, 1.35, 1.3]
        for (index, scale) in scales.enumerated() {
            let frame = index == 3 ? changed : source
            let rects = [CGRect(x: CGFloat(-30 + index * 3), y: -10, width: size.width * scale, height: size.height * scale)]
            precondition(BaselineMetalScreenRenderer.wait(for: baseline.submit(screenFrame: frame, sampleRects: rects, into: a)!))
            precondition(StudioMetalScreenRenderer.wait(for: improved.submit(screenFrame: frame, sampleRects: rects, into: b)!))
            precondition(pixels(image(a)) == pixels(image(b)), "Prefilter reuse changed screen pixels")
        }
        let nextOutput = buffer(1920, 1080)
        for samples in [8, 24] {
            let shutter = (0..<samples).map { i in
                CGRect(x: CGFloat(-30 - i * 2), y: CGFloat(-10 - i),
                       width: size.width * 1.3, height: size.height * 1.3)
            }
            let first = improved.submit(screenFrame: source, sampleRects: shutter, into: b)!
            let next = improved.submit(screenFrame: source, sampleRects: shutter, into: nextOutput)!
            precondition(BaselineMetalScreenRenderer.wait(for: baseline.submit(screenFrame: source, sampleRects: shutter, into: a)!))
            precondition(StudioMetalScreenRenderer.wait(for: first) && StudioMetalScreenRenderer.wait(for: next))
            let expected = pixels(image(a))
            precondition(expected == pixels(image(b)) && expected == pixels(image(nextOutput)),
                         "In-flight prefilter reuse changed shutter pixels")
        }
        let rects = [CGRect(x: -30, y: -10, width: size.width * 1.3, height: size.height * 1.3)]
        let oldMS = measure { precondition(BaselineMetalScreenRenderer.wait(for: baseline.submit(screenFrame: source, sampleRects: rects, into: a)!)) }
        let newMS = measure { precondition(StudioMetalScreenRenderer.wait(for: improved.submit(screenFrame: source, sampleRects: rects, into: b)!)) }
        print(String(format: "8K source → 1080p pan: before %.3fms, after %.3fms (%.2fx). Exact pixels PASS.", oldMS, newMS, oldMS / newMS))
    }

    static func cameraChecks() {
        let size = CGSize(width: 500, height: 880)
        let baseline = BaselineCameraBubbleScaler(size: size, colorSpace: space)!
        let improved = StudioCameraBubbleScaler(size: size, colorSpace: space)!
        let sources = (0..<3).map { buffer(1920, 1080, seed: $0 * 7) }
        let rect = CGRect(x: -532.2, y: -0.7, width: 1564.4, height: 881.4)
        // Two in-flight outputs must survive later submissions unchanged.
        let first = improved.submit(sources[0], fillRect: rect)!
        let second = improved.submit(sources[1], fillRect: rect)!
        precondition(pixels(improved.image(for: first)!) == pixels(baseline.scale(sources[0], fillRect: rect)!))
        precondition(pixels(improved.image(for: second)!) == pixels(baseline.scale(sources[1], fillRect: rect)!))
        let third = improved.submit(sources[2], fillRect: rect)!
        precondition(improved.submit(sources[0], fillRect: rect) == nil, "Camera output pool exceeded its bound")
        precondition(pixels(improved.image(for: third)!) == pixels(baseline.scale(sources[2], fillRect: rect)!))
        precondition(improved.submit(sources[0], fillRect: .zero) == nil)
        print("PASS: three bounded camera outputs, overlapped completion, exact camera pixels, invalid geometry fallback.")
    }

    static func frameCacheChecks() {
        let cache = StudioComposedFrameCache<Int>()
        let source = buffer(3840, 2160)
        let target = buffer(3840, 2160)
        let screenCache = StudioScreenLayerCache()
        let rect = CGRect(x: 0, y: 0, width: 3840, height: 2160)
        CVPixelBufferLockBaseAddress(source, [])
        screenCache.capture(source: source, rect: rect, fromLocked: source)
        CVPixelBufferUnlockBaseAddress(source, [])
        cache.store(source, state: 1)
        precondition(cache.frame(matching: 1) === source)
        precondition(cache.frame(matching: 2) == nil)
        let oldMS = measure { precondition(screenCache.restore(source: source, rect: rect, into: target)) }
        let newMS = measure { precondition(cache.frame(matching: 1) === source) }
        precondition(pixels(image(target)) == pixels(image(source)))
        cache.store(target, state: 2)
        precondition(cache.frame(matching: 1) == nil && cache.frame(matching: 2) === target)
        cache.store(target, state: nil)
        precondition(cache.frame(matching: 2) == nil)
        print(String(format: "Repeated 4K composed frame: copy %.3fms → immutable reuse %.6fms. Exact pixels and invalidation PASS.", oldMS, newMS))
    }

    static func repeatedBufferEncoding(codec: AVVideoCodecType) async throws {
        let url = URL(fileURLWithPath: "/tmp/screendrop-repeated-frame-\(codec.rawValue).mov")
        try? FileManager.default.removeItem(at: url)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: codec, AVVideoWidthKey: 320, AVVideoHeightKey: 180,
            AVVideoCompressionPropertiesKey: [AVVideoExpectedSourceFrameRateKey: 60]])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: nil)
        writer.add(input)
        precondition(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        let frame = buffer(320, 180)
        let original = pixels(image(frame))
        for index in 0..<60 {
            let start = ContinuousClock.now
            while !input.isReadyForMoreMediaData {
                precondition(writer.status == .writing && start.duration(to: .now) < .seconds(10))
                try await Task.sleep(for: .milliseconds(1))
            }
            precondition(adaptor.append(frame, withPresentationTime: CMTime(value: Int64(index), timescale: 60)))
        }
        input.markAsFinished()
        await withCheckedContinuation { c in writer.finishWriting { c.resume() } }
        precondition(writer.status == .completed)
        precondition(pixels(image(frame)) == original, "Encoder modified the immutable composed frame")
        let asset = AVURLAsset(url: url)
        let track = try await asset.loadTracks(withMediaType: .video).first!
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        reader.add(output)
        precondition(reader.startReading())
        var count = 0
        while let sample = output.copyNextSampleBuffer() {
            precondition(abs(CMSampleBufferGetPresentationTimeStamp(sample).seconds - Double(count) / 60) < 0.00001)
            count += 1
        }
        let duration = try await asset.load(.duration).seconds
        precondition(count == 60 && reader.status == .completed && abs(duration - 1) < 0.00001)
        print("PASS: \(codec.rawValue) encoded all 60 immutable-buffer submissions at 60 fps, duration 1s.")
    }
}
