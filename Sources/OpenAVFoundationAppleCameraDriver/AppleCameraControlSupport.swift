import OpenAVFoundationDriver

struct AppleCameraControlSupport: Sendable, Equatable {
  var focusModes: [CaptureFocusMode]
  var supportsFocusPoint: Bool
  var exposureModes: [CaptureExposureMode]
  var supportsExposurePoint: Bool
  var whiteBalanceModes: [CaptureWhiteBalanceMode]
}
