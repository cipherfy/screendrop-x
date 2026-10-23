//
//  RecordingRedaction.swift
//  Screendrop
//
//  Pixelated or blurred regions of a Studio recording, for hiding something
//  private. A region is pinned to the recorded picture rather than the
//  canvas: it is applied to the source frame before anything else, so it
//  follows the picture through padding, crops, zooms and layout morphs, and
//  it lives on the recording's clock so cuts never slide it off what it
//  hides.
//
//  One Core Image routine filters the frame for both the live preview (an
//  AVVideoComposition on the screen player) and the exporter.
//

import AVFoundation
import CoreImage
import CoreImage.CIFilterBuiltins
import CoreVideo
import Foundation

nonisolated struct RecordingRedaction: Identifiable, Codable, Equatable, Hashable, Sendable {
    enum Style: String, Codable, CaseIterable, Identifiable, Sendable {
        case pixelate
        case blur

        var id: String { rawValue }

        var title: String {
            switch self {
            case .pixelate: "Pixelate"
            case .blur: "Blur"
            }
        }

        var systemImage: String {
            switch self {
            case .pixelate: "squareshape.split.3x3"
            case .blur: "drop.halffull"
            }
        }
    }

    static let minimumDuration: TimeInterval = 0.1
    static let defaultDuration: TimeInterval = 3
    /// Smallest region side, as a fraction of the picture.
    static let minimumSide: CGFloat = 0.02
    static let cornerRadiusRange: ClosedRange<Double> = 0...100
    static let fadeRange: ClosedRange<TimeInterval> = 0...2

    var id = UUID()
    /// Recording (source) time.
    var start: TimeInterval
    var end: TimeInterval
    /// The region of the recorded picture, normalized with a top-left
    /// origin.
    var rect = CGRect(x: 0.35, y: 0.4, width: 0.3, height: 0.2)
    var style: Style = .pixelate
    /// Strength, 0...1.
    var amount: Double = 0.6
    /// Corner radius in pixels of a 1080p picture.
    var cornerRadius: Double = 12
    var fadeIn: TimeInterval = 0
    var fadeOut: TimeInterval = 0

    var duration: TimeInterval { end - start }

    init(start: TimeInterval, end: TimeInterval) {
        self.start = start
        self.end = end
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        start = try container.decode(TimeInterval.self, forKey: .start)
        end = try container.decode(TimeInterval.self, forKey: .end)
        rect = try container.decodeIfPresent(CGRect.self, forKey: .rect) ?? rect
        style = try container.decodeIfPresent(Style.self, forKey: .style) ?? .pixelate
        amount = try container.decodeIfPresent(Double.self, forKey: .amount) ?? 0.6
        cornerRadius = try container.decodeIfPresent(Double.self, forKey: .cornerRadius) ?? 12
        fadeIn = try container.decodeIfPresent(TimeInterval.self, forKey: .fadeIn) ?? 0
        fadeOut = try container.decodeIfPresent(TimeInterval.self, forKey: .fadeOut) ?? 0
    }

    /// How strongly the region shows at a source time: 0 outside it, ramping
    /// through its fades.
    func opacity(atSourceTime time: TimeInterval) -> Double {
        guard time >= start, time < end else { return 0 }
        let local = time - start
        var value = 1.0
        if fadeIn > 0, local < fadeIn { value = min(value, local / fadeIn) }
        if fadeOut > 0, local > duration - fadeOut { value = min(value, (duration - local) / fadeOut) }
        return min(max(value, 0), 1)
    }

    /// Keeps the region inside the picture and no smaller than the minimum.
    static func clamped(_ rect: CGRect) -> CGRect {
        let width = min(max(rect.width, minimumSide), 1)
        let height = min(max(rect.height, minimumSide), 1)
        return CGRect(
            x: min(max(rect.minX, 0), 1 - width),
            y: min(max(rect.minY, 0), 1 - height),
            width: width,
            height: height
        )
    }
}

