@preconcurrency import AVFoundation
import AppleCameraExceptionBridge
import CoreMedia
import OpenAVFoundationDriver

enum AppleCameraDeviceConfigurationBridge {
  static func apply(
    format: AVFoundation.AVCaptureDevice.Format,
    frameRate: Double?,
    controls: CaptureDeviceControls,
    restoreAutoFrameRate: Bool,
    formatID: CaptureDeviceFormatID,
    driverID: CaptureDriverID,
    deviceID: CaptureDeviceID,
    device: AVFoundation.AVCaptureDevice,
    input: AVFoundation.AVCaptureDeviceInput
  ) throws(CaptureDriverError) {
    try validatePortable(controls: controls, deviceID: deviceID)
    let focus = try focusConfiguration(
      controls.focus,
      deviceID: deviceID
    )
    let exposure = try exposureConfiguration(
      controls.exposure,
      deviceID: deviceID
    )
    let whiteBalance = try whiteBalanceConfiguration(
      controls.whiteBalance,
      deviceID: deviceID
    )
    guard controls.zoom == nil else {
      throw .unsupportedControl(
        deviceID: deviceID,
        controlID: .zoom
      )
    }
    guard controls.deviceSpecific.isEmpty else {
      throw .unsupportedControl(
        deviceID: deviceID,
        controlID: controls.deviceSpecific[0].controlID
      )
    }

    let duration = frameRate.map(
      AppleCameraFrameDurationBridge.frameDuration(for:)
    ) ?? .invalid
    var errorCode: Int64 = 0
    let result = OAVApplyDeviceConfiguration(
      device,
      input,
      format,
      duration,
      frameRate != nil,
      restoreAutoFrameRate,
      focus,
      exposure,
      whiteBalance,
      &errorCode
    )

    switch result.rawValue {
    case 0:
      return
    case 1:
      throw .unsupportedFormat(
        deviceID: deviceID,
        formatID: formatID
      )
    case 2:
      if let frameRate {
        throw .unsupportedFrameRate(
          deviceID: deviceID,
          formatID: formatID,
          frameRate: frameRate
        )
      }
      throw backendFailure(
        result: Int64(result.rawValue),
        errorCode: errorCode,
        driverID: driverID,
        deviceID: deviceID
      )
    case 3:
      throw .unsupportedControl(
        deviceID: deviceID,
        controlID: try controlID(
          for: errorCode,
          driverID: driverID,
          deviceID: deviceID
        )
      )
    case 4, 5, 6:
      throw backendFailure(
        result: Int64(result.rawValue),
        errorCode: errorCode,
        driverID: driverID,
        deviceID: deviceID
      )
    default:
      throw backendFailure(
        result: Int64(result.rawValue),
        errorCode: errorCode,
        driverID: driverID,
        deviceID: deviceID
      )
    }
  }

  static func validatePortable(
    controls: CaptureDeviceControls,
    deviceID: CaptureDeviceID
  ) throws(CaptureDriverError) {
    _ = try focusConfiguration(controls.focus, deviceID: deviceID)
    _ = try exposureConfiguration(
      controls.exposure,
      deviceID: deviceID
    )
    _ = try whiteBalanceConfiguration(
      controls.whiteBalance,
      deviceID: deviceID
    )
    guard controls.zoom == nil else {
      throw .unsupportedControl(
        deviceID: deviceID,
        controlID: .zoom
      )
    }
    guard controls.deviceSpecific.isEmpty else {
      throw .unsupportedControl(
        deviceID: deviceID,
        controlID: controls.deviceSpecific[0].controlID
      )
    }
  }

