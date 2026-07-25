import OpenAVFoundationDriver

struct AppleCameraStreamIDSequence: Sendable {
  static let exhaustionCode: Int64 = 3_001

  private var nextValue: UInt64?

  init(firstValue: UInt64 = 1) {
    nextValue = firstValue
  }

  mutating func next(
    driverID: CaptureDriverID,
    deviceID: CaptureDeviceID
  ) throws(CaptureDriverError) -> UInt64 {
    guard let value = nextValue else {
      throw .backendFailure(
        driverID: driverID,
        deviceID: deviceID,
        operation: .streaming,
        code: Self.exhaustionCode
      )
    }
    nextValue = value == .max ? nil : value + 1
    return value
  }
}
