import CoreImage
import CoreVideo
import OpenCoreVideo
import Testing

@testable import OpenAVFoundationAppleCameraDriver

@Suite("Apple sample buffer bridge")
struct AppleSampleBufferBridgeTests {
  @Test("Bridge retains Apple pixels after callback ownership ends")
  func retainedPixelLifetime() throws {
    let bridge = try AppleSampleBufferBridge(
      format: AppleCameraTestFixtures.format(
        width: 4,
        height: 2
      )
    )
    let sample = try makeBridgedSample(
      bridge: bridge,
      fillByte: 0xA7
    )

    var observedByte: UInt8?
    try sample.imageBuffer().withReadBytes { bytes in
      observedByte = bytes[0]
    }
    #expect(observedByte == 0xA7)
  }

  @Test("Bridge reuses immutable format metadata")
  func formatDescriptionIdentity() throws {
    let bridge = try AppleSampleBufferBridge(
      format: AppleCameraTestFixtures.format(
        width: 4,
        height: 2
      )
    )
    let first = try bridge.sample(
      from: AppleCameraTestFixtures.sampleBuffer(
        width: 4,
        height: 2
      )
    )
    let second = try bridge.sample(
      from: AppleCameraTestFixtures.sampleBuffer(
        width: 4,
        height: 2
      )
    )

    #expect(
      try first.formatDescription()
        === second.formatDescription()
    )
  }

  @Test("Bridge rejects dimensions outside the negotiated format")
  func dimensionMismatch() throws {
    let bridge = try AppleSampleBufferBridge(
      format: AppleCameraTestFixtures.format(
        width: 4,
        height: 2
      )
    )
    let appleSample = try AppleCameraTestFixtures.sampleBuffer(
      width: 2,
      height: 2
    )

    do {
      _ = try bridge.sample(from: appleSample)
      Issue.record("Expected a negotiated-dimension failure")
    } catch let error {
      guard
        case .unexpectedDimensions(
          expectedWidth: 4,
          expectedHeight: 2,
          actualWidth: 2,
          actualHeight: 2
        ) = error
      else {
        Issue.record("Unexpected bridge error: \(error)")
        return
      }
    }
  }

  @Test("Bridge preserves an NV12 plane lease")
  func nv12PlaneLifetime() throws {
    let pixelFormat =
      kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
    let bridge = try AppleSampleBufferBridge(
      format: AppleCameraTestFixtures.format(
        width: 8,
        height: 4,
        pixelFormat: pixelFormat
      )
    )
    let sample = try makeNV12BridgedSample(
      bridge: bridge,
      pixelFormat: pixelFormat,
      fillByte: 0x6B
    )
    let image = try sample.imageBuffer()

    #expect(image.isPlanar)
    #expect(image.planeCount == 2)
    #expect(
      try sample.formatDescription().pixelFormat
        == .yCbCr420BiPlanarFullRange
    )
    var observedByte: UInt8?
    try image.withReadBytes(ofPlane: 1) { bytes in
      observedByte = bytes[0]
    }
    #expect(observedByte == 0x6B)
  }

  @Test("Core Image projection retains NV12 after native sample release")
  func coreImageProjectionLifetime() throws {
    let pixelFormat =
      kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
    let bridge = try AppleSampleBufferBridge(
      format: AppleCameraTestFixtures.format(
        width: 8,
        height: 4,
        pixelFormat: pixelFormat
      )
    )
    let sample = try makeNV12BridgedSample(
      bridge: bridge,
      pixelFormat: pixelFormat,
      fillByte: 0x70
    )
    let image = try sample.imageBuffer()

    var renderedImage: CGImage?
    image.withCoreVideoPixelBuffer { nativeBuffer in
      let source = CIImage(cvPixelBuffer: nativeBuffer)
      renderedImage = CIContext().createCGImage(
        source,
        from: source.extent
      )
    }
    #expect(renderedImage?.width == 8)
    #expect(renderedImage?.height == 4)
  }

  @Test("Bridge rejects a pixel format outside negotiation")
  func pixelFormatMismatch() throws {
    let bridge = try AppleSampleBufferBridge(
      format: AppleCameraTestFixtures.format(
        width: 8,
        height: 4,
        pixelFormat:
          kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
      )
    )
    let appleSample = try AppleCameraTestFixtures.sampleBuffer(
      width: 8,
      height: 4
    )

    #expect(throws: AppleSampleBridgeError.self) {
      _ = try bridge.sample(from: appleSample)
    }
  }

  private func makeBridgedSample(
    bridge: AppleSampleBufferBridge,
    fillByte: UInt8
  ) throws -> AppleSampleBufferBridge.SampleBuffer {
    let appleSample = try AppleCameraTestFixtures.sampleBuffer(
      width: 4,
      height: 2,
      fillByte: fillByte
    )
    return try bridge.sample(from: appleSample)
  }

  private func makeNV12BridgedSample(
    bridge: AppleSampleBufferBridge,
    pixelFormat: OSType,
    fillByte: UInt8
  ) throws -> AppleSampleBufferBridge.SampleBuffer {
    let appleSample = try AppleCameraTestFixtures.sampleBuffer(
      width: 8,
      height: 4,
      pixelFormat: pixelFormat,
      fillByte: fillByte
    )
    return try bridge.sample(from: appleSample)
  }
}
