import CoreVideo
import OpenAVFoundationDriver
import Testing

@testable import OpenAVFoundationAppleCameraDriver

@Suite("Apple camera pixel format policy")
struct AppleCameraPixelFormatPolicyTests {
  @Test("A supported native format is the only advertised format")
  func nativeFormat() {
    #expect(
      AppleCameraSnapshotFactory.supportedPixelFormats(
        nativeSubtype:
          kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
      ) == [kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange]
    )
  }

  @Test("An unsupported native format is not advertised")
  func unsupportedFormat() {
    #expect(
      AppleCameraSnapshotFactory.supportedPixelFormats(
        nativeSubtype: kCVPixelFormatType_422YpCbCr8
      ).isEmpty
    )
  }

  @Test("Frame rate selection remains inside an advertised range")
  func frameRateRange() throws {
    let ranges = [
      try CaptureFrameRateRange(minimum: 24, maximum: 60)
    ]
    #expect(
      AppleCameraSnapshotFactory.supports(
        frameRate: 30,
        ranges: ranges
      )
    )
    #expect(
      !AppleCameraSnapshotFactory.supports(
        frameRate: 120,
        ranges: ranges
      )
    )
  }

  @Test("Frame duration is the selected rate reciprocal")
  func frameDuration() {
    let duration = AppleCameraFrameDurationBridge.frameDuration(
      for: 30
    )
    #expect(abs(duration.seconds - (1.0 / 30.0)) < 0.000_000_001)
  }
}
