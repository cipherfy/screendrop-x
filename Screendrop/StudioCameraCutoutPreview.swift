//
//  StudioCameraCutoutPreview.swift
//  Screendrop
//
//  The cutout on the Studio canvas. The camera player keeps playing into
//  its AVPlayerLayer; an AVPlayerItemVideoOutput hands the same frames to
//  Vision and the cutout kernel, which draw only the person - and their
//  shadow - into a Metal layer over it, off the main thread. While the
//  camera morphs to or from a cutout, the framed picture underneath fades
//  by the amount the export melts the background, so the two layers add up
//  to the export's frame.
//

import AppKit
import AVFoundation
import CoreVideo
import Metal
import QuartzCore
import SwiftUI

/// What the cutout layer draws, in the layer's own points.
nonisolated struct StudioCutoutLayerParameters: Equatable, Sendable {
    var cornerRadius: CGFloat
    /// See StudioCutoutStyle.feather(picture:canvas:).
    var feather: SIMD4<Float>
    var shadowAlpha: CGFloat
}

/// The person cut out of `player`'s camera, filling its frame the way the
/// framed camera's AVPlayerLayer aspect-fills it. `onReady` runs once the
/// first cutout frame is on screen; until then the layer is empty.
struct StudioCameraCutoutView: NSViewRepresentable {
    let player: AVPlayer
    let parameters: StudioCutoutLayerParameters
    let onReady: () -> Void

    func makeNSView(context: Context) -> StudioCameraCutoutLayerView {
        let view = StudioCameraCutoutLayerView()
        update(view)
        return view
    }

    func updateNSView(_ view: StudioCameraCutoutLayerView, context: Context) {
        update(view)
    }

    private func update(_ view: StudioCameraCutoutLayerView) {
        view.onReady = onReady
        view.parameters = parameters
        view.player = player
    }

    static func dismantleNSView(_ view: StudioCameraCutoutLayerView, coordinator: ()) {
        view.stop()
    }
}

final class StudioCameraCutoutLayerView: NSView, AVPlayerItemOutputPullDelegate {
    var player: AVPlayer? {
        didSet { if player !== oldValue { attachOutput() } }
    }
    var onReady: (() -> Void)?
    var parameters = StudioCutoutLayerParameters(cornerRadius: 0, feather: .zero, shadowAlpha: 0) {
        didSet {
            guard parameters != oldValue else { return }
            pipeline?.update(parameters)
            wake()
        }
    }

    private let metalLayer = CAMetalLayer()
    private let pipeline: StudioCameraCutoutPipeline?
    private var output: AVPlayerItemVideoOutput?
    private weak var outputItem: AVPlayerItem?
    private var displayLink: CADisplayLink?
    /// Display refreshes since the last camera frame. A paused player
    /// sends none, so the link sleeps until the output says one is coming.
    private var idleTicks = 0
    private var hasColorSpace = false

    override init(frame frameRect: NSRect) {
        let device = MTLCreateSystemDefaultDevice()
        metalLayer.device = device
        metalLayer.pixelFormat = .bgra8Unorm
        // The kernel writes the drawable directly.
        metalLayer.framebufferOnly = false
        metalLayer.isOpaque = false
        metalLayer.maximumDrawableCount = 3
        pipeline = device == nil ? nil : StudioCameraCutoutPipeline(layer: metalLayer)
        super.init(frame: frameRect)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        pipeline?.onFirstFrame = { [weak self] in
            guard let self else { return }
            Task { @MainActor in self.onReady?() }
        }
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func makeBackingLayer() -> CALayer {
        metalLayer
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        displayLink?.invalidate()
        displayLink = nil
        guard window != nil else { return }
        updateDrawableSize()
        let link = displayLink(target: self, selector: #selector(tick(_:)))
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateDrawableSize()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateDrawableSize()
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    func stop() {
        displayLink?.invalidate()
        displayLink = nil
        detachOutput()
        pipeline?.stop()
    }

    private func updateDrawableSize() {
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        metalLayer.contentsScale = scale
        pipeline?.setDrawable(
            size: CGSize(width: (bounds.width * scale).rounded(), height: (bounds.height * scale).rounded()),
            scale: scale
        )
        wake()
    }

    private func attachOutput() {
        detachOutput()
        guard let player, let item = player.currentItem else { return }
        let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferMetalCompatibilityKey as String: true,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Int]()
        ])
        output.setDelegate(self, queue: .main)
        item.add(output)
        self.output = output
        outputItem = item
        // A paused player hands a new output nothing until it decodes
        // again; seeking to where it is redelivers the frame on screen.
        if player.rate == 0 {
            player.seek(to: player.currentTime(), toleranceBefore: .zero, toleranceAfter: .zero)
        }
        wake()
    }

    private func detachOutput() {
        if let output, let outputItem {
            outputItem.remove(output)
        }
        output = nil
        outputItem = nil
    }

    private func wake() {
        idleTicks = 0
        displayLink?.isPaused = false
    }

    @objc private func tick(_ link: CADisplayLink) {
        if let player, outputItem !== player.currentItem {
            attachOutput()
        }
        guard let output, let pipeline else { return }
        // Ask for the frame due when this refresh reaches the screen; the
        // cutout lands about a refresh after the framed camera would.
        let itemTime = output.itemTime(forHostTime: link.targetTimestamp)
        if output.hasNewPixelBuffer(forItemTime: itemTime) {
            var displayTime = CMTime.invalid
            if let buffer = output.copyPixelBuffer(forItemTime: itemTime, itemTimeForDisplay: &displayTime) {
                if !hasColorSpace { adoptColorSpace(of: buffer) }
                let time = displayTime.isValid ? displayTime.seconds : itemTime.seconds
                pipeline.submit(buffer, time: time.isFinite ? time : 0)
                idleTicks = 0
                return
            }
        }
        idleTicks += 1
        if idleTicks > 30, (player?.rate ?? 0) == 0 {
            link.isPaused = true
            output.requestNotificationOfMediaDataChange(withAdvanceInterval: 0.1)
        }
    }

