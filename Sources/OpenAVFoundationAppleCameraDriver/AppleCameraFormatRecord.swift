import OpenAVFoundationDriver

struct AppleCameraFormatRecord: Sendable, Equatable {
  let nativeIndex: Int
  let mediaSubtype: UInt32
  let dimensions: CaptureDimensions
  let frameRateRanges: [CaptureFrameRateRange]
  let isActive: Bool
}
