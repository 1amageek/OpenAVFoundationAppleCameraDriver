@preconcurrency import AVFoundation

final class AppleCaptureDeviceReference: Sendable {
    // AVFoundation capture objects are accessed only by the handle actor or the
    // runtime's serial control queue.
    nonisolated(unsafe) let value: AVFoundation.AVCaptureDevice

    init(_ value: AVFoundation.AVCaptureDevice) {
        self.value = value
    }
}
