@preconcurrency import AVFoundation
import OpenAVFoundationDriver

enum AppleCameraVideoConnectionBridge {
  static func capabilities()
    throws(CaptureContractError) -> CaptureVideoConnectionCapabilities
  {
    try CaptureVideoConnectionCapabilities(
      supportedOrientations: [
        .portrait,
        .portraitUpsideDown,
        .landscapeRight,
        .landscapeLeft,
      ],
      supportedStabilizationModes: [],
      supportedMirroringModes: [
        .automatic,
        .enabled,
        .disabled,
      ]
    )
  }

  static func apply(
    _ configuration: CaptureVideoConnectionConfiguration,
    to connection: AVFoundation.AVCaptureConnection,
    deviceID: CaptureDeviceID,
    streamID: CaptureStreamID
  ) throws(CaptureDriverError) {
    if let orientation = configuration.orientation {
      let angle = rotationAngle(for: orientation)
      guard connection.isVideoRotationAngleSupported(angle) else {
        throw .unsupportedVideoOrientation(
          deviceID: deviceID,
          streamID: streamID,
          orientation: orientation
        )
      }
      connection.videoRotationAngle = angle
    }
    if let mode = configuration.stabilizationMode {
      throw .unsupportedVideoStabilizationMode(
        deviceID: deviceID,
        streamID: streamID,
        mode: mode
      )
    }
    if let mode = configuration.mirroringMode {
      guard connection.isVideoMirroringSupported else {
        throw .unsupportedVideoMirroringMode(
          deviceID: deviceID,
          streamID: streamID,
          mode: mode
        )
      }
      switch mode {
      case .automatic:
        connection.automaticallyAdjustsVideoMirroring = true
      case .enabled:
        connection.automaticallyAdjustsVideoMirroring = false
        connection.isVideoMirrored = true
      case .disabled:
        connection.automaticallyAdjustsVideoMirroring = false
        connection.isVideoMirrored = false
      }
    }
    try validate(
      configuration,
      on: connection,
      deviceID: deviceID,
      streamID: streamID
    )
  }

  static func validate(
    _ configuration: CaptureVideoConnectionConfiguration,
    on connection: AVFoundation.AVCaptureConnection,
    deviceID: CaptureDeviceID,
    streamID: CaptureStreamID
  ) throws(CaptureDriverError) {
    if let orientation = configuration.orientation {
      let expectedAngle = rotationAngle(for: orientation)
      guard connection.videoRotationAngle == expectedAngle else {
        throw .unsupportedVideoOrientation(
          deviceID: deviceID,
          streamID: streamID,
          orientation: orientation
        )
      }
    }
    if let mode = configuration.stabilizationMode {
      throw .unsupportedVideoStabilizationMode(
        deviceID: deviceID,
        streamID: streamID,
        mode: mode
      )
    }
    if let mode = configuration.mirroringMode {
      let matches: Bool
      switch mode {
      case .automatic:
        matches = connection.automaticallyAdjustsVideoMirroring
      case .enabled:
        matches =
          !connection.automaticallyAdjustsVideoMirroring
          && connection.isVideoMirrored
      case .disabled:
        matches =
          !connection.automaticallyAdjustsVideoMirroring
          && !connection.isVideoMirrored
      }
      guard matches else {
        throw .unsupportedVideoMirroringMode(
          deviceID: deviceID,
          streamID: streamID,
          mode: mode
        )
      }
    }
  }

  static func rotationAngle(
    for orientation: CaptureVideoOrientation
  ) -> CGFloat {
    switch orientation {
    case .portrait:
      90
    case .portraitUpsideDown:
      270
    case .landscapeRight:
      0
    case .landscapeLeft:
      180
    }
  }
}
