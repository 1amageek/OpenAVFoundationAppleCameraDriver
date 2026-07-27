import CoreMedia
import CoreVideo
import Metal
import OpenCoreVideo
import Synchronization
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
    #expect(status == CoreVideo.kCVReturnSuccess)
    let buffer = try #require(pixelBuffer)
    let openBuffer = try AppleCameraPixelBuffer(
      pixelBuffer: buffer
    )

    let lockStatus = CVPixelBufferLockBaseAddress(buffer, .readOnly)
    #expect(lockStatus == CoreVideo.kCVReturnSuccess)
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
    #expect(status == CoreVideo.kCVReturnSuccess)
    let openBuffer = try AppleCameraPixelBuffer(
      pixelBuffer: try #require(pixelBuffer)
    )

    #expect(throws: CVPixelBufferError.unsupportedAccess(.write)) {
      try openBuffer.withWriteBytes { _ in }
    }
  }

  @Test("Native pixel storage is released exactly once with the wrapper")
  func nativeOwnerLifetime() throws {
    // The native pixel buffer exclusively owns these initialized bytes after
    // creation succeeds. The release context contributes one retain and the C
    // callback consumes it exactly once, records the release, and deallocates
    // the original aligned base address. Neither pointer escapes the callback.
    let byteCount = 32
    let bytes = UnsafeMutableRawPointer.allocate(
      byteCount: byteCount,
      alignment: 16
    )
    bytes.initializeMemory(
      as: UInt8.self,
      repeating: 0x4D,
      count: byteCount
    )
    let releaseProbe = NativePixelReleaseProbe()
    let releaseContext = Unmanaged
      .passRetained(releaseProbe)
      .toOpaque()
    var pixelBuffer: CoreVideo.CVPixelBuffer?
    let status = CVPixelBufferCreateWithBytes(
      nil,
      4,
      2,
      kCVPixelFormatType_32BGRA,
      bytes,
      16,
      { releaseContext, baseAddress in
        guard let releaseContext else {
          return
        }
        let probe = Unmanaged<NativePixelReleaseProbe>
          .fromOpaque(releaseContext)
          .takeRetainedValue()
        probe.recordRelease()
        if let baseAddress {
          UnsafeMutableRawPointer(mutating: baseAddress).deallocate()
        }
      },
      releaseContext,
      nil,
      &pixelBuffer
    )
    guard status == CoreVideo.kCVReturnSuccess else {
      Unmanaged<NativePixelReleaseProbe>
        .fromOpaque(releaseContext)
        .release()
      bytes.deallocate()
      Issue.record("Could not create a callback-backed pixel buffer")
      return
    }

    func wrapper() throws -> AppleCameraPixelBuffer {
      let nativeBuffer = try #require(pixelBuffer)
      let result = try AppleCameraPixelBuffer(
        pixelBuffer: nativeBuffer
      )
      pixelBuffer = nil
      return result
    }

    var openBuffer: AppleCameraPixelBuffer? = try wrapper()
    #expect(releaseProbe.releaseCount == 0)
    openBuffer = nil
    #expect(openBuffer == nil)
    #expect(releaseProbe.releaseCount == 1)
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
    #expect(status == CoreVideo.kCVReturnSuccess)
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
    #expect(lockStatus == CoreVideo.kCVReturnSuccess)
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

  @Test("Metal texture projection retains the exact native buffer")
  func metalTextureProjectionLifetime() throws {
    let metalDevice = try #require(MTLCreateSystemDefaultDevice())
    var textureCache: CVMetalTextureCache?
    let cacheStatus = CVMetalTextureCacheCreate(
      nil,
      nil,
      metalDevice,
      nil,
      &textureCache
    )
    #expect(cacheStatus == CoreVideo.kCVReturnSuccess)
    let cache = try #require(textureCache)

    let attributes = [
      kCVPixelBufferMetalCompatibilityKey: true,
      kCVPixelBufferIOSurfacePropertiesKey: [:],
    ] as CFDictionary
    var nativePixelBuffer: CoreVideo.CVPixelBuffer?
    let pixelStatus = CVPixelBufferCreate(
      nil,
      16,
      8,
      kCVPixelFormatType_32BGRA,
      attributes,
      &nativePixelBuffer
    )
    #expect(pixelStatus == CoreVideo.kCVReturnSuccess)
    let original = try #require(nativePixelBuffer)
    let originalIdentity = ObjectIdentifier(original)
    let openBuffer = try AppleCameraPixelBuffer(
      pixelBuffer: original
    )
    nativePixelBuffer = nil

    var projectedIdentity: ObjectIdentifier?
    var projectionStatus: CVReturn?
    var metalTexture: MTLTexture?
    openBuffer.withCoreVideoPixelBuffer { borrowedBuffer in
      projectedIdentity = ObjectIdentifier(borrowedBuffer)
      var projectedTexture: CVMetalTexture?
      projectionStatus = CVMetalTextureCacheCreateTextureFromImage(
        nil,
        cache,
        borrowedBuffer,
        nil,
        .bgra8Unorm,
        16,
        8,
        0,
        &projectedTexture
      )
      if let projectedTexture {
        metalTexture = CVMetalTextureGetTexture(projectedTexture)
      }
    }

    #expect(projectedIdentity == originalIdentity)
    #expect(projectionStatus == CoreVideo.kCVReturnSuccess)
    #expect(metalTexture != nil)
  }
}

private final class NativePixelReleaseProbe: Sendable {
  private let releaseCountState = Mutex(0)

  var releaseCount: Int {
    releaseCountState.withLock { $0 }
  }

  func recordRelease() {
    releaseCountState.withLock { releaseCount in
      releaseCount += 1
    }
  }
}
