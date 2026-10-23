import CoreGraphics
import CoreVideo
import Metal
import MetalPerformanceShaders

/// Export-local GPU resources. One command buffer evaluates the complete
/// shutter; no full-resolution intermediate image is allocated per sample.
/// The caller may keep one frame in flight - submitting the next frame's
/// pass while it draws the previous frame's overlays - and must wait on each
/// submission before touching that frame's pixels on the CPU.
nonisolated final class StudioMetalScreenRenderer {
    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let pipeline: MTLComputePipelineState
    /// For frames inside a layout morph; nil if the shader is missing.
    private let morphPipeline: MTLComputePipelineState?
    private let textureCache: CVMetalTextureCache
    private let backdropTexture: MTLTexture
    private let clipTexture: MTLTexture
    private let downsampler: MPSImageLanczosScale
    private var downsampledTexture: MTLTexture?
    /// The prefilter is independent of the viewport's translation. Queue
    /// ordering makes it safe to reuse even before its first pass completes.
    /// Retain the source so decoder-pool recycling cannot create a false hit.
    private var downsampledSource: CVPixelBuffer?
    private let colorSpace: CGColorSpace

    init?(
        canvasSize: CGSize, backdrop: CGImage?, cardPath: CGPath,
        colorSpace: CGColorSpace, library: MTLLibrary? = nil
    ) {
        guard let device = library?.device ?? MTLCreateSystemDefaultDevice(),
            let queue = device.makeCommandQueue(),
            let library = library ?? device.makeDefaultLibrary(),
            let function = library.makeFunction(name: "studioMotionBlur"),
            let pipeline = try? device.makeComputePipelineState(function: function)
        else { return nil }
        var cache: CVMetalTextureCache?
        guard CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &cache) == kCVReturnSuccess,
            let cache
        else { return nil }
        let width = Int(canvasSize.width)
        let height = Int(canvasSize.height)
        guard
            let backdropTexture = Self.makeTexture(
                device: device, width: width, height: height,
                colorSpace: colorSpace,
                draw: { context in
                    let bounds = CGRect(origin: .zero, size: canvasSize)
                    if let backdrop {
                        context.draw(backdrop, in: bounds)
                    } else {
                        context.setFillColor(CGColor(gray: 0, alpha: 1))
                        context.fill(bounds)
                    }
                }),
            let clipTexture = Self.makeTexture(
                device: device, width: width, height: height,
                colorSpace: colorSpace,
                draw: { context in
                    context.setFillColor(CGColor(gray: 1, alpha: 1))
                    context.addPath(cardPath)
                    context.fillPath()
                })
        else { return nil }
        self.device = device
        self.queue = queue
        self.pipeline = pipeline
        self.morphPipeline = library.makeFunction(name: "studioMorphScreen")
            .flatMap { try? device.makeComputePipelineState(function: $0) }
        self.textureCache = cache
        self.backdropTexture = backdropTexture
        self.clipTexture = clipTexture
        self.downsampler = MPSImageLanczosScale(device: device)
        self.downsampler.edgeMode = .clamp
        self.colorSpace = colorSpace
    }

    /// A committed pass. It retains the Core Video texture wrappers, whose
    /// textures alone do not keep their backing allocations alive.
    struct Submission {
        fileprivate let command: MTLCommandBuffer
        fileprivate let textures: [CVMetalTexture]
    }

    /// The card of a frame inside a layout morph, in top-left canvas
    /// pixels. Its clip and shadow are computed from this shape on the GPU,
    /// over the renderer's backdrop, which should be the plain background.
    struct MorphCard {
        var rect: CGRect
        var cornerRadius: CGFloat
        /// The screen's coverage, for a card fading in or out.
        var opacity: CGFloat
        var shadow: StudioMorphShadow?
    }

    /// Rectangles use the same top-left canvas coordinates as StudioLayout.
    /// Returns nil, without encoding anything, if Metal cannot take a frame.
    /// Commands on one queue run in order, so the shared downsample texture
    /// is never overwritten while an earlier pass still reads it.
    func submit(screenFrame: CVPixelBuffer, sampleRects: [CGRect], into destination: CVPixelBuffer) -> Submission? {
        submit(screenFrame: screenFrame, sampleRects: sampleRects, morph: nil, into: destination)
    }

    /// A frame inside a layout morph: unlike `redraw`, nothing is drawn on
    /// the CPU or uploaded, so passes can follow each other on one renderer.
    func submitMorph(
        screenFrame: CVPixelBuffer, sampleRects: [CGRect], card: MorphCard, into destination: CVPixelBuffer
    ) -> Submission? {
        guard morphPipeline != nil else { return nil }
        return submit(screenFrame: screenFrame, sampleRects: sampleRects, morph: card, into: destination)
    }

    private func submit(
        screenFrame: CVPixelBuffer, sampleRects: [CGRect], morph: MorphCard?, into destination: CVPixelBuffer
    ) -> Submission? {
        guard (1...24).contains(sampleRects.count),
            sampleRects.allSatisfy({
                $0.width > 0 && $0.height > 0 && $0.minX.isFinite && $0.minY.isFinite && $0.width.isFinite
                    && $0.height.isFinite
            }),
            let source = texture(for: screenFrame, usage: .shaderRead),
            let output = texture(for: destination, usage: .shaderWrite),
            let sourceTexture = CVMetalTextureGetTexture(source),
            let outputTexture = CVMetalTextureGetTexture(output),
            outputTexture.width == backdropTexture.width,
            outputTexture.height == backdropTexture.height,
            let command = queue.makeCommandBuffer()
        else { return nil }

        // Bound the per-pixel filter footprint for very large reductions.
        // Leave up to 2x resolution for the shutter's scale-aware Lanczos
        // reconstruction, rather than reducing straight to output size.
        var sampledTexture = sourceTexture
        let scaledWidth = Int(min(CGFloat(sourceTexture.width), ceil(sampleRects.map(\.width).max()! * 2)))
        let scaledHeight = Int(min(CGFloat(sourceTexture.height), ceil(sampleRects.map(\.height).max()! * 2)))
        if scaledWidth < sourceTexture.width || scaledHeight < sourceTexture.height {
            if downsampledTexture?.width != scaledWidth || downsampledTexture?.height != scaledHeight {
                let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                    pixelFormat: .bgra8Unorm,
                    width: scaledWidth, height: scaledHeight, mipmapped: false)
                descriptor.usage = [.shaderRead, .shaderWrite]
                descriptor.storageMode = .private
                downsampledTexture = device.makeTexture(descriptor: descriptor)
                downsampledSource = nil
            }
            guard let downsampledTexture else { return nil }
            if downsampledSource !== screenFrame {
                downsampler.encode(
                    commandBuffer: command, sourceTexture: sourceTexture,
                    destinationTexture: downsampledTexture)
            }
            sampledTexture = downsampledTexture
        }
        // shouldAccelerate screens these out first; this only guards callers
        // that skip it.
        guard
            sampleRects.allSatisfy({
                $0.width * 4 >= CGFloat(sampledTexture.width) && $0.height * 4 >= CGFloat(sampledTexture.height)
            })
        else { return nil }
        guard let encoder = command.makeComputeCommandEncoder() else { return nil }

        var count = UInt32(sampleRects.count)
        let rects = sampleRects.map { SIMD4<Float>(Float($0.minX), Float($0.minY), Float($0.width), Float($0.height)) }
        let pipeline: MTLComputePipelineState
        encoder.setTexture(sampledTexture, index: 0)
        encoder.setTexture(backdropTexture, index: 1)
        if let morph, let morphPipeline {
            pipeline = morphPipeline
            encoder.setTexture(outputTexture, index: 2)
            let shape: [SIMD4<Float>] = [
                SIMD4(Float(morph.rect.minX), Float(morph.rect.minY), Float(morph.rect.width), Float(morph.rect.height)),
                SIMD4(Float(morph.cornerRadius), Float(morph.opacity), 0, 0),
                morph.shadow?.parameters ?? .zero
            ]
            shape.withUnsafeBytes { bytes in
                encoder.setBytes(bytes.baseAddress!, length: bytes.count, index: 2)
            }
        } else {
            pipeline = self.pipeline
            encoder.setTexture(clipTexture, index: 2)
            encoder.setTexture(outputTexture, index: 3)
        }
        encoder.setComputePipelineState(pipeline)
        rects.withUnsafeBytes { bytes in
            encoder.setBytes(bytes.baseAddress!, length: bytes.count, index: 0)
        }
        encoder.setBytes(&count, length: MemoryLayout<UInt32>.size, index: 1)
        let width = pipeline.threadExecutionWidth
        let height = min(8, pipeline.maxTotalThreadsPerThreadgroup / width)
        encoder.dispatchThreads(
            MTLSize(width: outputTexture.width, height: outputTexture.height, depth: 1),
            threadsPerThreadgroup: MTLSize(width: width, height: height, depth: 1))
        encoder.endEncoding()
        command.commit()
        // Set only after committing: a failed submission must not make a
        // later frame skip a prefilter that never ran.
        downsampledSource = sampledTexture === downsampledTexture ? screenFrame : nil
        return Submission(command: command, textures: [source, output])
    }

    /// Blocks until the pass finishes. False means the frame has no screen
    /// layer and must be drawn another way.
    static func wait(for submission: Submission) -> Bool {
        withExtendedLifetime(submission.textures) { submission.command.waitUntilCompleted() }
        return submission.command.status == .completed
    }

    /// Every frame - settled or blurred - renders on the GPU, so an export
    /// never alternates between two reconstruction filters. The one
    /// exception is an extreme discontinuity inside a shutter, where one
    /// rect is far smaller than the texture the others share; Core Graphics
    /// draws that frame. This is a per-frame fallback, not a GPU failure.
    static func shouldAccelerate(screenFrame: CVPixelBuffer, sampleRects: [CGRect]) -> Bool {
        guard let widest = sampleRects.map(\.width).max(),
              let tallest = sampleRects.map(\.height).max() else { return false }
        // Mirrors the downsample bound in render(screenFrame:sampleRects:into:).
        let sampledWidth = min(CGFloat(CVPixelBufferGetWidth(screenFrame)), ceil(widest * 2))
        let sampledHeight = min(CGFloat(CVPixelBufferGetHeight(screenFrame)), ceil(tallest * 2))
        return sampleRects.allSatisfy {
            $0.width * 4 >= sampledWidth && $0.height * 4 >= sampledHeight
        }
    }

    private func texture(for buffer: CVPixelBuffer, usage: MTLTextureUsage) -> CVMetalTexture? {
        guard CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_32BGRA else { return nil }
        var texture: CVMetalTexture?
        let attributes = [kCVMetalTextureUsage: usage.rawValue] as CFDictionary
        guard
            CVMetalTextureCacheCreateTextureFromImage(
                kCFAllocatorDefault, textureCache, buffer,
                attributes, .bgra8Unorm, CVPixelBufferGetWidth(buffer), CVPixelBufferGetHeight(buffer), 0,
                &texture) == kCVReturnSuccess
        else { return nil }
        return texture
    }

    private static func makeTexture(
        device: MTLDevice, width: Int, height: Int,
        colorSpace: CGColorSpace, draw: (CGContext) -> Void
    ) -> MTLTexture? {
        guard
            let context = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
            let pixels = context.data
        else { return nil }
        draw(context)
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: width, height: height, mipmapped: false)
        descriptor.usage = .shaderRead
        descriptor.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }
        texture.replace(
            region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0,
            withBytes: pixels, bytesPerRow: context.bytesPerRow)
        return texture
    }
}

/// A black shadow as Core Graphics casts it, for the morph shaders to
/// compute from a shape: offset downwards and blurred, in canvas pixels.
nonisolated struct StudioMorphShadow {
    var offset: CGFloat
    var blur: CGFloat
    var alpha: CGFloat

    /// Core Graphics' blur measures as a Gaussian with sigma = blur / 2,
    /// cut off at 1.05 x blur; this matches it within 2/255 at full alpha
    /// for the blurs exports use.
    var parameters: SIMD4<Float> {
        let blur = max(blur, 0.5)
        return SIMD4(Float(offset), Float(blur * 0.5), Float(blur * 1.05), Float(alpha))
    }
}
