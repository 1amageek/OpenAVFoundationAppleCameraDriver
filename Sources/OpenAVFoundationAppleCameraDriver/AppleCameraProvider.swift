@preconcurrency import AVFoundation
import Foundation
import OpenAVFoundationDriver

public struct AppleCameraProvider:
  CaptureDeviceProvider,
  CaptureDeviceEventProvider
{
  public let driverID: CaptureDriverID

  private let failureHandler: @Sendable (CaptureDriverError) -> Void
  private let descriptorSource:
    @Sendable (CaptureDiscoveryRequest)
      throws(CaptureDriverError) -> [CaptureDeviceDescriptor]
  private let notificationCenter: NotificationCenter
  private let connectedNotification: Notification.Name
  private let disconnectedNotification: Notification.Name

  public init(
    failureHandler:
      @escaping @Sendable (CaptureDriverError) -> Void
  ) throws(CaptureContractError) {
    let resolvedDriverID = try CaptureDriverID(
      "apple.avfoundation.camera"
    )
    driverID = resolvedDriverID
    self.failureHandler = failureHandler
    descriptorSource = {
      (request: CaptureDiscoveryRequest)
        throws(CaptureDriverError) -> [CaptureDeviceDescriptor] in
      try Self.nativeDeviceDescriptors(
        driverID: resolvedDriverID,
        matching: request
      )
    }
    notificationCenter = .default
    connectedNotification =
      AVFoundation.AVCaptureDevice.wasConnectedNotification
    disconnectedNotification =
      AVFoundation.AVCaptureDevice.wasDisconnectedNotification
  }

  init(
    driverID: CaptureDriverID,
    failureHandler:
      @escaping @Sendable (CaptureDriverError) -> Void,
    descriptorSource:
      @escaping @Sendable (CaptureDiscoveryRequest)
        throws(CaptureDriverError) -> [CaptureDeviceDescriptor],
    notificationCenter: NotificationCenter,
    connectedNotification: Notification.Name,
    disconnectedNotification: Notification.Name
  ) {
    self.driverID = driverID
    self.failureHandler = failureHandler
    self.descriptorSource = descriptorSource
    self.notificationCenter = notificationCenter
    self.connectedNotification = connectedNotification
    self.disconnectedNotification = disconnectedNotification
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
    try descriptorSource(request)
  }

  public func deviceEventSubscription(
    matching request: CaptureDiscoveryRequest,
    sink: any CaptureDeviceEventSink
  ) async throws(CaptureDriverError)
    -> any CaptureDeviceEventSubscription
  {
    AppleCameraDeviceEventSubscription(
      driverID: driverID,
      sink: sink,
      failureHandler: failureHandler,
      snapshot: { () throws(CaptureDriverError)
        -> [CaptureDeviceDescriptor] in
        try descriptorSource(request)
      },
      notificationCenter: notificationCenter,
      connectedNotification: connectedNotification,
      disconnectedNotification: disconnectedNotification
    )
  }

  private static func nativeDeviceDescriptors(
    driverID: CaptureDriverID,
    matching request: CaptureDiscoveryRequest
  ) throws(CaptureDriverError) -> [CaptureDeviceDescriptor] {
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
      let descriptor: CaptureDeviceDescriptor
      do {
        descriptor = try factory.snapshot(
          for: device
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
    let snapshot = try AppleCameraSnapshotFactory(
      driverID: driverID
    ).snapshot(for: device)
    let backend: AppleCameraNativeDeviceBackend
    do {
      backend = try AppleCameraNativeDeviceBackend(
        driverID: driverID,
        deviceID: deviceID,
        device: device
      )
    } catch {
      throw .contractViolation(driverID: driverID, error: error)
    }
    return AppleCameraDeviceHandle(
      snapshot: snapshot,
      backend: backend,
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
