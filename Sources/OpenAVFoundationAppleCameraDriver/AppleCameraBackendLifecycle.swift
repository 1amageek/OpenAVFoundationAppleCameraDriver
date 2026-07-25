import OpenAVFoundationDriver

struct AppleCameraBackendLifecycle: Sendable {
  private enum Phase: Sendable {
    case active
    case invalidated(Int64)
    case shutdown
  }

  private var phase = Phase.active

  var isShutdown: Bool {
    if case .shutdown = phase {
      return true
    }
    return false
  }

  mutating func invalidateAfterConfigurationRollback() {
    invalidate(code: 2)
  }

  mutating func invalidateAfterTopologyRollback() {
    invalidate(code: 3)
  }

  func requireAvailable(
    driverID: CaptureDriverID,
    deviceID: CaptureDeviceID
  ) throws(CaptureDriverError) {
    switch phase {
    case .active:
      return
    case .invalidated(let code):
      throw .backendFailure(
        driverID: driverID,
        deviceID: deviceID,
        operation: .configuration,
        code: code
      )
    case .shutdown:
      throw .deviceDisconnected(deviceID)
    }
  }

  mutating func finishShutdown() {
    phase = .shutdown
  }

  private mutating func invalidate(code: Int64) {
    guard case .active = phase else {
      return
    }
    phase = .invalidated(code)
  }
}
