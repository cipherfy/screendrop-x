//
//  StudioCameraCutout.swift
//  Screendrop
//
//  The person cut out of the camera's background. Vision's person
//  segmentation turns each camera frame into a matte; the Metal kernel
//  `studioCutoutCamera` composites the camera through it, for the Studio
//  preview and the export alike, so both show the same person.
//
//  Vision's balanced quality is used throughout: about 8 ms a 1080p frame
//  on an M4 Pro, against 30 ms for accurate, whose finer matte only shows
//  when a cutout is drawn larger than the matte's 384 rows - and a cutout
//  is usually drawn smaller. The kernel tightens the matte's soft edge at
//  draw size, which is most of what accurate would add.
//
//  Vision runs its model on the Neural Engine but scales the input on the
//  GPU, where an export's screen pass is already busy; handing it a frame
//  already the model's size (scaled on the CPU, under a millisecond) takes
//  a third off each frame for a matte within half a level of full size.
//

import Accelerate
import AVFoundation
import CoreGraphics
import CoreVideo
import Foundation
import Metal
import MetalPerformanceShaders
import Vision

nonisolated enum RecordingCameraVideo {
    /// The camera movie's picture aspect, width over height, as displayed.
    static func aspect(of url: URL) async -> CGFloat? {
        guard let track = try? await AVURLAsset(url: url).loadTracks(withMediaType: .video).first,
              let (size, transform) = try? await track.load(.naturalSize, .preferredTransform)
        else { return nil }
        let displayed = size.applying(transform)
        let width = abs(displayed.width), height = abs(displayed.height)
        guard width > 0, height > 0 else { return nil }
        return width / height
    }
}

/// How a cutout looks, shared by the preview and the export.
nonisolated enum StudioCutoutStyle {
    /// How far in from the picture's edge the person fades out, where the
    /// edge stands inside the canvas: a share of the picture's width at
    /// the sides, of its height at the top and bottom.
    static let sideFeather: CGFloat = 0.1
    static let verticalFeather: CGFloat = 0.06
    /// The person's own shadow, as shares of the picture's height: a soft
    /// lift off the screen behind, like the framed camera's.
    static let shadowOffset: CGFloat = 0.012
    static let shadowSigma: CGFloat = 0.016
    static let shadowAlpha: CGFloat = 0.32

    /// The feather for a picture drawn at `picture` on `canvas`, in the
    /// kernel's (left, right, top, bottom) order. An edge the canvas crops
    /// gets none; one standing inside gets the full fade once it's in by
    /// the fade's own width, so an edge sliding in from the canvas's edge
    /// softens gradually.
    static func feather(picture: CGRect, canvas: CGSize) -> SIMD4<Float> {
        guard picture.width > 0, picture.height > 0 else { return .zero }
        func fade(inside: CGFloat, share: CGFloat, extent: CGFloat) -> Float {
            let width = share * extent
            guard width > 0 else { return 0 }
            return Float(share * min(max(inside / width, 0), 1))
        }
        return SIMD4(
            fade(inside: picture.minX, share: sideFeather, extent: picture.width),
            fade(inside: canvas.width - picture.maxX, share: sideFeather, extent: picture.width),
            fade(inside: picture.minY, share: verticalFeather, extent: picture.height),
            fade(inside: canvas.height - picture.maxY, share: verticalFeather, extent: picture.height)
        )
    }
}

/// One camera frame's person matte, and the blurred copy the person's
/// shadow is cast from: a few hundred kilobytes, against megabytes for the
/// frame itself.
nonisolated final class StudioCameraMatte: @unchecked Sendable {
    /// Vision's matte, read in place.
    let matte: MTLTexture
    let shadow: MTLTexture
    /// Keeps Vision's buffer and its texture wrapper alive.
    private let retained: (CVPixelBuffer, CVMetalTexture)

    fileprivate init(mask: CVPixelBuffer, maskTexture: CVMetalTexture, matte: MTLTexture, shadow: MTLTexture) {
        self.matte = matte
        self.shadow = shadow
        self.retained = (mask, maskTexture)
    }
}

