import OpenAVFoundationDriver

actor AppleCameraDeviceHandle: CaptureDeviceHandle {
  private enum OperationPhase {
    case idle
    case operating
    case shutdown
  }

  private let snapshotValue: CaptureDeviceSnapshot
  private let backend: any AppleCameraDeviceBackend
  private let failureHandler: @Sendable (CaptureDriverError) -> Void

  private var configuration: CaptureDeviceConfiguration?
  private var phase = OperationPhase.idle

  init(
    snapshot: CaptureDeviceSnapshot,
    backend: any AppleCameraDeviceBackend,
    failureHandler:
      @escaping @Sendable (CaptureDriverError) -> Void
  ) {
    snapshotValue = snapshot
    self.backend = backend
    self.failureHandler = failureHandler
  }

  func snapshot() async throws(CaptureDriverError)
    -> CaptureDeviceSnapshot
  {
    try beginOperation()
    defer { finishOperation() }
    try await backend.requireAvailable()
    return snapshotValue
  }

  func configure(
    _ configuration: CaptureDeviceConfiguration
  ) async throws(CaptureDriverError) -> CaptureDeviceSnapshot {
    try beginOperation()
    defer { finishOperation() }
    try await backend.requireAvailable()
    let capabilities = snapshotValue.capabilities
    _ = try capabilities.validatedConfiguration(configuration)
    guard let format = capabilities.formats.first(
      where: { $0.formatID == configuration.formatID }
    ) else {
      throw .unsupportedFormat(
        deviceID: configuration.deviceID,
        formatID: configuration.formatID
      )
    }

    try await backend.configure(
      format: format,
      frameRate: configuration.frameRate,
      controls: configuration.controls
    )
    self.configuration = configuration
    return snapshotValue
  }

  func stream(
    for request: CaptureStreamRequest,
    sink: any CaptureSampleSink
  ) async throws(CaptureDriverError) -> any CaptureStream {
    try beginOperation()
    defer { finishOperation() }
    try await backend.requireAvailable()
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
    _ = try snapshotValue.capabilities.validatedStreamRequest(request)
    let streamID: CaptureStreamID
    if let requestedStreamID = request.streamID {
      streamID = requestedStreamID
    } else if let preferredStream = snapshotValue.capabilities.streams.first(
      where: { $0.formatIDs.contains(configuration.formatID) }
    ) {
      streamID = preferredStream.streamID
    } else {
      throw .unsupportedStreamCombination(
        deviceID: configuration.deviceID,
        streamIDs: []
      )
    }

    return try await backend.stream(
      format: format,
      streamID: streamID,
      connectionConfiguration: request.videoConnectionConfiguration,
      sink: sink,
      failureHandler: failureHandler
    )
  }

  func shutdown() async throws(CaptureDriverError) {
    guard phase != .shutdown else {
      return
    }
    try beginOperation()
    do {
      try await backend.shutdown()
      configuration = nil
      phase = .shutdown
    } catch {
      // A backend shutdown error can report cleanup failure after the native
      // resource has already become unavailable. Keep this handle terminal so
      // no later operation can commit state against a partially closed backend.
      configuration = nil
      phase = .shutdown
      throw error
    }
  }

  private func beginOperation() throws(CaptureDriverError) {
    switch phase {
    case .idle:
      phase = .operating
    case .operating:
      throw .deviceBusy(snapshotValue.descriptor.deviceID)
    case .shutdown:
      throw .deviceDisconnected(snapshotValue.descriptor.deviceID)
    }
  }

  private func finishOperation() {
    guard phase == .operating else {
      return
    }
    phase = .idle
  }
}
