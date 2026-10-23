import CoreVideo

/// Holds one composed frame without copying its pixels. The caller supplies
/// an exact identity for everything drawn, finishes frames in submission order,
/// and never modifies a cached buffer after its first finish. This also permits
/// the following frame to reuse a buffer whose GPU pass is still in flight.
/// Retaining the identity must retain any decoded buffers it identifies.
nonisolated final class StudioComposedFrameCache<State: Equatable> {
    private var state: State?
    private var buffer: CVPixelBuffer?

    func frame(matching state: State) -> CVPixelBuffer? {
        self.state == state ? buffer : nil
    }

    func store(_ buffer: CVPixelBuffer, state: State?) {
        self.state = state
        self.buffer = state == nil ? nil : buffer
    }
}
