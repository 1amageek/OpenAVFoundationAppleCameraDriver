import OpenAVFoundationDriver
import Testing

@testable import OpenAVFoundationAppleCameraDriver

@Suite("Apple camera stream identifier sequence")
struct AppleCameraStreamIDSequenceTests {
  @Test("Maximum identifier is issued once before typed exhaustion")
  func typedExhaustion() throws {
    let driverID = try CaptureDriverID("apple.test.stream-sequence")
    let deviceID = try CaptureDeviceID(
      driverID: driverID,
      localID: "camera"
    )
    var sequence = AppleCameraStreamIDSequence(firstValue: .max)

    #expect(
      try sequence.next(
        driverID: driverID,
        deviceID: deviceID
      ) == .max
    )
    #expect(
      throws: CaptureDriverError.backendFailure(
        driverID: driverID,
        deviceID: deviceID,
        operation: .streaming,
        code: AppleCameraStreamIDSequence.exhaustionCode
      )
    ) {
      _ = try sequence.next(
        driverID: driverID,
        deviceID: deviceID
      )
    }
  }
}
