// Run: python3 scripts/check-studio-camera-motion.py
// Compiles the production geometry and motion types without launching Screendrop.
import Foundation
import CoreGraphics

@main
struct MotionChecks {
    static var count = 0
    static func check(_ value: Bool, _ message: String) {
        count += 1
        precondition(value, message)
    }
    static func near(_ actual: CGFloat, _ expected: CGFloat, _ message: String, tolerance: CGFloat = 0.02) {
        check(actual.isFinite && abs(actual - expected) <= tolerance, "\(message): \(actual) vs \(expected)")
    }
    static func base(canvas: CGSize, crop: CGRect, mode: RecordingStudioLayout.ContentMode,
                     sourceAspect: CGFloat = 16 / 9) -> RecordingStudioLayout {
        RecordingStudioLayout.make(canvasSize: canvas, style: RecordingStudioStyle(), contentAspect: sourceAspect,
                                  contentMode: mode, contentCropRect: crop)
    }
    static func track(canvas: CGSize, crop: CGRect = RecordingVideoCropGeometry.unit,
                      mode: RecordingStudioLayout.ContentMode = .fill,
                      camera: Bool = true, layout: RecordingCameraLayout,
                      cues: [ZoomCue], capture: PointerCaptureFile = PointerCaptureFile(),
                      clips: RecordingClipTimeline = .legacyTrim(start: nil, end: nil, sourceDuration: 10),
                      layoutCues: [RecordingCameraLayoutCue] = [], sourceAspect: CGFloat = 16 / 9) -> RecordingStudioMotionTimeline {
        RecordingStudioMotionTimeline.build(canvasSize: canvas, style: RecordingStudioStyle(), usesUniformPadding: false,
                                        contentAspect: sourceAspect, contentMode: mode, contentCropRect: crop,
                                        showsCamera: camera,
                                        layoutTimeline: .build(defaultLayout: layout, cues: layoutCues, clipTimeline: clips),
                                        cues: cues, capture: capture, clipTimeline: clips)
    }
    static func edgeFramingChecks() {
        let sourceAspect: CGFloat = 3456 / 2234
        let crops = [RecordingVideoCropGeometry.unit, CGRect(x: 0.15, y: 0.1, width: 0.65, height: 0.7)]
        let canvases = [CGSize(width: 3456, height: 2234), CGSize(width: 1080, height: 1920)]
        let layouts = [RecordingCameraLayout(kind: .split),
                       RecordingCameraLayout(kind: .split, side: .leading),
                       RecordingCameraLayout(kind: .pictureInPicture, corner: .topLeading),
                       RecordingCameraLayout.screenOnly]
        let points = [CGPoint(x: 0.05299207899305555, y: 0.015040985899731423),
                      CGPoint(x: 0.985, y: 0.015), CGPoint(x: 0.015, y: 0.985), CGPoint(x: 0.985, y: 0.985),
                      CGPoint(x: 0.015, y: 0.5), CGPoint(x: 0.985, y: 0.5),
                      CGPoint(x: 0.5, y: 0.015), CGPoint(x: 0.5, y: 0.985)]
        let cases = points.flatMap { point in [0.0, 0.25, 1.0].map { (point, $0) } }
        for canvas in canvases {
            for crop in crops {
                for cameraLayout in layouts {
                    for (relative, bias) in cases {
                        let point = CGPoint(x: crop.minX + relative.x * crop.width,
                                            y: crop.minY + relative.y * crop.height)
                        let zoom = ZoomCue(start: 2, end: 8, zoom: 1.5, pinnedPoint: point, boundsBias: bias)
                        var input = PointerCaptureFile()
                        input.travel = [PointerTravelSample(time: 0, x: point.x, y: point.y)]
                        input.presses = [PointerPressEvent(time: 2.3, x: point.x, y: point.y, button: 0, phase: .down)]
                        let motion = track(canvas: canvas, crop: crop, layout: cameraLayout, cues: [zoom], capture: input,
                                           sourceAspect: sourceAspect)
                        for time in [2.001, 2.08, 2.3, 5, 8.08, 8.3] {
                            let frame = motion.layoutFrame(at: time, canvasSize: canvas)!
                            let geometry = base(canvas: canvas, crop: crop, mode: .fill, sourceAspect: sourceAspect).applying(frame)
                            let draw = geometry.frameRect(for: motion.viewport(at: time)!)
                            let region = CGRect(x: draw.minX + crop.minX * draw.width,
                                                y: draw.minY + crop.minY * draw.height,
                                                width: crop.width * draw.width, height: crop.height * draw.height)
                            // A subpixel difference is allowed during the rectangle
                            // morph; a settled source edge must align precisely.
                            let tolerance: CGFloat = time == 5 ? 0.02 : 0.5
                            if relative.x < 0.1 { near(region.minX, frame.screenRect.minX, "Left-edge action retains source edge at \(time)", tolerance: tolerance) }
                            if relative.x > 0.9 { near(region.maxX, frame.screenRect.maxX, "Right-edge action retains source edge at \(time)", tolerance: tolerance) }
                            if relative.y < 0.1 { near(region.minY, frame.screenRect.minY, "Top-edge action retains source edge at \(time)", tolerance: tolerance) }
                            if relative.y > 0.9 { near(region.maxY, frame.screenRect.maxY, "Bottom-edge action retains source edge at \(time)", tolerance: tolerance) }
                            if relative.x < 0.1, relative.y < 0.1 {
                                // A menu opens below the top-left menu-bar click.
                                // Keeping only the hotspot visible would miss its cut-off text.
                                let menu = CGRect(x: crop.minX, y: crop.minY, width: crop.width * 0.18, height: crop.height * 0.5)
                                let menuDraw = CGRect(x: draw.minX + menu.minX * draw.width,
                                                      y: draw.minY + menu.minY * draw.height,
                                                      width: menu.width * draw.width, height: menu.height * draw.height)
                                check(menuDraw.minX >= frame.screenRect.minX - tolerance && menuDraw.minY >= frame.screenRect.minY - tolerance
                                      && menuDraw.maxX <= frame.screenRect.maxX + tolerance && menuDraw.maxY <= frame.screenRect.maxY + tolerance,
                                      "Opening menu remains fully framed while zooming")
                            }
                        }
                    }
                }
            }
        }
    }

