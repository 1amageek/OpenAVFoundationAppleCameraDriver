import OpenAVFoundationDriver

protocol AppleCameraDeviceBackend: Sendable {
  func requireAvailable() async throws(CaptureDriverError)

  func configure(
    format: CaptureDeviceFormatDescriptor,
    frameRate: Double?,
    controls: CaptureDeviceControls
  ) async throws(CaptureDriverError)

  func stream(
    format: CaptureDeviceFormatDescriptor,
    streamID: CaptureStreamID,
    connectionConfiguration: CaptureVideoConnectionConfiguration,
    sink: any CaptureSampleSink,
    failureHandler: @escaping @Sendable (CaptureDriverError) -> Void
  ) async throws(CaptureDriverError) -> any CaptureStream

  func shutdown() async throws(CaptureDriverError)
}
