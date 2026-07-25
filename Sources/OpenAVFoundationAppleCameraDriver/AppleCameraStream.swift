import OpenAVFoundationDriver

actor AppleCameraStream: CaptureStreamEventSource {
  private enum Phase {
    case idle
    case operating
    case running
    case shutdown
  }

  nonisolated let deviceID: CaptureDeviceID
  nonisolated let eventCapabilities: CaptureStreamEventCapabilities

  private let streamID: UInt64
  private let runtime: any AppleCameraStreamRuntime
  private nonisolated let eventRelay: AppleCameraStreamEventRelay
  private var phase = Phase.idle

  init(
    deviceID: CaptureDeviceID,
    streamID: UInt64,
    runtime: any AppleCameraStreamRuntime,
    eventRelay: AppleCameraStreamEventRelay
  ) {
    self.deviceID = deviceID
    self.streamID = streamID
    self.runtime = runtime
    self.eventRelay = eventRelay
    eventCapabilities = eventRelay.capabilities
  }

  nonisolated func setEventSink(
    _ sink: (any CaptureStreamEventSink)?
  ) throws(CaptureDriverError) {
    try eventRelay.setSink(sink)
  }

  func start() async throws(CaptureDriverError) {
    switch phase {
    case .running:
      return
    case .operating:
      throw .deviceBusy(deviceID)
    case .shutdown:
      throw .deviceDisconnected(deviceID)
    case .idle:
      phase = .operating
    }

    do {
      try eventRelay.beginStart()
      try await runtime.startStream(identifiedBy: streamID)
      phase = .running
    } catch {
      eventRelay.cancelStart()
      phase = .idle
      throw error
    }
  }

  func shutdown() async throws(CaptureDriverError) {
    switch phase {
    case .shutdown:
      return
    case .operating:
      throw .deviceBusy(deviceID)
    case .idle, .running:
      phase = .operating
    }

    eventRelay.shutdown()
    do {
      try await runtime.shutdownStream(identifiedBy: streamID)
      phase = .shutdown
    } catch {
      // Native teardown may already have released part of the capture graph.
      // Keep the public stream terminal after a reported cleanup failure.
      phase = .shutdown
      throw error
    }
  }
}
