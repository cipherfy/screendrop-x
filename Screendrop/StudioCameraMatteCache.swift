//
//  StudioCameraMatteCache.swift
//  Screendrop
//
//  A cutout's mattes for the whole camera recording, made once in the
//  background while the project is open, so an export reads them instead
//  of running Vision. Vision is the slowest part of a cutout export, and
//  slower still beside the export's own GPU work: about 11 ms a frame
//  there against 8 ms on its own.
//
//  Each matte is the brightness of one frame of a small HEVC movie, stamped
//  with its camera frame's time. At quality 0.75 that's about 1.3 MB a
//  minute of camera, and the matte reads back within a few levels, which
//  the kernel's edge tightening makes indistinguishable.
//

import AVFoundation
import CoreVideo
import Foundation

nonisolated enum StudioCameraMatteCache {
    static func url(forCamera cameraURL: URL) -> URL {
        cameraURL.deletingLastPathComponent().appendingPathComponent(RecordingSession.cameraMatteFileName)
    }

    private static func partialURL(forCamera cameraURL: URL) -> URL {
        cameraURL.deletingLastPathComponent().appendingPathComponent("camera-matte.partial.mov")
    }

    /// True when the cache covers the whole recording and was made from the
    /// camera movie as it is now. It's only ever moved into place complete.
    static func isComplete(forCamera cameraURL: URL) -> Bool {
        let manager = FileManager.default
        guard let cache = try? manager.attributesOfItem(atPath: url(forCamera: cameraURL).path),
              let camera = try? manager.attributesOfItem(atPath: cameraURL.path),
              let cacheDate = cache[.modificationDate] as? Date,
              let cameraDate = camera[.modificationDate] as? Date
        else { return false }
        return cacheDate >= cameraDate
    }

    /// Segments every frame of the camera movie into the cache, off the
    /// caller's actor at utility priority. Returns quietly if cancelled or
    /// if anything fails; the export segments live without it.
    @concurrent
    static func generate(cameraURL: URL) async {
        let partial = partialURL(forCamera: cameraURL)
        do {
            try await write(cameraURL: cameraURL, to: partial)
            let destination = url(forCamera: cameraURL)
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: partial, to: destination)
        } catch {
            try? FileManager.default.removeItem(at: partial)
        }
    }

    private enum GenerationError: Error {
        case unreadable
        case writerFailed
    }

    private static func write(cameraURL: URL, to destination: URL) async throws {
        let asset = AVURLAsset(url: cameraURL)
        guard let track = try await asset.loadTracks(withMediaType: .video).first,
              let generator = StudioCameraMatteGenerator()
        else { throw GenerationError.unreadable }
        let size = try await track.load(.naturalSize)
        guard size.width > 0, size.height > 0 else { throw GenerationError.unreadable }
        let height = min(Int(size.height), StudioCameraMatteGenerator.visionInputHeight)
        let width = max(2, Int((size.width * CGFloat(height) / size.height).rounded()) & ~1)

        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height
        ])
        output.alwaysCopiesSampleData = false
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? GenerationError.unreadable }
        defer { reader.cancelReading() }

        try? FileManager.default.removeItem(at: destination)
        var writer: AVAssetWriter?
        var input: AVAssetWriterInput?
        var adaptor: AVAssetWriterInputPixelBufferAdaptor?
        defer {
            if let writer, writer.status == .writing { writer.cancelWriting() }
        }

        while let sample = output.copyNextSampleBuffer() {
            try Task.checkCancellation()
            guard let camera = CMSampleBufferGetImageBuffer(sample) else { continue }
            let time = CMSampleBufferGetPresentationTimeStamp(sample)
            guard let mask = autoreleasepool(invoking: { generator.mask(for: camera, time: time.seconds) }) else {
                continue
            }
            if writer == nil {
                // Vision's matte size is fixed per quality, so the first one
                // sizes the movie.
                (writer, input, adaptor) = try makeWriter(
                    at: destination,
                    width: CVPixelBufferGetWidth(mask),
                    height: CVPixelBufferGetHeight(mask)
                )
            }
            guard let writer, let input, let adaptor, let pool = adaptor.pixelBufferPool else {
                throw GenerationError.writerFailed
            }
            var frame: CVPixelBuffer?
            guard CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &frame) == kCVReturnSuccess,
                  let frame, copy(mask, intoLuma: frame)
            else { throw GenerationError.writerFailed }
            while !input.isReadyForMoreMediaData {
                try Task.checkCancellation()
                try await Task.sleep(nanoseconds: 2_000_000)
            }
            guard adaptor.append(frame, withPresentationTime: time) else { throw writer.error ?? GenerationError.writerFailed }
        }
        guard reader.status == .completed, let writer, let input else { throw GenerationError.unreadable }
        try Task.checkCancellation()
        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? GenerationError.writerFailed }
    }

    private static func makeWriter(
        at url: URL, width: Int, height: Int
    ) throws -> (AVAssetWriter, AVAssetWriterInput, AVAssetWriterInputPixelBufferAdaptor) {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoQualityKey: 0.75,
                AVVideoExpectedSourceFrameRateKey: 30
            ] as [String: Any]
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            // Full range keeps the matte's 0...255 as it is.
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Int]()
        ])
        guard writer.canAdd(input) else { throw GenerationError.writerFailed }
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? GenerationError.writerFailed }
        writer.startSession(atSourceTime: .zero)
        return (writer, input, adaptor)
    }

    /// The matte as the frame's brightness, with neutral color.
    private static func copy(_ mask: CVPixelBuffer, intoLuma frame: CVPixelBuffer) -> Bool {
        guard CVPixelBufferLockBaseAddress(mask, .readOnly) == kCVReturnSuccess else { return false }
        defer { CVPixelBufferUnlockBaseAddress(mask, .readOnly) }
        guard CVPixelBufferLockBaseAddress(frame, []) == kCVReturnSuccess else { return false }
        defer { CVPixelBufferUnlockBaseAddress(frame, []) }
        guard let source = CVPixelBufferGetBaseAddress(mask),
              let luma = CVPixelBufferGetBaseAddressOfPlane(frame, 0),
              let chroma = CVPixelBufferGetBaseAddressOfPlane(frame, 1)
        else { return false }
        let rows = min(CVPixelBufferGetHeight(mask), CVPixelBufferGetHeightOfPlane(frame, 0))
        let width = min(CVPixelBufferGetWidth(mask), CVPixelBufferGetWidthOfPlane(frame, 0))
        let sourceRow = CVPixelBufferGetBytesPerRow(mask)
        let lumaRow = CVPixelBufferGetBytesPerRowOfPlane(frame, 0)
        for row in 0..<rows {
            memcpy(luma + row * lumaRow, source + row * sourceRow, width)
        }
        memset(chroma, 128, CVPixelBufferGetBytesPerRowOfPlane(frame, 1) * CVPixelBufferGetHeightOfPlane(frame, 1))
        return true
    }
}
