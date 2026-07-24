@preconcurrency import AVFoundation
import OpenAVFoundationDriver

public struct AppleCameraProvider: CaptureDeviceProvider {
  public let driverID: CaptureDriverID

  private let failureHandler: @Sendable (CaptureDriverError) -> Void

  public init(
    failureHandler:
      @escaping @Sendable (CaptureDriverError) -> Void
  ) throws(CaptureContractError) {
    driverID = try CaptureDriverID("apple.avfoundation.camera")
    self.failureHandler = failureHandler
  }

  public func authorizationStatus(
    for mediaType: CaptureMediaTypeID
  ) async -> CaptureAuthorizationStatus {
    guard mediaType == .video else {
      return .denied
    }
    return Self.portableAuthorizationStatus(
      AVFoundation.AVCaptureDevice.authorizationStatus(
        for: .video
      )
    )
  }

  public func requestAccess(
    for mediaType: CaptureMediaTypeID
  ) async throws(CaptureDriverError) -> CaptureAuthorizationStatus {
    guard mediaType == .video else {
      throw .authorizationDenied(
        driverID: driverID,
        mediaType: mediaType
      )
    }
    let granted = await AVFoundation.AVCaptureDevice.requestAccess(
      for: .video
    )
    return granted ? .authorized : .denied
  }

  public func devices(
    matching request: CaptureDiscoveryRequest
  ) async throws(CaptureDriverError) -> [CaptureDeviceDescriptor] {
    if let mediaType = request.mediaType, mediaType != .video {
      return []
    }

    let discovery = AVFoundation.AVCaptureDevice.DiscoverySession(
      deviceTypes: [
        .builtInWideAngleCamera,
        .external,
        .continuityCamera,
        .deskViewCamera,
      ],
      mediaType: .video,
      position: .unspecified
    )
    let factory = AppleCameraSnapshotFactory(driverID: driverID)
    var descriptors: [CaptureDeviceDescriptor] = []
    descriptors.reserveCapacity(discovery.devices.count)

    for device in discovery.devices {
      let reference = AppleCaptureDeviceReference(device)
      let descriptor: CaptureDeviceDescriptor
      do {
        descriptor = try factory.snapshot(
          for: reference
        ).descriptor
      } catch CaptureDriverError.unsupportedConfiguration {
        // Discovery returns devices that this provider can open under
        // its declared pixel-buffer contract. An unsupported native
        // camera format remains available to another provider.
        continue
      }
      guard
        request.deviceTypeSelection.includes(
          descriptor.deviceTypeID
        )
      else {
        continue
      }
      guard
        request.position == .unspecified
          || request.position == descriptor.position
      else {
        continue
      }
      descriptors.append(descriptor)
    }
    return descriptors
  }

  public func deviceHandle(
    for deviceID: CaptureDeviceID
  ) async throws(CaptureDriverError) -> any CaptureDeviceHandle {
    guard deviceID.driverID == driverID else {
      throw .deviceNotFound(deviceID)
    }
    guard
      let device = AVFoundation.AVCaptureDevice(
        uniqueID: deviceID.localID
      )
    else {
      throw .deviceNotFound(deviceID)
    }
    let reference = AppleCaptureDeviceReference(device)
    let snapshot = try AppleCameraSnapshotFactory(
      driverID: driverID
    ).snapshot(for: reference)
    return AppleCameraDeviceHandle(
      driverID: driverID,
      reference: reference,
      snapshot: snapshot,
      failureHandler: failureHandler
    )
  }

  private static func portableAuthorizationStatus(
    _ status: AVFoundation.AVAuthorizationStatus
  ) -> CaptureAuthorizationStatus {
    switch status {
    case .notDetermined:
      .notDetermined
    case .restricted:
      .restricted
    case .denied:
      .denied
    case .authorized:
      .authorized
    @unknown default:
      .restricted
    }
  }
}