    nonisolated func outputMediaDataWillChange(_ sender: AVPlayerItemOutput) {
        MainActor.assumeIsolated { wake() }
    }

    /// Tags the layer with the camera's own color space, as AVPlayerLayer
    /// manages it, so the cutout matches the framed picture beneath.
    private func adoptColorSpace(of buffer: CVPixelBuffer) {
        hasColorSpace = true
        if let attachments = CVBufferCopyAttachments(buffer, .shouldPropagate),
           let space = CVImageBufferCreateColorSpaceFromAttachments(attachments)?.takeRetainedValue() {
            metalLayer.colorspace = space
        } else {
            metalLayer.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
        }
    }
}

/// Segments and draws cutout frames on its own queue. The newest camera
/// frame always wins: one that arrives while another is being segmented
/// replaces any still waiting, so the preview never falls behind.
nonisolated final class StudioCameraCutoutPipeline: @unchecked Sendable {
    /// Called on the pipeline's queue once a frame has been presented.
    var onFirstFrame: (@Sendable () -> Void)?

    private let layer: CAMetalLayer
    private let queue = DispatchQueue(label: "com.fayazahmed.Screendrop.cutout-preview", qos: .userInteractive)
    private let lock = NSLock()
    // Guarded by `lock`.
    private var pendingFrame: (buffer: CVPixelBuffer, time: TimeInterval)?
    private var parameters: StudioCutoutLayerParameters?
    private var drawableSize = CGSize.zero
    private var pixelsPerPoint: CGFloat = 2
    private var needsRedraw = false
    private var isDraining = false
    private var isStopped = false
    // The queue's alone.
    private var generator: StudioCameraMatteGenerator?
    private var renderer: StudioMorphCameraRenderer?
    private var current: (camera: CVPixelBuffer, matte: StudioCameraMatte)?
    private var hasPresented = false

    init(layer: CAMetalLayer) {
        self.layer = layer
    }

    func submit(_ buffer: CVPixelBuffer, time: TimeInterval) {
        schedule { $0.pendingFrame = (buffer, time) }
    }

    func update(_ parameters: StudioCutoutLayerParameters) {
        schedule {
            $0.parameters = parameters
            $0.needsRedraw = true
        }
    }

    func setDrawable(size: CGSize, scale: CGFloat) {
        schedule {
            guard $0.drawableSize != size || $0.pixelsPerPoint != scale else { return }
            $0.drawableSize = size
            $0.pixelsPerPoint = scale
            $0.needsRedraw = true
        }
    }

    func stop() {
        lock.withLock {
            isStopped = true
            pendingFrame = nil
        }
    }

    private func schedule(_ change: (StudioCameraCutoutPipeline) -> Void) {
        lock.lock()
        change(self)
        let starts = !isDraining && !isStopped
        if starts { isDraining = true }
        lock.unlock()
        guard starts else { return }
        queue.async { [self] in drain() }
    }

    private func drain() {
        while true {
            lock.lock()
            let frame = pendingFrame
            let redraw = needsRedraw
            let parameters = parameters
            let size = drawableSize
            let scale = pixelsPerPoint
            pendingFrame = nil
            needsRedraw = false
            guard !isStopped, frame != nil || redraw else {
                isDraining = false
                lock.unlock()
                return
            }
            lock.unlock()

            autoreleasepool {
                if let frame {
                    if generator == nil { generator = StudioCameraMatteGenerator() }
                    if let matte = generator?.matte(for: frame.buffer, time: frame.time) {
                        current = (frame.buffer, matte)
                    }
                }
                if let current, let parameters {
                    render(current.camera, matte: current.matte, parameters: parameters, size: size, scale: scale)
                }
            }
        }
    }

    private func render(
        _ camera: CVPixelBuffer, matte: StudioCameraMatte, parameters: StudioCutoutLayerParameters,
        size: CGSize, scale: CGFloat
    ) {
        guard size.width >= 1, size.height >= 1 else { return }
        if renderer == nil { renderer = StudioMorphCameraRenderer() }
        guard let renderer else { return }
        if layer.drawableSize != size { layer.drawableSize = size }
        guard let drawable = layer.nextDrawable() else { return }
        let width = CGFloat(CVPixelBufferGetWidth(camera))
        let height = CGFloat(CVPixelBufferGetHeight(camera))
        guard width > 0, height > 0 else { return }
        // Aspect-fill, as the framed camera's player layer draws it.
        let fill = max(size.width / width, size.height / height)
        let picture = CGRect(
            x: (size.width - width * fill) / 2, y: (size.height - height * fill) / 2,
            width: width * fill, height: height * fill
        )
        let presented = renderer.renderLayer(
            camera: camera,
            fillRects: [picture],
            bubble: StudioMorphCameraRenderer.Bubble(
                rect: CGRect(origin: .zero, size: size),
                cornerRadius: parameters.cornerRadius * scale,
                opacity: 1,
                borderWidth: 0,
                borderAlpha: 0,
                shadow: StudioMorphShadow(offset: 0, blur: 0, alpha: 0)
            ),
            // Only the person: the framed picture beneath supplies the
            // background while the camera is partway to a cutout.
            cutout: StudioMorphCameraRenderer.Cutout(
                matte: matte,
                amount: 1,
                feather: parameters.feather,
                picture: picture,
                shadowAlpha: parameters.shadowAlpha
            ),
            into: drawable
        )
        if presented, !hasPresented {
            hasPresented = true
            onFirstFrame?()
        }
    }
}
