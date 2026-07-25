import CoreMedia
import CoreVideo
import OpenAVFoundationDriver
import Testing

@testable import OpenAVFoundationAppleCameraDriver

@Suite("Apple camera format and control configuration")
struct AppleCameraConfigurationTests {
  @Test("Every native format record receives a stable unique identifier")
  func formatEnumeration() throws {
    let dimensions = try CaptureDimensions(width: 1_920, height: 1_080)
    let ranges = [
      try CaptureFrameRateRange(minimum: 24, maximum: 30),
      try CaptureFrameRateRange(minimum: 30, maximum: 60),
    ]
    let records = [
      AppleCameraFormatRecord(
        nativeIndex: 4,
        mediaSubtype: kCVPixelFormatType_32BGRA,
        dimensions: dimensions,
        frameRateRanges: ranges,
        isActive: false
      ),
      AppleCameraFormatRecord(
        nativeIndex: 9,
        mediaSubtype: kCVPixelFormatType_32BGRA,
        dimensions: dimensions,
        frameRateRanges: ranges,
        isActive: true
      ),
    ]

    let descriptors = try AppleCameraSnapshotFactory
      .formatDescriptors(from: records)
    #expect(descriptors.count == 2)
    #expect(descriptors[0].formatID != descriptors[1].formatID)
    #expect(descriptors[0].frameRateRanges == ranges)
    #expect(
      AppleCameraSnapshotFactory.preferredFormatIndex(
        in: records
      ) == 1
    )
  }

  @Test("The first supported format is preferred without an active match")
  func preferredFormatFallback() throws {
    let record = AppleCameraFormatRecord(
      nativeIndex: 2,
      mediaSubtype: kCVPixelFormatType_32BGRA,
      dimensions: try CaptureDimensions(width: 640, height: 480),
      frameRateRanges: [],
      isActive: false
    )

    #expect(
      AppleCameraSnapshotFactory.preferredFormatIndex(
        in: [record]
      ) == 0
    )
    #expect(
      AppleCameraSnapshotFactory.preferredFormatIndex(in: []) == nil
    )
  }

  @Test("macOS capabilities advertise modes and points without custom values")
  func controlCapabilities() throws {
    let support = AppleCameraControlSupport(
      focusModes: [.locked, .continuousAutoFocus],
      supportsFocusPoint: true,
      exposureModes: [.locked, .continuousAutoExposure],
      supportsExposurePoint: true,
      whiteBalanceModes: [.locked, .continuousAutoWhiteBalance]
    )

    let capabilities = try AppleCameraControlCapabilitiesFactory
      .capabilities(from: support)
    #expect(
      capabilities.focus?.supportedModes
        == [.locked, .continuousAutoFocus]
    )
    #expect(capabilities.focus?.supportsPointOfInterest == true)
    #expect(capabilities.focus?.lensPositionRange == nil)
    #expect(capabilities.exposure?.supportsPointOfInterest == true)
    #expect(capabilities.exposure?.durationRange == nil)
    #expect(capabilities.exposure?.isoRange == nil)
    #expect(capabilities.whiteBalance?.gainRange == nil)
    #expect(capabilities.zoom == nil)
  }

  @Test("No native control support maps to no portable controls")
  func noControlCapabilities() throws {
    let support = AppleCameraControlSupport(
      focusModes: [],
      supportsFocusPoint: false,
      exposureModes: [],
      supportsExposurePoint: false,
      whiteBalanceModes: []
    )

    let capabilities = try AppleCameraControlCapabilitiesFactory
      .capabilities(from: support)
    #expect(capabilities == .none)
  }

  @Test("Mode and point controls pass portable validation")
  func supportedPortableControls() throws {
    let point = try CaptureNormalizedPoint(x: 0.25, y: 0.75)
    let controls = try CaptureDeviceControls(
      focus: try CaptureFocusConfiguration(
        mode: .continuousAutoFocus,
        pointOfInterest: point
      ),
      exposure: try CaptureExposureConfiguration(
        mode: .continuousAutoExposure,
        pointOfInterest: point
      ),
      whiteBalance: try CaptureWhiteBalanceConfiguration(
        mode: .continuousAutoWhiteBalance
      )
    )

    try AppleCameraDeviceConfigurationBridge.validatePortable(
      controls: controls,
      deviceID: try deviceID()
    )
  }

  @Test("macOS-unavailable custom values fail with typed control errors")
  func unsupportedPortableValues() throws {
    let deviceID = try deviceID()
    let focus = try CaptureDeviceControls(
      focus: try CaptureFocusConfiguration(
        mode: .locked,
        lensPosition: 0.5
      )
    )
    #expect(
      throws: CaptureDriverError.unsupportedControlValue(
        deviceID: deviceID,
        controlID: .focus
      )
    ) {
      try AppleCameraDeviceConfigurationBridge.validatePortable(
        controls: focus,
        deviceID: deviceID
      )
    }

    let exposure = try CaptureDeviceControls(
      exposure: try CaptureExposureConfiguration(
        mode: .custom,
        duration: CMTime(value: 1, timescale: 30),
        iso: 100
      )
    )
    #expect(
      throws: CaptureDriverError.unsupportedControlValue(
        deviceID: deviceID,
        controlID: .exposure
      )
    ) {
      try AppleCameraDeviceConfigurationBridge.validatePortable(
        controls: exposure,
        deviceID: deviceID
      )
    }

    let whiteBalance = try CaptureDeviceControls(
      whiteBalance: try CaptureWhiteBalanceConfiguration(
        mode: .locked,
        gains: try CaptureWhiteBalanceGains(
          red: 1,
          green: 1,
          blue: 1
        )
      )
    )
    #expect(
      throws: CaptureDriverError.unsupportedControlValue(
        deviceID: deviceID,
        controlID: .whiteBalance
      )
    ) {
      try AppleCameraDeviceConfigurationBridge.validatePortable(
        controls: whiteBalance,
        deviceID: deviceID
      )
    }

    let zoom = try CaptureDeviceControls(
      zoom: try CaptureZoomConfiguration(factor: 2)
    )
    #expect(
      throws: CaptureDriverError.unsupportedControl(
        deviceID: deviceID,
        controlID: .zoom
      )
    ) {
      try AppleCameraDeviceConfigurationBridge.validatePortable(
        controls: zoom,
        deviceID: deviceID
      )
    }
  }

  @Test("Rollback failures invalidate every later backend operation")
  func rollbackFailuresInvalidateBackend() throws {
    let deviceID = try deviceID()
    let driverID = deviceID.driverID
    var configurationFailure = AppleCameraBackendLifecycle()
    configurationFailure.invalidateAfterConfigurationRollback()
    #expect(
      throws: CaptureDriverError.backendFailure(
        driverID: driverID,
        deviceID: deviceID,
        operation: .configuration,
        code: 2
      )
    ) {
      try configurationFailure.requireAvailable(
        driverID: driverID,
        deviceID: deviceID
      )
    }

    var topologyFailure = AppleCameraBackendLifecycle()
    topologyFailure.invalidateAfterTopologyRollback()
    #expect(
      throws: CaptureDriverError.backendFailure(
        driverID: driverID,
        deviceID: deviceID,
        operation: .configuration,
        code: 3
      )
    ) {
      try topologyFailure.requireAvailable(
        driverID: driverID,
        deviceID: deviceID
      )
    }
    // A failed cleanup attempt does not call finishShutdown, so the retained
    // invalidated backend remains available for one more cleanup attempt.
    #expect(
      throws: CaptureDriverError.backendFailure(
        driverID: driverID,
        deviceID: deviceID,
        operation: .configuration,
        code: 3
      )
    ) {
      try topologyFailure.requireAvailable(
        driverID: driverID,
        deviceID: deviceID
      )
    }
    // A later successful cleanup performs the single terminal transition.
    topologyFailure.finishShutdown()
    topologyFailure.finishShutdown()
    #expect(
      throws: CaptureDriverError.deviceDisconnected(deviceID)
    ) {
      try topologyFailure.requireAvailable(
        driverID: driverID,
        deviceID: deviceID
      )
    }
  }

  private func deviceID() throws -> CaptureDeviceID {
    try CaptureDeviceID(
      driverID: CaptureDriverID("apple.test.configuration"),
      localID: "camera"
    )
  }
}
