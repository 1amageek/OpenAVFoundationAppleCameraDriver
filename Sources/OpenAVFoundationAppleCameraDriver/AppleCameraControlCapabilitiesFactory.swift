@preconcurrency import AVFoundation
import OpenAVFoundationDriver

enum AppleCameraControlCapabilitiesFactory {
  static func capabilities(
    for device: AVFoundation.AVCaptureDevice
  ) throws(CaptureContractError) -> CaptureDeviceControlCapabilities {
    try capabilities(from: support(for: device))
  }

  static func capabilities(
    from support: AppleCameraControlSupport
  ) throws(CaptureContractError) -> CaptureDeviceControlCapabilities {
    let focus = support.focusModes.isEmpty
      ? nil
      : try CaptureFocusCapabilities(
        supportedModes: support.focusModes,
        lensPositionRange: nil,
        supportsPointOfInterest: support.supportsFocusPoint
      )
    let exposure = support.exposureModes.isEmpty
      ? nil
      : try CaptureExposureCapabilities(
        supportedModes: support.exposureModes,
        durationRange: nil,
        isoRange: nil,
        supportsPointOfInterest: support.supportsExposurePoint
      )
    let whiteBalance = support.whiteBalanceModes.isEmpty
      ? nil
      : try CaptureWhiteBalanceCapabilities(
        supportedModes: support.whiteBalanceModes,
        gainRange: nil
      )
    return try CaptureDeviceControlCapabilities(
      focus: focus,
      exposure: exposure,
      whiteBalance: whiteBalance,
      zoom: nil
    )
  }

  static func currentConfiguration(
    for device: AVFoundation.AVCaptureDevice
  ) throws(CaptureContractError) -> CaptureDeviceControls {
    let support = support(for: device)
    let focus = support.focusModes.isEmpty
      ? nil
      : try CaptureFocusConfiguration(
        mode: try portableFocusMode(device.focusMode),
        pointOfInterest: support.supportsFocusPoint
          ? try CaptureNormalizedPoint(
            x: device.focusPointOfInterest.x,
            y: device.focusPointOfInterest.y
          )
          : nil
      )
    let exposure = support.exposureModes.isEmpty
      ? nil
      : try CaptureExposureConfiguration(
        mode: try portableExposureMode(device.exposureMode),
        pointOfInterest: support.supportsExposurePoint
          ? try CaptureNormalizedPoint(
            x: device.exposurePointOfInterest.x,
            y: device.exposurePointOfInterest.y
          )
          : nil
      )
    let whiteBalance = support.whiteBalanceModes.isEmpty
      ? nil
      : try CaptureWhiteBalanceConfiguration(
        mode: try portableWhiteBalanceMode(device.whiteBalanceMode)
      )
    return try CaptureDeviceControls(
      focus: focus,
      exposure: exposure,
      whiteBalance: whiteBalance,
      zoom: nil
    )
  }

  private static func support(
    for device: AVFoundation.AVCaptureDevice
  ) -> AppleCameraControlSupport {
    AppleCameraControlSupport(
      focusModes: CaptureFocusMode.allCases.filter {
        device.isFocusModeSupported(nativeFocusMode($0))
      },
      supportsFocusPoint: device.isFocusPointOfInterestSupported,
      exposureModes: CaptureExposureMode.allCases.filter {
        device.isExposureModeSupported(nativeExposureMode($0))
      },
      supportsExposurePoint:
        device.isExposurePointOfInterestSupported,
      whiteBalanceModes: CaptureWhiteBalanceMode.allCases.filter {
        device.isWhiteBalanceModeSupported(
          nativeWhiteBalanceMode($0)
        )
      }
    )
  }

  private static func nativeFocusMode(
    _ mode: CaptureFocusMode
  ) -> AVFoundation.AVCaptureDevice.FocusMode {
    switch mode {
    case .locked:
      .locked
    case .autoFocus:
      .autoFocus
    case .continuousAutoFocus:
      .continuousAutoFocus
    }
  }

  private static func nativeExposureMode(
    _ mode: CaptureExposureMode
  ) -> AVFoundation.AVCaptureDevice.ExposureMode {
    switch mode {
    case .locked:
      .locked
    case .autoExpose:
      .autoExpose
    case .continuousAutoExposure:
      .continuousAutoExposure
    case .custom:
      .custom
    }
  }

  private static func nativeWhiteBalanceMode(
    _ mode: CaptureWhiteBalanceMode
  ) -> AVFoundation.AVCaptureDevice.WhiteBalanceMode {
    switch mode {
    case .locked:
      .locked
    case .autoWhiteBalance:
      .autoWhiteBalance
    case .continuousAutoWhiteBalance:
      .continuousAutoWhiteBalance
    }
  }

  private static func portableFocusMode(
    _ mode: AVFoundation.AVCaptureDevice.FocusMode
  ) throws(CaptureContractError) -> CaptureFocusMode {
    switch mode {
    case .locked:
      .locked
    case .autoFocus:
      .autoFocus
    case .continuousAutoFocus:
      .continuousAutoFocus
    @unknown default:
      throw .invalidControlConfiguration(.focus)
    }
  }

  private static func portableExposureMode(
    _ mode: AVFoundation.AVCaptureDevice.ExposureMode
  ) throws(CaptureContractError) -> CaptureExposureMode {
    switch mode {
    case .locked:
      .locked
    case .autoExpose:
      .autoExpose
    case .continuousAutoExposure:
      .continuousAutoExposure
    case .custom:
      .custom
    @unknown default:
      throw .invalidControlConfiguration(.exposure)
    }
  }

  private static func portableWhiteBalanceMode(
    _ mode: AVFoundation.AVCaptureDevice.WhiteBalanceMode
  ) throws(CaptureContractError) -> CaptureWhiteBalanceMode {
    switch mode {
    case .locked:
      .locked
    case .autoWhiteBalance:
      .autoWhiteBalance
    case .continuousAutoWhiteBalance:
      .continuousAutoWhiteBalance
    @unknown default:
      throw .invalidControlConfiguration(.whiteBalance)
    }
  }
}

private extension CaptureFocusMode {
  static let allCases: [Self] = [
    .locked,
    .autoFocus,
    .continuousAutoFocus,
  ]
}

private extension CaptureExposureMode {
  static let allCases: [Self] = [
    .locked,
    .autoExpose,
    .continuousAutoExposure,
    .custom,
  ]
}

private extension CaptureWhiteBalanceMode {
  static let allCases: [Self] = [
    .locked,
    .autoWhiteBalance,
    .continuousAutoWhiteBalance,
  ]
}
