import CoreMedia
import CoreVideo
import OpenCoreVideo
import Testing

@testable import OpenAVFoundationAppleCameraDriver

@Suite("Apple camera pixel buffer")
struct AppleCameraPixelBufferTests {
  @Test("Read borrow exposes the original Core Video address")
  func addressIdentity() throws {
    var pixelBuffer: CoreVideo.CVPixelBuffer?
    let status = CVPixelBufferCreate(
      nil,
      4,
      2,
      kCVPixelFormatType_32BGRA,
      nil,
      &pixelBuffer
    )
    #expect(status == kCVReturnSuccess)
    let buffer = try #require(pixelBuffer)
    let openBuffer = try AppleCameraPixelBuffer(
      pixelBuffer: buffer
    )

    let lockStatus = CVPixelBufferLockBaseAddress(buffer, .readOnly)
    #expect(lockStatus == kCVReturnSuccess)
    let expectedAddress = CVPixelBufferGetBaseAddress(buffer).map {
      UInt(bitPattern: $0)
    }
    CVPixelBufferUnlockBaseAddress(buffer, .readOnly)

    try openBuffer.withReadBytes { bytes in
      let borrowedAddress = bytes.withUnsafeBufferPointer { pointer in
        pointer.baseAddress.map { UInt(bitPattern: $0) }
      }
      #expect(borrowedAddress == expectedAddress)
    }
  }

  @Test("Write access is an explicit typed failure")
  func writeFailure() throws {
    var pixelBuffer: CoreVideo.CVPixelBuffer?
    let status = CVPixelBufferCreate(
      nil,
      2,
      2,
      kCVPixelFormatType_32BGRA,
      nil,
      &pixelBuffer
    )
    #expect(status == kCVReturnSuccess)
    let openBuffer = try AppleCameraPixelBuffer(
      pixelBuffer: try #require(pixelBuffer)
    )

    #expect(throws: CVPixelBufferError.unsupportedAccess(.write)) {
      try openBuffer.withWriteBytes { _ in }
    }
  }

  @Test("NV12 planes borrow the original Core Video addresses")
  func planarAddressIdentity() throws {
    var pixelBuffer: CoreVideo.CVPixelBuffer?
    let status = CVPixelBufferCreate(
      nil,
      8,
      4,
      kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
      nil,
      &pixelBuffer
    )
    #expect(status == kCVReturnSuccess)
    let buffer = try #require(pixelBuffer)
    let openBuffer = try AppleCameraPixelBuffer(
      pixelBuffer: buffer
    )

    #expect(openBuffer.isPlanar)
    #expect(openBuffer.planeCount == 2)
    #expect(try openBuffer.dimensionsOfPlane(at: 0).width == 8)
    #expect(try openBuffer.dimensionsOfPlane(at: 1).width == 4)
    #expect(
      try openBuffer.byteCount(ofPlane: 1)
        == openBuffer.bytesPerRowOfPlane(at: 1)
        * openBuffer.dimensionsOfPlane(at: 1).height
    )

    let lockStatus = CVPixelBufferLockBaseAddress(buffer, .readOnly)
    #expect(lockStatus == kCVReturnSuccess)
    let expectedAddress = CVPixelBufferGetBaseAddressOfPlane(
      buffer,
      1
    ).map { UInt(bitPattern: $0) }
    CVPixelBufferUnlockBaseAddress(buffer, .readOnly)

    try openBuffer.withReadBytes(ofPlane: 1) { bytes in
      let borrowedAddress = bytes.withUnsafeBufferPointer { pointer in
        pointer.baseAddress.map { UInt(bitPattern: $0) }
      }
      #expect(borrowedAddress == expectedAddress)
    }
  }

  @Test("NV12 planes can be nested under one native read lock")
  func nestedPlanarReads() throws {
    let sample = try AppleCameraTestFixtures.sampleBuffer(
      width: 8,
      height: 4,
      pixelFormat: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
      fillByte: 0x45
    )
    let nativeBuffer = try #require(
      CMSampleBufferGetImageBuffer(sample)
    )
    let openBuffer = try AppleCameraPixelBuffer(
      pixelBuffer: nativeBuffer
    )

    var observedLuma: UInt8?
    var observedChroma: UInt8?
    func readChroma() throws(CVPixelBufferError) {
      try openBuffer.withReadBytes(ofPlane: 1) { chroma in
        observedChroma = chroma[0]
      }
    }
    try openBuffer.withReadBytes(ofPlane: 0) { luma in
      observedLuma = luma[0]
      do {
        try readChroma()
      } catch {
        Issue.record("Nested plane read failed: \(error)")
      }
    }

    #expect(observedLuma == 0x45)
    #expect(observedChroma == 0x45)
  }

  @Test("Planar whole-buffer access is an explicit typed failure")
  func planarWholeBufferFailure() throws {
    let sample = try AppleCameraTestFixtures.sampleBuffer(
      width: 8,
      height: 4,
      pixelFormat:
        kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
    )
    let pixelBuffer = try #require(
      CMSampleBufferGetImageBuffer(sample)
    )
    let openBuffer = try AppleCameraPixelBuffer(
      pixelBuffer: pixelBuffer
    )

    #expect(throws: CVPixelBufferError.planarBufferRequiresPlaneAccess) {
      try openBuffer.withReadBytes { _ in }
    }
  }
}
