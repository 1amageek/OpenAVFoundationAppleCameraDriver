import CoreMedia
import CoreVideo
import OpenAVFoundationDriver

enum AppleCameraTestFixtures {
  static func format(
    width: Int,
    height: Int,
    pixelFormat: OSType = kCVPixelFormatType_32BGRA
  ) throws -> CaptureDeviceFormatDescriptor {
    CaptureDeviceFormatDescriptor(
      formatID: try CaptureDeviceFormatID(
        "\(pixelFormat)-\(width)x\(height)"
      ),
      mediaType: .video,
      mediaSubtype: CaptureMediaSubtype(
        rawValue: UInt32(pixelFormat)
      ),
      dimensions: try CaptureDimensions(
        width: width,
        height: height
      )
    )
  }

  static func sampleBuffer(
    width: Int,
    height: Int,
    pixelFormat: OSType = kCVPixelFormatType_32BGRA,
    fillByte: UInt8 = 0
  ) throws -> CoreMedia.CMSampleBuffer {
    var pixelBuffer: CoreVideo.CVPixelBuffer?
    let pixelStatus = CVPixelBufferCreate(
      nil,
      width,
      height,
      pixelFormat,
      nil,
      &pixelBuffer
    )
    guard pixelStatus == CoreVideo.kCVReturnSuccess,
      let pixelBuffer
    else {
      throw FixtureError.pixelBufferCreation(pixelStatus)
    }

    let lockStatus = CVPixelBufferLockBaseAddress(pixelBuffer, [])
    guard lockStatus == CoreVideo.kCVReturnSuccess else {
      throw FixtureError.pixelBufferLock(lockStatus)
    }
    if CVPixelBufferIsPlanar(pixelBuffer) {
      for index in 0..<CVPixelBufferGetPlaneCount(pixelBuffer) {
        guard
          let baseAddress =
            CVPixelBufferGetBaseAddressOfPlane(
              pixelBuffer,
              index
            )
        else {
          CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
          throw FixtureError.missingBaseAddress
        }
        let byteCount =
          CVPixelBufferGetBytesPerRowOfPlane(
            pixelBuffer,
            index
          ) * CVPixelBufferGetHeightOfPlane(pixelBuffer, index)
        baseAddress.initializeMemory(
          as: UInt8.self,
          repeating: fillByte,
          count: byteCount
        )
      }
    } else {
      guard
        let baseAddress = CVPixelBufferGetBaseAddress(
          pixelBuffer
        )
      else {
        CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
        throw FixtureError.missingBaseAddress
      }
      baseAddress.initializeMemory(
        as: UInt8.self,
        repeating: fillByte,
        count: CVPixelBufferGetDataSize(pixelBuffer)
      )
    }
    let unlockStatus = CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
    guard unlockStatus == CoreVideo.kCVReturnSuccess else {
      throw FixtureError.pixelBufferUnlock(unlockStatus)
    }

    var formatDescription: CoreMedia.CMVideoFormatDescription?
    let formatStatus = CMVideoFormatDescriptionCreateForImageBuffer(
      allocator: nil,
      imageBuffer: pixelBuffer,
      formatDescriptionOut: &formatDescription
    )
    guard formatStatus == noErr, let formatDescription else {
      throw FixtureError.formatDescriptionCreation(formatStatus)
    }

    var timing = CoreMedia.CMSampleTimingInfo(
      duration: CoreMedia.CMTime(value: 1, timescale: 30),
      presentationTimeStamp:
        CoreMedia.CMTime(value: 10, timescale: 30),
      decodeTimeStamp: .invalid
    )
    var sampleBuffer: CoreMedia.CMSampleBuffer?
    let sampleStatus = CMSampleBufferCreateReadyWithImageBuffer(
      allocator: nil,
      imageBuffer: pixelBuffer,
      formatDescription: formatDescription,
      sampleTiming: &timing,
      sampleBufferOut: &sampleBuffer
    )
    guard sampleStatus == noErr, let sampleBuffer else {
      throw FixtureError.sampleBufferCreation(sampleStatus)
    }
    return sampleBuffer
  }
}

enum FixtureError: Error {
  case pixelBufferCreation(CVReturn)
  case pixelBufferLock(CVReturn)
  case missingBaseAddress
  case pixelBufferUnlock(CVReturn)
  case formatDescriptionCreation(OSStatus)
  case sampleBufferCreation(OSStatus)
}