  static func validate(
    controls: CaptureDeviceControls,
    deviceID: CaptureDeviceID,
    device: AVFoundation.AVCaptureDevice
  ) throws(CaptureDriverError) {
    if let focus = controls.focus {
      guard
        device.focusMode == nativeFocusMode(focus.mode),
        focus.pointOfInterest.map({
          pointsMatch(
            device.focusPointOfInterest,
            x: $0.x,
            y: $0.y
          )
        }) ?? true
      else {
        throw .unsupportedControlValue(
          deviceID: deviceID,
          controlID: .focus
        )
      }
    }
    if let exposure = controls.exposure {
      guard
        device.exposureMode == nativeExposureMode(exposure.mode),
        exposure.pointOfInterest.map({
          pointsMatch(
            device.exposurePointOfInterest,
            x: $0.x,
            y: $0.y
          )
        }) ?? true
      else {
        throw .unsupportedControlValue(
          deviceID: deviceID,
          controlID: .exposure
        )
      }
    }
    if let whiteBalance = controls.whiteBalance {
      guard
        device.whiteBalanceMode
          == nativeWhiteBalanceMode(whiteBalance.mode)
      else {
        throw .unsupportedControlValue(
          deviceID: deviceID,
          controlID: .whiteBalance
        )
      }
    }
  }

  private static func focusConfiguration(
    _ configuration: CaptureFocusConfiguration?,
    deviceID: CaptureDeviceID
  ) throws(CaptureDriverError) -> OAVModeControlConfiguration {
    guard let configuration else {
      return disabledConfiguration()
    }
    guard configuration.lensPosition == nil else {
      throw .unsupportedControlValue(
        deviceID: deviceID,
        controlID: .focus
      )
    }
    return modeConfiguration(
      mode: nativeFocusMode(configuration.mode).rawValue,
      point: configuration.pointOfInterest
    )
  }

  private static func exposureConfiguration(
    _ configuration: CaptureExposureConfiguration?,
    deviceID: CaptureDeviceID
  ) throws(CaptureDriverError) -> OAVModeControlConfiguration {
    guard let configuration else {
      return disabledConfiguration()
    }
    guard configuration.duration == nil, configuration.iso == nil else {
      throw .unsupportedControlValue(
        deviceID: deviceID,
        controlID: .exposure
      )
    }
    return modeConfiguration(
      mode: nativeExposureMode(configuration.mode).rawValue,
      point: configuration.pointOfInterest
    )
  }

  private static func whiteBalanceConfiguration(
    _ configuration: CaptureWhiteBalanceConfiguration?,
    deviceID: CaptureDeviceID
  ) throws(CaptureDriverError) -> OAVModeControlConfiguration {
    guard let configuration else {
      return disabledConfiguration()
    }
    guard configuration.gains == nil else {
      throw .unsupportedControlValue(
        deviceID: deviceID,
        controlID: .whiteBalance
      )
    }
    return modeConfiguration(
      mode: nativeWhiteBalanceMode(configuration.mode).rawValue,
      point: nil
    )
  }

  private static func modeConfiguration(
    mode: Int,
    point: CaptureNormalizedPoint?
  ) -> OAVModeControlConfiguration {
    OAVModeControlConfiguration(
      enabled: ObjCBool(true),
      mode: mode,
      pointEnabled: ObjCBool(point != nil),
      pointX: point?.x ?? 0,
      pointY: point?.y ?? 0
    )
  }

  private static func disabledConfiguration()
    -> OAVModeControlConfiguration
  {
    OAVModeControlConfiguration(
      enabled: ObjCBool(false),
      mode: 0,
      pointEnabled: ObjCBool(false),
      pointX: 0,
      pointY: 0
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

  private static func pointsMatch(
    _ point: CGPoint,
    x: Double,
    y: Double
  ) -> Bool {
    point.x == x && point.y == y
  }

  private static func controlID(
    for errorCode: Int64,
    driverID: CaptureDriverID,
    deviceID: CaptureDeviceID
  ) throws(CaptureDriverError) -> CaptureDeviceControlID {
    switch errorCode {
    case 1:
      .focus
    case 2:
      .exposure
    case 3:
      .whiteBalance
    default:
      throw .backendFailure(
        driverID: driverID,
        deviceID: deviceID,
        operation: .configuration,
        code: errorCode
      )
    }
  }

  private static func backendFailure(
    result: Int64,
    errorCode: Int64,
    driverID: CaptureDriverID,
    deviceID: CaptureDeviceID
  ) -> CaptureDriverError {
    .backendFailure(
      driverID: driverID,
      deviceID: deviceID,
      operation: .configuration,
      code: errorCode == 0 ? result : errorCode
    )
  }
}
