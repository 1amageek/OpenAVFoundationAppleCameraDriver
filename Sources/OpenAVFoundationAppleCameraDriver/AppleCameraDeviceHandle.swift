import OpenAVFoundationDriver

actor AppleCameraDeviceHandle: CaptureDeviceHandle {
  private let driverID: CaptureDriverID
  private let reference: AppleCaptureDeviceReference
  private let snapshotValue: CaptureDeviceSnapshot
  private let failureHandler: @Sendable (CaptureDriverError) -> Void

  private var configuration: CaptureDeviceConfiguration?
  private var isShutdown = false

  init(
    driverID: CaptureDriverID,
    reference: AppleCaptureDeviceReference,
    snapshot: CaptureDeviceSnapshot,
    failureHandler:
      @escaping @Sendable (CaptureDriverError) -> Void
  ) {
    self.driverID = driverID
    self.reference = reference
    snapshotValue = snapshot
    self.failureHandler = failureHandler
  }

  func snapshot() throws(CaptureDriverError) -> CaptureDeviceSnapshot {
    try requireAvailable()
    return snapshotValue
  }

  func configure(
    _ configuration: CaptureDeviceConfiguration
  ) throws(CaptureDriverError) -> CaptureDeviceSnapshot {
    try requireAvailable()
    let capabilities = snapshotValue.capabilities
    guard configuration.deviceID == capabilities.deviceID else {
      throw .deviceNotFound(configuration.deviceID)
    }
    guard configuration.capabilityRevision == capabilities.revision else {
      throw .staleCapabilities(
        deviceID: configuration.deviceID,
        expectedRevision: configuration.capabilityRevision,
        actualRevision: capabilities.revision
      )
    }
    guard
      capabilities.formats.contains(
        where: { $0.formatID == configuration.formatID }
      )
    else {
      throw .unsupportedFormat(
        deviceID: configuration.deviceID,
        formatID: configuration.formatID
      )
    }
    // FIXME(INCOMPLETE_IMPLEMENTATION): The production Apple camera path currently
    // applies the advertised native format without changing device duration.
    // It must not accept an explicit frame rate until the driver validates the
    // active format range and applies matching min/max frame durations.
    if let frameRate = configuration.frameRate {
      throw .unsupportedFrameRate(
        deviceID: configuration.deviceID,
        formatID: configuration.formatID,
        frameRate: frameRate
      )
    }
    self.configuration = configuration
    return snapshotValue
  }

  func stream(
    for request: CaptureStreamRequest,
    sink: any CaptureSampleSink
  ) throws(CaptureDriverError) -> any CaptureStream {
    try requireAvailable()
    guard let configuration,
      configuration == request.configuration
    else {
      throw .unsupportedConfiguration(
        snapshotValue.descriptor.deviceID
      )
    }
    guard
      let format = snapshotValue.capabilities.formats.first(
        where: { $0.formatID == configuration.formatID }
      )
    else {
      throw .unsupportedFormat(
        deviceID: configuration.deviceID,
        formatID: configuration.formatID
      )
    }
    let runtime = try AppleCameraRuntime(
      driverID: driverID,
      deviceID: snapshotValue.descriptor.deviceID,
      format: format,
      device: reference,
      sink: sink,
      failureHandler: failureHandler
    )
    return AppleCameraStream(
      deviceID: snapshotValue.descriptor.deviceID,
      runtime: runtime
    )
  }

  func shutdown() {
    isShutdown = true
    configuration = nil
  }

  private func requireAvailable() throws(CaptureDriverError) {
    guard !isShutdown else {
      throw .deviceDisconnected(snapshotValue.descriptor.deviceID)
    }
    guard reference.value.isConnected else {
      throw .deviceDisconnected(snapshotValue.descriptor.deviceID)
    }
    guard !reference.value.isSuspended else {
      throw .deviceSuspended(snapshotValue.descriptor.deviceID)
    }
  }
}