// MARK: - Rendering

nonisolated enum RecordingRedactionRenderer {
    /// What a frame shows at a moment: each active region and its fade.
    /// Equal states over the same source frame render the same pixels.
    struct State: Equatable {
        var regions: [RecordingRedaction] = []
        var opacities: [Double] = []

        var isEmpty: Bool { regions.isEmpty }
    }

    static func state(for redactions: [RecordingRedaction], atSourceTime time: TimeInterval) -> State {
        var state = State()
        for redaction in redactions {
            let opacity = redaction.opacity(atSourceTime: time)
            guard opacity > 0.001 else { continue }
            state.regions.append(redaction)
            state.opacities.append(opacity)
        }
        return state
    }

    /// Filters `image`, a whole source frame with its origin at zero, through
    /// every region in `state`.
    static func apply(_ state: State, to image: CIImage) -> CIImage {
        guard !state.isEmpty else { return image }
        let extent = image.extent
        guard extent.width > 1, extent.height > 1 else { return image }
        // Strengths are measured on a 1080p picture, so a region reads the
        // same at any recording size.
        let unit = min(extent.width, extent.height) / 1080
        let clamped = image.clampedToExtent()
        var output = image

        for (redaction, opacity) in zip(state.regions, state.opacities) {
            let rect = RecordingRedaction.clamped(redaction.rect)
            // Core Image's origin is the bottom-left corner.
            let region = CGRect(
                x: extent.minX + rect.minX * extent.width,
                y: extent.minY + (1 - rect.maxY) * extent.height,
                width: rect.width * extent.width,
                height: rect.height * extent.height
            ).integral.intersection(extent)
            guard region.width >= 1, region.height >= 1 else { continue }
            let strength = CGFloat(min(max(redaction.amount, 0), 1))

            let filtered: CIImage
            switch redaction.style {
            case .pixelate:
                let pixellate = CIFilter.pixellate()
                pixellate.inputImage = clamped
                pixellate.center = CGPoint(x: region.minX, y: region.minY)
                pixellate.scale = Float(max(2, (4 + 56 * strength) * unit))
                guard let result = pixellate.outputImage else { continue }
                filtered = result
            case .blur:
                let blur = CIFilter.gaussianBlur()
                blur.inputImage = clamped
                blur.radius = Float((4 + 46 * strength) * unit)
                guard let result = blur.outputImage else { continue }
                filtered = result
            }

            let mask = CIFilter.roundedRectangleGenerator()
            mask.extent = region
            mask.radius = Float(min(CGFloat(redaction.cornerRadius) * unit, region.width / 2, region.height / 2))
            let level = CGFloat(opacity)
            mask.color = CIColor(red: level, green: level, blue: level, alpha: 1)
            guard let maskImage = mask.outputImage else { continue }

            let blend = CIFilter.blendWithMask()
            blend.inputImage = filtered.cropped(to: region)
            blend.backgroundImage = output
            blend.maskImage = maskImage
            output = blend.outputImage?.cropped(to: extent) ?? output
        }
        return output
    }
}

// MARK: - Preview

