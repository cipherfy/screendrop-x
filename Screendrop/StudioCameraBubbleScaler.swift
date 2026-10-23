import CoreGraphics
import CoreVideo
import Metal
import MetalPerformanceShaders

/// Aspect-fills camera frames into the bubble's pixel box on the GPU. Core
/// Graphics' high-quality resample of a full camera frame was most of an
/// export's CPU time once the screen moved to Metal; Lanczos here matches
/// its quality and leaves the CPU only a 1:1 clipped draw. Submissions run
/// serially on one GPU queue; distinct pooled outputs allow the next frame's
/// scale to overlap the previous frame's CPU overlays.
nonisolated final class StudioCameraBubbleScaler {
    private let queue: MTLCommandQueue
    private let textureCache: CVMetalTextureCache
    private let scaler: MPSImageLanczosScale
    private let outputPool: CVPixelBufferPool
    private let colorSpace: CGColorSpace

    init?(size: CGSize, colorSpace: CGColorSpace) {
        let width = Int(size.width)
        let height = Int(size.height)
        var outputPool: CVPixelBufferPool?
        var cache: CVMetalTextureCache?
        guard width > 0, height > 0,
              let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue(),
              CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &cache) == kCVReturnSuccess,
              let cache,
              CVPixelBufferPoolCreate(
                  kCFAllocatorDefault, nil,
                  [
                      kCVPixelBufferWidthKey: width,
                      kCVPixelBufferHeightKey: height,
                      kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
                      kCVPixelBufferMetalCompatibilityKey: true,
                      kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary
                  ] as CFDictionary,
                  &outputPool
              ) == kCVReturnSuccess,
              let outputPool
        else { return nil }
        self.queue = queue
        self.textureCache = cache
        self.scaler = MPSImageLanczosScale(device: device)
        self.outputPool = outputPool
        self.colorSpace = colorSpace
    }

    /// `fillRect` is where the whole camera frame lands, in top-left pixels
    /// relative to the output box; whatever falls outside is cropped.
    /// Returns nil if the frame can't go through Metal. A submission owns
    /// its output until the caller has taken its immutable image snapshot.
    struct Submission {
        fileprivate let command: MTLCommandBuffer
        fileprivate let textures: [CVMetalTexture]
        fileprivate let output: CVPixelBuffer
    }

    func submit(_ camera: CVPixelBuffer, fillRect: CGRect) -> Submission? {
        guard fillRect.width > 0, fillRect.height > 0,
              fillRect.minX.isFinite, fillRect.minY.isFinite,
              fillRect.width.isFinite, fillRect.height.isFinite else { return nil }
        var outputBuffer: CVPixelBuffer?
        // Two begun frames plus one retained scale for a repeated camera
        // frame. Failure uses the existing Core Graphics fallback.
        guard CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(
            kCFAllocatorDefault, outputPool,
            [kCVPixelBufferPoolAllocationThresholdKey: 3] as CFDictionary,
            &outputBuffer) == kCVReturnSuccess,
              let output = outputBuffer,
              let source = texture(for: camera, usage: .shaderRead),
              let destination = texture(for: output, usage: .shaderWrite),
              let sourceTexture = CVMetalTextureGetTexture(source),
              let destinationTexture = CVMetalTextureGetTexture(destination),
              let command = queue.makeCommandBuffer()
        else { return nil }
        var transform = MPSScaleTransform(
            scaleX: Double(fillRect.width) / Double(sourceTexture.width),
            scaleY: Double(fillRect.height) / Double(sourceTexture.height),
            translateX: Double(fillRect.minX),
            translateY: Double(fillRect.minY)
        )
        withUnsafePointer(to: &transform) { pointer in
            scaler.scaleTransform = pointer
            scaler.encode(commandBuffer: command, sourceTexture: sourceTexture, destinationTexture: destinationTexture)
            scaler.scaleTransform = nil
        }
        command.commit()
        return Submission(command: command, textures: [source, destination], output: output)
    }

    func image(for submission: Submission) -> CGImage? {
        withExtendedLifetime(submission.textures) { submission.command.waitUntilCompleted() }
        guard submission.command.status == .completed else { return nil }
        let output = submission.output
        CVPixelBufferLockBaseAddress(output, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(output, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(output),
              let context = CGContext(
                data: base,
                width: CVPixelBufferGetWidth(output),
                height: CVPixelBufferGetHeight(output),
                bitsPerComponent: 8,
                bytesPerRow: CVPixelBufferGetBytesPerRow(output),
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
              ) else { return nil }
        // Copies: the pooled output may serve a later camera frame.
        return context.makeImage()
    }

    private func texture(for buffer: CVPixelBuffer, usage: MTLTextureUsage) -> CVMetalTexture? {
        guard CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_32BGRA else { return nil }
        var texture: CVMetalTexture?
        let attributes = [kCVMetalTextureUsage: usage.rawValue] as CFDictionary
        guard CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault, textureCache, buffer, attributes, .bgra8Unorm,
            CVPixelBufferGetWidth(buffer), CVPixelBufferGetHeight(buffer), 0, &texture
        ) == kCVReturnSuccess else { return nil }
        return texture
    }
}
