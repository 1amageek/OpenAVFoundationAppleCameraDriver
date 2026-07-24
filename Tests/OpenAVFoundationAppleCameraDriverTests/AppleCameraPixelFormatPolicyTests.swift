import CoreVideo
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
}
