@preconcurrency import AVFoundation
import OpenAVFoundationDriver

enum AppleCameraVideoConnectionBridge {
  static func capabilities()
    throws(CaptureContractError) -> CaptureVideoConnectionCapabilities
  {
    try CaptureVideoConnectionCapabilities(
      supportedRotationAngles: [
        .zero,
        .clockwise90,
        .clockwise180,
        .clockwise270,
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
    if let rotationAngle = configuration.rotationAngle {
      let nativeAngle = CGFloat(rotationAngle.rawValue)
      guard connection.isVideoRotationAngleSupported(nativeAngle) else {
        throw .unsupportedVideoRotationAngle(
          deviceID: deviceID,
          streamID: streamID,
          angle: rotationAngle
        )
      }
      connection.videoRotationAngle = nativeAngle
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
    if let rotationAngle = configuration.rotationAngle {
      let expectedAngle = CGFloat(rotationAngle.rawValue)
      guard connection.videoRotationAngle == expectedAngle else {
        throw .unsupportedVideoRotationAngle(
          deviceID: deviceID,
          streamID: streamID,
          angle: rotationAngle
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
}