/// Segments camera frames in order. Vision's request is stateful - it
/// steadies the matte from one frame to the next - so a single generator
/// serves one sequence on one thread at a time, and starts afresh whenever
/// the frames jump.
nonisolated final class StudioCameraMatteGenerator: @unchecked Sendable {
    let device: MTLDevice
    private let queue: MTLCommandQueue
    private let shadowPipeline: MTLComputePipelineState
    private let textureCache: CVMetalTextureCache
    private let request: VNGeneratePersonSegmentationRequest
    private var handler = VNSequenceRequestHandler()
    private var lastTime: TimeInterval?
    private var shadowSource: MTLTexture?
    private var blur: MPSImageGaussianBlur?
    private var visionInput: CVPixelBuffer?

    /// The shadow is a blur, so a small copy of the matte casts it.
    private static let shadowHeight = 192
    /// Balanced's model sees 384 rows; its matte comes back that tall.
    static let visionInputHeight = 384

    init?(device: MTLDevice? = MTLCreateSystemDefaultDevice()) {
        guard let device,
              let queue = device.makeCommandQueue(),
              let function = device.makeDefaultLibrary()?.makeFunction(name: "studioCutoutShadowSource"),
              let pipeline = try? device.makeComputePipelineState(function: function)
        else { return nil }
        var cache: CVMetalTextureCache?
        guard CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &cache) == kCVReturnSuccess,
              let cache
        else { return nil }
        self.device = device
        self.queue = queue
        self.shadowPipeline = pipeline
        self.textureCache = cache
        self.request = Self.makeRequest()
    }

    private static func makeRequest() -> VNGeneratePersonSegmentationRequest {
        let request = VNGeneratePersonSegmentationRequest()
        request.qualityLevel = .balanced
        request.outputPixelFormat = kCVPixelFormatType_OneComponent8
        return request
    }

    private static let warmup: Void = {
        // Vision loads its model on first use - a few hundred milliseconds -
        // and keeps it for the process, so a throwaway frame takes the hit
        // before anyone is waiting on a cutout.
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, 64, 64, kCVPixelFormatType_32BGRA, nil, &buffer)
        guard let buffer else { return }
        try? VNSequenceRequestHandler().perform([makeRequest()], on: buffer, orientation: .up)
    }()

    /// Loads Vision's model in the background, once per process.
    static func prewarm() {
        DispatchQueue.global(qos: .utility).async { _ = warmup }
    }

    /// Starts a new sequence: the next frame is segmented on its own.
    func reset() {
        handler = VNSequenceRequestHandler()
        lastTime = nil
    }

    /// Segments `camera` and prepares its shadow, waiting for the GPU.
    /// `time` is the frame's time in the camera recording.
    func matte(for camera: CVPixelBuffer, time: TimeInterval) -> StudioCameraMatte? {
        guard let mask = mask(for: camera, time: time) else { return nil }
        let aspect = CGFloat(CVPixelBufferGetWidth(camera)) / CGFloat(max(1, CVPixelBufferGetHeight(camera)))
        return matte(fromMask: mask, aspect: aspect)
    }

    /// Vision's matte for `camera`: one 8-bit channel, 4:3 whatever the
    /// camera's shape. A jump back, or forward past a few frames, starts a
    /// new sequence so Vision never steadies one moment's matte with
    /// another's.
    func mask(for camera: CVPixelBuffer, time: TimeInterval) -> CVPixelBuffer? {
        if let lastTime, time < lastTime - 0.001 || time - lastTime > 0.25 {
            handler = VNSequenceRequestHandler()
        }
        lastTime = time
        do {
            try handler.perform([request], on: visionFrame(for: camera) ?? camera, orientation: .up)
        } catch {
            return nil
        }
        guard let mask = request.results?.first?.pixelBuffer,
              CVPixelBufferGetPixelFormatType(mask) == kCVPixelFormatType_OneComponent8
        else { return nil }
        return mask
    }

    /// A matte from a mask - Vision's, or one read back from the matte
    /// cache, whose first plane carries it - for a picture `aspect` wide.
    func matte(fromMask mask: CVPixelBuffer, aspect: CGFloat) -> StudioCameraMatte? {
        let isPlanar = CVPixelBufferIsPlanar(mask)
        var wrapper: CVMetalTexture?
        guard CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault, textureCache, mask, nil, .r8Unorm,
            isPlanar ? CVPixelBufferGetWidthOfPlane(mask, 0) : CVPixelBufferGetWidth(mask),
            isPlanar ? CVPixelBufferGetHeightOfPlane(mask, 0) : CVPixelBufferGetHeight(mask),
            0, &wrapper
        ) == kCVReturnSuccess,
              let wrapper,
              let matte = CVMetalTextureGetTexture(wrapper)
        else { return nil }

        let height = Self.shadowHeight
        let width = min(max(Int((CGFloat(height) * aspect).rounded()), 32), 768)
        guard let source = shadowSourceTexture(width: width, height: height),
              let shadow = makeTexture(width: width, height: height, usage: [.shaderRead, .shaderWrite]),
              let blur = blurFilter(height: height),
              let command = queue.makeCommandBuffer(),
              let encoder = command.makeComputeCommandEncoder()
        else { return nil }
        encoder.setComputePipelineState(shadowPipeline)
        encoder.setTexture(matte, index: 0)
        encoder.setTexture(source, index: 1)
        let threadWidth = shadowPipeline.threadExecutionWidth
        let threadHeight = min(8, shadowPipeline.maxTotalThreadsPerThreadgroup / threadWidth)
        encoder.dispatchThreads(
            MTLSize(width: width, height: height, depth: 1),
            threadsPerThreadgroup: MTLSize(width: threadWidth, height: threadHeight, depth: 1)
        )
        encoder.endEncoding()
        blur.encode(commandBuffer: command, sourceTexture: source, destinationTexture: shadow)
        command.commit()
        command.waitUntilCompleted()
        guard command.status == .completed else { return nil }
        return StudioCameraMatte(mask: mask, maskTexture: wrapper, matte: matte, shadow: shadow)
    }

    /// `camera` scaled on the CPU to the height Vision's model works at,
    /// keeping its aspect so the matte still lines up with the frame. Nil
    /// for a camera already about that small, or one that can't be read.
    private func visionFrame(for camera: CVPixelBuffer) -> CVPixelBuffer? {
        let width = CVPixelBufferGetWidth(camera), height = CVPixelBufferGetHeight(camera)
        guard height > Self.visionInputHeight * 3 / 2,
              CVPixelBufferGetPixelFormatType(camera) == kCVPixelFormatType_32BGRA
        else { return nil }
        let scaledHeight = Self.visionInputHeight
        let scaledWidth = max(1, Int((CGFloat(width) * CGFloat(scaledHeight) / CGFloat(height)).rounded()))
        if visionInput.map({ CVPixelBufferGetWidth($0) != scaledWidth || CVPixelBufferGetHeight($0) != scaledHeight }) ?? true {
            var buffer: CVPixelBuffer?
            CVPixelBufferCreate(
                kCFAllocatorDefault, scaledWidth, scaledHeight, kCVPixelFormatType_32BGRA,
                [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary] as CFDictionary, &buffer
            )
            visionInput = buffer
        }
        guard let input = visionInput,
              CVPixelBufferLockBaseAddress(camera, .readOnly) == kCVReturnSuccess
        else { return nil }
        defer { CVPixelBufferUnlockBaseAddress(camera, .readOnly) }
        guard CVPixelBufferLockBaseAddress(input, []) == kCVReturnSuccess else { return nil }
        defer { CVPixelBufferUnlockBaseAddress(input, []) }
        var source = vImage_Buffer(
            data: CVPixelBufferGetBaseAddress(camera), height: vImagePixelCount(height),
            width: vImagePixelCount(width), rowBytes: CVPixelBufferGetBytesPerRow(camera)
        )
        var destination = vImage_Buffer(
            data: CVPixelBufferGetBaseAddress(input), height: vImagePixelCount(scaledHeight),
            width: vImagePixelCount(scaledWidth), rowBytes: CVPixelBufferGetBytesPerRow(input)
        )
        guard source.data != nil, destination.data != nil,
              vImageScale_ARGB8888(&source, &destination, nil, vImage_Flags(kvImageNoFlags)) == kvImageNoError
        else { return nil }
        return input
    }

    private func shadowSourceTexture(width: Int, height: Int) -> MTLTexture? {
        if let shadowSource, shadowSource.width == width, shadowSource.height == height { return shadowSource }
        shadowSource = makeTexture(width: width, height: height, usage: [.shaderRead, .shaderWrite])
        return shadowSource
    }

    private func blurFilter(height: Int) -> MPSImageGaussianBlur? {
        if let blur { return blur }
        let sigma = Float(StudioCutoutStyle.shadowSigma * CGFloat(height))
        let filter = MPSImageGaussianBlur(device: device, sigma: sigma)
        // Beyond the picture there's no person to cast a shadow.
        filter.edgeMode = .zero
        blur = filter
        return filter
    }

    private func makeTexture(width: Int, height: Int, usage: MTLTextureUsage) -> MTLTexture? {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .r8Unorm, width: width, height: height, mipmapped: false)
        descriptor.usage = usage
        descriptor.storageMode = .private
        return device.makeTexture(descriptor: descriptor)
    }
}

