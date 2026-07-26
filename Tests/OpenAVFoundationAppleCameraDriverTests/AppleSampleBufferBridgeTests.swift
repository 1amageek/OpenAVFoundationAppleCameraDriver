import CoreImage
import CoreMedia
import CoreVideo
import Foundation
import OpenCoreMedia
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

  @Test("Bridge retains the exact native pixel-buffer owner")
  func nativePixelBufferIdentity() throws {
    let bridge = try AppleSampleBufferBridge(
      format: AppleCameraTestFixtures.format(
        width: 4,
        height: 2
      )
    )
    let nativeSample = try AppleCameraTestFixtures.sampleBuffer(
      width: 4,
      height: 2
    )
    let nativeImage = try #require(
      CMSampleBufferGetImageBuffer(nativeSample)
    )
    let sample = try bridge.sample(from: nativeSample)
    let image = try #require(
      sample.imageBuffer() as? AppleCameraPixelBuffer
    )

    var preservesIdentity = false
    image.withCoreVideoPixelBuffer { projectedImage in
      preservesIdentity = projectedImage === nativeImage
    }
    #expect(preservesIdentity)
  }

  @Test("Bridge preserves native sample timing exactly")
  func sampleTiming() throws {
    let bridge = try AppleSampleBufferBridge(
      format: AppleCameraTestFixtures.format(
        width: 4,
        height: 2
      )
    )
    let nativeSample = try AppleCameraTestFixtures.sampleBuffer(
      width: 4,
      height: 2
    )
    let sample = try bridge.sample(from: nativeSample)
    let timing = try sample.timingInfo(at: 0)

    expectEquivalent(
      timing.duration,
      CMSampleBufferGetDuration(nativeSample)
    )
    expectEquivalent(
      timing.presentationTimeStamp,
      CMSampleBufferGetPresentationTimeStamp(nativeSample)
    )
    expectEquivalent(
      timing.decodeTimeStamp,
      CMSampleBufferGetDecodeTimeStamp(nativeSample)
    )
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
    let image = try #require(
      sample.imageBuffer() as? AppleCameraPixelBuffer
    )

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
    let image = try #require(
      sample.imageBuffer() as? AppleCameraPixelBuffer
    )

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

  @Test("Bridge preserves image, bearer, and per-sample attachments")
  func attachmentMapping() throws {
    let bridge = try AppleSampleBufferBridge(
      format: AppleCameraTestFixtures.format(
        width: 4,
        height: 2
      )
    )
    let nativeSample = try AppleCameraTestFixtures.sampleBuffer(
      width: 4,
      height: 2
    )
    let nativeImage = try #require(
      CMSampleBufferGetImageBuffer(nativeSample)
    )
    let imageKey = "test.image.metadata" as CFString
    let imageValue: NSDictionary = [
      "nested": NSArray(array: [true, 7, "camera"])
    ]
    CVBufferSetAttachment(
      nativeImage,
      imageKey,
      imageValue,
      .shouldPropagate
    )
    CVBufferSetAttachment(
      nativeImage,
      "test.image.private" as CFString,
      NSNumber(value: UInt64.max),
      .shouldNotPropagate
    )

    let bearerKey = "test.sample.bearer" as CFString
    CMSetAttachment(
      nativeSample,
      key: bearerKey,
      value: "retained" as CFString,
      attachmentMode: kCMAttachmentMode_ShouldNotPropagate
    )
    let bearerValue: NSArray = [
      NSNumber(value: 2.5),
      NSDictionary(dictionary: ["role": "preview"]),
    ]
    CMSetAttachment(
      nativeSample,
      key: "test.sample.propagated" as CFString,
      value: bearerValue,
      attachmentMode: kCMAttachmentMode_ShouldPropagate
    )
    let nativeSampleAttachments = try #require(
      CMSampleBufferGetSampleAttachmentsArray(
        nativeSample,
        createIfNecessary: true
      )
    )
    let rawDictionary = try #require(
      CFArrayGetValueAtIndex(nativeSampleAttachments, 0)
    )
    let sampleDictionary = Unmanaged<NSMutableDictionary>
      .fromOpaque(rawDictionary)
      .takeUnretainedValue()
    sampleDictionary["test.sample.flag"] = [
      "nested": [true, "frame"]
    ]

    let sample = try bridge.sample(from: nativeSample)
    let image = try #require(
      sample.imageBuffer() as? AppleCameraPixelBuffer
    )
    #expect(
      image.attachments.attachment(
        for: CVAttachmentKey(rawValue: "test.image.metadata")
      )
        == CVBufferAttachment(
          value: .dictionary([
            "nested": .array([
              .boolean(true),
              .integer(7),
              .string("camera"),
            ])
          ]),
          mode: .shouldPropagate
        )
    )
    #expect(
      image.attachments.attachment(
        for: CVAttachmentKey(rawValue: "test.image.private")
      )
        == CVBufferAttachment(
          value: .unsignedInteger(UInt64.max),
          mode: .shouldNotPropagate
        )
    )
    #expect(
      sample.attachments["test.sample.bearer"]
        == .shouldNotPropagate(.string("retained"))
    )
    #expect(
      sample.attachments["test.sample.propagated"]
        == .shouldPropagate(
          .array([
            .floatingPoint(2.5),
            .dictionary(["role": .string("preview")]),
          ])
        )
    )
    let portableSampleAttachments = try #require(
      sample.sampleAttachments(createIfNecessary: false)
    )
    #expect(
      try portableSampleAttachments.attachment(at: 0)[
        rawAttachment: "test.sample.flag"
      ] == .dictionary([
        "nested": .array([
          .boolean(true),
          .string("frame"),
        ])
      ])
    )
  }

  @Test("Unsupported native attachment values fail explicitly")
  func unsupportedAttachmentValue() throws {
    let bridge = try AppleSampleBufferBridge(
      format: AppleCameraTestFixtures.format(
        width: 4,
        height: 2
      )
    )
    let nativeSample = try AppleCameraTestFixtures.sampleBuffer(
      width: 4,
      height: 2
    )
    let nativeImage = try #require(
      CMSampleBufferGetImageBuffer(nativeSample)
    )
    CVBufferSetAttachment(
      nativeImage,
      "test.unsupported" as CFString,
      NSDate(timeIntervalSince1970: 0),
      .shouldNotPropagate
    )

    do {
      _ = try bridge.sample(from: nativeSample)
      Issue.record("An unsupported attachment must not be dropped")
    } catch let error {
      guard case .attachment(.unsupportedValueType) = error else {
        Issue.record("Unexpected bridge error: \(error)")
        return
      }
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

  private func expectEquivalent(
    _ portable: OpenCoreMedia.CMTime,
    _ native: CoreMedia.CMTime
  ) {
    #expect(portable.value == native.value)
    #expect(portable.timescale == native.timescale)
    #expect(portable.flags.rawValue == native.flags.rawValue)
    #expect(portable.epoch == native.epoch)
  }
}