    static func main() {
        edgeFramingChecks()
        let unit = RecordingVideoCropGeometry.unit
        let manualCrop = CGRect(x: 0.15, y: 0.1, width: 0.65, height: 0.7)
        let canvases = [CGSize(width: 1920, height: 1080), CGSize(width: 1080, height: 1920), CGSize(width: 1080, height: 1080)]
        var capture = PointerCaptureFile()
        capture.travel = [
            PointerTravelSample(time: 0, x: 0.15, y: 0.4), PointerTravelSample(time: 1, x: 0.2, y: 0.42),
            PointerTravelSample(time: 2.5, x: 0.85, y: 0.7), PointerTravelSample(time: 3.5, x: 0.83, y: 0.68),
            PointerTravelSample(time: 5.6, x: 0.3, y: 0.5), PointerTravelSample(time: 8, x: 0.1, y: 0.2)
        ]
        capture.presses = [PointerPressEvent(time: 3, x: 0.85, y: 0.7, button: 0, phase: .down)]
        let zooms = [ZoomCue(start: 2, end: 5, zoom: 1.7),
                     ZoomCue(start: 6, end: 7.5, zoom: 2, anchorMode: .pinnedAnchor, pinnedPoint: CGPoint(x: 0.2, y: 0.15))]
        for canvas in canvases {
            for crop in [unit, manualCrop] {
                for mode in [RecordingStudioLayout.ContentMode.fill, .fit] {
                    for side in [RecordingCameraLayout.Side.leading, .trailing] {
                        for fit in [RecordingCameraLayout.ScreenFit.fit, .fill] {
                            let cameraLayout = RecordingCameraLayout(kind: .split, side: side, screenFit: fit)
                            let resting = base(canvas: canvas, crop: crop, mode: mode)
                            let resolver = RecordingCameraLayoutResolver(base: resting, style: RecordingStudioStyle(), showsCamera: true)
                            let frame = resolver.frame(for: cameraLayout)
                            let applied = resting.applying(frame)
                            if fit == .fit {
                                near(frame.screenRect.width / frame.screenRect.height, 16 / 9 * crop.width / crop.height,
                                     "Fit uses source crop aspect", tolerance: 0.002)
                                near(applied.contentFillSize.width * crop.width, frame.screenRect.width, "Fit contains full source width")
                                near(applied.contentFillSize.height * crop.height, frame.screenRect.height, "Fit contains full source height")
                            }
                            let motion = track(canvas: canvas, crop: crop, mode: mode, layout: cameraLayout, cues: zooms, capture: capture)
                            for index in 0...600 {
                                let time = min(10, Double(index) / 60 + 0.0021)
                                let current = motion.layoutFrame(at: time, canvasSize: canvas)!
                                let geometry = resting.applying(current)
                                let viewport = motion.viewport(at: time)!
                                let draw = geometry.frameRect(for: viewport)
                                let visible = CGRect(x: draw.minX + crop.minX * draw.width, y: draw.minY + crop.minY * draw.height,
                                                     width: draw.width * crop.width, height: draw.height * crop.height)
                                check(viewport.magnification.isFinite && viewport.anchor.x.isFinite && viewport.anchor.y.isFinite, "Finite motion")
                                check(visible.minX <= current.screenRect.minX + 0.03 && visible.maxX >= current.screenRect.maxX - 0.03,
                                      "No exposed source edges horizontally")
                                check(visible.minY <= current.screenRect.minY + 0.03 && visible.maxY >= current.screenRect.maxY - 0.03,
                                      "No exposed source edges vertically")
                                near(draw.width / draw.height, resting.contentFillSize.width / resting.contentFillSize.height,
                                     "Uniform source scale throughout morph", tolerance: 0.00001)
                                // Preview's cursor formula equals the exported source-to-canvas transform.
                                let point = CGPoint(x: 0.85, y: 0.7)
                                near(current.screenRect.midX + geometry.contentFillSize.width * viewport.magnification * (point.x - viewport.anchor.x),
                                     draw.minX + point.x * draw.width, "Cursor X shares draw transform", tolerance: 0.000001)
                                near(current.screenRect.midY + geometry.contentFillSize.height * viewport.magnification * (point.y - viewport.anchor.y),
                                     draw.minY + point.y * draw.height, "Cursor Y shares draw transform", tolerance: 0.000001)
                            }
                            let during = motion.layoutFrame(at: 3.5, canvasSize: canvas)!
                            check(during.screenRect.width >= frame.screenRect.width - 0.1, "Screen expands during zoom")
                            if fit == .fill {
                                check(during.cameraRect.height < frame.cameraRect.height || during.cameraRect.width < frame.cameraRect.width,
                                      "Full-height split camera shrinks into overlay")
                            }
                            let zoomedDestination = resolver.frame(for: cameraLayout, zoomProgress: 1)
                            near(during.cameraRect.maxX, zoomedDestination.cameraRect.maxX, "Overlay reaches its corner", tolerance: 2)
                            let shrunk = motion.layoutFrame(at: 3.5, canvasSize: CGSize(width: canvas.width / 3, height: canvas.height / 3))!
                            near(shrunk.screenRect.width * 3, during.screenRect.width, "Preview/export canvas scaling")
                        }
                    }
                }
            }
        }
        let canvas = canvases[0]
        let split = RecordingCameraLayout(kind: .split)
        let motion = track(canvas: canvas, layout: split, cues: zooms, capture: capture)
        let resting = motion.layoutFrame(at: 1.5, canvasSize: canvas)!
        let moving = motion.layoutFrame(at: 2.15, canvasSize: canvas)!
        check(moving.screenRect.width > resting.screenRect.width + 5 && moving.cameraRect.height < resting.cameraRect.height - 5,
              "Screen expansion and camera shrink start together")
        check(motion.viewport(at: 2.15)!.magnification > 1.01, "Zoom moves while layout moves")
        for boundary in [2.0, 2.5, 3.0, 5.0, 6.0, 7.5] {
            let a = motion.viewport(at: boundary - 0.00001)!
            let b = motion.viewport(at: boundary + 0.00001)!
            near(a.anchor.x, b.anchor.x, "Continuous pan at event boundary", tolerance: 0.0001)
            near(a.magnification, b.magnification, "Continuous scale at event boundary", tolerance: 0.0001)
        }
        let pressFrame = motion.layoutFrame(at: 3, canvasSize: canvas)!
        let pressLayout = base(canvas: canvas, crop: unit, mode: .fill).applying(pressFrame)
        let pressDraw = pressLayout.frameRect(for: motion.viewport(at: 3)!)
        let pressPoint = CGPoint(x: pressDraw.minX + pressDraw.width * 0.85, y: pressDraw.minY + pressDraw.height * 0.7)
        check(pressFrame.screenRect.contains(pressPoint), "Anticipated click stays visible")
        check(!pressFrame.cameraRect.contains(pressPoint), "Zoomed click avoids camera: point=\(pressPoint) camera=\(pressFrame.cameraRect) draw=\(pressDraw)")
        let ordinaryCue = ZoomCue(start: 2, end: 4, zoom: 1.8, anchorMode: .pinnedAnchor, pinnedPoint: CGPoint(x: 0.8, y: 0.6))
        let fastCue = ZoomCue(start: 4, end: 8, zoom: 1.8, anchorMode: .pinnedAnchor, pinnedPoint: CGPoint(x: 0.8, y: 0.6))
        let fastClips = RecordingClipTimeline(segments: [RecordingClipSegment(sourceStart: 0, sourceEnd: 10, speed: 2)])
        let ordinary = track(canvas: canvas, layout: split, cues: [ordinaryCue])
        let fast = track(canvas: canvas, layout: split, cues: [fastCue], clips: fastClips)
        for time in [2.1, 2.3, 2.6, 3.0] {
            near(ordinary.viewport(at: time)!.magnification, fast.viewport(at: time)!.magnification, "Speed-independent zoom", tolerance: 0.000001)
            near(ordinary.layoutFrame(at: time, canvasSize: canvas)!.cameraRect.height,
                 fast.layoutFrame(at: time, canvasSize: canvas)!.cameraRect.height, "Speed-independent camera spring")
        }
        let cutClips = RecordingClipTimeline(segments: [RecordingClipSegment(sourceStart: 0, sourceEnd: 3),
                                                       RecordingClipSegment(sourceStart: 5, sourceEnd: 10, speed: 2)])
        let cutMotion = track(canvas: canvas, layout: split, cues: zooms, capture: capture, clips: cutClips,
                              layoutCues: [RecordingCameraLayoutCue(start: 5.5, end: 7, layout: .cameraOnly)])
        let beforeCut = cutMotion.viewport(at: 2.999)!
        let afterCut = cutMotion.viewport(at: 3.001)!
        near(beforeCut.anchor.x, afterCut.anchor.x, "Cut retains camera continuity", tolerance: 0.01)
        let noCamera = track(canvas: canvas, camera: false, layout: split, cues: zooms, capture: capture)
        near(noCamera.layoutFrame(at: 3.5, canvasSize: canvas)!.cameraOpacity, 0, "Hidden camera stays hidden")
        let noZoom = track(canvas: canvas, layout: split, cues: [], capture: capture)
        near(noZoom.layoutFrame(at: 3.5, canvasSize: canvas)!.cameraRect.height, resting.cameraRect.height, "Disabled zoom retains split")
        let snap = track(canvas: canvas, layout: split,
                         cues: [ZoomCue(start: 2, end: 4, zoom: 1.8, anchorMode: .pinnedAnchor, skipsEasing: true)])
        near(snap.viewport(at: 2)!.magnification, 1.8, "Skip easing remains authoritative", tolerance: 0.001)
        print("Passed \(count) camera-motion geometry checks across 48 configurations, plus edge-menu, timing, and visibility checks.")
    }
}