/// An export's cutout mattes, made ahead of it on their own thread: read
/// from the matte cache when it's complete, otherwise segmented from a
/// second decode of the camera movie that the decoder already scales to
/// Vision's size. Only the frames the export will show cut out are made -
/// including ahead through stretches where it isn't cut out - and only
/// their small mattes are kept, so Vision is busy for the whole export
/// instead of only while a cutout is on screen.
nonisolated final class StudioCameraMatteTrack: @unchecked Sendable {
    private let reader: AVAssetReader
    private let output: AVAssetReaderTrackOutput
    /// Non-nil when reading the cache: the camera picture's aspect, for the
    /// shadow, which the cache's 4:3 mattes don't carry.
    private let cachedAspect: CGFloat?
    private let offset: TimeInterval
    /// Sorted screen-clock times the export shows the camera cut out at.
    private let neededTimes: [TimeInterval]
    private let generator: StudioCameraMatteGenerator
    private let queue = DispatchQueue(label: "com.fayazahmed.Screendrop.cutout-matte", qos: .userInitiated)
    private let condition = NSCondition()
    // Guarded by `condition`.
    /// Oldest first.
    private var mattes: [(time: TimeInterval, matte: StudioCameraMatte)] = []
    /// The latest camera frame segmented or passed over.
    private var completedThrough = -TimeInterval.infinity
    private var isFinished = false
    private var isCancelled = false
    /// About three seconds of a 30 fps camera, at a few hundred kilobytes each.
    private static let capacity = 96

    /// `offset` and `neededTimes` are on the screen's clock, as the export's
    /// camera frame times are; nil if the camera can't be read.
    init?(url: URL, offset: TimeInterval, neededTimes: [TimeInterval]) async {
        let asset = AVURLAsset(url: url)
        guard let generator = StudioCameraMatteGenerator(),
              let track = try? await asset.loadTracks(withMediaType: .video).first,
              let size = try? await track.load(.naturalSize),
              size.width > 0, size.height > 0
        else { return nil }

        let reader: AVAssetReader
        let output: AVAssetReaderTrackOutput
        let cache = AVURLAsset(url: StudioCameraMatteCache.url(forCamera: url))
        if StudioCameraMatteCache.isComplete(forCamera: url),
           let cacheTrack = try? await cache.loadTracks(withMediaType: .video).first,
           let cacheReader = try? AVAssetReader(asset: cache) {
            reader = cacheReader
            output = AVAssetReaderTrackOutput(track: cacheTrack, outputSettings: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
                kCVPixelBufferMetalCompatibilityKey as String: true,
                kCVPixelBufferIOSurfacePropertiesKey as String: [String: Int]()
            ])
            cachedAspect = size.width / size.height
        } else {
            guard let cameraReader = try? AVAssetReader(asset: asset) else { return nil }
            reader = cameraReader
            let height = min(Int(size.height), StudioCameraMatteGenerator.visionInputHeight)
            let width = max(2, Int((size.width * CGFloat(height) / size.height).rounded()) & ~1)
            output = AVAssetReaderTrackOutput(track: track, outputSettings: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height
            ])
            cachedAspect = nil
        }
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { return nil }
        reader.add(output)
        guard reader.startReading() else { return nil }
        self.reader = reader
        self.output = output
        self.offset = offset
        self.neededTimes = neededTimes.sorted()
        self.generator = generator
        queue.async { [self] in run() }
    }

    /// The matte for the camera frame at `time`, waiting until the track
    /// has reached it. Nil if that frame wasn't segmented. Frames are asked
    /// for in time order, so everything before `time` is let go.
    func matte(at time: TimeInterval) -> StudioCameraMatte? {
        condition.lock()
        defer { condition.unlock() }
        // Before waiting too: the track may be waiting for room.
        releaseMattes(before: time)
        while completedThrough < time, !isFinished, !isCancelled {
            condition.wait()
        }
        releaseMattes(before: time)
        return mattes.first.flatMap { $0.time == time ? $0.matte : nil }
    }

    /// Call holding `condition`.
    private func releaseMattes(before time: TimeInterval) {
        let count = mattes.prefix { $0.time < time }.count
        guard count > 0 else { return }
        mattes.removeFirst(count)
        condition.broadcast()
    }

    func cancel() {
        condition.withLock {
            isCancelled = true
            condition.broadcast()
        }
        reader.cancelReading()
    }

    private func run() {
        defer {
            condition.withLock {
                isFinished = true
                condition.broadcast()
            }
        }
        var neededIndex = 0
        var frame = nextFrame()
        var isFirst = true
        while let current = frame {
            if condition.withLock({ isCancelled }) { return }
            let next = nextFrame()
            // The export shows this frame from its own time until the next
            // one's - and the very first from the start, before it arrives.
            let start = isFirst ? -TimeInterval.infinity : current.time
            let end = next?.time ?? .infinity
            while neededIndex < neededTimes.count, neededTimes[neededIndex] < start { neededIndex += 1 }
            let isNeeded = neededIndex < neededTimes.count && neededTimes[neededIndex] < end
            while neededIndex < neededTimes.count, neededTimes[neededIndex] < end { neededIndex += 1 }

            if isNeeded {
                condition.lock()
                while mattes.count >= Self.capacity, !isCancelled { condition.wait() }
                condition.unlock()
                let matte = autoreleasepool {
                    if let cachedAspect {
                        generator.matte(fromMask: current.buffer, aspect: cachedAspect)
                    } else {
                        generator.matte(for: current.buffer, time: current.time)
                    }
                }
                if let matte {
                    condition.withLock { mattes.append((current.time, matte)) }
                }
            }
            condition.withLock {
                completedThrough = current.time
                condition.broadcast()
            }
            isFirst = false
            frame = next
            if neededIndex >= neededTimes.count, frame != nil {
                // Nothing further is shown cut out.
                return
            }
        }
    }

    private func nextFrame() -> (buffer: CVPixelBuffer, time: TimeInterval)? {
        while let sample = output.copyNextSampleBuffer() {
            guard let buffer = CMSampleBufferGetImageBuffer(sample) else { continue }
            return (buffer, CMSampleBufferGetPresentationTimeStamp(sample).seconds + offset)
        }
        return nil
    }
}
