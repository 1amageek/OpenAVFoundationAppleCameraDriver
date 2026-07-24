import CoreMedia
import CoreVideo
import OpenAVFoundationDriver
import OpenCoreMedia
import OpenCoreVideo

struct AppleSampleBufferBridge: Sendable {
  typealias ImageBuffer = AppleCameraPixelBuffer
  typealias FormatDescription =
    OpenCoreMedia.CMImmutableVideoFormatDescription
  typealias SampleBuffer = OpenCoreMedia.CMImageSampleBuffer<
    ImageBuffer,
    FormatDescription
  >

  private let expectedDimensions: OpenCoreVideo.CVPixelDimensions
  private let expectedPixelFormat: OpenCoreVideo.CVPixelFormatType
  private let formatDescription: FormatDescription

  init(
    format: CaptureDeviceFormatDescriptor
  ) throws(AppleSampleBridgeError) {
    let expectedPixelFormat: OpenCoreVideo.CVPixelFormatType
    switch OSType(format.mediaSubtype.rawValue) {
    case kCVPixelFormatType_32BGRA:
      expectedPixelFormat = .bgra32
    case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange:
      expectedPixelFormat = .yCbCr420BiPlanarVideoRange
    case kCVPixelFormatType_420YpCbCr8BiPlanarFullRange:
      expectedPixelFormat = .yCbCr420BiPlanarFullRange
    default:
      throw .unsupportedPixelFormat(
        OSType(format.mediaSubtype.rawValue)
      )
    }
    guard let dimensions = format.dimensions else {
      throw .missingExpectedDimensions
    }

    let expectedDimensions: OpenCoreVideo.CVPixelDimensions
    do {
      expectedDimensions = try OpenCoreVideo.CVPixelDimensions(
        width: dimensions.width,
        height: dimensions.height
      )
    } catch {
      throw .pixelBuffer(error)
    }
    self.expectedDimensions = expectedDimensions
    self.expectedPixelFormat = expectedPixelFormat
    formatDescription = FormatDescription(
      dimensions: expectedDimensions,
      pixelFormat: expectedPixelFormat
    )
  }

  func sample(
    from sampleBuffer: CoreMedia.CMSampleBuffer
  ) throws(AppleSampleBridgeError) -> SampleBuffer {
    guard
      let pixelBuffer = CMSampleBufferGetImageBuffer(
        sampleBuffer
      )
    else {
      throw .missingImageBuffer
    }
    let actualPixelFormat = OpenCoreVideo.CVPixelFormatType(
      rawValue: CVPixelBufferGetPixelFormatType(pixelBuffer)
    )
    guard actualPixelFormat == expectedPixelFormat else {
      throw .unsupportedPixelFormat(
        CVPixelBufferGetPixelFormatType(pixelBuffer)
      )
    }
    let actualWidth = CVPixelBufferGetWidth(pixelBuffer)
    let actualHeight = CVPixelBufferGetHeight(pixelBuffer)
    guard actualWidth == expectedDimensions.width,
      actualHeight == expectedDimensions.height
    else {
      throw .unexpectedDimensions(
        expectedWidth: expectedDimensions.width,
        expectedHeight: expectedDimensions.height,
        actualWidth: actualWidth,
        actualHeight: actualHeight
      )
    }

    let imageBuffer: ImageBuffer
    do {
      imageBuffer = try AppleCameraPixelBuffer(
        pixelBuffer: pixelBuffer
      )
    } catch {
      throw .pixelBuffer(error)
    }

    let timing = OpenCoreMedia.CMSampleTimingInfo(
      duration: Self.portableTime(
        CMSampleBufferGetDuration(sampleBuffer)
      ),
      presentationTimeStamp: Self.portableTime(
        CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
      ),
      decodeTimeStamp: Self.portableTime(
        CMSampleBufferGetDecodeTimeStamp(sampleBuffer)
      )
    )
    do {
      return try SampleBuffer(
        imageBuffer: imageBuffer,
        formatDescription: formatDescription,
        timing: [timing]
      )
    } catch {
      throw .sampleBuffer(error)
    }
  }

  private static func portableTime(
    _ time: CoreMedia.CMTime
  ) -> OpenCoreMedia.CMTime {
    OpenCoreMedia.CMTime(
      value: time.value,
      timescale: time.timescale,
      flags: OpenCoreMedia.CMTimeFlags(
        rawValue: time.flags.rawValue
      ),
      epoch: time.epoch
    )
  }
}

enum AppleSampleBridgeError: Error, Sendable {
  case missingImageBuffer
  case missingExpectedDimensions
  case unsupportedPixelFormat(OSType)
  case unexpectedDimensions(
    expectedWidth: Int,
    expectedHeight: Int,
    actualWidth: Int,
    actualHeight: Int
  )
  case pixelBuffer(OpenCoreVideo.CVPixelBufferError)
  case sampleBuffer(OpenCoreMedia.CMSampleBufferError)

  var code: Int64 {
    switch self {
    case .missingImageBuffer:
      2_001
    case .missingExpectedDimensions:
      2_002
    case .unsupportedPixelFormat:
      2_003
    case .unexpectedDimensions:
      2_004
    case .pixelBuffer:
      2_005
    case .sampleBuffer:
      2_006
    }
  }
}
