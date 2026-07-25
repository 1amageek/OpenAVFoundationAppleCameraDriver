import OpenAVFoundationDriver

protocol AppleCameraStreamRuntime: Sendable {
  func startStream(
    identifiedBy streamID: UInt64
  ) async throws(CaptureDriverError)

  func shutdownStream(
    identifiedBy streamID: UInt64
  ) async throws(CaptureDriverError)
}