/// The regions the live preview filters through, read by the player's
/// composition on its own thread. Edits write a new snapshot; the paused
/// frame is re-rendered by the model.
nonisolated final class RecordingRedactionPreviewSource: @unchecked Sendable {
    private let lock = NSLock()
    private var redactions: [RecordingRedaction] = []
    private var clipTimeline = RecordingClipTimeline(segments: [])

    func update(redactions: [RecordingRedaction], clipTimeline: RecordingClipTimeline) {
        lock.withLock {
            self.redactions = redactions
            self.clipTimeline = clipTimeline
        }
    }

    func state(atEditorTime time: TimeInterval) -> RecordingRedactionRenderer.State {
        let (redactions, clipTimeline) = lock.withLock { (self.redactions, self.clipTimeline) }
        guard !redactions.isEmpty else { return RecordingRedactionRenderer.State() }
        return RecordingRedactionRenderer.state(
            for: redactions,
            atSourceTime: clipTimeline.sourceTime(at: time)
        )
    }

    /// A composition that filters every frame the player shows. The
    /// composition's clock is editor time, which the source maps back to the
    /// recording's.
    func makeVideoComposition(for asset: AVAsset) -> AVVideoComposition {
        let composition = AVMutableVideoComposition(asset: asset) { [self] request in
            let state = state(atEditorTime: request.compositionTime.seconds)
            let image = request.sourceImage
            let origin = image.extent.origin
            // Filter in a zero-origin frame, the same space the exporter uses.
            let normalized = image.transformed(by: CGAffineTransform(translationX: -origin.x, y: -origin.y))
            let filtered = RecordingRedactionRenderer.apply(state, to: normalized)
                .transformed(by: CGAffineTransform(translationX: origin.x, y: origin.y))
            request.finish(with: filtered, context: nil)
        }
        // Screen captures only hold frames where pixels changed. Rendering
        // on a fixed clock instead of the source's frames lets a region
        // start or fade over a held frame, as it does in the export.
        composition.frameDuration = CMTime(value: 1, timescale: 60)
        composition.sourceTrackIDForFrameTiming = kCMPersistentTrackID_Invalid
        return composition
    }
}

// MARK: - Export

/// Filters the exporter's decoded screen frames. A held frame whose regions
/// are unchanged gets the same output buffer back, so the exporter's
/// identity-keyed screen and frame caches keep working through it.
nonisolated final class RecordingRedactionFrameFilter: @unchecked Sendable {
    private let redactions: [RecordingRedaction]
    private let context: CIContext
    private var pool: CVPixelBufferPool?
    private var poolSize: (width: Int, height: Int)?
    private var lastInput: CVPixelBuffer?
    private var lastState = RecordingRedactionRenderer.State()
    private var lastOutput: CVPixelBuffer?

    init?(redactions: [RecordingRedaction]) {
        guard !redactions.isEmpty else { return nil }
        self.redactions = redactions
        context = CIContext(options: [
            .cacheIntermediates: false,
            .workingColorSpace: CGColorSpace(name: CGColorSpace.sRGB) as Any
        ])
    }

    func apply(to buffer: CVPixelBuffer, atSourceTime time: TimeInterval) -> CVPixelBuffer {
        let state = RecordingRedactionRenderer.state(for: redactions, atSourceTime: time)
        guard !state.isEmpty else { return buffer }
        if let lastInput, lastInput === buffer, state == lastState, let lastOutput {
            return lastOutput
        }
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        guard let output = makeBuffer(width: width, height: height) else { return buffer }

        let image = CIImage(cvPixelBuffer: buffer)
        let filtered = RecordingRedactionRenderer.apply(state, to: image)
        let destination = CIRenderDestination(pixelBuffer: output)
        destination.colorSpace = CVImageBufferGetColorSpace(buffer)?.takeUnretainedValue()
            ?? CGColorSpace(name: CGColorSpace.sRGB)
        do {
            // Metal reads this buffer next, so the render must be complete.
            try context.startTask(toRender: filtered, to: destination).waitUntilCompleted()
        } catch {
            return buffer
        }
        CVBufferPropagateAttachments(buffer, output)
        lastInput = buffer
        lastState = state
        lastOutput = output
        return output
    }

    private func makeBuffer(width: Int, height: Int) -> CVPixelBuffer? {
        if pool == nil || poolSize?.width != width || poolSize?.height != height {
            let attributes: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
                kCVPixelBufferMetalCompatibilityKey as String: true,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:]
            ]
            var created: CVPixelBufferPool?
            CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, attributes as CFDictionary, &created)
            pool = created
            poolSize = (width, height)
        }
        guard let pool else { return nil }
        var buffer: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &buffer) == kCVReturnSuccess else {
            return nil
        }
        return buffer
    }
}
